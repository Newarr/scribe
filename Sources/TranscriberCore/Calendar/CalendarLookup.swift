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

    /// Returns the meeting event whose [start, end] range overlaps `date`, or the
    /// closest event that started in the last 15 minutes / will start in the next
    /// 15 minutes. Filters out all-day events (birthdays, OOO, holidays) and events
    /// marked `availability == .free` (reminders, blockers) since those are never
    /// the actual meeting context. nil if no matching event or access is denied.
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
        let candidates = store.events(matching: predicate).filter(Self.isMeetingContext)
        guard !candidates.isEmpty else { return nil }

        let containing = candidates.filter { $0.startDate <= date && date <= $0.endDate }
        let chosen = containing.first
            ?? candidates.min(by: { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) })
        return chosen.map(Self.makeEvent(from:))
    }

    /// True if the EKEvent is plausibly a meeting (timed + busy). All-day entries
    /// like birthdays / holidays / OOO and `.free` blockers are excluded so they
    /// don't hijack the recording's context.
    private static func isMeetingContext(_ ek: EKEvent) -> Bool {
        if ek.isAllDay { return false }
        if ek.availability == .free { return false }
        return true
    }

    private static func makeEvent(from ek: EKEvent) -> CalendarEvent {
        let attendees: [CalendarEvent.Attendee] = (ek.attendees ?? []).compactMap { participant in
            // Spec line 115 forbids attendee emails from leaving the device unless the
            // user explicitly opts in. EKParticipant.url is typically `mailto:`, so if
            // there's no display name we drop the participant rather than fall back
            // to the email. Anonymous attendees just don't get mapped to a speaker.
            guard let name = participant.name, !name.isEmpty else { return nil }
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
