import XCTest
@testable import TranscriberCore

final class PermissionsServiceTests: XCTestCase {
    func testStatusEnumIsExhaustive() {
        let cases: [PermissionStatus] = [.notDetermined, .denied, .granted]
        XCTAssertEqual(cases.count, 3)
    }
}
