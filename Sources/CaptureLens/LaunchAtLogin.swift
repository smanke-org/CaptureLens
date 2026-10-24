import Foundation
import Observation
import ServiceManagement

/// Whether CaptureLens opens when you log in, backed by the system's login-item
/// registration rather than a stored preference.
///
/// The registration is the only truth: it can be switched off in System Settings › General ›
/// Login Items at any time, and SMAppService sends no notification when that happens, so the
/// status is re-read whenever Settings is shown instead of being cached in UserDefaults.
@Observable
@MainActor
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    /// Registered, but switched off in System Settings — only the user can turn it back on.
    var needsApproval: Bool { status == .requiresApproval }

    private init() { refresh() }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func set(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled, status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration needs a signed app in /Applications; from anywhere else it fails.
            lastError = Bundle.main.bundlePath.hasPrefix("/Applications/")
                ? "macOS refused to change the login item: \(error.localizedDescription)"
                : "Move CaptureLens to your Applications folder to open it at login."
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
