import AppKit

/// Downloads and installs the latest release from GitHub, then restarts.
///
/// This installs code fetched from the network, so nothing is trusted on the strength of
/// where it came from. Before anything is copied over the running app, the downloaded
/// bundle must:
///
/// 1. pass `codesign --verify --deep --strict`,
/// 2. carry the **same Team ID as the app that is running**, so a valid signature from
///    somebody else is refused, and
/// 3. pass Gatekeeper assessment, which means Apple notarized it.
///
/// A failure at any step aborts the update and leaves the installed app untouched.
enum UpdateController {
    private static let repository: String = {
        #if DEBUG
        // Debug builds only: `CAPTURELENS_UPDATE_REPOSITORY=owner/name` checks another
        // repository's releases, to exercise the download and verification steps.
        if let override = ProcessInfo.processInfo.environment["CAPTURELENS_UPDATE_REPOSITORY"] { return override }
        #endif
        return "smanke-org/CaptureLens"
    }()

    enum UpdateOutcome {
        case upToDate(current: String)
        case failed(String)
    }

    // MARK: - Entry point

    /// - Parameter silent: when true, say nothing unless there is an update to offer.
    ///   Used for the check at launch, where reporting "up to date" or a network hiccup
    ///   every time would just be noise.
    static func checkForUpdates(silent: Bool = false) {
        Task { @MainActor in
            let current = AppInfo.version
            do {
                // No release published yet (or the repository doesn't exist yet) means there
                // is nothing newer: that is "up to date", not a failure.
                guard let release = try await fetchLatestRelease() else {
                    if !silent { present(.upToDate(current: AppInfo.labeledVersion)) }
                    return
                }
                guard isNewer(release.version, than: current) else {
                    if !silent { present(.upToDate(current: AppInfo.labeledVersion)) }
                    return
                }
                // A version the user skipped is not raised again on its own.
                if silent, AppDefaults.store.string(forKey: "skippedUpdateVersion") == release.version {
                    return
                }

                // The launch check never installs. It only records that something is
                // available, and the window surfaces it. Prompting from a background path
                // in a menu bar app is not safe: with no active app to own it, the modal
                // is not reliably shown and runModal() hands back its default button —
                // which silently installed an update nobody agreed to.
                if silent {
                    UpdateAvailability.shared.pending = release.version
                    return
                }

                let choice = confirmInstall(
                    newVersion: release.version,
                    current: current,
                    allowSkip: UpdateAvailability.shared.pending == release.version
                )
                switch choice {
                case .cancel:
                    return
                case .skip:
                    AppDefaults.store.set(release.version, forKey: "skippedUpdateVersion")
                    UpdateAvailability.shared.pending = nil
                    return
                case .install:
                    break
                }

                let stagedApp = try await downloadAndStage(release)
                try verifyCandidate(stagedApp, version: release.version)
                try installAndRelaunch(from: stagedApp)
                // Control does not return: the app is replaced and restarted.
            } catch {
                if silent {
                    // Offline at launch is not worth interrupting anyone over.
                    NSLog("CaptureLens: update check failed: \(error.localizedDescription)")
                } else {
                    present(.failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Release lookup

    struct Release {
        let version: String
        let downloadURL: URL
    }

    static func fetchLatestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API requests without one.
        request.setValue("CaptureLens/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw fail("Could not reach GitHub to check for updates.")
        }
        // A repository with no published releases answers 404, which is not the same
        // thing as being offline and should not be reported as a network problem.
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200 else {
            throw fail("GitHub returned an error (\(http.statusCode)) while checking for updates.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw fail("The release information from GitHub could not be read.")
        }

        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        guard let urlString = dmg?["browser_download_url"] as? String,
              let url = URL(string: urlString), url.scheme == "https" else {
            throw fail("The latest release has no disk image to download.")
        }

        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, downloadURL: url)
    }

    /// Numeric component comparison, so 1.1.10 is correctly newer than 1.1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        // Leading digits of each part, so a stray suffix ("4-beta") still counts as 4.
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Download

    static func downloadAndStage(_ release: Release) async throws -> URL {
        let (downloadedURL, response) = try await URLSession.shared.download(from: release.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw fail("The download failed.")
        }

        return try stage(downloadedURL)
    }

    /// Verifies a downloaded disk image, then copies the app out of it into a staging folder.
    static func stage(_ downloadedURL: URL) throws -> URL {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CaptureLensUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let dmg = staging.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: downloadedURL, to: dmg)
        // Before the disk image is mounted at all: same developer, notarized by Apple.
        try verifyDiskImage(dmg)

        // Mount read-only and without opening a Finder window.
        let mountPoint = staging.appendingPathComponent("mount")
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path])
        guard attach.status == 0 else { throw fail("The downloaded disk image could not be opened.") }
        defer { run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)) ?? []
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw fail("The downloaded disk image does not contain an app.")
        }

