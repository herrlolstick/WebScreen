import Foundation
import Network
import Security

/// Browsers only offer WebCodecs (decoding video frame by frame, without buffering)
/// in a *secure context*, i.e. over HTTPS with a trusted certificate. A plain LAN
/// address can't get one – so WebScreen uses local-ip.sh: names like
/// `192-168-178-20.local-ip.sh` resolve to that LAN address, and the service publishes
/// a Let's Encrypt wildcard certificate (including its private key) for them.
///
/// Note: since the key is public, this provides a *secure context*, not secrecy –
/// about the same protection as the plain HTTP stream on a home network.
enum SecureOrigin {
    static let domain = "local-ip.sh"
    private static let certURL = URL(string: "https://local-ip.sh/server.pem")!
    private static let keyURL = URL(string: "https://local-ip.sh/server.key")!
    /// Download a fresh certificate when the cached one expires sooner than this
    private static let renewBefore: TimeInterval = 20 * 24 * 3600

    struct Identity {
        let identity: sec_identity_t
        let expires: Date
    }

    /// `192.168.178.20` → `192-168-178-20.local-ip.sh`
    static func hostname(for ipv4: String) -> String {
        ipv4.replacingOccurrences(of: ".", with: "-") + "." + domain
    }

    /// Loads the cached certificate or downloads a new one if needed.
    static func load() async throws -> Identity {
        let cached = try? identity(pem: Data(contentsOf: cacheFile("server.pem")),
                                   key: Data(contentsOf: cacheFile("server.key")))
        if let cached, cached.expires.timeIntervalSinceNow > renewBefore {
            return cached
        }
        do {
            let (pem, _) = try await URLSession.shared.data(from: certURL)
            let (key, _) = try await URLSession.shared.data(from: keyURL)
            let fresh = try identity(pem: pem, key: key)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try pem.write(to: cacheFile("server.pem"), options: .atomic)
            try key.write(to: cacheFile("server.key"), options: .atomic)
            return fresh
        } catch {
            // Offline? A cached certificate that is still valid is good enough.
            if let cached, cached.expires > Date() { return cached }
            throw error
        }
    }

    // MARK: Building the identity

    private static func identity(pem: Data, key: Data) throws -> Identity {
        guard let pemText = String(data: pem, encoding: .utf8),
              let keyText = String(data: key, encoding: .utf8),
              keyText.contains("PRIVATE KEY") else { throw SecureOriginError.invalidCertificate }

        let certificates = pemBlocks(pemText, label: "CERTIFICATE")
            .compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard let leaf = certificates.first else { throw SecureOriginError.invalidCertificate }

        // Only accept a publicly trusted certificate for exactly this domain
        let policy = SecPolicyCreateSSL(true, ("test." + domain) as CFString)
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust)
        guard let trust, SecTrustEvaluateWithError(trust, nil) else { throw SecureOriginError.untrusted }
        let expires = expiryDate(of: leaf) ?? Date().addingTimeInterval(7 * 24 * 3600)

        let p12 = try makePKCS12(pem: pem, key: key)
        guard #available(macOS 15.0, *) else { throw SecureOriginError.requiresMacOS15 }
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Password,
            kSecImportToMemoryOnly as String: true,
        ]
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let ref = first[kSecImportItemIdentity as String] else {
            throw SecureOriginError.importFailed(status)
        }
        let secIdentity = ref as! SecIdentity // swiftlint:disable:this force_cast
        // Send the intermediates along so every browser can build the chain
        let chain = Array(certificates.dropFirst()) as CFArray
        guard let identity = sec_identity_create_with_certificates(secIdentity, chain) ?? sec_identity_create(secIdentity) else {
            throw SecureOriginError.importFailed(errSecInternalError)
        }
        return Identity(identity: identity, expires: expires)
    }

    private static let p12Password = "webscreen"

    /// Converts PEM certificate + key into PKCS#12 using the system's LibreSSL
    private static func makePKCS12(pem: Data, key: Data) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("webscreen-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pemFile = dir.appendingPathComponent("server.pem")
        let keyFile = dir.appendingPathComponent("server.key")
        let outFile = dir.appendingPathComponent("server.p12")
        try pem.write(to: pemFile)
        try key.write(to: keyFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["pkcs12", "-export", "-in", pemFile.path, "-inkey", keyFile.path,
                             "-out", outFile.path, "-passout", "pass:\(p12Password)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SecureOriginError.importFailed(errSecDecode) }
        return try Data(contentsOf: outFile)
    }

    private static func pemBlocks(_ text: String, label: String) -> [Data] {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        var result: [Data] = []
        var rest = Substring(text)
        while let start = rest.range(of: begin), let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex) {
            let body = rest[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: String(body)) { result.append(data) }
            rest = rest[stop.upperBound...]
        }
        return result
    }

    /// Reads "notAfter" from the certificate
    private static func expiryDate(of certificate: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let number = entry[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebScreen", isDirectory: true)
    }

    private static func cacheFile(_ name: String) -> URL {
        cacheDirectory.appendingPathComponent(name)
    }
}

enum SecureOriginError: LocalizedError {
    case invalidCertificate
    case untrusted
    case requiresMacOS15
    case importFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCertificate: return "The certificate from local-ip.sh could not be read."
        case .untrusted: return "The certificate from local-ip.sh is not trusted."
        case .requiresMacOS15: return "Low-latency mode requires macOS 15 or later."
        case .importFailed(let status): return "The certificate could not be loaded (error \(status))."
        }
    }
}
