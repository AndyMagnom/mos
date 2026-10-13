import Foundation
import Security
import CryptoKit

// Pins use Apple's NSPinnedDomains SPKI format. Default trust evaluation must
// also pass; a matching pin never overrides expiry, hostname or CA validation.
enum PinnedTrust {
    static func pins(host: String) -> Set<String> {
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        let domains = ats?["NSPinnedDomains"] as? [String: Any]
        let entry = domains?[host.lowercased()] as? [String: Any]
        let leaves = entry?["NSPinnedLeafIdentities"] as? [[String: String]] ?? []
        return Set(leaves.compactMap { item in
            guard let value = item["SPKI-SHA256-BASE64"], let bytes = Data(base64Encoded: value), bytes.count == 32 else { return nil }
            return value
        })
    }
    static func configured(host: String) -> Bool { pins(host: host).count >= 2 }
    static func accepts(_ challenge: URLAuthenticationChallenge) -> Bool {
        let host = challenge.protectionSpace.host.lowercased()
        guard configured(host: host), let trust = challenge.protectionSpace.serverTrust,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, let spki = subjectPublicKeyInfo(SecCertificateCopyData(leaf) as Data) else { return false }
        return pins(host: host).contains(Data(SHA256.hash(data: spki)).base64EncodedString())
    }
    // Read DER ranges, retaining the original SPKI algorithm/curve encoding.
    // Security.framework has already validated the complete X.509 certificate.
    static func subjectPublicKeyInfo(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        func item(_ start: Int, limit: Int) -> (tag: UInt8, body: Range<Int>, full: Range<Int>)? {
            guard start >= 0, start + 2 <= limit, limit <= bytes.count else { return nil }
            let tag = bytes[start]; var cursor = start + 2; var length = Int(bytes[start + 1])
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, cursor + count <= limit, bytes[cursor] != 0 else { return nil }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[cursor]); cursor += 1 }
                guard length >= 128 else { return nil }
            }
            guard length <= limit - cursor else { return nil }
            return (tag, cursor..<(cursor + length), start..<(cursor + length))
        }
        guard let certificate = item(0, limit: bytes.count), certificate.tag == 0x30,
              certificate.full.upperBound == bytes.count,
              let tbs = item(certificate.body.lowerBound, limit: certificate.body.upperBound), tbs.tag == 0x30 else { return nil }
        var cursor = tbs.body.lowerBound
        if let version = item(cursor, limit: tbs.body.upperBound), version.tag == 0xa0 { cursor = version.full.upperBound }
        for _ in 0..<5 {
            guard let field = item(cursor, limit: tbs.body.upperBound) else { return nil }
            cursor = field.full.upperBound
        }
        guard let spki = item(cursor, limit: tbs.body.upperBound), spki.tag == 0x30 else { return nil }
        return Data(bytes[spki.full])
    }
}
