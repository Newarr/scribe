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
