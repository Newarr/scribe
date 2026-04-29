import XCTest
@testable import TranscriberCore

final class CalendarCacheTests: XCTestCase {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(title: String, startsAt: TimeInterval, durationSec: TimeInterval = 1800) -> CalendarEvent {
        CalendarEvent(
            title: title,
            startDate: Self.baseDate.addingTimeInterval(startsAt),
            endDate: Self.baseDate.addingTimeInterval(startsAt + durationSec),
            attendees: []
        )
    }

    func testEmptyCacheReturnsNil() {
        let cache = CalendarCache()
        XCTAssertNil(cache.eventOverlapping(Self.baseDate))
        XCTAssertNil(cache.eventClosestTo(Self.baseDate))
    }

    func testOverlappingFindsActiveEvent() {
        let cache = CalendarCache(events: [
            event(title: "Standup", startsAt: 0),
            event(title: "Faris 1:1", startsAt: 1800),
        ])
        let mid = Self.baseDate.addingTimeInterval(900)
        XCTAssertEqual(cache.eventOverlapping(mid)?.title, "Standup")
    }

    func testOverlappingPrefersMostRecentStartOnBackToBackBoundary() {
        let cache = CalendarCache(events: [
            event(title: "Standup", startsAt: 0),
            event(title: "Faris 1:1", startsAt: 1800),
        ])
        // 1800s = exactly the boundary. Both events match (one ends, one starts).
        let boundary = Self.baseDate.addingTimeInterval(1800)
        XCTAssertEqual(cache.eventOverlapping(boundary)?.title, "Faris 1:1",
                       "boundary lookups must prefer the meeting that just started")
    }

    func testClosestToWithinWindow() {
        let cache = CalendarCache(events: [
            event(title: "Faris 1:1", startsAt: 600),  // 10 min from baseDate
            event(title: "Standup", startsAt: 1200),   // 20 min from baseDate
        ])
        let result = cache.eventClosestTo(Self.baseDate, within: 15 * 60)
        XCTAssertEqual(result?.title, "Faris 1:1", "10-min event is closer than 20-min")
    }

    func testClosestToOutsideWindowReturnsNil() {
        let cache = CalendarCache(events: [
            event(title: "Tomorrow", startsAt: 86400),
        ])
        XCTAssertNil(cache.eventClosestTo(Self.baseDate, within: 15 * 60))
    }

    func testBestPrefersOverlapOverClosest() {
        let cache = CalendarCache(events: [
            event(title: "Now", startsAt: 0, durationSec: 1800),
            event(title: "Soon", startsAt: 600), // starts 10 min after baseDate
        ])
        let mid = Self.baseDate.addingTimeInterval(300) // 5 min in, overlap with "Now"
        XCTAssertEqual(cache.best(for: mid)?.title, "Now")
    }

    func testBestFallsBackToClosestWhenNoOverlap() {
        let cache = CalendarCache(events: [
            event(title: "Soon", startsAt: 600),
        ])
        // Lookup at baseDate: no overlap (event starts in 10 min), closest within 15 min is "Soon".
        XCTAssertEqual(cache.best(for: Self.baseDate)?.title, "Soon")
    }
}
