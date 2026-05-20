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
    let firstEvent = CalendarEvent(
      title: "First", startDate: now, endDate: now.addingTimeInterval(1800), attendees: [])
    let secondEvent = CalendarEvent(
      title: "Second", startDate: now, endDate: now.addingTimeInterval(1800), attendees: [])
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
    let event = CalendarEvent(
      title: "Mid", startDate: now.addingTimeInterval(-300), endDate: now.addingTimeInterval(300),
      attendees: [])
    let fake = FakeCalendarLookup(scripted: [[event]])
    let watcher = CalendarWatcher(lookup: fake, pollInterval: 60)
    await watcher.start()

    let result = await watcher.eventOverlapping(now)
    XCTAssertEqual(result?.title, "Mid")
    await watcher.stop()
  }

  func testStartIsIdempotent() async {
    let event = CalendarEvent(
      title: "Once", startDate: Date(), endDate: Date().addingTimeInterval(60), attendees: [])
    let fake = FakeCalendarLookup(scripted: [[event], [event]])
    let watcher = CalendarWatcher(lookup: fake, pollInterval: 60)
    await watcher.start()
    await watcher.start()  // second start cancels + re-fires
    let count = await fake.callCount
    // Both starts trigger a refresh.
    XCTAssertGreaterThanOrEqual(count, 2)
    await watcher.stop()
  }

  func testRestartDoesNotCommitStaleCancelledPollRefresh() async {
    let staleEvent = CalendarEvent(
      title: "Stale",
      startDate: Date(),
      endDate: Date().addingTimeInterval(1800),
      attendees: []
    )
    let freshEvent = CalendarEvent(
      title: "Fresh",
      startDate: Date(),
      endDate: Date().addingTimeInterval(1800),
      attendees: []
    )
    let fake = ControlledCalendarLookup()
    let watcher = CalendarWatcher(
      lookup: fake, pollInterval: 0.01, notificationSource: FakeCalendarChangeNotificationSource())

    let firstStart = Task { await watcher.start() }
    await fake.waitForFetchCount(1)
    await fake.completeFetch(number: 1, with: [staleEvent])
    await firstStart.value

    await fake.waitForFetchCount(2)
    let restart = Task { await watcher.start() }
    await fake.waitForFetchCount(3)
    await fake.completeFetch(number: 3, with: [freshEvent])
    await restart.value

    await fake.completeFetch(number: 2, with: [staleEvent])
    try? await Task.sleep(nanoseconds: 20_000_000)

    let snapshot = await watcher.currentCache()
    XCTAssertEqual(snapshot.events.map(\.title), ["Fresh"])
    await fake.completeAllPending(with: [])
    await watcher.stop()
  }

  func testCalendarChangeNotificationRefreshesAndStopRemovesObserver() async {
    let firstEvent = CalendarEvent(
      title: "Before",
      startDate: Date(),
      endDate: Date().addingTimeInterval(1800),
      attendees: []
    )
    let changedEvent = CalendarEvent(
      title: "After notification",
      startDate: Date(),
      endDate: Date().addingTimeInterval(1800),
      attendees: []
    )
    let fakeLookup = FakeCalendarLookup(scripted: [[firstEvent], [changedEvent], []])
    let fakeNotifications = FakeCalendarChangeNotificationSource()
    let watcher = CalendarWatcher(
      lookup: fakeLookup, pollInterval: 60, notificationSource: fakeNotifications)

    await watcher.start()
    let initialLookupCount = await fakeLookup.callCount
    let initialObserverCount = await fakeNotifications.activeObserverCount
    XCTAssertEqual(initialLookupCount, 1)
    XCTAssertEqual(initialObserverCount, 1)

    await fakeNotifications.postChange()
    await fakeLookup.waitForCallCount(2)
    let changed = await watcher.currentCache()
    XCTAssertEqual(changed.events.map(\.title), ["After notification"])

    await watcher.stop()
    let stoppedObserverCount = await fakeNotifications.activeObserverCount
    XCTAssertEqual(stoppedObserverCount, 0)
    await fakeNotifications.postChange()
    try? await Task.sleep(nanoseconds: 20_000_000)
    let finalLookupCount = await fakeLookup.callCount
    XCTAssertEqual(finalLookupCount, 2)
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
    XCTAssertTrue(
      source.contains(
        "currentUser.participantStatus == .declined || currentUser.participantStatus == .tentative")
    )
  }
}

