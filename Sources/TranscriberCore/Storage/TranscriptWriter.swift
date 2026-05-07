import Foundation

public struct TranscriptPerson: Sendable, Codable, Equatable {
    public let name: String
    public let email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

public struct TranscriptContext: Sendable {
    public let title: String
    public let date: String          // YYYY-MM-DD
    public let engine: String        // "elevenlabs" | "cohere"
    public let audioRelativePaths: [String]  // every source track that survives capture
    public let scheduledStart: String?
    public let scheduledEnd: String?
    public let actualStart: String   // ISO8601
    public let actualEnd: String
    public let organizer: TranscriptPerson?
    public let location: String?
    public let calendarEventID: String?
    public let joinedLate: Bool?
    public let elapsedAtStartSeconds: Int?
    public let attendees: [TranscriptPerson]
    public let language: String?

    public var startedAt: String { actualStart }
    public var endedAt: String { actualEnd }

    public init(
        title: String,
        date: String,
        engine: String,
        audioRelativePaths: [String],
        scheduledStart: String? = nil,
        scheduledEnd: String? = nil,
        actualStart: String? = nil,
        actualEnd: String? = nil,
        startedAt: String? = nil,
        endedAt: String? = nil,
        organizer: TranscriptPerson? = nil,
        location: String? = nil,
        calendarEventID: String? = nil,
        joinedLate: Bool? = nil,
        elapsedAtStartSeconds: Int? = nil,
        attendees: [TranscriptPerson],
        language: String?
    ) {
        self.title = title
        self.date = date
        self.engine = engine
        self.audioRelativePaths = audioRelativePaths
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.actualStart = actualStart ?? startedAt ?? ""
        self.actualEnd = actualEnd ?? endedAt ?? ""
        self.organizer = organizer
        self.location = location
        self.calendarEventID = calendarEventID
        self.joinedLate = joinedLate
        self.elapsedAtStartSeconds = elapsedAtStartSeconds
        self.attendees = attendees
        self.language = language
    }
}

public enum TranscriptWriter {
    public static func writePending(at url: URL, context c: TranscriptContext) throws {
        let body = """
        \(frontmatter(status: "pending", context: c))

        # \(c.title)

        > Transcription pending. Audio captured at \(audioReferenceList(c.audioRelativePaths)).
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeComplete(
        at url: URL,
        context c: TranscriptContext,
        utterances: [EngineResponse.Utterance],
        speakerMapping: [String: String]
    ) throws {
        var body = "\(frontmatter(status: nil, context: c))\n\n# \(c.title)\n\n\(metadataBlockquote(c))\n\n"
        if !c.attendees.isEmpty {
            body += "## Attendees\n\n"
            for attendee in c.attendees {
                body += "- \(attendee.name)\n"
            }
            body += "\n"
        }
        body += "## Transcript\n\n"
        for u in utterances {
            let displayName = speakerMapping[u.speaker] ?? u.speaker
            let timestamp = formatHHMMSS(u.startSeconds)
            body += "### [\(timestamp)] \(displayName)\n\n\(u.text)\n\n"
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeFailed(at url: URL, context c: TranscriptContext, errorMessage: String) throws {
        let audioRef = audioReferenceList(c.audioRelativePaths)
        let body = """
        \(frontmatter(status: "failed", context: c))

        # Transcription failed

        Your recording is safe. The audio is saved as \(audioRef) inside this folder.

        This was the transcript for `\(c.title)`.

        ## What you can do

        - **Retry:** Delete this `transcript.md` and relaunch Scribe. The supervisor scan picks it up and tries again.
        - **Use the audio elsewhere:** Drop \(audioRef) into another transcription tool. The recording is a normal mono AAC m4a.
        - **Get help:** Open Scribe → Diagnostics… → Export… and share the JSON file.

        ---

        Engine error: `\(errorMessage)`
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func frontmatter(status: String?, context c: TranscriptContext, attempts: Int? = nil) -> String {
        var lines: [String] = ["---"]
        if let status { lines.append("status: \(status)") }
        lines.append("title: \"\(yamlEscape(c.title))\"")
        lines.append("date: \(c.date)")
        lines.append("engine: \(c.engine)")
        if let lang = c.language { lines.append("language: \(lang)") }
        if c.audioRelativePaths.count == 1 {
            lines.append("audio: \"\(yamlEscape(c.audioRelativePaths[0]))\"")
        } else {
            lines.append("audio:")
            for path in c.audioRelativePaths {
                lines.append("  - \"\(yamlEscape(path))\"")
            }
        }
        if let scheduledStart = c.scheduledStart { lines.append("scheduled_start: \(scheduledStart)") }
        if let scheduledEnd = c.scheduledEnd { lines.append("scheduled_end: \(scheduledEnd)") }
        lines.append("actual_start: \(c.actualStart)")
        lines.append("actual_end: \(c.actualEnd)")
        lines.append("started_at: \(c.actualStart)")
        lines.append("ended_at: \(c.actualEnd)")
        if let organizer = c.organizer {
            appendPerson(organizer, key: "organizer", to: &lines)
        }
        if let location = c.location, !location.isEmpty { lines.append("location: \"\(yamlEscape(location))\"") }
        if let calendarEventID = c.calendarEventID, !calendarEventID.isEmpty { lines.append("calendar_event_id: \"\(yamlEscape(calendarEventID))\"") }
        if let joinedLate = c.joinedLate { lines.append("joined_late: \(joinedLate)") }
        if let elapsedAtStartSeconds = c.elapsedAtStartSeconds { lines.append("elapsed_at_start_seconds: \(elapsedAtStartSeconds)") }
        if !c.attendees.isEmpty {
            lines.append("attendees:")
            for attendee in c.attendees { appendListPerson(attendee, to: &lines) }
        }
        if let attempts { lines.append("attempts: \(attempts)") }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private static func metadataBlockquote(_ c: TranscriptContext) -> String {
        var parts: [String] = ["Engine: \(c.engine)", "Audio: \(audioReferenceList(c.audioRelativePaths))"]
        if let scheduledStart = c.scheduledStart { parts.append("Scheduled: \(scheduledStart)") }
        parts.append("Recorded: \(c.actualStart) → \(c.actualEnd)")
        return parts.map { "> \($0)" }.joined(separator: "\n")
    }

    private static func appendPerson(_ person: TranscriptPerson, key: String, to lines: inout [String]) {
        lines.append("\(key):")
        lines.append("  name: \"\(yamlEscape(person.name))\"")
        if let email = person.email, !email.isEmpty {
            lines.append("  email: \"\(yamlEscape(email))\"")
        }
    }

    private static func appendListPerson(_ person: TranscriptPerson, to lines: inout [String]) {
        lines.append("  - name: \"\(yamlEscape(person.name))\"")
        if let email = person.email, !email.isEmpty {
            lines.append("    email: \"\(yamlEscape(email))\"")
        }
    }

    private static func audioReferenceList(_ paths: [String]) -> String {
        switch paths.count {
        case 0: return "(no audio captured)"
        case 1: return "`\(paths[0])`"
        case 2: return "`\(paths[0])` and `\(paths[1])`"
        default:
            let prefix = paths.dropLast().map { "`\($0)`" }.joined(separator: ", ")
            return "\(prefix), and `\(paths.last!)`"
        }
    }

    private static func formatHHMMSS(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    public static func yamlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }
}
