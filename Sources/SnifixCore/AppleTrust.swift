import Foundation
import Security
import NIOCore
import NIOSSL

/// Server certificate check for hosts given as an IP address: BoringSSL skips the name check
/// without a hostname, so the chain and the IP are verified with the system trust instead.
enum AppleTrust {
    static func isIPAddress(_ host: String) -> Bool {
        host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
    }

    static func verify(_ certificates: [NIOSSLCertificate], host: String) -> NIOSSLVerificationResult {
        let sec = certificates.compactMap { c -> SecCertificate? in
            guard let der = try? c.toDERBytes() else { return nil }
            return SecCertificateCreateWithData(nil, Data(der) as CFData)
        }
        guard !sec.isEmpty else { return .failed }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(sec as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { return .failed }
        return SecTrustEvaluateWithError(trust, nil) ? .certificateVerified : .failed
    }

    static func clientHandler(context: NIOSSLContext, host: String) throws -> NIOSSLClientHandler {
        if isIPAddress(host) {
            return try NIOSSLClientHandler(context: context, serverHostname: nil) { certificates, promise in
                promise.succeed(verify(certificates, host: host))
            }
        }
        return try NIOSSLClientHandler(context: context, serverHostname: host)
    }
}
