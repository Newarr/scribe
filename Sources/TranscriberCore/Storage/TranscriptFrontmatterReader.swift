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

    /// Codex rc2-audit PRIVACY-1: streaming reader that opens the file
    /// and reads byte-by-byte until the second `---` line. Stops the
    /// stream there — never loads transcript bodies, attendees, or
    /// titles into memory. Returns ONLY (status, attempts) for the
    /// diagnostics aggregate-counts surface; the full Frontmatter
    /// reader stays available for the supervisor's resume path.
    public static func readStatusAndAttemptsStreaming(at url: URL) -> (status: TranscriptStatus, attempts: Int)? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var lineBuffer = Data()
        var lineCount = 0
        var sawOpener = false
        var statusRaw: String?
        var attempts = 0

        let chunkSize = 256
        var byte: UInt8 = 0
        while stream.hasBytesAvailable {
            let n = stream.read(&byte, maxLength: 1)
            if n <= 0 { break }
            if byte == 0x0A {  // newline
                lineCount += 1
                let line = String(data: lineBuffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                lineBuffer.removeAll(keepingCapacity: true)

                if !sawOpener {
                    if line == "---" { sawOpener = true; continue }
                    // Anything before the opening "---" is malformed.
                    return nil
                }
                if line == "---" {
                    // Closing delimiter — distinguish missing status (statusless
                    // success: .complete) from present-but-unrecognized status
                    // (malformed: nil), matching TranscriptStatusReader.
                    if let raw = statusRaw {
                        guard let parsed = TranscriptStatus(rawValue: raw) else { return nil }
                        return (parsed, attempts)
                    }
                    return (.complete, attempts)
                }
                if line.hasPrefix("status:") {
                    statusRaw = String(line.dropFirst("status:".count))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                if line.hasPrefix("attempts:") {
                    let v = String(line.dropFirst("attempts:".count))
                        .trimmingCharacters(in: .whitespaces)
                    attempts = Int(v) ?? 0
                }
            } else {
                lineBuffer.append(byte)
                // Per-line cap: a frontmatter line should be at most a
                // couple hundred bytes. If we're not seeing newlines,
                // bail rather than loading half the file.
                if lineBuffer.count > chunkSize * 4 { return nil }
            }
            // Hard cap on number of lines read: spec frontmatters are
            // ~10-15 lines; 100 is generous and stops us walking the
            // body in the no-closing-delimiter case.
            if lineCount > 100 { return nil }
        }
        return nil
    }

    static func readFromString(_ content: String) -> Frontmatter? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var inFrontmatter = true
        var fields: [String: String] = [:]
        var audioPaths: [String] = []
        var attendees: [TranscriptPerson] = []
        var organizer: TranscriptPerson?
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
                    if item.hasPrefix("  - name:") {
                        let name = value(after: "  - name:", in: item)
                        var email: String?
                        if i + 1 < lines.count, lines[i + 1].hasPrefix("    email:") {
                            email = value(after: "    email:", in: lines[i + 1])
                            i += 1
                        }
                        attendees.append(TranscriptPerson(name: name, email: email))
                        i += 1
                    } else if item.hasPrefix("  - ") {
                        attendees.append(TranscriptPerson(name: value(after: "  - ", in: item)))
                        i += 1
                    } else {
                        break
                    }
                }
                continue
            }
            if trimmed == "organizer:" {
                var name = ""
                var email: String?
                i += 1
                while i < lines.count {
                    let item = lines[i]
                    if item.hasPrefix("  name:") {
                        name = value(after: "  name:", in: item)
                        i += 1
                    } else if item.hasPrefix("  email:") {
                        email = value(after: "  email:", in: item)
                        i += 1
                    } else {
                        break
                    }
                }
                if !name.isEmpty { organizer = TranscriptPerson(name: name, email: email) }
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

        let status: TranscriptStatus
        if let statusRaw = fields["status"] {
            guard let parsed = TranscriptStatus(rawValue: statusRaw) else { return nil }
            status = parsed
        } else {
            status = .complete
        }

        // `audio:` may have been a single inline value (single-track case).
        if audioPaths.isEmpty, let single = fields["audio"], !single.isEmpty {
            audioPaths = [single]
        }

        let context = TranscriptContext(
            title: fields["title"] ?? "(untitled)",
            date: fields["date"] ?? "",
            engine: fields["engine"] ?? "elevenlabs",
            audioRelativePaths: audioPaths,
            scheduledStart: fields["scheduled_start"],
            scheduledEnd: fields["scheduled_end"],
            actualStart: fields["actual_start"],
            actualEnd: fields["actual_end"],
            startedAt: fields["started_at"],
            endedAt: fields["ended_at"],
            organizer: organizer,
            location: fields["location"],
            calendarEventID: fields["calendar_event_id"],
            joinedLate: fields["joined_late"].flatMap(Bool.init),
            elapsedAtStartSeconds: fields["elapsed_at_start_seconds"].flatMap(Int.init),
            attendees: attendees,
            language: fields["language"]
        )
        let attempts = fields["attempts"].flatMap(Int.init) ?? 0
        return Frontmatter(status: status, context: context, attempts: attempts)
    }

    private static func value(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