        // Copy off the image before it is unmounted.
        let stagedApp = staging.appendingPathComponent(appName)
        try FileManager.default.copyItem(at: mountPoint.appendingPathComponent(appName), to: stagedApp)
        return stagedApp
    }

    // MARK: - Verification

    static func verifySignature(of app: URL) throws {
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else {
            throw fail("The downloaded app's signature is not valid, so it was not installed.")
        }

        guard let downloadedTeam = teamIdentifier(of: app.path) else {
            throw fail("The downloaded app is not signed by an identifiable developer, so it was not installed.")
        }
        guard let runningTeam = teamIdentifier(of: Bundle.main.bundlePath) else {
            throw fail("This copy of the app is unsigned, so an update cannot be verified against it.")
        }
        guard downloadedTeam == runningTeam else {
            throw fail("The downloaded app is signed by a different developer (\(downloadedTeam)), so it was not installed.")
        }

        // Gatekeeper assessment: passes only if Apple notarized the build.
        let assess = run("/usr/sbin/spctl", ["-a", "-t", "exec", app.path])
        guard assess.status == 0 else {
            throw fail("The downloaded app is not notarized by Apple, so it was not installed.")
        }
    }

    /// Checks the downloaded disk image before it is mounted: signed by the same team as this
    /// copy, and notarized by Apple. Mounting an image runs the system's disk-image and
    /// file-system code on whatever was downloaded, so it is not done for an unverified one.
    static func verifyDiskImage(_ dmg: URL) throws {
        guard let runningTeam = teamIdentifier(of: Bundle.main.bundlePath) else {
            throw fail("This copy of the app is unsigned, so an update cannot be verified against it.")
        }
        guard teamIdentifier(of: dmg.path) == runningTeam else {
            throw fail("The downloaded disk image isn't signed by this app's developer, so it was not opened.")
        }
        let assess = run("/usr/sbin/spctl", ["-a", "-t", "open", "--context", "context:primary-signature", dmg.path])
        guard assess.status == 0 else {
            throw fail("The downloaded disk image isn't notarized by Apple, so it was not opened.")
        }
    }

    /// Everything `verifySignature` checks, plus: it is this app (same bundle identifier) and
    /// exactly the version the release announced, which must be newer than this copy. Without
    /// these, any older or different app signed by the same team would pass. Run again right
    /// before a deferred install, because the staged copy could have changed while it waited.
    static func verifyCandidate(_ app: URL, version: String) throws {
        try verifySignature(of: app)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let identifier = info?["CFBundleIdentifier"] as? String, identifier == Bundle.main.bundleIdentifier else {
            throw fail("The download is a different app, so it was not installed.")
        }
        guard let staged = info?["CFBundleShortVersionString"] as? String, staged == version,
              isNewer(staged, than: AppInfo.version) else {
            throw fail("The download isn't the expected newer version, so it was not installed.")
        }
    }

    private static func teamIdentifier(of path: String) -> String? {
        let result = run("/usr/bin/codesign", ["-dvvv", path])
        // codesign writes its description to stderr, which run() folds in.
        for line in result.output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    // MARK: - Install

    /// Hands the swap to a detached shell script, because the app cannot replace and
    /// relaunch itself while it is the one running.
    @MainActor
    static func installAndRelaunch(from stagedApp: URL) throws {
        let destination = Bundle.main.bundlePath
        let staging = stagedApp.deletingLastPathComponent()
        let script = staging.appendingPathComponent("install.sh")
        guard let team = teamIdentifier(of: destination), let identifier = Bundle.main.bundleIdentifier else {
            throw fail("This copy of the app is unsigned, so an update cannot be verified against it.")
        }

        // The bundle is updated *in place* rather than deleted and recreated, so the Login
        // Items registration and privacy approvals keep pointing at the same app.
        //
        // Paths and identifiers arrive as arguments, never spliced into the script's text.
        // The staged copy is checked once more just before it is copied (it sat in a folder
        // other processes of this user can write to), the installed result is checked after,
        // and anything that fails is rolled back from a backup. The download flag is removed
        // only from a result that passed.
        let body = #"""
        #!/bin/sh
        PID="$1"; SRC="$2"; DEST="$3"; REQ="$4"; STAGING="$5"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        if ! /usr/bin/codesign --verify --deep --strict -R "=$REQ" "$SRC" 2>/dev/null; then
          /usr/bin/open "$DEST"; /bin/rm -rf "$STAGING"; exit 1
        fi
        /bin/rm -rf "$DEST.backup"
        /bin/cp -R "$DEST" "$DEST.backup"
        if /usr/bin/rsync -a --delete "$SRC/" "$DEST/" && /usr/bin/codesign --verify --deep --strict -R "=$REQ" "$DEST" 2>/dev/null; then
          /bin/rm -rf "$DEST.backup"
          /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        else
          /usr/bin/rsync -a --delete "$DEST.backup/" "$DEST/"
          /bin/rm -rf "$DEST.backup"
        fi
        /usr/bin/open "$DEST"
        /bin/rm -rf "$STAGING"
        """#
        try body.write(to: script, atomically: true, encoding: .utf8)

        let requirement = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)", stagedApp.path,
                          destination, requirement, staging.path]
        try task.run()

        QuitConfirmation.quitNow()
    }

    // MARK: - Helpers

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "CaptureLens.Update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - UI

    private enum ConfirmChoice: CustomStringConvertible {
        var description: String {
            switch self {
            case .install: "install"
            case .cancel: "cancel"
            case .skip: "skip"
            }
        }

        case install
        case cancel
        case skip
    }

    @MainActor
    private static func confirmInstall(newVersion: String, current: String, allowSkip: Bool) -> ConfirmChoice {
        // An accessory app has no Dock presence, and a modal it puts up cannot reliably
        // take focus — runModal() then returns its default button without ever showing
        // anything. Becoming a regular app for the duration gives the alert something to
        // belong to; the policy is restored either way.
        //
        // Restoring the old policy synchronously does not take: AppKit ignores a
        // .regular -> .accessory transition while the app is still active from the
        // modal, which would leave a menu bar app sitting in the Dock. Doing it on
        // the next runloop turn, once the alert is gone, works.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer {
            DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) }
        }

        let alert = NSAlert()
        alert.messageText = "Update to version \(newVersion)?"
        alert.informativeText = """
        You have \(current). The update will be downloaded, checked, and installed automatically.

        CaptureLens will quit and reopen to finish.
        """
        // Installing takes a deliberate press of "Update and Restart", never a stray key.
        //
        // This app takes keyboard focus when the dialog opens, so a Return the user meant
        // for another app lands here. When "Update and Restart" was the default button,
        // that one keystroke installed an update from a dialog nobody had read (reproduced
        // 2026-09-13). "Not Now" is now first, so it owns Return. "Update and Restart" has
        // no key equivalent, and InstallConsent keeps it disabled until the dialog has been
        // on screen and in front for a moment, and records the press itself.
        alert.addButton(withTitle: "Not Now")
        let install = alert.addButton(withTitle: "Update and Restart")
        install.keyEquivalent = ""
        if allowSkip { alert.addButton(withTitle: "Skip This Version") }
        let consent = InstallConsent(button: install, window: alert.window)
        defer { consent.finish() }
        bringForward(alert)

        let response = alert.runModal()
        NSLog("CaptureLens: update prompt response=\(response.rawValue) installPressed=\(consent.pressed)")
        if consent.pressed { return .install }
        return response == .alertThirdButtonReturn && allowSkip ? .skip : .cancel
    }

    /// Makes the app active with the alert in front, before `runModal()`.
    ///
    /// The check finishes after a network wait, by which time another app is
    /// frontmost. Asking to activate with no window of ours on screen is then
    /// refused, and the alert opened by `runModal()` sits in the background.
    /// That kept "Update and Restart" disabled (InstallConsent waits for the app
    /// to be active) until the user clicked the Dock icon. Ordering the alert's
    /// window front with the request is honored. Reproduced and verified with a
    /// harness on macOS 27: without this, never active; with it, active and key
    /// within 0.25 s.
    @MainActor
    private static func bringForward(_ alert: NSAlert) {
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    /// Makes "Update and Restart" respond only to a deliberate press.
    ///
    /// The button starts disabled. It is enabled only after the dialog has been key and
    /// visible, with the app active, for `delay` without a break, and it is disabled again
    /// the moment any of that stops being true. Key with the app active means it's in front.
    /// (It no longer asks whether the window is unobscured: on macOS 27.2 `occlusionState`
    /// reports this alert as covered while nothing is above it, which left the button
    /// disabled for good.) The press is recorded here rather than
    /// inferred from runModal's return value, so an install requires this button to have
    /// actually been pressed while enabled.
    @MainActor
    private final class InstallConsent: NSObject {
        private let button: NSButton
        private let window: NSWindow
        private let delay: TimeInterval
        private var timer: Timer?
        private var readySince: Date?
        private(set) var pressed = false

        init(button: NSButton, window: NSWindow, delay: TimeInterval = 1.0) {
            self.button = button
            self.window = window
            self.delay = delay
            super.init()
            button.isEnabled = false
            button.target = self
            button.action = #selector(installPressed(_:))
            let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(tick),
                              userInfo: nil, repeats: true)
            // Common modes, so it keeps firing inside runModal's modal run loop.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        @objc private func tick() {
            let ready = NSApp.isActive && window.isVisible && window.isKeyWindow
            if ready {
                let since = readySince ?? Date()
                readySince = since
                button.isEnabled = Date().timeIntervalSince(since) >= delay
            } else {
                readySince = nil
                button.isEnabled = false
            }
        }

        @objc private func installPressed(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            pressed = true
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }

        /// Stops the timer, which otherwise keeps this object alive.
        func finish() {
            timer?.invalidate()
            timer = nil
        }
    }

    @MainActor
    private static func present(_ outcome: UpdateOutcome) {
        let alert = NSAlert()
        switch outcome {
        case .upToDate(let current):
            alert.messageText = "You're up to date"
            alert.informativeText = "Version \(current) is the latest release."
        case .failed(let message):
            alert.messageText = "Update failed"
            alert.informativeText = message
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        bringForward(alert)
        alert.runModal()
    }
}

