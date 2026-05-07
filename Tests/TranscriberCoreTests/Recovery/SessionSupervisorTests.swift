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
            attendees: [TranscriptPerson(name: "Szymon"), TranscriptPerson(name: "Faris")],
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
                XCTAssertEqual(ctx.attendees, [TranscriptPerson(name: "Szymon"), TranscriptPerson(name: "Faris")])
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

    /// Phase ζ: spec line 339 forbids transcribing one-sided audio.
    /// Supervisor must write a failed transcript (referencing the
    /// surviving file) instead of dispatching a worker against a session
    /// the engine can't actually use.
    func testOneSidedAudioGetsFailedTranscriptAndDoesNotDispatchWorker() async throws {
        let dir = makeSessionDir("partial-mic")
        // Only mic.m4a.partial — system never made it to disk (e.g.,
        // screen recording permission denied mid-call).
        try Data("mic-bytes".utf8).write(to: dir.micPartial)

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("partial-mic") },
            workerFactory: { d, _ in
                XCTFail("worker must not run for one-sided audio sessions per spec line 339")
                return Self.makeWorker(dir: d, responses: [])
            }
        )
        XCTAssertEqual(r.partialAudioMarkedFailed, 1)
        XCTAssertEqual(r.resumed, 0)
        XCTAssertEqual(r.rescued, 0, "rescue counter is only for both-tracks recovery")
        XCTAssertEqual(r.totalFailed, 1, "totalFailed convenience must include partial-audio sessions")
        XCTAssertEqual(TranscriptStatusReader.read(at: dir.transcript), .failed)

        // Surviving file is still on disk — user can recover it manually.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micFinal.path))

        // Codex Phase ζ P0.2 + P2.1: failed transcript must NOT promise
        // both audio files when only mic survived. Body asserts the
        // explicit one-sided message; frontmatter must show single
        // audio: "mic.m4a" (NOT a list including system.m4a).
        let body = try String(contentsOf: dir.transcript, encoding: .utf8)
        XCTAssertTrue(body.contains("only mic survived"), "failed transcript body must say it's one-sided: \(body)")
        XCTAssertTrue(body.contains("mic.m4a"), "failed transcript body must reference the surviving file: \(body)")
        XCTAssertFalse(body.contains("system.m4a"), "failed transcript body must NOT promise system.m4a when only mic survived: \(body)")
        // Frontmatter audio key uses single-string form when there's
        // exactly one path; substring check is the cheapest assertion.
        XCTAssertTrue(body.contains("audio: \"mic.m4a\"") || body.contains("audio:\n  - \"mic.m4a\""), "frontmatter must list only the surviving file: \(body)")
    }

    /// Phase ζ P0.2 mirror image: system-only also lands a failed
    /// transcript with system.m4a in the audio path AND no mic.m4a.
    func testOneSidedSystemOnlyFailedTranscriptDoesNotMentionMic() async throws {
        let dir = makeSessionDir("partial-system")
        try Data("sys-bytes".utf8).write(to: dir.systemPartial)

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("partial-system") },
            workerFactory: { d, _ in
                XCTFail("worker must not run for one-sided audio sessions")
                return Self.makeWorker(dir: d, responses: [])
            }
        )
        XCTAssertEqual(r.partialAudioMarkedFailed, 1)
        let body = try String(contentsOf: dir.transcript, encoding: .utf8)
        XCTAssertTrue(body.contains("only system survived"), body)
        XCTAssertTrue(body.contains("system.m4a"), body)
        XCTAssertFalse(body.contains("mic.m4a"), "failed transcript body must NOT promise mic.m4a when only system survived: \(body)")
    }

    /// Codex Phase ζ P0.1: a session whose `.partial` rename failed
    /// must NOT be terminally stamped — leave it pending so the next
    /// scan can retry once the underlying problem (immutable flag,
    /// transient I/O) clears. Uses the immutable file flag for a
    /// deterministic rename failure.
    func testRecoveryDeferredLeavesSessionPending() async throws {
        let dir = makeSessionDir("rename-fails")
        try Data("mic-bytes".utf8).write(to: dir.micPartial)
        try Data("sys-bytes".utf8).write(to: dir.systemPartial)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: dir.micPartial.path)
        let micPartialPath = dir.micPartial.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: micPartialPath)
        }

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("rename-fails") },
            workerFactory: { _, _ in
                XCTFail("worker must not run while recovery is deferred")
                return Self.makeWorker(dir: dir, responses: [])
            }
        )
        XCTAssertEqual(r.recoveryDeferred, 1)
        XCTAssertEqual(r.partialAudioMarkedFailed, 0, "deferred is not a terminal failure")
        XCTAssertEqual(r.markedFailed, 0)
        XCTAssertEqual(r.totalFailed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.transcript.path), "deferred recovery must NOT write a failed transcript")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.micPartial.path), "stranded .partial bytes must remain for next-scan retry")
    }

    /// Phase ζ P0.2: noAudio sessions also got the stale-context
    /// treatment (frontmatter promised both audio files even though
    /// neither existed). Verify the override produces an empty audio key.
    func testNoAudioFailedTranscriptDoesNotPromiseFiles() async throws {
        let dir = makeSessionDir("no-audio")
        // Pre-populate a pending transcript with rich context (so the
        // contextFactory isn't the source of the audio paths). The
        // supervisor's stale-context bug used existing.context.audioRelativePaths
        // verbatim; the fix overrides it with [] for this case.
        try TranscriptWriter.writePending(at: dir.transcript, context: Self.makeContext("no-audio"))

        let supervisor = SessionSupervisor()
        let r = await supervisor.scanAndResume(
            under: root,
            contextFactory: { _ in Self.makeContext("no-audio") },
            workerFactory: { _, _ in
                XCTFail("worker must not run for no-audio sessions")
                return Self.makeWorker(dir: dir, responses: [])
            }
        )
        XCTAssertEqual(r.markedFailed, 1)
        let body = try String(contentsOf: dir.transcript, encoding: .utf8)
        XCTAssertFalse(body.contains("\"mic.m4a\""), "no-audio failed transcript must not promise files that don't exist: \(body)")
        XCTAssertFalse(body.contains("\"system.m4a\""), body)
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
