import CommonCrypto
import CryptoKit
import Foundation

/// End-to-end encryption for everything CaptureLens puts in iCloud Drive (settings and capture counts).
///
/// Every file is sealed with AES-256-GCM under one random 256-bit data key. The data key
/// itself is stored in iCloud only in wrapped form — sealed with a key derived from your
/// sync passphrase by PBKDF2-HMAC-SHA256 — so the passphrase never leaves your Macs and
/// Apple's servers only ever hold ciphertext. Changing the passphrase rewraps the data key
/// without re-encrypting any content.
public enum SyncCrypto {
    public static let magic = Data("CLE1".utf8)
    public static let defaultIterations = 600_000

    public enum CryptoError: LocalizedError {
        case wrongPassphrase, notEncrypted, damaged
        public var errorDescription: String? {
            switch self {
            case .wrongPassphrase: "That passphrase doesn't unlock the synced data."
            case .notEncrypted: "The file isn't a CaptureLens encrypted file."
            case .damaged: "The file is damaged or was sealed with a different key."
            }
        }
    }

    /// The wrapped data key, kept beside the synced data as Keyring.json.
    public struct Keyring: Codable, Equatable, Sendable {
        public var version = 1
        public var keyID: String
        public var salt: Data
        public var iterations: Int
        public var wrappedKey: Data
        public var createdAt: Date
    }

    public static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        salt.withUnsafeBytes { saltBytes in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     password.map { Int8(bitPattern: $0) }, password.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &derived, derived.count)
        }
        return SymmetricKey(data: derived)
    }

    /// Makes a fresh data key and wraps it with the passphrase.
    public static func createKeyring(passphrase: String, iterations: Int = defaultIterations) throws -> (Keyring, SymmetricKey) {
        let dataKey = SymmetricKey(size: .bits256)
        let keyring = try wrap(dataKey, passphrase: passphrase, iterations: iterations)
        return (keyring, dataKey)
    }

    public static func wrap(_ dataKey: SymmetricKey, passphrase: String, iterations: Int = defaultIterations) throws -> Keyring {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let wrapping = deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let raw = dataKey.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(raw, using: wrapping).combined!
        return Keyring(keyID: keyID(for: dataKey), salt: salt, iterations: iterations, wrappedKey: sealed, createdAt: Date())
    }

    public static func unwrap(_ keyring: Keyring, passphrase: String) throws -> SymmetricKey {
        let wrapping = deriveKey(passphrase: passphrase, salt: keyring.salt, iterations: keyring.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: keyring.wrappedKey),
              let raw = try? AES.GCM.open(box, using: wrapping) else { throw CryptoError.wrongPassphrase }
        return SymmetricKey(data: raw)
    }

    /// A short public fingerprint of a data key, to notice when another Mac starts over with a new one.
    public static func keyID(for key: SymmetricKey) -> String {
        let digest = key.withUnsafeBytes { SHA256.hash(data: Data("CaptureLens key id".utf8) + Data($0)) }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "CLE1", a flags byte (bit 0: LZFSE-compressed), then AES-GCM nonce, ciphertext and tag.
    public static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        var flags: UInt8 = 0
        var payload = plaintext
        if plaintext.count > 256, let compressed = try? (plaintext as NSData).compressed(using: .lzfse) as Data,
           compressed.count < plaintext.count {
            payload = compressed
            flags |= 1
        }
        let box = try AES.GCM.seal(payload, using: key, authenticating: magic + Data([flags]))
        return magic + Data([flags]) + box.combined!
    }

    public static func open(_ sealed: Data, using key: SymmetricKey) throws -> Data {
        guard sealed.count > magic.count + 1 + 28, sealed.prefix(magic.count) == magic else { throw CryptoError.notEncrypted }
        let flags = sealed[sealed.startIndex + magic.count]
        let body = sealed.dropFirst(magic.count + 1)
        guard let box = try? AES.GCM.SealedBox(combined: body),
              let payload = try? AES.GCM.open(box, using: key, authenticating: magic + Data([flags])) else {
            throw CryptoError.damaged
        }
        if flags & 1 != 0 {
            guard let raw = try? (payload as NSData).decompressed(using: .lzfse) as Data else { throw CryptoError.damaged }
            return raw
        }
        return payload
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
