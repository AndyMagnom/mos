import XCTest
@testable import MedPrepMac

@MainActor final class SecurityTests: XCTestCase {
    func testMacPolicyRequiresExactVersionAndMinimumBuild() throws {
        let data = Data(#"{"enabled":true,"reviewedOSVersions":["26.2.0"],"minimumBuild":1}"#.utf8)
        let policy = try JSONDecoder().decode(CapturePolicy.self, from: data)
        XCTAssertTrue(policy.allows(version: "26.2.0", build: 1))
        XCTAssertFalse(policy.allows(version: "26.2.1", build: 1))
        XCTAssertFalse(policy.allows(version: "26.2.0", build: 0))
    }
    func testRangesRejectWrongOffsetsMalformedTotalsAndOverflow() {
        XCTAssertNotNil(MediaResourceLoader.parseRange("bytes 0-99/1000", requestedOffset: 0, requestedEnd: 99))
        for header in ["bytes 1-99/1000", "bytes 0-100/1000", "bytes 0-99/99", "bytes 0-99/*", "bytes -1-99/1000", "bytes bytes 0-99/1000", "bytes 0-99/9999999999999999999999999"] {
            XCTAssertNil(MediaResourceLoader.parseRange(header, requestedOffset: 0, requestedEnd: 99))
        }
    }
    func testKnownOriginsStillRejectCleartextAndCredentials() {
        let sites = SiteRegistry()
        XCTAssertTrue(sites.allows(URL(string: "https://new.medpreparation.com/course/view.php")!))
        XCTAssertFalse(sites.allows(URL(string: "http://new.medpreparation.com/")!))
        XCTAssertFalse(sites.allows(URL(string: "https://user@new.medpreparation.com/")!))
    }
    func testBuiltInDisplayPolicyRejectsExternalAdditionalMirroredAndUnknownDisplays() {
        let builtIn = MacSecurityGate.DisplayState(builtIn: true, mirrored: false)
        let external = MacSecurityGate.DisplayState(builtIn: false, mirrored: false)
        let mirrored = MacSecurityGate.DisplayState(builtIn: true, mirrored: true)
        XCTAssertTrue(MacSecurityGate.displayAllowed([builtIn], builtInOnly: true))
        for displays in [[], [external], [mirrored], [builtIn, external]] {
            XCTAssertFalse(MacSecurityGate.displayAllowed(displays, builtInOnly: true))
        }
        XCTAssertTrue(MacSecurityGate.displayAllowed([external], builtInOnly: false))
        XCTAssertFalse(MacSecurityGate.displayAllowed([external, external], builtInOnly: false))
    }
    func testGeneratedConstantsDecryptAndRejectInvalidIndex() throws {
        XCTAssertFalse(try R7.value(1).isEmpty)
        XCTAssertEqual(try R7.value(10), "frida")
        XCTAssertThrowsError(try R7.value(-1))
        XCTAssertThrowsError(try R7.value(23))
    }
    func testHardwareSignalIsSeparateFromDeviceSigningKey() throws {
        let signals = DeviceSignals(hardwareUUID: "12345678-1234-1234-1234-123456789012", platform: "macos", idfv: nil,
            keychainUUID: "87654321-1234-1234-1234-123456789012", deviceCheckToken: "", osVersion: "26.2.0", build: 1, appAttestKeyID: "proof-key")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(signals)) as! [String: Any]
        XCTAssertEqual(json["hardwareUUID"] as? String, signals.hardwareUUID)
        XCTAssertEqual(json["appAttestKeyID"] as? String, "proof-key")
        XCTAssertNil(json["idfv"])
    }
}
