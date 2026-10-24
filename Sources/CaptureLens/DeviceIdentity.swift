import CryptoKit
import Foundation
import IOKit
import SystemConfiguration

/// This Mac, as far as sync is concerned: a stable, anonymous ID and the Mac's name.
enum DeviceIdentity {
    /// From the hardware UUID, so it survives reinstalls and is not carried to a new Mac
    /// by Migration Assistant (an ID kept in UserDefaults would be, and two Macs would then
    /// share one file). Hashed, so the hardware identifier never leaves the Mac.
    static let deviceID: String = {
        #if DEBUG
        // Test copies on one Mac pretend to be different Macs.
        if let override = ProcessInfo.processInfo.environment["CAPTURELENS_DEVICE_ID"] { return override }
        #endif
        let source = hardwareUUID() ?? fallbackUUID()
        let digest = SHA256.hash(data: Data("\(source):com.smanke.CaptureLens".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }()

    /// The name in System Settings › General › About. Not `Host.current().localizedName`,
    /// which can block for seconds on DNS.
    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// Only reached if IOKit won't give up the hardware UUID.
    private static func fallbackUUID() -> String {
        let key = "device.fallbackUUID"
        if let existing = AppDefaults.store.string(forKey: key) { return existing }
        let created = UUID().uuidString
        AppDefaults.store.set(created, forKey: key)
        return created
    }
}
