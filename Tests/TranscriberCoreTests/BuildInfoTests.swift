import XCTest
@testable import TranscriberCore

final class BuildInfoTests: XCTestCase {
    func testVersionIsSemver() {
        let v = BuildInfo.version
        // SemVer 2.0: MAJOR.MINOR.PATCH[-prerelease][+build]. Strip
        // both suffixes before validating numeric core parts so
        // versions like "1.0.0-rc1" and "1.0.0+build42" both pass.
        // Codex rc1-final P2.3.
        var core = v
        if let dashIdx = core.firstIndex(of: "-") {
            core = String(core[..<dashIdx])
        }
        if let plusIdx = core.firstIndex(of: "+") {
            core = String(core[..<plusIdx])
        }
        let parts = core.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "version must be semver: MAJOR.MINOR.PATCH (got \(v))")
        for part in parts {
            XCTAssertNotNil(Int(part), "each component must be numeric: \(v)")
        }
    }

    func testNameIsScribe() {
        XCTAssertEqual(BuildInfo.appName, "Scribe")
    }
}
