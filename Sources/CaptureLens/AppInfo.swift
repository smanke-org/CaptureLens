import Foundation

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

    /// "v1.0.1", or "v1.0.1 (12)" when the build number has moved past the
    /// marketing version.
    static var displayVersion: String {
        version == build ? "v\(version)" : "v\(version) (\(build))"
    }
}
