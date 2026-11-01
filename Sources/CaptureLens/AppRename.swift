import AppKit
import ServiceManagement

/// SnagAnything was called CaptureLens until 1.1.0.
///
/// The updater in CaptureLens 1.0.29 and earlier installs a new version into the bundle that
/// is running, so a copy updated from CaptureLens arrives as `CaptureLens.app`. At its first
/// launch it renames itself to `SnagAnything.app` and reopens from there. The bundle ID stays
/// `com.smanke.CaptureLens`, so its settings, keychain items, iCloud data and Screen Recording
/// permission all carry over.
///
/// A copy installed fresh beside an old `CaptureLens.app` puts the old one in the Trash
/// instead, so there's only one, and only one claims the shortcuts and links.
@MainActor
enum AppRename {
    static let oldBundleName = "CaptureLens.app"
    static let newBundleName = "SnagAnything.app"
    /// Set before reopening, when the login item has to be registered again at the new path.
    private static let reregisterLoginKey = "rename.reregisterLoginItem"

    /// Renames this copy if it's still `CaptureLens.app`. True when it has handed over to the
    /// renamed copy and is quitting, so launch should go no further.
    static func renameIfNeeded() -> Bool {
        #if APPSTORE
        return false
        #else
        #if DEBUG
        // Debug builds only when testing this, with the login item left alone: a test copy
        // would otherwise move the real app's login item onto itself.
        guard ProcessInfo.processInfo.environment["CAPTURELENS_RENAME_TEST"] != nil else { return false }
        let handlesLoginItem = false
        #else
        let handlesLoginItem = true
        #endif
        let bundle = Bundle.main.bundleURL
        guard bundle.lastPathComponent == oldBundleName else {
            if handlesLoginItem { restoreLoginItemIfNeeded() }
            trashOldCopy(besides: bundle)
            #if DEBUG
            // `CAPTURELENS_RENAME_TEST=<file>`: say where this copy runs from, then quit.
            let report = ProcessInfo.processInfo.environment["CAPTURELENS_RENAME_TEST"] ?? ""
            try? "running from \(bundle.path)\n".write(toFile: report, atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            return true
            #else
            return false
            #endif
        }
        let destination = bundle.deletingLastPathComponent().appending(path: newBundleName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            NSLog("SnagAnything: \(destination.path) already exists; staying at \(bundle.path)")
            return false
        }
        // The login item points at this path; take it off before the path changes, and put it
        // back from the renamed copy.
        let wasLoginItem = handlesLoginItem && SMAppService.mainApp.status == .enabled
        if wasLoginItem { try? SMAppService.mainApp.unregister() }
        do {
            try FileManager.default.moveItem(at: bundle, to: destination)
        } catch {
            // No permission to rename in this folder (a standard user in /Applications, say):
            // it keeps working under the old file name.
            NSLog("SnagAnything: couldn't rename \(bundle.path): \(error.localizedDescription)")
            if wasLoginItem { try? SMAppService.mainApp.register() }
            return false
        }
        NSLog("SnagAnything: renamed \(bundle.path) to \(destination.path); reopening")
        if wasLoginItem { AppDefaults.store.set(true, forKey: reregisterLoginKey) }
        AppDefaults.store.synchronize()
        reopen(destination)
        return true
        #endif
    }

    /// Opens the renamed copy once this process has gone, then quits.
    private static func reopen(_ app: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        var open = ["/usr/bin/open"]
        #if DEBUG
        // A test copy hands its test settings on; `open` doesn't pass the environment.
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("CAPTURELENS_") {
            open += ["--env", "\(key)=\(value)"]
        }
        #endif
        task.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; shift 2; "$@""#, "sh",
                          "\(ProcessInfo.processInfo.processIdentifier)", app.path] + open + [app.path]
        do {
            try task.run()
        } catch {
            NSLog("SnagAnything: couldn't reopen \(app.path): \(error.localizedDescription)")
        }
        QuitConfirmation.quitNow()
    }

    private static func restoreLoginItemIfNeeded() {
        guard AppDefaults.store.bool(forKey: reregisterLoginKey) else { return }
        AppDefaults.store.removeObject(forKey: reregisterLoginKey)
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("SnagAnything: couldn't register the login item again: \(error.localizedDescription)")
        }
        LaunchAtLogin.shared.refresh()
    }

    /// An old `CaptureLens.app` (this app, an older version) in the same folder goes to the
    /// Trash, where it can still be put back.
    private static func trashOldCopy(besides bundle: URL) {
        let old = bundle.deletingLastPathComponent().appending(path: oldBundleName)
        guard let info = NSDictionary(contentsOf: old.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              !UpdateController.isNewer(version, than: AppInfo.version) else { return }
        // Not while it's running; it would just come back next time.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.bundleURL?.standardizedFileURL == old.standardizedFileURL }) else { return }
        NSWorkspace.shared.recycle([old]) { _, error in
            NSLog("SnagAnything: old copy \(old.path) to the Trash: \(error?.localizedDescription ?? "done")")
        }
    }
}
