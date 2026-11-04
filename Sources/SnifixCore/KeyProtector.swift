import Foundation
import Security
import Crypto

/// Encrypts secrets kept on disk.
public protocol KeyProtector: Sendable {
    func seal(_ plain: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var description: String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Keychain: \(text)"
    }
}

/// AES-256-GCM with a random key that lives in the login keychain, so the encrypted file is useless on its own.
/// macOS asks once after each update of the app whether Snifix may read it.
public struct KeychainKeyProtector: KeyProtector {
    let service: String
    let account: String

    public init(service: String = "Snifix", account: String = "CA key encryption") {
        self.service = service
        self.account = account
    }

    private func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        let key = SymmetricKey(size: .bits256)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Snifix — CA key encryption",
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
        return key
    }

    /// Removes the encryption key (when the CA is replaced, the next one gets a new key too).
    public func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    public func seal(_ plain: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key()).combined else { throw KeychainError(status: errSecParam) }
        return combined
    }

    public func open(_ sealed: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key())
    }
}

/// Password-protected files (saved sessions): PBKDF2-SHA256 → AES-256-GCM.
public enum PasswordSeal {
    static let magic = Data("SNIFIXENC1".utf8)

    public static func isSealed(_ data: Data) -> Bool { data.starts(with: magic) }

    public static func seal(_ plain: Data, password: String) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let iterations: UInt32 = 300_000
        let key = try derive(password, salt: salt, iterations: iterations)
        guard let box = try AES.GCM.seal(plain, using: key).combined else { throw KeychainError(status: errSecParam) }
        var out = magic
        out.append(salt)
        withUnsafeBytes(of: iterations.bigEndian) { out.append(contentsOf: $0) }
        out.append(box)
        return out
    }

    public static func open(_ sealed: Data, password: String) throws -> Data {
        var rest = sealed.dropFirst(magic.count)
        guard rest.count > 20 else { throw KeychainError(status: errSecDecode) }
        let salt = Data(rest.prefix(16)); rest = rest.dropFirst(16)
        let iterations = rest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }; rest = rest.dropFirst(4)
        // A damaged or crafted file must not crash (0) or hang (billions) Snifix
        guard (10_000...5_000_000).contains(iterations) else { throw KeychainError(status: errSecDecode) }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(rest)), using: derive(password, salt: salt, iterations: iterations))
    }

    private static func derive(_ password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        // PBKDF2-HMAC-SHA256, implemented on top of swift-crypto's HMAC
        let pw = SymmetricKey(data: Data(password.utf8))
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: pw))
        var t = u
        for _ in 1..<iterations {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: pw))
            for i in 0..<t.count { t[i] ^= u[i] }
        }
        return SymmetricKey(data: t)
    }
}
