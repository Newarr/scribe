import EventKit
import Foundation

public final class CalendarLookup: Sendable {
    public enum LookupError: Error {
        case accessDenied
        case noEventStore
    }

    public init() {}

    /// Triggers the EKEventStore.requestFullAccessToEvents prompt. Returns the
    /// resulting authorization status. Per spec, missing calendar permission must
    /// not block recording — callers degrade gracefully when this returns .denied.
    public func requestAccess() async -> EKAuthorizationStatus {
        let store = EKEventStore()
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // User declined or system rejected; status reflects it.
        }
        return EKEventStore.authorizationStatus(for: .event)
    }

    /// Returns the calendar event whose [start, end] range overlaps `date`, or the
    /// closest event that started in the last 15 minutes / will start in the next
    /// 15 minutes. nil if no matching event or access is denied.
    public func eventOverlapping(_ date: Date) -> CalendarEvent? {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return nil }

        let store = EKEventStore()
        let windowStart = date.addingTimeInterval(-15 * 60)
        let windowEnd = date.addingTimeInterval(15 * 60)
        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )
        let events = store.events(matching: predicate)
        guard !events.isEmpty else { return nil }

        let containing = events.filter { $0.startDate <= date && date <= $0.endDate }
        let candidate = containing.first
            ?? events.min(by: { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) })
        return candidate.map(Self.makeEvent(from:))
    }

    private static func makeEvent(from ek: EKEvent) -> CalendarEvent {
        let attendees: [CalendarEvent.Attendee] = (ek.attendees ?? []).map { participant in
            let name = participant.name ?? participant.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
            return .init(name: name, isCurrentUser: participant.isCurrentUser)
        }
        return CalendarEvent(
            title: ek.title ?? "(untitled)",
            startDate: ek.startDate,
            endDate: ek.endDate,
            attendees: attendees
        )
    }
}
