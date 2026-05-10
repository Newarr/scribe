import Foundation

/// Production entry point for an explicit user retry of a terminal failed
/// session. Unlike supervisor recovery, this intentionally bypasses the normal
/// failed-session skip after validating that the existing session directory and
/// saved `audio.m4a` are present, then constructs a worker in terminal-retry
/// mode so artifacts are updated in place.
public enum FailedSessionRetryCoordinator {
    public enum RetryError: Error, Equatable, Sendable {
        case sessionDirectoryMissing
        case savedAudioMissing
        case transcriptMissingOrNotFailed
        case missingEngineProvenance
        case localSetupRequired
    }

    public typealias EngineFactory = @Sendable (EngineMode) -> TranscriptionEngine

    public static func makeWorker(
        forSessionDirectory sessionURL: URL,
        engineFactory: EngineFactory,
        keepRawStreams: Bool = false,
        localModelStatus: LocalModelCacheStatus = .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: CohereMLXBackend.defaultModelCacheRoot, diskUsageBytes: 0)),
        sleep: @escaping TranscriptionWorker.Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) throws -> TranscriptionWorker {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RetryError.sessionDirectoryMissing
        }
        let dir = SessionDirectory(url: sessionURL)
        let audioURL = sessionURL.appendingPathComponent("audio.m4a")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw RetryError.savedAudioMissing
        }
        guard let frontmatter = TranscriptFrontmatterReader.read(at: dir.transcript), frontmatter.status == .failed else {
            throw RetryError.transcriptMissingOrNotFailed
        }
        let provenance = RecoveryEngineProvenance.resolve(
            sessionEngineIdentifier: frontmatter.context.engine,
            localModelStatus: localModelStatus
        )
        guard let engineMode = provenance.engineMode else {
            switch provenance {
            case .localSetupRequired: throw RetryError.localSetupRequired
            case .missingOrInvalid: throw RetryError.missingEngineProvenance
            case .cloud, .localReady: throw RetryError.missingEngineProvenance
            }
        }
        let context = replaceAudio(in: frontmatter.context, with: ["audio.m4a"])
        return TranscriptionWorker(
            directory: dir,
            context: context,
            engine: engineFactory(engineMode),
            request: EngineRequest(
                audioURL: audioURL,
                mode: .singleChannelDiarized(numSpeakers: 2),
                languageCode: context.language,
                keyterms: [],
                modelID: engineMode == .local ? CohereMLXBackend.modelID : "scribe_v2"
            ),
            speakerMapping: [:],
            policy: .cloud,
            sleep: sleep,
            prepareAudio: { },
            keepRawStreams: keepRawStreams,
            languageDetector: nil,
            retryTerminalFailures: true
        )
    }

    public static func retry(
        sessionDirectory sessionURL: URL,
        engineFactory: EngineFactory,
        keepRawStreams: Bool = false,
        localModelStatus: LocalModelCacheStatus = .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: CohereMLXBackend.defaultModelCacheRoot, diskUsageBytes: 0)),
        sleep: @escaping TranscriptionWorker.Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws -> TranscriptionWorker.FinalState {
        let worker = try makeWorker(
            forSessionDirectory: sessionURL,
            engineFactory: engineFactory,
            keepRawStreams: keepRawStreams,
            localModelStatus: localModelStatus,
            sleep: sleep
        )
        return await worker.run()
    }

    private static func replaceAudio(in context: TranscriptContext, with paths: [String]) -> TranscriptContext {
        TranscriptContext(
            title: context.title,
            date: context.date,
            engine: context.engine,
            audioRelativePaths: paths,
            scheduledStart: context.scheduledStart,
            scheduledEnd: context.scheduledEnd,
            actualStart: context.actualStart,
            actualEnd: context.actualEnd,
            organizer: context.organizer,
            location: context.location,
            calendarEventID: context.calendarEventID,
            joinedLate: context.joinedLate,
            elapsedAtStartSeconds: context.elapsedAtStartSeconds,
            attendees: context.attendees,
            language: context.language
        )
    }
}
