import Foundation

public struct TranscriptContext: Sendable {
    public let title: String
    public let date: String          // YYYY-MM-DD
    public let engine: String        // "elevenlabs" | "cohere"
    public let audioRelativePaths: [String]  // every source track that survives capture
    public let startedAt: String     // ISO8601
    public let endedAt: String
    public let attendees: [String]   // wikilink-formatted, e.g. "[[Faris Riaz]]"
    public let language: String?

    public init(title: String, date: String, engine: String, audioRelativePaths: [String],
                startedAt: String, endedAt: String, attendees: [String], language: String?) {
        self.title = title
        self.date = date
        self.engine = engine
        self.audioRelativePaths = audioRelativePaths
        self.startedAt = startedAt
        self.endedAt = endedAt
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
        var body = "\(frontmatter(status: "complete", context: c))\n\n# \(c.title)\n\n## Transcript\n\n"
        for u in utterances {
            let displayName = speakerMapping[u.speaker] ?? u.speaker
            let timestamp = formatMMSS(u.startSeconds)
            body += "**\(displayName)** [\(timestamp)]: \(u.text)\n\n"
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeFailed(at url: URL, context c: TranscriptContext, errorMessage: String) throws {
        let body = """
        \(frontmatter(status: "failed", context: c))

        # Transcription Failed

        Audio was captured and saved as \(audioReferenceList(c.audioRelativePaths)).

        Error: \(errorMessage)
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func frontmatter(status: String, context c: TranscriptContext) -> String {
        var lines: [String] = ["---", "schema: transcriber/v1", "status: \(status)"]
        lines.append("title: \"\(yamlEscape(c.title))\"")
        lines.append("date: \(c.date)")
        lines.append("engine: \(c.engine)")
        if let lang = c.language { lines.append("language: \(lang)") }
        if c.audioRelativePaths.count == 1 {
            lines.append("audio: \(c.audioRelativePaths[0])")
        } else {
            lines.append("audio:")
            for path in c.audioRelativePaths {
                lines.append("  - \(path)")
            }
        }
        lines.append("started_at: \(c.startedAt)")
        lines.append("ended_at: \(c.endedAt)")
        if !c.attendees.isEmpty {
            lines.append("attendees:")
            for a in c.attendees { lines.append("  - \"\(a)\"") }
        }
        lines.append("---")
        return lines.joined(separator: "\n")
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

    private static func formatMMSS(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static func yamlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
