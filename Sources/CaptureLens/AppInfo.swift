import AppKit

/// Version details read from the bundle, so the number shown in the menu and in
/// Settings always matches what was actually built rather than a hardcoded copy.
enum AppInfo {
    static let name = "CaptureLens"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// "beta" while CaptureLens is in beta (Info.plist `CaptureLensReleaseStage`). It's shown
    /// after the version but never part of it: the updater compares plain numbers, and copies
    /// already installed would read "1.0.4-beta" as an older version and never update.
    static var stage: String? {
        (Bundle.main.infoDictionary?["CaptureLensReleaseStage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "1.0.4 beta", for people to read.
    static var labeledVersion: String {
        stage.map { "\(version) \($0)" } ?? version
    }

    /// "v1.0.4 beta", or "v1.0.4 beta (12)" when the build number has moved past the
    /// marketing version.
    static var displayVersion: String {
        version == build ? "v\(labeledVersion)" : "v\(labeledVersion) (\(build))"
    }

    /// The About panel, with the beta label.
    @MainActor
    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: labeledVersion, .version: ""])
    }
}
