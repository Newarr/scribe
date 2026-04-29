import Foundation

public struct CalendarEvent: Sendable, Equatable {
    public struct Attendee: Sendable, Equatable {
        public let name: String
        public let isCurrentUser: Bool

        public init(name: String, isCurrentUser: Bool) {
            self.name = name
            self.isCurrentUser = isCurrentUser
        }
    }

    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let attendees: [Attendee]

    public init(title: String, startDate: Date, endDate: Date, attendees: [Attendee]) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.attendees = attendees
    }

    /// Returns the local user's display name (`isCurrentUser == true`) if the event
    /// has one; nil otherwise.
    public var currentUser: String? {
        attendees.first(where: { $0.isCurrentUser })?.name
    }

    /// Returns the first non-current-user attendee. For 1:1 meetings this is the
    /// remote speaker. For group meetings, the caller decides what to do; slice 3
    /// only maps `speaker_1` for 1:1 events.
    public var firstRemoteAttendee: String? {
        attendees.first(where: { !$0.isCurrentUser })?.name
    }

    public var isOneOnOne: Bool {
        attendees.count == 2 && attendees.contains(where: { $0.isCurrentUser })
    }
}
