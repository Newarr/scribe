import Darwin
import Foundation
import XCTest
@testable import TranscriberCore

final class SessionClaimTests: XCTestCase {

    private func makeClaimURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).claim.json")
    }

    // MARK: acquire

    func testAcquireOnFreshDirectoryReturnsToken() {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let token = SessionClaim.acquire(at: url)
        XCTAssertNotNil(token)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSecondAcquireWhileFirstAliveReturnsNil() {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SessionClaim.acquire(at: url)
        XCTAssertNotNil(first)

        let second = SessionClaim.acquire(at: url)
        XCTAssertNil(second, "live claim must block second worker")
    }

    func testReleaseAllowsReclaim() {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let token = SessionClaim.acquire(at: url)
        XCTAssertNotNil(token)
        SessionClaim.release(token!)

        let second = SessionClaim.acquire(at: url)
        XCTAssertNotNil(second, "release must clear the claim")
    }

    // MARK: stale detection

    func testStaleHeartbeatTriggersReclaim() throws {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Manually write an "old" claim (heartbeat 60s ago) for the
        // current process. The current-PID is alive, the boot is the
        // current boot — but the heartbeat lapsed.
        let stale = SessionClaim.Payload(
            pid: getpid(),
            bootTime: SessionClaim.currentBootTime(),
            startedAt: Date().addingTimeInterval(-300),
            heartbeatAt: Date().addingTimeInterval(-60)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stale).write(to: url)

        XCTAssertTrue(SessionClaim.isStale(stale, currentBootTime: SessionClaim.currentBootTime(),
                                            now: Date(), staleAfter: 30))

        let token = SessionClaim.acquire(at: url)
        XCTAssertNotNil(token, "stale heartbeat must be reclaimable")
    }

    func testBootTimeMismatchTriggersReclaim() throws {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Old claim from a hypothetical previous boot. PID may now be
        // recycled to a different process — the boot mismatch protects
        // against PID reuse (codex pass 2 P1 #6).
        let oldBoot = Int64(0)  // Definitely not current boot.
        let stale = SessionClaim.Payload(
            pid: getpid(),
            bootTime: oldBoot,
            startedAt: Date().addingTimeInterval(-3600),
            heartbeatAt: Date()  // Within heartbeat window, but boot is wrong.
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stale).write(to: url)

        XCTAssertTrue(SessionClaim.isStale(stale, currentBootTime: SessionClaim.currentBootTime()))

        let token = SessionClaim.acquire(at: url)
        XCTAssertNotNil(token, "previous-boot claim must be reclaimable even if PID is alive on this boot")
    }

    func testDeadProcessTriggersReclaim() {
        // PID 1 (launchd) is always alive; using a guaranteed-not-to-exist
        // PID via Int32.max emulates the dead-process case for isStale().
        let stale = SessionClaim.Payload(
            pid: Int32.max,
            bootTime: SessionClaim.currentBootTime(),
            startedAt: Date(),
            heartbeatAt: Date()
        )
        XCTAssertTrue(SessionClaim.isStale(stale, currentBootTime: SessionClaim.currentBootTime()),
                      "PID belongs to no live process; claim must be stale")
    }

    // MARK: heartbeat

    func testHeartbeatUpdatesTimestamp() throws {
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let token = SessionClaim.acquire(at: url)!
        let before = try readHeartbeat(at: url)

        // Hop forward in time.
        let after = Date().addingTimeInterval(1)
        SessionClaim.heartbeat(token, now: after)

        let updated = try readHeartbeat(at: url)
        XCTAssertGreaterThan(updated.timeIntervalSinceReferenceDate, before.timeIntervalSinceReferenceDate)
    }

    func testReleaseFromForeignTokenIsNoOp() throws {
        // Defensive: if some other process's reclaim has already replaced
        // the file, our release must NOT delete the new owner's claim.
        let url = makeClaimURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let token = SessionClaim.acquire(at: url)!

        // Simulate another process having reclaimed the file (different
        // PID + boot). Our release should leave the foreign claim intact.
        let foreign = SessionClaim.Payload(
            pid: 999_999,
            bootTime: SessionClaim.currentBootTime() + 1,  // mismatched
            startedAt: Date(),
            heartbeatAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(foreign).write(to: url)

        SessionClaim.release(token)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "release must not delete a claim that has been reassigned")
    }

    // MARK: helpers

    private func readHeartbeat(at url: URL) throws -> Date {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(SessionClaim.Payload.self, from: data)
        return payload.heartbeatAt
    }
}
