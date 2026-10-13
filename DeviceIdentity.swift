#if os(macOS)
import AppKit
import IOKit
#else
import UIKit
#endif
import QuartzCore
import Security
#if !os(macOS)
import DeviceCheck
#endif
import CryptoKit

struct DeviceSignals: Codable {
    let hardwareUUID: String?
    let platform: String
    let idfv: String?
    let keychainUUID: String
    let deviceCheckToken: String
    let osVersion: String
    let build: Int
    let appAttestKeyID: String
}

enum IdentityError: LocalizedError {
    case unsupported, keychain(OSStatus), invalidChallenge
    var errorDescription: String? {
        switch self {
        case .unsupported:
            #if os(macOS)
            return "This app build or macOS version is not enabled by the server."
            #else
            return "This device cannot provide the required Apple integrity verification."
            #endif
        case .keychain: return "Secure device storage is unavailable. Unlock your device and retry."
        case .invalidChallenge: return "The server returned an invalid device-verification challenge."
        }
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        var attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrSynchronizable as String: false,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.med.prep") + ".identity", kSecAttrAccount as String: key]
        #if os(macOS)
        attributes[kSecUseDataProtectionKeychain as String] = true
        #endif
        return attributes
    }
    static func read(_ key: String) throws -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw IdentityError.keychain(status) }
        return value
    }
    static func write(_ value: String, key: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var request = query(key)
        attributes.forEach { request[$0.key] = $0.value }
        var status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem { status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary) }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
    }
}

