import Foundation

/// Where CaptureLens keeps its settings. Normally AppDefaults.store; a Debug build run with
/// `CAPTURELENS_DEFAULTS_SUITE=<name>` uses its own domain instead, so test copies (which share
/// the installed app's bundle ID, and with it its preferences) never touch the real ones.
enum AppDefaults {
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG
        if let suite = suiteName, let defaults = UserDefaults(suiteName: suite) { return defaults }
        #endif
        return .standard
    }()

    static var suiteName: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CAPTURELENS_DEFAULTS_SUITE"]
        #else
        return nil
        #endif
    }
}
