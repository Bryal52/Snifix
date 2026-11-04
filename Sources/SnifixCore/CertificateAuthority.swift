import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL
import NIOConcurrencyHelpers

/// Root certificate of Snifix and the per-host certificates it signs for HTTPS interception.
public final class CertificateAuthority: @unchecked Sendable {
    public let certificate: Certificate
    public let certificatePEM: String
    public let certificateDER: Data
    private let caKey: P256.Signing.PrivateKey
    private let caSSLCertificate: NIOSSLCertificate
    // One key for every leaf certificate: signing is cheap, generating keys is not needed per host
    private let leafKey = P256.Signing.PrivateKey()
    private let leafSSLKey: NIOSSLPrivateKey
    private let contexts = NIOLockedValueBox<[String: NIOSSLContext]>([:])

    /// Loads the CA from `directory` or creates a new one there.
    /// `name` is used only when a new CA is created; test copies pass their own so phones can tell them apart.
    /// With a `protector` the private key is stored encrypted; an existing plain key file is moved over to it.
    public init(directory: URL, name: String? = nil, protector: KeyProtector? = nil) throws {
        let certURL = directory.appendingPathComponent("snifix-ca.pem")
        let plainKeyURL = directory.appendingPathComponent("snifix-ca-key.pem")
        let sealedKeyURL = directory.appendingPathComponent("snifix-ca-key.sealed")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var storedKey: P256.Signing.PrivateKey?
        if let protector, fm.fileExists(atPath: sealedKeyURL.path) {
            // A key that cannot be unlocked is an error, never a reason to make a new CA: phones trust the old one
            storedKey = try P256.Signing.PrivateKey(rawRepresentation: protector.open(Data(contentsOf: sealedKeyURL)))
        } else if let pem = try? String(contentsOf: plainKeyURL, encoding: .utf8) {
            storedKey = try? P256.Signing.PrivateKey(pemRepresentation: pem)
        }

        if let certPEM = try? String(contentsOf: certURL, encoding: .utf8),
           let cert = try? Certificate(pemEncoded: certPEM),
           let key = storedKey,
           cert.notValidAfter > Date().addingTimeInterval(86400 * 30) {
            certificate = cert
            caKey = key
            if let protector, fm.fileExists(atPath: plainKeyURL.path) {
                try Self.storeSealed(key, protector, to: sealedKeyURL)
                Self.wipe(plainKeyURL)
            }
        } else {
            let key = P256.Signing.PrivateKey()
            let name = try DistinguishedName {
                CommonName(name ?? "Snifix CA (\(Host.current().localizedName ?? "Mac"))")
                OrganizationName("Snifix")
            }
            let now = Date()
            certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: .init(key.publicKey),
                notValidBefore: now.addingTimeInterval(-86400),
                notValidAfter: now.addingTimeInterval(86400 * 365 * 10),
                issuer: name,
                subject: name,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                    Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                    SubjectKeyIdentifier(hash: Certificate.PublicKey(key.publicKey))
                },
                issuerPrivateKey: .init(key)
            )
            caKey = key
            try certificate.serializeAsPEM().pemString.write(to: certURL, atomically: true, encoding: .utf8)
            if let protector {
                try Self.storeSealed(key, protector, to: sealedKeyURL)
                Self.wipe(plainKeyURL)
            } else {
                try Self.writePrivate(Data(key.pemRepresentation.utf8), to: plainKeyURL)
            }
        }
        certificatePEM = try certificate.serializeAsPEM().pemString
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        certificateDER = Data(serializer.serializedBytes)
        caSSLCertificate = try NIOSSLCertificate(bytes: Array(certificateDER), format: .der)
        leafSSLKey = try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)
    }

    /// SHA-256 of the certificate, as iOS and Android show it in the certificate details.
    public var fingerprint: String {
        SHA256.hash(data: certificateDER).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func storeSealed(_ key: P256.Signing.PrivateKey, _ protector: KeyProtector, to url: URL) throws {
        try writePrivate(protector.seal(key.rawRepresentation), to: url)
    }

    /// Creates the file readable by this user only, before any secret is written into it.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Overwrites a plain key file before deleting it.
    private static func wipe(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return }
        try? Data(repeating: 0, count: size).write(to: url)
        try? FileManager.default.removeItem(at: url)
    }

    public var commonName: String {
        let parts = certificate.subject.description.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.first { $0.hasPrefix("CN=") }.map { String($0.dropFirst(3)) } ?? "Snifix CA"
    }

    /// Server-side TLS context presenting a certificate for `host`, cached per host.
    public func serverContext(for host: String, http2: Bool) throws -> NIOSSLContext {
        let key = host.lowercased() + (http2 ? "|h2" : "")
        if let cached = contexts.withLockedValue({ $0[key] }) { return cached }
        let leaf = try makeLeaf(for: host.lowercased())
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(leaf), .certificate(caSSLCertificate)],
            privateKey: .privateKey(leafSSLKey)
        )
        config.applicationProtocols = http2 ? ["h2", "http/1.1"] : ["http/1.1"]
        let context = try NIOSSLContext(configuration: config)
        contexts.withLockedValue { $0[key] = context }
        return context
    }

    private func makeLeaf(for host: String) throws -> NIOSSLCertificate {
        let now = Date()
        let subject = try DistinguishedName { CommonName(host); OrganizationName("Snifix") }
        let san: GeneralName
        if let ip = IPv4Address(host) { san = .ipAddress(ASN1OctetString(contentBytes: ArraySlice(ip.bytes))) }
        else { san = .dnsName(host) }
        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86400),
            // Apple platforms reject TLS server certificates valid for more than 398 days
            notValidAfter: now.addingTimeInterval(86400 * 365),
            issuer: certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([san])
                AuthorityKeyIdentifier(keyIdentifier: try certificate.extensions.subjectKeyIdentifier?.keyIdentifier)
            },
            issuerPrivateKey: .init(caKey)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(leaf)
        return try NIOSSLCertificate(bytes: serializer.serializedBytes, format: .der)
    }
}

private struct IPv4Address {
    let bytes: [UInt8]
    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts { guard let v = UInt8(p) else { return nil }; out.append(v) }
        bytes = out
    }
}
