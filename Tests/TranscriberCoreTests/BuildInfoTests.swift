import XCTest
@testable import TranscriberCore

final class BuildInfoTests: XCTestCase {
    func testVersionIsSemver() {
        let v = BuildInfo.version
        let parts = v.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "version must be semver: MAJOR.MINOR.PATCH")
        for part in parts {
            XCTAssertNotNil(Int(part), "each component must be numeric: \(v)")
        }
    }

    func testNameIsTranscriber() {
        XCTAssertEqual(BuildInfo.appName, "Transcriber")
    }
}
