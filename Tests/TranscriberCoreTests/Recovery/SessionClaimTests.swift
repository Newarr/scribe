import Darwin
import Foundation
import XCTest

@testable import TranscriberCore

final class SessionClaimTests: XCTestCase {
    private func makeClaimURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).claim.json")
    }

    func testClaimExcludesOtherOwnersUntilRelease() throws {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = try XCTUnwrap(SessionClaim.acquire(at: url))
        XCTAssertNil(SessionClaim.acquire(at: url))
        SessionClaim.release(owner)
        let successor = try XCTUnwrap(SessionClaim.acquire(at: url))
        defer { SessionClaim.release(successor) }
        SessionClaim.release(owner)
        XCTAssertNil(SessionClaim.acquire(at: url))
    }

    func testTokenDeinitReleasesOwnership() throws {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let owner = try XCTUnwrap(SessionClaim.acquire(at: url))
            withExtendedLifetime(owner) {
                XCTAssertNil(SessionClaim.acquire(at: url))
            }
        }
        let successor = try XCTUnwrap(SessionClaim.acquire(at: url))
        SessionClaim.release(successor)
    }

    func testWaitingDescriptorAndNewClaimCannotOwnDifferentInodes() throws {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = try XCTUnwrap(SessionClaim.acquire(at: url))
        let contender = open(url.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(contender, 0)
        guard contender >= 0 else { return }
        defer { close(contender) }
        XCTAssertEqual(flock(contender, LOCK_EX | LOCK_NB), -1)
        SessionClaim.release(owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(flock(contender, LOCK_EX | LOCK_NB), 0)
        XCTAssertNil(SessionClaim.acquire(at: url))
    }

    func testAbandonedPayloadDoesNotBlockUnlockedFile() throws {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("old claim payload".utf8).write(to: url)
        let owner = try XCTUnwrap(SessionClaim.acquire(at: url))
        XCTAssertNil(SessionClaim.acquire(at: url))
        SessionClaim.release(owner)
    }
}
