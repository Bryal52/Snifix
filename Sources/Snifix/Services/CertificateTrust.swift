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
        guard let cert = secCertificate(der) else { return "Could not read the certificate" }
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            return "Could not add the certificate to the keychain (\(status))"
        }
        // Trusted for TLS only, not for code signing, mail or anything else
        let sslOnly: [[String: Any]] = [[
            kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
            kSecTrustSettingsResult as String: SecTrustSettingsResult.trustRoot.rawValue,
        ]]
        let trust = SecTrustSettingsSetTrustSettings(cert, .user, sslOnly as CFArray)
        if trust == errSecSuccess { return nil }
        if trust == errAuthorizationCanceled || trust == errSecAuthFailed { return "Cancelled" }
        return "macOS did not allow trusting the certificate (\(trust))"
    }

    static func remove(_ der: Data) {
        guard let cert = secCertificate(der) else { return }
        SecTrustSettingsRemoveTrustSettings(cert, .user)
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert]
        SecItemDelete(query as CFDictionary)
    }
}
