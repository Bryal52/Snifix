import Foundation
import Security

/// Adds the Snifix root certificate to the login keychain and marks it trusted for the user.
enum CertificateTrust {
    static func secCertificate(_ der: Data) -> SecCertificate? {
        SecCertificateCreateWithData(nil, der as CFData)
    }

    static func isTrusted(_ der: Data) -> Bool {
        guard let cert = secCertificate(der) else { return false }
        var settings: CFArray?
        return SecTrustSettingsCopyTrustSettings(cert, .user, &settings) == errSecSuccess
    }

    /// Shows the system password prompt. Returns an error text or nil on success.
    static func installAndTrust(_ der: Data) -> String? {
        guard let cert = secCertificate(der) else { return "Не удалось прочитать сертификат" }
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            return "Не удалось добавить сертификат в связку ключей (\(status))"
        }
        let trust = SecTrustSettingsSetTrustSettings(cert, .user, nil)
        if trust == errSecSuccess { return nil }
        if trust == errAuthorizationCanceled || trust == errSecAuthFailed { return "Отменено" }
        return "macOS не разрешила доверие сертификату (\(trust))"
    }

    static func remove(_ der: Data) {
        guard let cert = secCertificate(der) else { return }
        SecTrustSettingsRemoveTrustSettings(cert, .user)
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert]
        SecItemDelete(query as CFDictionary)
    }
}