// A fresh server challenge gates every foreground session. No local boolean,
// user-agent marker or embedded shared secret can establish app authenticity.
@MainActor final class DeviceIdentity {
    private(set) var origin: URL?
    private(set) var token: String?
    private(set) var signals: DeviceSignals?
    private var capturePolicy: CapturePolicy?
    private var revision = 0
    private var policyCheckedAt = -Double.infinity
    var policyCurrent: Bool {
        CACurrentMediaTime() - policyCheckedAt < 60 && capturePolicy?.allowsCurrentDevice == true
    }
    var watermark: String { capturePolicy?.watermark ?? "Device verification required" }
    func invalidatePolicy() { revision += 1; capturePolicy = nil; policyCheckedAt = -Double.infinity }
    func refreshPolicy(origin: URL) async throws {
        let requestedRevision = revision
        let data: Data
        do {
            data = try await Network.json(origin.appendingPathComponent(AppConfig.identityPath),
                body: JSONSerialization.data(withJSONObject: ["action": "policy", "platform": AppConfig.platform]),
                token: self.origin == origin ? token : nil)
        } catch {
            if revision != requestedRevision { return }
            throw error
        }
        // Superseded poll responses must not overwrite/reject a freshly verified
        // identity. Full verification independently rechecks policy on the server.
        guard revision == requestedRevision else { return }
        let policy = try JSONDecoder().decode(CapturePolicy.self, from: data)
        guard self.origin == nil || self.origin == origin else { throw IdentityError.invalidChallenge }
        capturePolicy = policy; policyCheckedAt = CACurrentMediaTime()
        guard policy.allowsCurrentDevice else { throw IdentityError.unsupported }
    }
    #if !os(macOS)
    private var attest: DCAppAttestService { DCAppAttestService.shared }
    private var keyTasks: [String: Task<String, Error>] = [:]
    private func key(account: String, replace: Bool = false) async throws -> String {
        if let pending = keyTasks[account] { return try await pending.value }
        if !replace, let saved = try Keychain.read(account) { return saved }
        // A cancelled UI verification must not race another key creation. The
        // shared task completes its one Keychain write even if a caller leaves.
        let pending = Task { @MainActor in
            let generated = try await self.attest.generateKey()
            try Keychain.write(generated, key: account)
            return generated
        }
        keyTasks[account] = pending
        defer { keyTasks[account] = nil }
        return try await pending.value
    }
    #endif
    #if os(macOS)
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
            UUID(uuidString: property) != nil else { return nil }
        return property.lowercased()
    }
    #endif
    struct Challenge: Decodable { let id: String; let nonce: String; let requiresAttestation: Bool }
    struct Verification: Decodable { let sessionToken: String; let capturePolicy: CapturePolicy }
    struct Proof: Encodable {
        let action = "verify"
        let challengeID: String
        let clientData: String
        let attestation: String?
        let assertion: String?
    }
    private func validToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { "0123456789abcdef".utf8.contains($0) }
    }
    func invalidate() { revision += 1; token = nil; origin = nil }
    func verify(origin: URL, mayReplaceInvalidKey: Bool = true, cookieHeader: String? = nil) async throws {
        #if os(macOS)
        try await verifyDeviceKey(origin: origin, cookieHeader: cookieHeader)
        #else
        try await verifyAttested(origin: origin, mayReplaceInvalidKey: mayReplaceInvalidKey, cookieHeader: cookieHeader)
        #endif
    }
    #if !os(macOS)
    private func verifyAttested(origin: URL, mayReplaceInvalidKey: Bool, cookieHeader: String?) async throws {
        try Task.checkCancellation()
        try await refreshPolicy(origin: origin)
        guard attest.isSupported else { throw IdentityError.unsupported }
        guard DCDevice.current.isSupported else { throw IdentityError.unsupported }
        let uuid: String
        if let saved = try Keychain.read("uuid") { uuid = saved }
        else { uuid = UUID().uuidString; try Keychain.write(uuid, key: "uuid") }
        let keyAccount = "attestKey." + AppConfig.attestEnvironment + "." + (origin.host ?? "")
        let key = try await self.key(account: keyAccount)
        try Task.checkCancellation()
        let request = try JSONSerialization.data(withJSONObject: ["action": "challenge", "keyID": key, "platform": AppConfig.platform])
        let challengeData = try await Network.json(origin.appendingPathComponent(AppConfig.identityPath), body: request)
        try Task.checkCancellation()
        let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData)
        guard let nonce = Data(base64Encoded: challenge.nonce), nonce.count == 32,
              validToken(challenge.id) else { throw IdentityError.invalidChallenge }
        let deviceCheck = try await DCDevice.current.generateToken()
        let idfv = UIDevice.current.identifierForVendor?.uuidString
        let hardwareUUID: String? = nil
        try Task.checkCancellation()
        let signals = DeviceSignals(hardwareUUID: hardwareUUID, platform: AppConfig.platform, idfv: idfv,
            keychainUUID: uuid, deviceCheckToken: deviceCheck.base64EncodedString(),
            osVersion: CapturePolicy.osVersion, build: CapturePolicy.build, appAttestKeyID: key)
        // Hash the exact bytes sent; server must validate nonce AND all claimed signals.
        let clientData = try JSONSerialization.data(withJSONObject: [
            "challengeID": challenge.id, "nonce": challenge.nonce,
            "origin": origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "signals": try JSONSerialization.jsonObject(with: JSONEncoder().encode(signals))
        ], options: [.sortedKeys])
        let hash = Data(SHA256.hash(data: clientData))
        let attestation: Data?
        let assertion: Data?
        do {
            if challenge.requiresAttestation {
                attestation = try await attest.attestKey(key, clientDataHash: hash); assertion = nil
            } else {
                attestation = nil; assertion = try await attest.generateAssertion(key, clientDataHash: hash)
            }
        } catch {
            // An interrupted enrollment can also leave an already-attested key
            // unknown to the server. Apple invalid-key/input errors permit one
            // replacement. App Attest keys do not survive reinstall.
            // Replacement creates a NEW server device; never merge via claimed UUID.
            if mayReplaceInvalidKey, let failure = error as? DCError,
                failure.code == .invalidKey || failure.code == .invalidInput {
                try Task.checkCancellation()
                _ = try await self.key(account: keyAccount, replace: true)
                try Task.checkCancellation()
                try await verify(origin: origin, mayReplaceInvalidKey: false, cookieHeader: cookieHeader)
                return
            }
            throw error
        }
        try Task.checkCancellation()
        let proof = Proof(challengeID: challenge.id, clientData: clientData.base64EncodedString(),
                          attestation: attestation?.base64EncodedString(), assertion: assertion?.base64EncodedString())
        let response = try await Network.json(origin.appendingPathComponent(AppConfig.identityPath), body: JSONEncoder().encode(proof), cookieHeader: cookieHeader)
        try Task.checkCancellation()
        let verified = try JSONDecoder().decode(Verification.self, from: response)
        guard validToken(verified.sessionToken), verified.capturePolicy.allowsCurrentDevice else { throw IdentityError.invalidChallenge }
        capturePolicy = verified.capturePolicy; policyCheckedAt = CACurrentMediaTime()
        self.signals = signals; self.origin = origin; token = verified.sessionToken; revision += 1
    }
    #endif
    #if os(macOS)
    // Software P-256 key in the device-only data-protection Keychain. This
    // automatic enrollment proves key possession, not Apple app integrity.
    private func verifyDeviceKey(origin: URL, cookieHeader: String?) async throws {
        try Task.checkCancellation()
        try await refreshPolicy(origin: origin)
        try Task.checkCancellation()
        let account = "approvedP256." + (origin.host ?? "")
        let key: P256.Signing.PrivateKey
        if let saved = try Keychain.read(account) {
            guard let raw = Data(base64Encoded: saved) else { throw IdentityError.invalidChallenge }
            key = try P256.Signing.PrivateKey(rawRepresentation: raw)
        } else {
            key = P256.Signing.PrivateKey()
            try Keychain.write(key.rawRepresentation.base64EncodedString(), key: account)
        }
        let publicKey = key.publicKey.derRepresentation
        let digest = Data(SHA256.hash(data: publicKey))
        let keyID = digest.base64EncodedString()
        let endpoint = origin.appendingPathComponent(AppConfig.identityPath)
        let challengeData = try await Network.json(endpoint, body: JSONSerialization.data(withJSONObject:
            ["action": "mac_device_challenge", "keyID": keyID]))
        try Task.checkCancellation()
        let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData)
        guard validToken(challenge.id), Data(base64Encoded: challenge.nonce)?.count == 32 else { throw IdentityError.invalidChallenge }
        let uuid: String
        if let saved = try Keychain.read("uuid") { uuid = saved }
        else { uuid = UUID().uuidString; try Keychain.write(uuid, key: "uuid") }
        let signals = DeviceSignals(hardwareUUID: Self.hardwareUUID(), platform: "macos", idfv: nil,
            keychainUUID: uuid, deviceCheckToken: "", osVersion: CapturePolicy.osVersion,
            build: CapturePolicy.build, appAttestKeyID: keyID)
        let clientData = try JSONSerialization.data(withJSONObject: ["challengeID": challenge.id,
            "nonce": challenge.nonce, "origin": origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "signals": try JSONSerialization.jsonObject(with: JSONEncoder().encode(signals))], options: [.sortedKeys])
        let signature = try key.signature(for: clientData).derRepresentation
        let body = try JSONSerialization.data(withJSONObject: ["action": "verify", "challengeID": challenge.id,
            "clientData": clientData.base64EncodedString(), "publicKey": publicKey.base64EncodedString(),
            "signature": signature.base64EncodedString()])
        try Task.checkCancellation()
        let response = try await Network.json(endpoint, body: body, cookieHeader: cookieHeader)
        try Task.checkCancellation()
        let verified = try JSONDecoder().decode(Verification.self, from: response)
        guard validToken(verified.sessionToken), verified.capturePolicy.allowsCurrentDevice else { throw IdentityError.invalidChallenge }
        capturePolicy = verified.capturePolicy; policyCheckedAt = CACurrentMediaTime()
        self.signals = signals; self.origin = origin; token = verified.sessionToken; revision += 1
    }
    #endif
}


struct CapturePolicy: Decodable {
    let enabled: Bool
    let reviewedOSVersions: [String]
    let minimumBuild: Int
    let watermark: String?
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    static var build: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }
    var allowsCurrentDevice: Bool { allows(version: Self.osVersion, build: Self.build) }
    func allows(version: String, build: Int) -> Bool {
        enabled && minimumBuild > 0 && build >= minimumBuild && reviewedOSVersions.contains(version)
    }
}
