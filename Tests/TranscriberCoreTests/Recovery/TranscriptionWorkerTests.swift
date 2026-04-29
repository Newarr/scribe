import XCTest
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

    func testTransientFailureThenSuccessOnRetry() async throws {
        let worker = makeWorker(responses: [
            .failure(ElevenLabsScribeBackend.BackendError.rateLimited),
            .success(makeResponse())
        ])
        let final = await worker.run()
        XCTAssertEqual(final, .complete)
        XCTAssertEqual(TranscriptStatusReader.read(at: dir().transcript), .complete)
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
