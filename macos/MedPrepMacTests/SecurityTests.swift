import XCTest
@testable import MedPrepMac

@MainActor final class SecurityTests: XCTestCase {
    func testMacPolicyRequiresExactVersionAndMinimumBuild() throws {
        let data = Data(#"{"enabled":true,"reviewedOSVersions":["27.0.0"],"minimumBuild":1}"#.utf8)
        let policy = try JSONDecoder().decode(CapturePolicy.self, from: data)
        XCTAssertTrue(policy.allows(version: "27.0.0", build: 1))
        XCTAssertFalse(policy.allows(version: "27.0.1", build: 1))
        XCTAssertFalse(policy.allows(version: "27.0.0", build: 0))
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
    func testHardwareSignalIsSeparateFromAttestationKey() throws {
        let signals = DeviceSignals(hardwareUUID: "12345678-1234-1234-1234-123456789012", platform: "macos", idfv: nil,
            keychainUUID: "87654321-1234-1234-1234-123456789012", deviceCheckToken: "", osVersion: "27.0.0", build: 1, appAttestKeyID: "proof-key")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(signals)) as! [String: Any]
        XCTAssertEqual(json["hardwareUUID"] as? String, signals.hardwareUUID)
        XCTAssertEqual(json["appAttestKeyID"] as? String, "proof-key")
        XCTAssertNil(json["idfv"])
    }
}
