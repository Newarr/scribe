import XCTest

@testable import TranscriberCore

final class BuildInfoTests: XCTestCase {
  func testVersionIsSemver() {
    let v = BuildInfo.version
    // SemVer 2.0: MAJOR.MINOR.PATCH[-prerelease][+build].
    // Reject leading-zero numeric core parts, empty identifiers, and
    // leading-zero numeric prerelease identifiers instead of just
    // checking the stripped numeric core.
    let numericIdentifier = #"0|[1-9][0-9]*"#
    let prereleaseIdentifier =
      #"(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"#
    let buildIdentifier = #"[0-9A-Za-z-]+"#
    let semverPattern =
      "^(" + numericIdentifier + ")\\.(" + numericIdentifier + ")\\.("
      + numericIdentifier + ")(-(" + prereleaseIdentifier + ")(\\.("
      + prereleaseIdentifier + "))*)?(\\+(" + buildIdentifier + ")(\\.("
      + buildIdentifier + "))*)?$"
    XCTAssertNotNil(
      v.range(of: semverPattern, options: .regularExpression),
      "version must be strict SemVer 2.0 (got \(v))"
    )
  }

  func testNameIsScribe() {
    XCTAssertEqual(BuildInfo.appName, "Scribe")
  }
}
