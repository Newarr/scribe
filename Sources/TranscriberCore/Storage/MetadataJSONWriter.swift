import Foundation

/// Writes the per-session `metadata.json` — a machine-readable mirror of the
/// transcript frontmatter. Spec lines 285-288: "Agents prefer JSON; humans
/// prefer markdown; both are written so downstream pipelines pick their
/// preferred surface."
///
/// Body utterances live in `transcript.md` and aren't duplicated here — the
/// JSON is metadata only, not a transcript dump.
public enum MetadataJSONWriter {
    public struct Metadata: Codable, Sendable, Equatable {
        public let schema: String
        public let status: String
        public let title: String
        public let date: String
        public let engine: String
        public let language: String?
        public let audio: String
        public let started_at: String
        public let ended_at: String
        public let attendees: [String]
        /// Spec line 117 / D2: `succeeded` when the AEC pre-pass
        /// produced a cleaned mic file, `failed` when AEC was attempted
        /// and failed, or absent (nil) when the session predates AEC
        /// integration. Codex rc1-final P1.3: rc1 always writes
        /// "failed" because the AEC backend is research-gated.
        public let aec_status: String?

        public init(
            status: TranscriptStatus,
            context: TranscriptContext,
            audio: String,
            aecStatus: AECStatus? = nil
        ) {
            self.schema = "transcriber/v1"
            self.status = status.rawValue
            self.title = context.title
            self.date = context.date
            self.engine = context.engine
            self.language = context.language
            self.audio = audio
            self.started_at = context.startedAt
            self.ended_at = context.endedAt
            self.attendees = context.attendees
            self.aec_status = aecStatus?.rawValue
        }
    }

    public static func write(at url: URL, metadata: Metadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }
}
