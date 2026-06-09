import EventKit
import XCTest
@testable import TranscriberCore

final class PermissionsServiceTests: XCTestCase {
    func testStatusEnumIsExhaustive() {
        let cases: [PermissionStatus] = [.notDetermined, .denied, .granted]
        XCTAssertEqual(cases.count, 3)
    }

    func testCalendarAuthorizationMappingMatchesPermissionSurfaces() {
        XCTAssertEqual(PermissionsService.mapCalendarAuthorizationStatus(.fullAccess), .granted)
        XCTAssertEqual(PermissionsService.mapCalendarAuthorizationStatus(.authorized), .granted)
        XCTAssertEqual(PermissionsService.mapCalendarAuthorizationStatus(.denied), .denied)
        XCTAssertEqual(PermissionsService.mapCalendarAuthorizationStatus(.restricted), .denied)
        XCTAssertEqual(PermissionsService.mapCalendarAuthorizationStatus(.writeOnly), .denied)
        XCTAssertEqual(PermissionsService.mapCalendarAuthorizationStatus(.notDetermined), .notDetermined)
    }
}
