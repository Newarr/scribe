import Foundation

/// F-6: feeds the recents popover. Walks `outputRoot`, opens each
/// session folder's transcript via the streaming frontmatter reader
/// (PRIVACY-1: never loads bodies), and returns the most recent
/// `limit` entries with the data the popover needs to render rows.
public enum SessionFolderEnumerator {
    public struct Entry: Sendable, Equatable {
        public let directory: URL
        public let transcript: URL
        public let title: String
        public let status: TranscriptStatus
        public let createdAt: Date
        public let durationSeconds: Int?
    }

    /// Returns up to `limit` recent session entries, newest first.
    /// Errors fall back to an empty list — the popover is best-effort
    /// and a malformed folder shouldn't take the menu down with it.
    public static func recents(under root: URL, limit: Int = 5) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        struct Candidate {
            let url: URL
            let modified: Date
        }

        // Filter to directories only and sort by modification time desc.
        var candidates: [Candidate] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { continue }
            let modified = values?.contentModificationDate ?? Date.distantPast
            candidates.append(Candidate(url: url, modified: modified))
        }
        candidates.sort { $0.modified > $1.modified }

        var entries: [Entry] = []
        for candidate in candidates {
            if entries.count >= limit { break }
            let dir = SessionDirectory(url: candidate.url)
            guard fm.fileExists(atPath: dir.transcript.path) else { continue }
            guard let frontmatter = TranscriptFrontmatterReader.read(at: dir.transcript) else {
                continue
            }
            let title = frontmatter.context.title.isEmpty
                ? candidate.url.lastPathComponent
                : frontmatter.context.title
            entries.append(Entry(
                directory: candidate.url,
                transcript: dir.transcript,
                title: title,
                status: frontmatter.status,
                createdAt: candidate.modified,
                durationSeconds: nil // populated by caller if it has the audio metadata
            ))
        }
        return entries
    }
}
