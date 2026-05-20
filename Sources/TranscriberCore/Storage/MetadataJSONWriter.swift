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
        public let scheduled_start: String?
        public let scheduled_end: String?
        public let actual_start: String
        public let actual_end: String
        public let started_at: String
        public let ended_at: String
        public let organizer: TranscriptPerson?
        public let location: String?
        public let calendar_event_id: String?
        public let joined_late: Bool?
        public let elapsed_at_start_seconds: Int?
        public let attendees: [TranscriptPerson]
        /// Spec line 117 / D2: `succeeded` when the AEC pre-pass
        /// produced a cleaned mic file, `failed` when AEC was attempted
        /// and failed, or absent (nil) when the session predates AEC
        /// integration. Codex rc1-final P1.3: rc1 always writes
        /// "failed" because the AEC backend is research-gated.
        public let aec_status: String?
        public let error_code: String?
        public let error_message: String?
        public let retry_count: Int?
        public let attempt_count: Int?
        public let audio_duration_seconds: Int?
        public let audio_size_bytes: Int?

        public init(
            status: TranscriptStatus,
            context: TranscriptContext,
            audio: String,
            aecStatus: AECStatus? = nil,
            failureDetails: TranscriptFailureDetails? = nil
        ) {
            self.schema = "transcriber/v1"
            self.status = status.rawValue
            self.title = context.title
            self.date = context.date
            self.engine = context.engine
            self.language = context.language
            self.audio = audio
            self.scheduled_start = context.scheduledStart
            self.scheduled_end = context.scheduledEnd
            self.actual_start = context.actualStart
            self.actual_end = context.actualEnd
            self.started_at = context.startedAt
            self.ended_at = context.endedAt
            self.organizer = context.organizer
            self.location = context.location
            self.calendar_event_id = context.calendarEventID
            self.joined_late = context.joinedLate
            self.elapsed_at_start_seconds = context.elapsedAtStartSeconds
            self.attendees = context.attendees
            self.aec_status = aecStatus?.rawValue
            self.error_code = failureDetails?.errorCode
            self.error_message = failureDetails?.errorMessage
            self.retry_count = failureDetails?.retryCount
            self.attempt_count = failureDetails?.attemptCount
            self.audio_duration_seconds = failureDetails?.audioDurationSeconds
            self.audio_size_bytes = failureDetails?.audioSizeBytes
        }
    }

    public static func primaryAudioReference(context: TranscriptContext, preferredAudioPath: String = "") -> String {
        if !preferredAudioPath.isEmpty { return preferredAudioPath }
        return context.audioRelativePaths.first ?? ""
    }

    public static func write(at url: URL, metadata: Metadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }
}
