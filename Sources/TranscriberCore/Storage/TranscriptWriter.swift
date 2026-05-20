import Foundation

public struct TranscriptPerson: Sendable, Codable, Equatable {
    public let name: String
    public let email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}


public struct TranscriptFailureDetails: Sendable, Equatable {
    public let errorCode: String
    public let errorMessage: String
    public let retryCount: Int
    public let attemptCount: Int
    public let audioDurationSeconds: Int?
    public let audioSizeBytes: Int?

    public init(
        errorCode: String = "transcription_failed",
        errorMessage: String,
        retryCount: Int = 0,
        attemptCount: Int = 1,
        audioDurationSeconds: Int? = nil,
        audioSizeBytes: Int? = nil
    ) {
        self.errorCode = Self.boundedCode(errorCode)
        self.errorMessage = Self.boundedMessage(errorMessage)
        self.retryCount = max(0, retryCount)
        self.attemptCount = max(1, attemptCount)
        self.audioDurationSeconds = audioDurationSeconds
        self.audioSizeBytes = audioSizeBytes
    }

    public static func boundedCode(_ raw: String) -> String {
        let allowed = raw.lowercased().map { ch in
            (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") ? ch : "_"
        }
        let collapsed = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return String((collapsed.isEmpty ? "transcription_failed" : collapsed).prefix(80))
    }

    public static func boundedMessage(_ raw: String) -> String {
        PersistedErrorRedactor.redact(raw)
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

    public static func writeFailed(
        at url: URL,
        context c: TranscriptContext,
        errorMessage: String,
        details providedDetails: TranscriptFailureDetails? = nil
    ) throws {
        let details = providedDetails ?? TranscriptFailureDetails(errorMessage: errorMessage)
        let body = """
        \(frontmatter(status: "failed", context: c, failureDetails: details))

        # Transcription Failed

        \(failureExplanation(context: c, details: details))

        \(engineDisplayName(c.engine)) returned `\(details.errorCode)` after \(details.retryCount) retries. \(details.errorMessage)

        ## What you can do

        \(failureGuidance(context: c))
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func frontmatter(status: String?, context c: TranscriptContext, attempts: Int? = nil, failureDetails: TranscriptFailureDetails? = nil) -> String {
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
        if let failureDetails {
            lines.append("error_code: \"\(yamlEscape(failureDetails.errorCode))\"")
            lines.append("error_message: \"\(yamlEscape(failureDetails.errorMessage))\"")
            lines.append("retry_count: \(failureDetails.retryCount)")
            lines.append("attempt_count: \(failureDetails.attemptCount)")
            lines.append("audio_duration_seconds: \(failureDetails.audioDurationSeconds.map(String.init) ?? "")")
            lines.append("audio_size_bytes: \(failureDetails.audioSizeBytes.map(String.init) ?? "")")
        }
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


    private static func failureExplanation(context c: TranscriptContext, details: TranscriptFailureDetails) -> String {
        let audioRef = audioReferenceList(c.audioRelativePaths)
        let audioSummary = failureAudioSummary(paths: c.audioRelativePaths, duration: details.audioDurationSeconds, size: details.audioSizeBytes)
        if c.audioRelativePaths.isEmpty {
            return "No usable audio was captured for this session, so Scribe cannot retry transcription from saved audio."
        }
        if c.audioRelativePaths == ["audio.m4a"] {
            return "Audio is saved at \(audioRef)\(audioSummary). The recording itself is intact and complete; only transcription failed."
        }
        if c.audioRelativePaths.count == 1 {
            return "Only \(audioRef) was preserved for this session\(audioSummary). Scribe requires both microphone and system audio for retry, and the missing side cannot be reconstructed."
        }
        return "Captured audio streams are preserved at \(audioRef)\(audioSummary), but canonical `audio.m4a` was not created. Scribe can retry only after canonical saved audio exists."
    }

    private static func failureGuidance(context c: TranscriptContext) -> String {
        if c.audioRelativePaths.isEmpty {
            return """
            - Check microphone, System Audio, and output-folder setup before starting a new recording.
            - Keep this transcript as the failure record; there is no saved audio file for Scribe to retry.
            """
        }
        if c.audioRelativePaths == ["audio.m4a"] {
            return """
            - Retry from the Scribe menu bar: click the icon, then `Retry` next to this session.
            - Or transcribe locally: Settings → Engine → Cohere (local), then retry.
            - Or transcribe outside Scribe: open `audio.m4a` in any other tool.
            """
        }
        if c.audioRelativePaths.count == 1 {
            return """
            - Keep the surviving audio file for manual recovery: \(audioReferenceList(c.audioRelativePaths)).
            - Start a new Scribe recording after microphone and System Audio are both available; a normal retry cannot restore the missing side.
            """
        }
        return """
        - Keep the preserved source audio files for manual recovery: \(audioReferenceList(c.audioRelativePaths)).
        - Scribe retry is available only for failed sessions with canonical `audio.m4a`.
        """
    }

    private static func failureAudioSummary(paths: [String], duration: Int?, size: Int?) -> String {
        var parts: [String] = []
        if let size { parts.append(formatBytes(size)) }
        if let duration { parts.append(formatDuration(duration)) }
        guard !parts.isEmpty, !paths.isEmpty else { return "" }
        return " (" + parts.joined(separator: ", ") + ")"
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return "\(bytes / 1_000_000) MB" }
        if bytes >= 1_000 { return "\(bytes / 1_000) KB" }
        return "\(bytes) bytes"
    }

    private static func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d duration", seconds / 60, seconds % 60)
    }

    private static func engineDisplayName(_ engine: String) -> String {
        switch engine {
        case "elevenlabs": return "ElevenLabs"
        case "cohere": return "Cohere"
        default: return "The transcription engine"
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