/// Test double for CalendarLookupProtocol. Returns scripted responses in order;
/// repeats the last entry once exhausted. Records call count for assertions.
actor FakeCalendarLookup: CalendarLookupProtocol {
  private var scripted: [[CalendarEvent]]
  private(set) var callCount = 0
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(scripted: [[CalendarEvent]]) {
    self.scripted = scripted
  }

  func fetchEvents(from windowStart: Date, to windowEnd: Date) async -> [CalendarEvent] {
    callCount += 1
    resumeSatisfiedWaiters()
    if scripted.isEmpty { return [] }
    let next = scripted.first ?? []
    if scripted.count > 1 { scripted.removeFirst() }
    return next
  }

  func waitForCallCount(_ expectedCount: Int) async {
    if callCount >= expectedCount { return }
    await withCheckedContinuation { continuation in
      waiters.append((expectedCount, continuation))
    }
  }

  private func resumeSatisfiedWaiters() {
    let ready = waiters.filter { callCount >= $0.0 }
    waiters.removeAll { callCount >= $0.0 }
    ready.forEach { $0.1.resume() }
  }
}

private actor ControlledCalendarLookup: CalendarLookupProtocol {
  private struct PendingFetch {
    let number: Int
    let continuation: CheckedContinuation<[CalendarEvent], Never>
  }

  private var nextFetchNumber = 0
  private var pending: [Int: PendingFetch] = [:]
  private var fetchCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func fetchEvents(from windowStart: Date, to windowEnd: Date) async -> [CalendarEvent] {
    nextFetchNumber += 1
    let number = nextFetchNumber
    resumeSatisfiedFetchCountWaiters()
    return await withCheckedContinuation { continuation in
      pending[number] = PendingFetch(number: number, continuation: continuation)
    }
  }

  func waitForFetchCount(_ expectedCount: Int) async {
    if nextFetchNumber >= expectedCount { return }
    await withCheckedContinuation { continuation in
      fetchCountWaiters.append((expectedCount, continuation))
    }
  }

  func completeFetch(number: Int, with events: [CalendarEvent]) {
    let fetch = pending.removeValue(forKey: number)
    fetch?.continuation.resume(returning: events)
  }

  func completeAllPending(with events: [CalendarEvent]) {
    let fetches = pending.values
    pending.removeAll()
    fetches.forEach { $0.continuation.resume(returning: events) }
  }

  private func resumeSatisfiedFetchCountWaiters() {
    let ready = fetchCountWaiters.filter { nextFetchNumber >= $0.0 }
    fetchCountWaiters.removeAll { nextFetchNumber >= $0.0 }
    ready.forEach { $0.1.resume() }
  }
}

private actor FakeCalendarChangeNotificationSource: CalendarChangeNotificationSource {
  private var observers: [UUID: @Sendable () -> Void] = [:]

  var activeObserverCount: Int {
    observers.count
  }

  nonisolated func addCalendarChangeObserver(_ handler: @escaping @Sendable () -> Void)
    -> CalendarChangeObserver
  {
    let id = UUID()
    Task { await addObserver(id: id, handler: handler) }
    return FakeCalendarChangeObserver(owner: self, id: id)
  }

  func postChange() {
    for observer in observers.values {
      observer()
    }
  }

  private func addObserver(id: UUID, handler: @escaping @Sendable () -> Void) {
    observers[id] = handler
  }

  func removeObserver(id: UUID) {
    observers[id] = nil
  }
}

private final class FakeCalendarChangeObserver: CalendarChangeObserver, @unchecked Sendable {
  private let lock = NSLock()
  private weak var owner: FakeCalendarChangeNotificationSource?
  private var id: UUID?

  init(owner: FakeCalendarChangeNotificationSource, id: UUID) {
    self.owner = owner
    self.id = id
  }

  func invalidate() {
    lock.lock()
    let owner = owner
    let id = id
    self.id = nil
    lock.unlock()

    if let owner, let id {
      Task { await owner.removeObserver(id: id) }
    }
  }
}
