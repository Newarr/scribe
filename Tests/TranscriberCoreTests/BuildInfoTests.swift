import XCTest
@testable import TranscriberCore

final class BuildInfoTests: XCTestCase {
    func testVersionIsSemver() {
        let v = BuildInfo.version
        // SemVer 2.0: MAJOR.MINOR.PATCH[-prerelease]. Strip the
        // pre-release suffix before validating numeric parts so
        // versions like "1.0.0-rc1" pass.
        let core = v.split(separator: "-", maxSplits: 1).first.map(String.init) ?? v
        let parts = core.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "version must be semver: MAJOR.MINOR.PATCH (got \(v))")
        for part in parts {
            XCTAssertNotNil(Int(part), "each component must be numeric: \(v)")
        }
    }

    func testNameIsTranscriber() {
        XCTAssertEqual(BuildInfo.appName, "Transcriber")
    }
}
