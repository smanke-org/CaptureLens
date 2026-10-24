import AppKit
import LocalAuthentication
import Observation

/// Keeps the library window closed to anyone but you: Touch ID or your Mac's password opens
/// it, and it locks again after a while away, when the Mac sleeps or when the screen locks.
/// Capturing keeps working while it's locked. A setting of this Mac only, never synced.
@Observable
@MainActor
final class LibraryLock {
    static let shared = LibraryLock()

    private(set) var isEnabled: Bool
    /// Minutes the library can sit unused before it locks; 0 locks it as soon as its window closes.
    var lockAfter: Int {
        didSet { AppDefaults.store.set(lockAfter, forKey: Keys.after) }
    }
    private(set) var isLocked: Bool
    private(set) var lastError: String?

    @ObservationIgnored private var lastUsed = Date()
    @ObservationIgnored private var timer: Timer?

    private enum Keys {
        static let enabled = "lock.enabled"
        static let after = "lock.afterMinutes"
    }

    private init() {
        let enabled = AppDefaults.store.bool(forKey: Keys.enabled)
        isEnabled = enabled
        isLocked = enabled
        lockAfter = AppDefaults.store.object(forKey: Keys.after) as? Int ?? 5
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LibraryLock.shared.lockNow() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LibraryLock.shared.lockNow() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { LibraryLock.shared.checkIdle() }
        }
    }

    /// Whether this Mac can ask for Touch ID or the password at all.
    var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "your password"
    }

    /// Turning the lock on or off needs you to prove it's you.
    func setEnabled(_ on: Bool) async {
        guard on != isEnabled else { return }
        guard await authenticate(reason: on ? "turn on the library lock" : "turn off the library lock") else { return }
        isEnabled = on
        isLocked = false
        lastUsed = Date()
        AppDefaults.store.set(on, forKey: Keys.enabled)
    }

    func unlock() async {
        guard isLocked else { return }
        if await authenticate(reason: "open your capture library") {
            isLocked = false
            lastUsed = Date()
        }
    }

    func lockNow() {
        guard isEnabled, !isLocked else { return }
        isLocked = true
    }

    /// The library window was used just now.
    func touch() { lastUsed = Date() }

    func libraryClosed() {
        if lockAfter == 0 { lockNow() } else { lastUsed = Date() }
    }

    private func checkIdle() {
        guard isEnabled, !isLocked, lockAfter > 0 else { return }
        if LibraryWindow.shared.isKey { lastUsed = Date(); return }
        if Date().timeIntervalSince(lastUsed) > Double(lockAfter) * 60 { lockNow() }
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = error?.localizedDescription ?? "This Mac can't check who you are."
            return false
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            lastError = nil
            return ok
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
