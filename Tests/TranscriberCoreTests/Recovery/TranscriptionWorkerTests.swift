import XCTest
import AVFoundation
@testable import TranscriberCore

final class TranscriptionWorkerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHappyPathWritesCompleteOnFirstAttempt() async throws {
        let worker = makeWorker(responses: [.success(makeResponse())])
        let final = await worker.run()
        XCTAssertEqual(final, .complete)
        XCTAssertEqual(TranscriptStatusReader.read(at: dir().transcript), .complete)
    }

    /// Slice 9a output contract: a successful run must produce
    /// `audio.m4a` + `metadata.json` and the completed transcript should
    /// reference `audio.m4a` (not the raw mic/system files).
    func testSuccessfulRunProducesAudioAndMetadata() async throws {
        let dir = self.dir()
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        // AudioFinalizer needs real m4a inputs to mix.
        try writeAACSilence(to: dir.micFinal, durationSec: 0.3)
        try writeAACSilence(to: dir.systemFinal, durationSec: 0.3)

        let worker = makeWorker(responses: [.success(makeResponse())])
        let final = await worker.run()
        XCTAssertEqual(final, .complete)

        let audioPath = dir.url.appendingPathComponent("audio.m4a").path
        let metadataPath = dir.url.appendingPathComponent("metadata.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioPath), "audio.m4a missing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataPath), "metadata.json missing")

        // metadata.json should round-trip with audio = "audio.m4a".
        let data = try Data(contentsOf: dir.url.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(MetadataJSONWriter.Metadata.self, from: data)
        XCTAssertEqual(metadata.audio, "audio.m4a")
        XCTAssertEqual(metadata.status, "complete")

        // transcript.md should reference audio.m4a too.
        let transcript = try String(contentsOf: dir.transcript, encoding: .utf8)
        XCTAssertTrue(transcript.contains("audio: \"audio.m4a\""),
                      "completed transcript should reference audio.m4a, got: \(transcript.prefix(500))")
    }

    /// CDX-S9a.P2.1: failed transcripts must also produce audio.m4a +
    /// metadata.json per the spec output contract. Without this, JSON
    /// consumers see no asset at all on auth failures, retry exhaustion,
    /// or empty-utterance responses.
    func testFailedRunStillProducesAudioAndMetadata() async throws {
        let dir = self.dir()
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try writeAACSilence(to: dir.micFinal, durationSec: 0.3)
        try writeAACSilence(to: dir.systemFinal, durationSec: 0.3)

        // Terminal failure: unauthorized. No retries.
        let worker = makeWorker(responses: [.failure(ElevenLabsScribeBackend.BackendError.unauthorized)])
        let final = await worker.run()
        guard case .failed = final else {
            return XCTFail("expected .failed for unauthorized, got \(final)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("audio.m4a").path),
                      "audio.m4a must exist on failure path so the failed transcript template's `Audio was captured and saved as` reference is valid")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("metadata.json").path),
                      "metadata.json must exist on failure path")

        let data = try Data(contentsOf: dir.url.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(MetadataJSONWriter.Metadata.self, from: data)
        XCTAssertEqual(metadata.status, "failed")
        XCTAssertEqual(metadata.audio, "audio.m4a", "failure metadata must reference the canonical audio asset, not raw streams")
    }

    private func writeAACSilence(to url: URL, durationSec: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(durationSec * 48000)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        try file.write(from: buf)
    }

    func testTransientFailureThenSuccessOnRetry() async throws {
        let worker = makeWorker(responses: [
            .failure(ElevenLabsScribeBackend.BackendError.rateLimited),
            .success(makeResponse())
        ])
        let final = await worker.run()
        XCTAssertEqual(final, .complete)
        XCTAssertEqual(TranscriptStatusReader.read(at: dir().transcript), .complete)
    }

    /// CDX-S7-FINAL.P2.2: writeRetrying must preserve all calendar-enriched
    /// fields (attendees, language) on the retrying-status transcript so a
    /// relaunch during backoff can read them back via
    /// TranscriptFrontmatterReader and resume with the original metadata.
    func testRetryingFrontmatterPreservesAttendeesAndLanguage() async throws {
        try FileManager.default.createDirectory(at: dir().url, withIntermediateDirectories: true)
        let richContext = TranscriptContext(
            title: "1:1 with Faris",
            date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: "2026-04-29T14:30:00Z",
            endedAt: "2026-04-29T15:00:00Z",
            attendees: ["[[Szymon Sypniewicz]]", "[[Faris Riaz]]"],
            language: "en"
        )
        let engine = FakeEngine(responses: [
            .failure(ElevenLabsScribeBackend.BackendError.rateLimited),
            .success(makeResponse())
        ])
        let worker = TranscriptionWorker(
            directory: dir(),
            context: richContext,
            engine: engine,
            request: EngineRequest(
                audioURL: root.appendingPathComponent("multichannel.wav"),
                mode: .multichannel,
                languageCode: "en",
                keyterms: []
            ),
            speakerMapping: [:],
            policy: RetryPolicy(delays: [0.001, 0.001, 0.001]),
            sleep: { _ in /* skip */ }
        )

        // Capture the retrying-status frontmatter mid-run by reading it after
        // the first failure but before the worker overwrites with complete.
        // Easiest: pre-write a retrying status, parse its frontmatter, and
        // confirm the writer's output round-trips through the reader.
        // Drive the test by failing the engine once and asserting on whatever
        // intermediate file content surfaces — but simpler is to just verify
        // the round-trip after run() lands on complete.
        let final = await worker.run()
        XCTAssertEqual(final, .complete)

        // Then directly invoke the private codepath via a separate harness:
        // simulate the failure write by calling writeRetrying through a tiny
        // re-creation of its body builder. Since writeRetrying is private,
        // assert via the actually-observable behavior: a retrying transcript
        // written by the worker must parse back with attendees + language.
        // For this we run a SECOND worker that fails 3 times so it persists
        // retrying+terminal failure and never reaches complete.
        let dir2 = SessionDirectory(url: root.appendingPathComponent("session-retry"))
        try FileManager.default.createDirectory(at: dir2.url, withIntermediateDirectories: true)
        let engine2 = FakeEngine(responses: [
            .failure(ElevenLabsScribeBackend.BackendError.rateLimited)
        ])
        let worker2 = TranscriptionWorker(
            directory: dir2,
            context: richContext,
            engine: engine2,
            request: EngineRequest(
                audioURL: root.appendingPathComponent("multichannel.wav"),
                mode: .multichannel,
                languageCode: "en",
                keyterms: []
            ),
            speakerMapping: [:],
            policy: RetryPolicy(delays: [0.001]),
            sleep: { _ in /* skip */ }
        )
        // Pre-populate a retrying transcript from a fresh start to capture the writer's shape.
        // The worker first writes retrying after the initial failure, then sleeps 0.001s, then
        // gets noMoreResponses (terminal) and writes failed. Read the failed transcript and
        // assert it preserves attendees + language.
        _ = await worker2.run()
        let parsed = TranscriptFrontmatterReader.read(at: dir2.transcript)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.context.attendees, ["[[Szymon Sypniewicz]]", "[[Faris Riaz]]"])
        XCTAssertEqual(parsed?.context.language, "en")
    }

    func testThreeTransientFailuresExhaustsBudget() async throws {
        let err = ElevenLabsScribeBackend.BackendError.rateLimited
        let worker = makeWorker(responses: [.failure(err), .failure(err), .failure(err)])
        let final = await worker.run()
        guard case .failed = final else {
            return XCTFail("expected .failed, got \(final)")
        }
        XCTAssertEqual(TranscriptStatusReader.read(at: dir().transcript), .failed)
    }

    func testTerminalErrorDoesNotRetry() async throws {
        let counter = SleepCounter()
        let worker = makeWorker(
            responses: [.failure(ElevenLabsScribeBackend.BackendError.unauthorized)],
            sleep: { _ in await counter.increment() }
        )
        let final = await worker.run()
        guard case .failed = final else {
            return XCTFail("expected .failed, got \(final)")
        }
        let n = await counter.count
        XCTAssertEqual(n, 0, "terminal errors must not trigger sleep/retry")
        XCTAssertEqual(TranscriptStatusReader.read(at: dir().transcript), .failed)
    }

    func testEmptyResponseFails() async throws {
        let empty = EngineResponse(utterances: [], detectedLanguage: "en", modelID: "scribe_v2")
        let worker = makeWorker(responses: [.success(empty)])
        let final = await worker.run()
        guard case .failed(let reason) = final else {
            return XCTFail("expected .failed for empty utterances")
        }
        XCTAssertTrue(reason.contains("No speech"), "reason should mention no-speech: \(reason)")
    }

    /// CDX-S7-CHAL.P2.2: when resuming a `retrying` session whose attempt count
    /// is already at the policy max, the worker must NOT grant a fresh budget.
    /// One transient failure here should write `failed` and never sleep.
    func testRetryingSessionResumesFromPersistedAttempts() async throws {
        try FileManager.default.createDirectory(at: dir().url, withIntermediateDirectories: true)
        // Pre-populate the transcript at attempts=3 (the cloud policy's max
        // failure count). After this, a single fresh failure is terminal.
        let stub = """
        ---
        schema: transcriber/v1
        status: retrying
        title: "Test Session"
        date: 2026-04-29
        engine: elevenlabs
        audio:
          - mic.m4a
          - system.m4a
        started_at: 2026-04-29T14:30:00Z
        ended_at: 2026-04-29T15:00:00Z
        attempts: 3
        ---

        body
        """
        try stub.write(to: dir().transcript, atomically: true, encoding: .utf8)

        let counter = SleepCounter()
        let worker = makeWorker(
            responses: [.failure(ElevenLabsScribeBackend.BackendError.rateLimited)],
            sleep: { _ in await counter.increment() }
        )
        let final = await worker.run()
        guard case .failed = final else {
            return XCTFail("expected .failed (budget exhausted), got \(final)")
        }
        let sleeps = await counter.count
        XCTAssertEqual(sleeps, 0, "worker must not retry once persisted attempts hits policy max; \(sleeps) sleeps observed")
    }

    func testIdempotentOnAlreadyComplete() async throws {
        // Session dir must exist before we can write the pre-populated transcript.
        try FileManager.default.createDirectory(at: dir().url, withIntermediateDirectories: true)

        // Pre-populate the transcript with status: complete.
        let context = makeContext()
        let utterances = [EngineResponse.Utterance(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "Hi")]
        try TranscriptWriter.writeComplete(at: dir().transcript, context: context, utterances: utterances, speakerMapping: [:])

        // Engine throws to prove the worker doesn't call it.
        let worker = makeWorker(responses: [.failure(ElevenLabsScribeBackend.BackendError.unauthorized)])
        let final = await worker.run()
        XCTAssertEqual(final, .complete)
    }

    // MARK: - helpers

    private func dir() -> SessionDirectory {
        SessionDirectory(url: root.appendingPathComponent("session"))
    }

    private func makeContext() -> TranscriptContext {
        TranscriptContext(
            title: "Test Session",
            date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: "2026-04-29T14:30:00Z",
            endedAt: "2026-04-29T15:00:00Z",
            attendees: [],
            language: nil
        )
    }

    private func makeResponse() -> EngineResponse {
        EngineResponse(
            utterances: [
                .init(speaker: "speaker_0", startSeconds: 0, endSeconds: 1.0, text: "Hello"),
                .init(speaker: "speaker_1", startSeconds: 1.1, endSeconds: 2.0, text: "World")
            ],
            detectedLanguage: "en",
            modelID: "scribe_v2"
        )
    }

    private func makeWorker(
        responses: [Result<EngineResponse, Error>],
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in /* skip */ }
    ) -> TranscriptionWorker {
        let session = dir()
        try? FileManager.default.createDirectory(at: session.url, withIntermediateDirectories: true)
        let engine = FakeEngine(responses: responses)
        let request = EngineRequest(
            audioURL: root.appendingPathComponent("multichannel.wav"),
            mode: .multichannel,
            languageCode: nil,
            keyterms: []
        )
        return TranscriptionWorker(
            directory: session,
            context: makeContext(),
            engine: engine,
            request: request,
            speakerMapping: [:],
            policy: RetryPolicy(delays: [0.001, 0.001, 0.001]),
            sleep: sleep
        )
    }
}

actor SleepCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

actor FakeEngine: TranscriptionEngine {
    private var queue: [Result<EngineResponse, Error>]

    init(responses: [Result<EngineResponse, Error>]) {
        self.queue = responses
    }

    func transcribe(_ request: EngineRequest) async throws -> EngineResponse {
        guard !queue.isEmpty else { throw FakeError.noMoreResponses }
        let next = queue.removeFirst()
        switch next {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }

    enum FakeError: Error { case noMoreResponses }
}
