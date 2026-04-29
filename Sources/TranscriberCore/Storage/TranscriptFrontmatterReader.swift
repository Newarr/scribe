import Foundation

/// Restores a TranscriptContext + status + attempts count from an on-disk
/// transcript.md. Used by SessionSupervisor on app relaunch so resumed sessions
/// preserve the original title, attendees, language, and retry attempt count
/// instead of reverting to a placeholder context.
///
/// Limitations: line-by-line parser, not a real YAML parser. Trusts that the
/// frontmatter was produced by `TranscriptWriter` (or the matching stub format
/// from `CaptureSession.writeTranscriptStub`). Returns `nil` for malformed
/// input rather than crashing.
public enum TranscriptFrontmatterReader {
    public struct Frontmatter: Sendable {
        public let status: TranscriptStatus
        public let context: TranscriptContext
        /// Number of failed attempts already persisted. 0 for pending / complete /
        /// failed; non-zero only for `retrying` transcripts.
        public let attempts: Int
    }

    public static func read(at url: URL) -> Frontmatter? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return readFromString(content)
    }

    static func readFromString(_ content: String) -> Frontmatter? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var inFrontmatter = true
        var fields: [String: String] = [:]
        var audioPaths: [String] = []
        var attendees: [String] = []
        var i = 1
        var foundEnd = false

        while i < lines.count, inFrontmatter {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                foundEnd = true
                inFrontmatter = false
                break
            }

            // List opener: `audio:` followed by `  - <path>` lines, or `attendees:` similarly.
            if trimmed == "audio:" {
                i += 1
                while i < lines.count {
                    let item = lines[i]
                    if item.hasPrefix("  - ") {
                        audioPaths.append(String(item.dropFirst(4))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                        i += 1
                    } else {
                        break
                    }
                }
                continue
            }
            if trimmed == "attendees:" {
                i += 1
                while i < lines.count {
                    let item = lines[i]
                    if item.hasPrefix("  - ") {
                        attendees.append(String(item.dropFirst(4))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                        i += 1
                    } else {
                        break
                    }
                }
                continue
            }

            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon])
                let value = String(trimmed[trimmed.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                fields[key] = value
            }
            i += 1
        }
        guard foundEnd else { return nil }

        guard let statusRaw = fields["status"],
              let status = TranscriptStatus(rawValue: statusRaw) else { return nil }

        // `audio:` may have been a single inline value (single-track case).
        if audioPaths.isEmpty, let single = fields["audio"], !single.isEmpty {
            audioPaths = [single]
        }

        let context = TranscriptContext(
            title: fields["title"] ?? "(untitled)",
            date: fields["date"] ?? "",
            engine: fields["engine"] ?? "elevenlabs",
            audioRelativePaths: audioPaths,
            startedAt: fields["started_at"] ?? "",
            endedAt: fields["ended_at"] ?? "",
            attendees: attendees,
            language: fields["language"]
        )
        let attempts = fields["attempts"].flatMap(Int.init) ?? 0
        return Frontmatter(status: status, context: context, attempts: attempts)
    }
}
