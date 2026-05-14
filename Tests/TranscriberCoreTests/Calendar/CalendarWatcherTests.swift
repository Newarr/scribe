import XCTest
@testable import TranscriberCore

final class CalendarWatcherTests: XCTestCase {
    func testStartPopulatesCacheFromLookup() async {
        let now = Date()
        let event = CalendarEvent(
            title: "Standup",
            startDate: now,
            endDate: now.addingTimeInterval(1800),
            attendees: []
        )
        let fake = FakeCalendarLookup(scripted: [[event]])
        let watcher = CalendarWatcher(lookup: fake, pollInterval: 60)
        await watcher.start()

        let snapshot = await watcher.currentCache()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events[0].title, "Standup")
        await watcher.stop()
    }

    func testRefreshNowFetchesAgain() async {
        let now = Date()
        let firstEvent = CalendarEvent(title: "First", startDate: now, endDate: now.addingTimeInterval(1800), attendees: [])
        let secondEvent = CalendarEvent(title: "Second", startDate: now, endDate: now.addingTimeInterval(1800), attendees: [])
        let fake = FakeCalendarLookup(scripted: [[firstEvent], [secondEvent]])
        let watcher = CalendarWatcher(lookup: fake, pollInterval: 60)
        await watcher.start()
        let firstCount = await fake.callCount
        XCTAssertEqual(firstCount, 1)

        await watcher.refreshNow()
        let after = await watcher.currentCache()
        XCTAssertEqual(after.events.first?.title, "Second")
        let secondCount = await fake.callCount
        XCTAssertEqual(secondCount, 2)
        await watcher.stop()
    }

    func testStopCancelsPollLoop() async throws {
        let fake = FakeCalendarLookup(scripted: [[], [], []])
        let watcher = CalendarWatcher(lookup: fake, pollInterval: 0.05)
        await watcher.start()

        // Let the poll loop tick a couple times.
        try await Task.sleep(nanoseconds: 200_000_000)
        await watcher.stop()
        let countBefore = await fake.callCount
        // After stop, fake.callCount should not increase.
        try await Task.sleep(nanoseconds: 300_000_000)
        let countAfter = await fake.callCount
        XCTAssertEqual(countBefore, countAfter, "stop() must halt the poll loop")
    }

    func testEventOverlappingReadsCache() async {
        let now = Date()
        let event = CalendarEvent(title: "Mid", startDate: now.addingTimeInterval(-300), endDate: now.addingTimeInterval(300), attendees: [])
        let fake = FakeCalendarLookup(scripted: [[event]])
        let watcher = CalendarWatcher(lookup: fake, pollInterval: 60)
        await watcher.start()

        let result = await watcher.eventOverlapping(now)
        XCTAssertEqual(result?.title, "Mid")
        await watcher.stop()
    }

    func testStartIsIdempotent() async {
        let event = CalendarEvent(title: "Once", startDate: Date(), endDate: Date().addingTimeInterval(60), attendees: [])
        let fake = FakeCalendarLookup(scripted: [[event], [event]])
        let watcher = CalendarWatcher(lookup: fake, pollInterval: 60)
        await watcher.start()
        await watcher.start() // second start cancels + re-fires
        let count = await fake.callCount
        // Both starts trigger a refresh.
        XCTAssertGreaterThanOrEqual(count, 2)
        await watcher.stop()
    }

    func testEventKitLookupSkipsDeclinedTentativeCancelledAndPastEventsByPolicy() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TranscriberCore/Calendar/CalendarLookup.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("ek.endDate <= Date()"))
        XCTAssertTrue(source.contains("ek.status == .canceled || ek.status == .tentative"))
        XCTAssertTrue(source.contains("currentUser.participantStatus == .declined || currentUser.participantStatus == .tentative"))
    }
}

/// Test double for CalendarLookupProtocol. Returns scripted responses in order;
/// repeats the last entry once exhausted. Records call count for assertions.
actor FakeCalendarLookup: CalendarLookupProtocol {
    private var scripted: [[CalendarEvent]]
    private(set) var callCount = 0

    init(scripted: [[CalendarEvent]]) {
        self.scripted = scripted
    }

    func fetchEvents(from windowStart: Date, to windowEnd: Date) async -> [CalendarEvent] {
        callCount += 1
        if scripted.isEmpty { return [] }
        let next = scripted.first ?? []
        if scripted.count > 1 { scripted.removeFirst() }
        return next
    }
}
