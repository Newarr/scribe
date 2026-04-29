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

    /// Build a bounded keyterm list to feed to the cloud engine: event title words
    /// (length > 2 to skip "of", "to") plus attendee display names. Spec rule
    /// (lines 105-115): never raw descriptions, attendee emails, meeting URLs,
    /// dial-ins, or passcodes. Title + display names are explicitly allowed.
    ///
    /// All raw tokens pass through `KeytermSanitizer` to strip URLs, emails,
    /// phone numbers, digit runs, and passcode-style labels. Capped at 16
    /// entries to keep the request bounded.
    public var keyterms: [String] {
        var terms: [String] = []
        let titleWords = title
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 2 }
        terms.append(contentsOf: titleWords)
        terms.append(contentsOf: attendees.map(\.name))
        let sanitized = KeytermSanitizer.sanitize(terms)
        // Dedupe preserving order, cap at 16.
        var seen = Set<String>()
        var deduped: [String] = []
        for term in sanitized where seen.insert(term).inserted {
            deduped.append(term)
            if deduped.count >= 16 { break }
        }
        return deduped
    }
}
