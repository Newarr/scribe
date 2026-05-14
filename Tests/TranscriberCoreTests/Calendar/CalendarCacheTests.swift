import XCTest
@testable import TranscriberCore

final class CalendarCacheTests: XCTestCase {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        title: String,
        startsAt: TimeInterval,
        durationSec: TimeInterval = 1800,
        isEligibleMeetingContext: Bool = true
    ) -> CalendarEvent {
        CalendarEvent(
            title: title,
            startDate: Self.baseDate.addingTimeInterval(startsAt),
            endDate: Self.baseDate.addingTimeInterval(startsAt + durationSec),
            attendees: [],
            isEligibleMeetingContext: isEligibleMeetingContext
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

    func testIneligibleEventsAreIgnoredForOverlapAndClosestEnrichment() {
        let cache = CalendarCache(events: [
            event(title: "All-day holiday", startsAt: -3600, durationSec: 86400, isEligibleMeetingContext: false),
            event(title: "Free focus block", startsAt: 60, isEligibleMeetingContext: false),
            event(title: "Tentative hold", startsAt: -60, isEligibleMeetingContext: false),
            event(title: "Declined sales call", startsAt: -120, isEligibleMeetingContext: false),
            event(title: "Cancelled sync", startsAt: -180, isEligibleMeetingContext: false),
            event(title: "Stale past call", startsAt: -7200, durationSec: 1800, isEligibleMeetingContext: false),
        ])

        XCTAssertNil(cache.eventOverlapping(Self.baseDate), "all-day/free/declined/tentative/cancelled/stale events must not enrich active recognition")
        XCTAssertNil(cache.eventClosestTo(Self.baseDate, within: 15 * 60), "ineligible events near now must not be selected as closest enrichment")
        XCTAssertNil(cache.best(for: Self.baseDate), "calendar-only ineligible context must not produce prompt context")
    }

    func testEligibleEventWinsOverIneligibleCalendarNoise() {
        let cache = CalendarCache(events: [
            event(title: "Free blocker", startsAt: -60, isEligibleMeetingContext: false),
            event(title: "Customer Call", startsAt: -30, isEligibleMeetingContext: true),
            event(title: "Cancelled hold", startsAt: 30, isEligibleMeetingContext: false),
        ])

        XCTAssertEqual(cache.best(for: Self.baseDate)?.title, "Customer Call")
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
