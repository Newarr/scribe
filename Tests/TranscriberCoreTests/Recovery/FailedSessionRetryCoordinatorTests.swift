import XCTest
@testable import TranscriberCore

final class FailedSessionRetryCoordinatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCloudRetryEntryPointReusesExistingFailedSessionAudioInPlace() async throws {
        let session = try makeFailedSession(engine: "elevenlabs", audioBytes: Data("cloud audio".utf8))
        let engine = RetryRecordingEngine(responses: [.success(makeResponse(modelID: "scribe_v2"))])

        let final = try await FailedSessionRetryCoordinator.retry(
            sessionDirectory: session.url,
            engineFactory: { mode in
                XCTAssertEqual(mode, .cloud)
                return engine
            },
            sleep: { _ in }
        )

        XCTAssertEqual(final, .complete)
        let audioURLs = await engine.recordedAudioURLs()
        XCTAssertEqual(audioURLs, [session.url.appendingPathComponent("audio.m4a")])
        XCTAssertEqual(try Data(contentsOf: session.url.appendingPathComponent("audio.m4a")), Data("cloud audio".utf8))
        XCTAssertEqual(session.url.lastPathComponent, "failed-session")
        let transcript = try String(contentsOf: session.transcript, encoding: .utf8)
        XCTAssertTrue(transcript.contains("engine: elevenlabs"), transcript)
        XCTAssertTrue(transcript.contains("Retry succeeded"), transcript)
        XCTAssertFalse(transcript.contains("status:"), transcript)
    }

    func testLocalRetryEntryPointUsesPersistedCohereEngineAndExistingAudio() async throws {
        let session = try makeFailedSession(engine: "cohere", audioBytes: Data("local audio".utf8))
        let engine = RetryRecordingEngine(responses: [.success(makeResponse(modelID: CohereMLXBackend.modelID))])

        let final = try await FailedSessionRetryCoordinator.retry(
            sessionDirectory: session.url,
            engineFactory: { mode in
                XCTAssertEqual(mode, .local)
                return engine
            },
            localModelStatus: .verified(LocalModelCacheInfo(modelID: CohereMLXBackend.modelID, cacheURL: root.appendingPathComponent("model"), diskUsageBytes: 1)),
            sleep: { _ in }
        )

        XCTAssertEqual(final, .complete)
        let audioURLs = await engine.recordedAudioURLs()
        XCTAssertEqual(audioURLs, [session.url.appendingPathComponent("audio.m4a")])
        XCTAssertEqual(try Data(contentsOf: session.url.appendingPathComponent("audio.m4a")), Data("local audio".utf8))
        let metadata = try JSONDecoder().decode(
            MetadataJSONWriter.Metadata.self,
            from: Data(contentsOf: session.url.appendingPathComponent("metadata.json"))
        )
        XCTAssertEqual(metadata.status, "complete")
        XCTAssertEqual(metadata.engine, "cohere")
        XCTAssertEqual(metadata.audio, "audio.m4a")
    }


    func testRetryWithMissingCanonicalAudioDoesNotConstructWorker() async throws {
        let session = try makeFailedSession(engine: "elevenlabs", audioBytes: Data("canonical".utf8))
        try FileManager.default.removeItem(at: session.url.appendingPathComponent("audio.m4a"))
        try Data("mic raw".utf8).write(to: session.micFinal)
        try Data("system raw".utf8).write(to: session.systemFinal)

        do {
            _ = try await FailedSessionRetryCoordinator.retry(
                sessionDirectory: session.url,
                engineFactory: { mode in
                    XCTFail("engine factory must not be called without canonical audio.m4a; got \(mode)")
                    return RetryRecordingEngine(responses: [])
                },
                sleep: { _ in }
            )
            XCTFail("retry should reject raw streams without canonical saved audio")
        } catch let error as FailedSessionRetryCoordinator.RetryError {
            XCTAssertEqual(error, .savedAudioMissing)
        }

        XCTAssertEqual(try Data(contentsOf: session.micFinal), Data("mic raw".utf8))
        XCTAssertEqual(try Data(contentsOf: session.systemFinal), Data("system raw".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.url.appendingPathComponent("audio.m4a").path))
    }

    func testRetryValidatesSavedAudioAndFailedTranscript() async throws {
        let session = try makeFailedSession(engine: "elevenlabs", audioBytes: Data())
        try FileManager.default.removeItem(at: session.url.appendingPathComponent("audio.m4a"))

        do {
            _ = try await FailedSessionRetryCoordinator.retry(
                sessionDirectory: session.url,
                engineFactory: { _ in RetryRecordingEngine(responses: []) },
                sleep: { _ in }
            )
            XCTFail("retry should reject missing saved audio")
        } catch let error as FailedSessionRetryCoordinator.RetryError {
            XCTAssertEqual(error, .savedAudioMissing)
        }
    }

    func testLocalRetryRequiresReadyLocalModelInsteadOfFallingBackToCloud() async throws {
        let session = try makeFailedSession(engine: "cohere", audioBytes: Data("local audio".utf8))
        do {
            _ = try await FailedSessionRetryCoordinator.retry(
                sessionDirectory: session.url,
                engineFactory: { mode in
                    XCTFail("engine factory must not be called when persisted Cohere is unavailable; got \(mode)")
                    return RetryRecordingEngine(responses: [])
                },
                localModelStatus: .notDownloaded(modelID: CohereMLXBackend.modelID),
                sleep: { _ in }
            )
            XCTFail("retry should route to Local setup when persisted Cohere is unavailable")
        } catch let error as FailedSessionRetryCoordinator.RetryError {
            XCTAssertEqual(error, .localSetupRequired)
        }
    }

    private func makeFailedSession(engine: String, audioBytes: Data) throws -> SessionDirectory {
        try makeFailedSession(named: "failed-session", engine: engine, audioBytes: audioBytes)
    }

    private func makeFailedSession(named name: String, engine: String, audioBytes: Data) throws -> SessionDirectory {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dir = SessionDirectory(url: url)
        try audioBytes.write(to: url.appendingPathComponent("audio.m4a"))
        let context = TranscriptContext(
            title: "Failed Session",
            date: "2026-05-09",
            engine: engine,
            audioRelativePaths: ["audio.m4a"],
            startedAt: "2026-05-09T10:00:00Z",
            endedAt: "2026-05-09T10:05:00Z",
            attendees: [],
            language: "en"
        )
        try TranscriptWriter.writeFailed(
            at: dir.transcript,
            context: context,
            errorMessage: "previous failure",
            details: TranscriptFailureDetails(errorMessage: "previous failure", retryCount: 3, attemptCount: 4)
        )
        try MetadataJSONWriter.write(
            at: url.appendingPathComponent("metadata.json"),
            metadata: MetadataJSONWriter.Metadata(status: .failed, context: context, audio: "audio.m4a")
        )
        return dir
    }


    func testSessionFolderEnumeratorMarksFailedRecentsRetryableOnlyWhenSavedAudioExists() throws {
        let retryable = try makeFailedSession(named: "retryable-session", engine: "elevenlabs", audioBytes: Data("audio".utf8))
        let repairOnly = try makeFailedSession(named: "repair-only-session", engine: "elevenlabs", audioBytes: Data("audio".utf8))
        try FileManager.default.removeItem(at: repairOnly.url.appendingPathComponent("audio.m4a"))

        let retryableEntries = SessionFolderEnumerator.recents(under: retryable.url.deletingLastPathComponent(), limit: 10)
        let retryableEntry = try XCTUnwrap(retryableEntries.first { $0.directory.lastPathComponent == retryable.url.lastPathComponent })
        XCTAssertEqual(retryableEntry.status, .failed)
        XCTAssertTrue(retryableEntry.hasSavedAudio)

        let repairOnlyEntries = SessionFolderEnumerator.recents(under: repairOnly.url.deletingLastPathComponent(), limit: 10)
        let repairOnlyEntry = try XCTUnwrap(repairOnlyEntries.first { $0.directory.lastPathComponent == repairOnly.url.lastPathComponent })
        XCTAssertEqual(repairOnlyEntry.status, .failed)
        XCTAssertFalse(repairOnlyEntry.hasSavedAudio)
    }

    private func makeResponse(modelID: String) -> EngineResponse {
        EngineResponse(
            utterances: [EngineResponse.Utterance(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "Retry succeeded")],
            detectedLanguage: "en",
            modelID: modelID
        )
    }
}

private actor RetryRecordingEngine: TranscriptionEngine {
    private let responses: [Result<EngineResponse, Error>]
    private var index = 0
    private var audioURLs: [URL] = []

    init(responses: [Result<EngineResponse, Error>]) {
        self.responses = responses
    }

    func recordedAudioURLs() -> [URL] { audioURLs }

    func transcribe(_ request: EngineRequest) async throws -> EngineResponse {
        audioURLs.append(request.audioURL)
        guard index < responses.count else { throw ElevenLabsScribeBackend.BackendError.malformedResponse }
        let response = responses[index]
        index += 1
        return try response.get()
    }
}
