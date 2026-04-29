import XCTest
@testable import TranscriberCore

final class SkipStateTests: XCTestCase {
    func testFreshStateNothingSuppressed() async {
        let s = SkipState()
        let suppressed = await s.isSuppressed("us.zoom.xos")
        XCTAssertFalse(suppressed)
    }

    func testSuppressionWithinTTL() async {
        let s = SkipState()
        let now = Date()
        await s.suppress("us.zoom.xos", for: 60, now: now)
        let stillSuppressed = await s.isSuppressed("us.zoom.xos", now: now.addingTimeInterval(30))
        XCTAssertTrue(stillSuppressed)
    }

    func testSuppressionExpiresAfterTTL() async {
        let s = SkipState()
        let now = Date()
        await s.suppress("us.zoom.xos", for: 60, now: now)
        let expiredCheck = await s.isSuppressed("us.zoom.xos", now: now.addingTimeInterval(120))
        XCTAssertFalse(expiredCheck, "must report not-suppressed after the TTL elapses")
    }

    func testClearRemovesSuppression() async {
        let s = SkipState()
        let now = Date()
        await s.suppress("us.zoom.xos", for: 600, now: now)
        await s.clear("us.zoom.xos")
        let suppressed = await s.isSuppressed("us.zoom.xos", now: now)
        XCTAssertFalse(suppressed)
    }

    func testIndependentSuppressionsByBundleID() async {
        let s = SkipState()
        let now = Date()
        await s.suppress("us.zoom.xos", for: 60, now: now)
        let zoomSuppressed = await s.isSuppressed("us.zoom.xos", now: now)
        let teamsSuppressed = await s.isSuppressed("com.microsoft.teams2", now: now)
        XCTAssertTrue(zoomSuppressed)
        XCTAssertFalse(teamsSuppressed)
    }
}
