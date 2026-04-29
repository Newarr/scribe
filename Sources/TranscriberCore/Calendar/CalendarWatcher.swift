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

/// Adapts the slice 3 `CalendarLookup` to the protocol. Slice 3's lookup only
/// returned a single event for a single point-in-time; for the watcher we need
/// the full window. Adds a window-spanning fetch that mirrors `eventOverlapping`'s
/// EventKit query.
public struct CalendarLookupAdapter: CalendarLookupProtocol {
    private let lookup: CalendarLookup

    public init(lookup: CalendarLookup = CalendarLookup()) {
        self.lookup = lookup
    }

    public func fetchEvents(from windowStart: Date, to windowEnd: Date) async -> [CalendarEvent] {
        // Sample the window densely (every 5 minutes) and dedupe by start date.
        // Slice 3's CalendarLookup.eventOverlapping returns at most one event
        // per call, so we need multiple probes to surface a 24h window. Slice
        // 6b can replace this with a direct EKEventStore.events(matching:)
        // query that returns the full window in one shot — but that would mean
        // duplicating the EKEventStore wiring outside of CalendarLookup.
        var events: [CalendarEvent] = []
        var seen = Set<Date>()
        let stride: TimeInterval = 5 * 60
        var probe = windowStart
        while probe <= windowEnd {
            if let event = lookup.eventOverlapping(probe), seen.insert(event.startDate).inserted {
                events.append(event)
            }
            probe = probe.addingTimeInterval(stride)
        }
        return events
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

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
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
