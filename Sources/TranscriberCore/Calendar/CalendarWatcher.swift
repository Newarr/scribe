import Foundation

/// Source of truth for the watcher's data fetch — abstracted as a protocol so
/// tests can inject a fake without dragging EventKit into XCTest.
public protocol CalendarLookupProtocol: Sendable {
    /// Fetch every event whose [start, end] overlaps the [windowStart, windowEnd]
    /// range. Empty array means "no events" — does NOT distinguish from "no
    /// permission"; callers treat both the same per spec
    /// `decision_calendar_enrichment_only` (calendar never blocks).
    func fetchEvents(from windowStart: Date, to windowEnd: Date) async -> [CalendarEvent]
}

/// Adapts `CalendarLookup` to the protocol. Uses the window-fetch method so a
/// 24-hour cache refresh is a single EKEventStore query instead of 291 sampled
/// `eventOverlapping` probes.
public struct CalendarLookupAdapter: CalendarLookupProtocol {
    private let lookup: CalendarLookup

    public init(lookup: CalendarLookup = CalendarLookup()) {
        self.lookup = lookup
    }

    public func fetchEvents(from windowStart: Date, to windowEnd: Date) async -> [CalendarEvent] {
        lookup.fetchEvents(from: windowStart, to: windowEnd)
    }
}

/// Owns the in-memory `CalendarCache`, refreshes it on a timer, and exposes
/// sync lookups so the prompt path doesn't await EventKit. Restarting the poll
/// loop after wake-from-sleep keeps the cache fresh after long lid-closed
/// gaps.
public actor CalendarWatcher {
    public typealias PollInterval = TimeInterval

    private let lookup: CalendarLookupProtocol
    private let pollInterval: PollInterval
    private let windowSpan: (past: TimeInterval, future: TimeInterval)
    private var cache = CalendarCache()
    private var pollTask: Task<Void, Never>?

    public init(
        lookup: CalendarLookupProtocol = CalendarLookupAdapter(),
        pollInterval: PollInterval = 60,
        windowPast: TimeInterval = 15 * 60,
        windowFuture: TimeInterval = 24 * 60 * 60
    ) {
        self.lookup = lookup
        self.pollInterval = pollInterval
        self.windowSpan = (windowPast, windowFuture)
    }

    /// Performs an initial refresh and starts the poll loop. Idempotent —
    /// calling start() while already running re-cancels and re-launches.
    public func start() async {
        pollTask?.cancel()
        await refreshNow()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                await self?.refreshNow()
            }
        }
    }

    /// Cancels the poll loop and awaits its termination. The previous sync
    /// variant returned before the in-flight `refreshNow()` had finished, so
    /// `stop()` could complete and a stale poll iteration would still bump
    /// the lookup callout afterward — visible on slower hardware as a
    /// flaky `testStopCancelsPollLoop`. By awaiting `task.value` here, any
    /// in-progress refresh is allowed to drain before `stop()` returns and
    /// no further polls can happen for this watcher instance.
    public func stop() async {
        let task = pollTask
        pollTask = nil
        task?.cancel()
        await task?.value
    }

    /// Forces an immediate refresh outside the regular cadence. Called on
    /// wake-from-sleep so a multi-hour gap doesn't leave the cache stale.
    public func refreshNow() async {
        let now = Date()
        let windowStart = now.addingTimeInterval(-windowSpan.past)
        let windowEnd = now.addingTimeInterval(windowSpan.future)
        let events = await lookup.fetchEvents(from: windowStart, to: windowEnd)
        cache = CalendarCache(events: events, refreshedAt: now)
        Log.calendar.info("Calendar cache refreshed: count=\(events.count, privacy: .public)")
    }

    /// Sync lookup over the current cache. Returns nil if no event overlaps;
    /// callers degrade gracefully without blocking on EventKit.
    public func eventOverlapping(_ date: Date) -> CalendarEvent? {
        cache.eventOverlapping(date)
    }

    public func best(for date: Date, withinTolerance tolerance: TimeInterval = 15 * 60) -> CalendarEvent? {
        cache.best(for: date, withinTolerance: tolerance)
    }

    /// Test introspection.
    public func currentCache() -> CalendarCache {
        cache
    }
}
