import XCTest
@testable import TranscriberCore

final class SessionIDTests: XCTestCase {
    func testFromDateInWarsawTimezone() {
        // 2026-04-29 14:30:00 UTC = 16:30 in CEST (Warsaw)
        let utc = Date(timeIntervalSince1970: 1777473000)
        let id = SessionID(from: utc, timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        XCTAssertEqual(id.slug, "2026-04-29-1630")
    }

    func testFromDateInUTC() {
        let utc = Date(timeIntervalSince1970: 1777473000)
        let id = SessionID(from: utc, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(id.slug, "2026-04-29-1430")
    }

    func testCollisionSuffix() {
        let utc = Date(timeIntervalSince1970: 1777473000)
        let id = SessionID(from: utc, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(id.slugWithSuffix(2), "2026-04-29-1430-2")
        XCTAssertEqual(id.slugWithSuffix(3), "2026-04-29-1430-3")
    }
}
