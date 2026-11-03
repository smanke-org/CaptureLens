import Foundation

/// Where SnagAnything keeps its settings. Normally AppDefaults.store; a Debug build run with
/// `CAPTURELENS_DEFAULTS_SUITE=<name>` uses its own domain instead, so test copies (which share
/// the installed app's bundle ID, and with it its preferences) never touch the real ones. An
/// agent CLI test copy (`APP_STORE=<folder>`) gets its own domain the same way.
enum AppDefaults {
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG
        if let suite = suiteName, let defaults = UserDefaults(suiteName: suite) { return defaults }
        #endif
        return .standard
    }()

    static var suiteName: String? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        // An agent CLI test copy (APP_STORE) gets settings of its own too.
        if env["CAPTURELENS_DEFAULTS_SUITE"] == nil, AgentSocket.isTestRun { return "com.smanke.CaptureLens.agenttest" }
        return env["CAPTURELENS_DEFAULTS_SUITE"]
        #else
        return nil
        #endif
    }
}
