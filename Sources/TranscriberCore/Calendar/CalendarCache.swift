import Foundation

/// Snapshot of calendar events the watcher has fetched. The cache is a value
/// type so updates land atomically — readers always see a consistent state.
struct CalendarCache: Sendable, Equatable {
    let events: [CalendarEvent]
    let refreshedAt: Date

    init(events: [CalendarEvent] = [], refreshedAt: Date = Date()) {
        self.events = events
        self.refreshedAt = refreshedAt
    }

    /// Returns the event whose [start, end] range contains `date`. If multiple
    /// events overlap (back-to-back boundaries), prefers the most recently
    /// started one — typical case is a meeting that just started over one
    /// that's wrapping up at the same minute.
    func eventOverlapping(_ date: Date) -> CalendarEvent? {
        let containing = eligibleEvents.filter { $0.startDate <= date && date <= $0.endDate }
        return containing.max(by: { $0.startDate < $1.startDate })
    }

    /// Returns the event whose start is closest to `date`, within `tolerance`
    /// seconds (default ±15 minutes). Used for "I clicked Start while the
    /// meeting was about to begin" cases.
    func eventClosestTo(_ date: Date, within tolerance: TimeInterval = 15 * 60) -> CalendarEvent? {
        let inWindow = eligibleEvents.filter { abs($0.startDate.timeIntervalSince(date)) <= tolerance }
        return inWindow.min(by: { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) })
    }

    /// Best-effort lookup: try overlap first, fall back to closest-within.
    func best(for date: Date, withinTolerance tolerance: TimeInterval = 15 * 60) -> CalendarEvent? {
        eventOverlapping(date) ?? eventClosestTo(date, within: tolerance)
    }

    private var eligibleEvents: [CalendarEvent] {
        var seen = Set<CalendarEvent.OccurrenceIdentity>()
        var deduped: [CalendarEvent] = []
        for event in events where event.isEligibleMeetingContext {
            if let identity = event.occurrenceIdentity {
                guard seen.insert(identity).inserted else { continue }
            }
            deduped.append(event)
        }
        return deduped
    }
}
