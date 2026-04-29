import XCTest
@testable import TranscriberCore

final class RetryPolicyTests: XCTestCase {
    func testCloudScheduleMatchesSpec() {
        let p = RetryPolicy.cloud
        XCTAssertEqual(p.nextDelay(afterFailedAttempts: 0), 60)
        XCTAssertEqual(p.nextDelay(afterFailedAttempts: 1), 300)
        XCTAssertEqual(p.nextDelay(afterFailedAttempts: 2), 1800)
        XCTAssertNil(p.nextDelay(afterFailedAttempts: 3), "policy must be terminal after 3 failures")
        XCTAssertEqual(p.maxAttempts, 4)
    }

    func testCustomDelays() {
        let p = RetryPolicy(delays: [1, 2])
        XCTAssertEqual(p.nextDelay(afterFailedAttempts: 0), 1)
        XCTAssertEqual(p.nextDelay(afterFailedAttempts: 1), 2)
        XCTAssertNil(p.nextDelay(afterFailedAttempts: 2))
    }

    func testNegativeAttemptsReturnNil() {
        XCTAssertNil(RetryPolicy.cloud.nextDelay(afterFailedAttempts: -1))
    }

    func testEmptyDelaysIsImmediatelyTerminal() {
        let p = RetryPolicy(delays: [])
        XCTAssertNil(p.nextDelay(afterFailedAttempts: 0))
        XCTAssertEqual(p.maxAttempts, 1)
    }
}
