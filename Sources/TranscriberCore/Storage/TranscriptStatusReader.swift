import Foundation

/// Parses just enough of a `transcript.md` frontmatter to identify status.
/// Avoids pulling in a full YAML parser since the writer's output shape is fixed.
enum TranscriptStatusReader {
    /// Returns the parsed status, or `nil` if the file is missing, malformed,
    /// has no frontmatter, or the status field is unrecognized.
    static func read(at url: URL) -> TranscriptStatus? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return readFromString(content)
    }

    static func readFromString(_ content: String) -> TranscriptStatus? {
        // Frontmatter must start at the first line and be terminated by a second
        // `---` line. Reject anything that doesn't open with `---`.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first, firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        var foundEnd = false
        var statusValue: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { foundEnd = true; break }
            if trimmed.hasPrefix("status:") {
                let v = String(trimmed.dropFirst("status:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                statusValue = v
            }
        }
        guard foundEnd else { return nil }
        guard let raw = statusValue else { return .complete }
        return TranscriptStatus(rawValue: raw)
    }
}
