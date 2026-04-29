import XCTest
@testable import TranscriberCore

final class SessionSupervisorTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCompleteSessionIsSkipped() async throws {
        let dir = makeSessionDir("a")
        try Data("mic".utf8).write(to: dir.micFinal)
        try Data("sys".utf8).write(to: dir.systemFinal)
        try TranscriptWriter.writeComplete(
            at: dir.transcript,
            context: Self.makeContext("a"),
            utterances: [.init(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "Hi")],
            speakerMapping: [:]
        )

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("a") },
            workerFactory: { d, _ in
                XCTFail("worker should not be created for complete sessions")
                return Self.makeWorker(dir: d, responses: [])
            }
        )
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.resumed, 0)
        XCTAssertEqual(TranscriptStatusReader.read(at: dir.transcript), .complete)
    }

    func testPendingSessionGetsTranscribed() async throws {
        let dir = makeSessionDir("b")
        try Data("mic".utf8).write(to: dir.micFinal)
        try Data("sys".utf8).write(to: dir.systemFinal)
        try TranscriptWriter.writePending(at: dir.transcript, context: Self.makeContext("b"))

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("b") },
            workerFactory: { d, _ in
                Self.makeWorker(dir: d, responses: [.success(Self.makeResponse())])
            }
        )
        XCTAssertEqual(r.resumed, 1)
        XCTAssertEqual(TranscriptStatusReader.read(at: dir.transcript), .complete)
    }

    func testOrphanPartialSessionIsRescuedAndTranscribed() async throws {
        let dir = makeSessionDir("c")
        try Data("mic".utf8).write(to: dir.micPartial)
        try Data("sys".utf8).write(to: dir.systemPartial)

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("c") },
            workerFactory: { d, _ in
                Self.makeWorker(dir: d, responses: [.success(Self.makeResponse())])
            }
        )
        XCTAssertEqual(r.rescued, 1)
        XCTAssertEqual(r.resumed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.systemFinal.path))
        XCTAssertEqual(TranscriptStatusReader.read(at: dir.transcript), .complete)
    }

    func testNoAudioSessionIsMarkedFailed() async throws {
        let dir = makeSessionDir("d")

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("d") },
            workerFactory: { d, _ in
                XCTFail("worker should not run for no-audio sessions")
                return Self.makeWorker(dir: d, responses: [])
            }
        )
        XCTAssertEqual(r.markedFailed, 1)
        XCTAssertEqual(r.resumed, 0)
        XCTAssertEqual(TranscriptStatusReader.read(at: dir.transcript), .failed)
    }

    /// CDX-S7-CHAL.P2.3: a complete session whose audio was manually moved
    /// must NOT have its completed transcript overwritten by a failed marker.
    func testCompleteSessionWithMissingAudioIsLeftAlone() async throws {
        let dir = makeSessionDir("audio-deleted")
        // Write a complete transcript; do NOT write any audio files.
        try TranscriptWriter.writeComplete(
            at: dir.transcript,
            context: Self.makeContext("audio-deleted"),
            utterances: [.init(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "Original")],
            speakerMapping: [:]
        )

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("audio-deleted") },
            workerFactory: { d, _ in Self.makeWorker(dir: d, responses: []) }
        )
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.markedFailed, 0)
        XCTAssertEqual(TranscriptStatusReader.read(at: dir.transcript), .complete)
        let body = try String(contentsOf: dir.transcript, encoding: .utf8)
        XCTAssertTrue(body.contains("Original"), "complete transcript body must survive scan: \(body)")
    }

    /// CDX-S7-CHAL.P2.1: pending session with rich on-disk frontmatter must
    /// preserve its original title/attendees/language across resume rather
    /// than getting overwritten by the placeholder contextFactory.
    func testPendingSessionPreservesRichContextAcrossResume() async throws {
        let dir = makeSessionDir("rich")
        try Data("mic".utf8).write(to: dir.micFinal)
        try Data("sys".utf8).write(to: dir.systemFinal)

        // Slice 3-style pending transcript with full event metadata.
        let originalContext = TranscriptContext(
            title: "1:1 with Faris",
            date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: "2026-04-29T14:30:00Z",
            endedAt: "2026-04-29T15:00:00Z",
            attendees: ["[[Szymon]]", "[[Faris]]"],
            language: "en"
        )
        try TranscriptWriter.writePending(at: dir.transcript, context: originalContext)

        let supervisor = SessionSupervisor()
        let factoryCalls = SleepCounter()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in
                Task { await factoryCalls.increment() }
                return Self.makeContext("placeholder")
            },
            workerFactory: { d, ctx in
                // Worker should receive the ORIGINAL context, not the placeholder.
                XCTAssertEqual(ctx.title, "1:1 with Faris")
                XCTAssertEqual(ctx.attendees, ["[[Szymon]]", "[[Faris]]"])
                XCTAssertEqual(ctx.language, "en")
                return Self.makeWorker(dir: d, responses: [.success(Self.makeResponse())])
            }
        )
        XCTAssertEqual(r.resumed, 1)
        // Allow async increment Task to settle, then assert.
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await factoryCalls.count
        XCTAssertEqual(calls, 0, "factory should not be invoked when on-disk context is available")
    }

    func testFailedSessionIsSkipped() async throws {
        let dir = makeSessionDir("e")
        try Data("mic".utf8).write(to: dir.micFinal)
        try Data("sys".utf8).write(to: dir.systemFinal)
        try TranscriptWriter.writeFailed(at: dir.transcript, context: Self.makeContext("e"), errorMessage: "previous run gave up")

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("e") },
            workerFactory: { d, _ in
                XCTFail("worker should not run for failed sessions")
                return Self.makeWorker(dir: d, responses: [])
            }
        )
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(TranscriptStatusReader.read(at: dir.transcript), .failed)
    }

    // MARK: - helpers (static so they can be captured into @Sendable closures)

    private func makeSessionDir(_ name: String) -> SessionDirectory {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SessionDirectory(url: url)
    }

    private static func makeContext(_ slug: String) -> TranscriptContext {
        TranscriptContext(
            title: "Session \(slug)",
            date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: "2026-04-29T14:30:00Z",
            endedAt: "2026-04-29T15:00:00Z",
            attendees: [],
            language: nil
        )
    }

    private static func makeResponse() -> EngineResponse {
        EngineResponse(
            utterances: [.init(speaker: "speaker_0", startSeconds: 0, endSeconds: 1.0, text: "Hi")],
            detectedLanguage: "en",
            modelID: "scribe_v2"
        )
    }

    private static func makeWorker(dir: SessionDirectory, responses: [Result<EngineResponse, Error>]) -> TranscriptionWorker {
        let engine = FakeEngine(responses: responses)
        let request = EngineRequest(
            audioURL: dir.url.appendingPathComponent("multichannel.wav"),
            mode: .multichannel,
            languageCode: nil,
            keyterms: []
        )
        return TranscriptionWorker(
            directory: dir,
            context: makeContext("worker"),
            engine: engine,
            request: request,
            speakerMapping: [:],
            policy: RetryPolicy(delays: [0.001]),
            sleep: { _ in /* skip */ }
        )
    }
}
