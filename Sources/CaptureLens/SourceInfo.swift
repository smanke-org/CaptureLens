import AppKit
import CaptureLensKit

/// Where a capture came from: the app, its window, and, in a browser, the web page.
@MainActor
enum SourceInfo {
    /// The app and window under the middle of `frame` (global Cocoa coordinates), from the
    /// windows on screen when the capture was taken; else the frontmost app.
    static func describe(frame: CGRect?, windows: [ScreenWindow], window picked: ScreenWindow? = nil,
                         display: CGDirectDisplayID?) -> CaptureItem.Source {
        var source = CaptureItem.Source()
        let window = picked ?? frame.flatMap { f in windows.first { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) } }
        if let window, let app = NSRunningApplication(processIdentifier: window.ownerPID) {
            source.appName = app.localizedName ?? window.ownerName
            source.bundleID = app.bundleIdentifier
            source.windowTitle = window.title.flatMap { $0.isEmpty ? nil : $0 }
        } else if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            source.appName = app.localizedName
            source.bundleID = app.bundleIdentifier
        }
        if let display, let screen = NSScreen.screens.first(where: { $0.displayID == display }) {
            source.displayName = screen.localizedName
        }
        return source
    }

    // MARK: Web pages

    /// Browsers CaptureLens can ask for the front page, and how.
    private static let safariFamily: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromeFamily: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
        "com.operasoftware.Opera",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return safariFamily.contains(bundleID) || chromeFamily.contains(bundleID)
    }

    private static let queue = DispatchQueue(label: "CaptureLens.AppleScript")

    /// The address and title of the page in the browser's front window, asked through
    /// AppleScript (macOS asks once for permission to control each browser). Gives up after
    /// two seconds, so a busy browser can't hold up a capture.
    static func webPage(bundleID: String) async -> (url: String, title: String?)? {
        let script: String
        if safariFamily.contains(bundleID) {
            script = """
                tell application id "\(bundleID)"
                    if (count of documents) is 0 then return ""
                    return (URL of front document) & linefeed & (name of front document)
                end tell
                """
        } else if chromeFamily.contains(bundleID) {
            script = """
                tell application id "\(bundleID)"
                    if (count of windows) is 0 then return ""
                    set t to active tab of front window
                    return (URL of t) & linefeed & (title of t)
                end tell
                """
        } else {
            return nil
        }
        let result: String? = await withCheckedContinuation { continuation in
            let gate = Gate(continuation)
            queue.async {
                var error: NSDictionary?
                let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
                if let error { NSLog("CaptureLens: couldn't ask \(bundleID) for its page: \(error[NSAppleScript.errorMessage] ?? error)") }
                gate.resume(output)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { gate.resume(nil) }
        }
        guard let result, !result.isEmpty else { return nil }
        let parts = result.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let url = parts.first, url.hasPrefix("http") || url.hasPrefix("file") else { return nil }
        return (url, parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }

    /// Resumes a continuation once, whichever comes first: the answer or the timeout.
    private final class Gate: @unchecked Sendable {
        private var continuation: CheckedContinuation<String?, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
        func resume(_ value: String?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}
