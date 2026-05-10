import XCTest
@testable import TranscriberCore

/// Phase θ mandatory redaction tests. Spec line 364: diagnostics export
/// must NOT leak transcript content, attendee names, API key fragments,
/// or stray session-folder content.
///
/// These tests are the critical guardrails — every PII-bearing source
/// of input is planted with a known sentinel string, the diagnostics
/// blob is exported, and we assert the sentinel is NOT in the output.
final class DiagnosticsExporterTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeContext() -> TranscriptContext {
        TranscriptContext(
            title: "Innocuous title",
            date: "2026-04-30",
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: "2026-04-30T14:30:00Z",
            endedAt: "2026-04-30T15:00:00Z",
            attendees: [],
            language: "en"
        )
    }

    private func makeSnapshot(sessions: DiagnosticsSnapshot.SessionSummary) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "0.0.0-test",
            osVersion: .init(major: 26, minor: 4, patch: 1),
            activeCalendarSource: "appleCalendar",
            exportedAt: "2026-04-30T10:00:00Z",
            settings: .init(
                engineMode: "cloud",
                keepRawStreams: false,
                aecEnabled: true,
                privacyAcknowledged: true,
                outputRootHash: DiagnosticsCollector.hashPath(root, instanceID: "test-instance"),
                outputRootIsWritable: true
            ),
            permissions: .init(microphone: "granted", screenRecording: "granted", calendar: "granted"),
            engine: .init(
                selectedEngine: "cloud",
                selectedEngineReady: true,
                cloudKey: "configured",
                localModelStatus: "notDownloaded",
                localModelID: CohereMLXBackend.modelID,
                localCachePathExists: false,
                mlxAvailable: true,
                localReady: false,
                lastDownloadError: ""
            ),
            sessions: sessions,
            liveLevels: .init(micRMS: 0.42, systemRMS: 0.31)
        )
    }

    // MARK: - mandatory redaction guards (spec line 364)

    func testDiagnosticsContainsNoTranscriptContent() throws {
        // Plant a sentinel inside the transcript BODY (not frontmatter).
        // Collector must read only frontmatter status + attempts.
        let dir = SessionDirectory(url: root.appendingPathComponent("session-a", isDirectory: true))
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try TranscriptWriter.writeComplete(
            at: dir.transcript,
            context: makeContext(),
            utterances: [.init(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "SECRET-PHRASE-XYZ-12345")],
            speakerMapping: [:]
        )

        let summary = DiagnosticsCollector.collectSessions(under: root)
        let data = try DiagnosticsExporter.encode(makeSnapshot(sessions: summary))
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(summary.complete, 1, "session must be counted")
        XCTAssertFalse(json.contains("SECRET-PHRASE-XYZ-12345"), "transcript body must NOT leak into diagnostics export: \(json)")
    }

    func testDiagnosticsContainsNoAttendeeNames() throws {
        // Attendees live in the frontmatter context. The collector must
        // read status only — never project context.attendees into the
        // diagnostics output.
        let dir = SessionDirectory(url: root.appendingPathComponent("session-b", isDirectory: true))
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        var ctx = makeContext()
        ctx = TranscriptContext(
            title: "Meeting with [[Faris-Sentinel-Riaz]]",
            date: ctx.date,
            engine: ctx.engine,
            audioRelativePaths: ctx.audioRelativePaths,
            startedAt: ctx.startedAt,
            endedAt: ctx.endedAt,
            attendees: [TranscriptPerson(name: "Faris-Sentinel-Riaz"), TranscriptPerson(name: "Other-Sentinel-Person")],
            language: ctx.language
        )
        try TranscriptWriter.writePending(at: dir.transcript, context: ctx)

        let summary = DiagnosticsCollector.collectSessions(under: root)
        let data = try DiagnosticsExporter.encode(makeSnapshot(sessions: summary))
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(summary.pending, 1)
        XCTAssertFalse(json.contains("Faris-Sentinel-Riaz"), "attendee name must NOT leak into diagnostics export: \(json)")
        XCTAssertFalse(json.contains("Other-Sentinel-Person"), "attendee name must NOT leak: \(json)")
        XCTAssertFalse(json.contains("Meeting with"), "session title must NOT leak: \(json)")
    }

    func testDiagnosticsContainsNoAPIKey() throws {
        // The Engine view holds `cloudKey: String` ("configured" |
        // "missing" | "unreadable") — never the value. Schema review
        // proves no String field that would carry a key.
        let summary = DiagnosticsSnapshot.SessionSummary.zero
        let snapshot = DiagnosticsSnapshot(
            appVersion: "0.0.0-test",
            osVersion: .init(major: 26, minor: 4, patch: 1),
            activeCalendarSource: "appleCalendar",
            exportedAt: "2026-04-30T10:00:00Z",
            settings: .init(
                engineMode: "cloud",
                keepRawStreams: false,
                aecEnabled: true,
                privacyAcknowledged: true,
                outputRootHash: DiagnosticsCollector.hashPath(root, instanceID: "test-instance"),
                outputRootIsWritable: true
            ),
            permissions: .init(microphone: "granted", screenRecording: "granted", calendar: "granted"),
            engine: .init(
                selectedEngine: "cloud",
                selectedEngineReady: true,
                cloudKey: "configured",
                localModelStatus: "notDownloaded",
                localModelID: CohereMLXBackend.modelID,
                localCachePathExists: false,
                mlxAvailable: true,
                localReady: false,
                lastDownloadError: ""
            ),  // schema: enum-string/key-safe fields only
            sessions: summary,
            liveLevels: nil
        )
        let data = try DiagnosticsExporter.encode(snapshot)
        let json = String(decoding: data, as: UTF8.self)

        // The user could have a Keychain key like "sk_TEST-API-KEY-XYZ".
        XCTAssertFalse(json.contains("sk_"), "Keychain-style key prefix must not appear: \(json)")
        XCTAssertFalse(json.contains("TEST-API-KEY"), "any sentinel key must not appear: \(json)")
    }

    func testDiagnosticsRedactionWalksWholeSessionFolder() throws {
        // Plant garbage files INSIDE a session folder (not just the
        // transcript). The collector must NOT walk the folder reading
        // unknown files; aggregate counts only.
        let dir = SessionDirectory(url: root.appendingPathComponent("session-c", isDirectory: true))
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try TranscriptWriter.writePending(at: dir.transcript, context: makeContext())
        // Stray files with sentinel content.
        try Data("STRAY-AUDIO-BYTES-aabbccdd".utf8).write(to: dir.url.appendingPathComponent("debug-notes.txt"))
        try Data("MIC-RAW-BYTES-eeff0011".utf8).write(to: dir.micFinal)
        try Data("ATTENDEE-CACHE-22334455".utf8).write(to: dir.url.appendingPathComponent("attendees.json"))
        try Data("LEAKED-EVENT-TITLE-66778899".utf8).write(to: dir.url.appendingPathComponent("calendar-event.txt"))

        let summary = DiagnosticsCollector.collectSessions(under: root)
        let data = try DiagnosticsExporter.encode(makeSnapshot(sessions: summary))
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(summary.pending, 1)
        // Codex Phase θ P2.1: also check base64 + hex encodings so a
        // future field accidentally including the bytes via
        // Data.base64EncodedString or hex would trip the test.
        for sentinel in ["STRAY-AUDIO-BYTES", "MIC-RAW-BYTES", "ATTENDEE-CACHE", "LEAKED-EVENT-TITLE"] {
            XCTAssertFalse(json.contains(sentinel), "stray file content must NOT leak: \(sentinel) in \(json)")
            let bytes = Data(sentinel.utf8)
            let b64 = bytes.base64EncodedString()
            XCTAssertFalse(json.contains(b64), "stray file content must NOT leak (base64): \(b64) in \(json)")
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            XCTAssertFalse(json.contains(hex), "stray file content must NOT leak (hex): \(hex) in \(json)")
        }
        // Filenames also must not appear (no listing of folder contents).
        XCTAssertFalse(json.contains("debug-notes.txt"), "stray filenames must NOT leak: \(json)")
        XCTAssertFalse(json.contains("attendees.json"), json)
        XCTAssertFalse(json.contains("calendar-event.txt"), json)
        // Even the session folder name shouldn't appear (the hash is the
        // only identifier).
        XCTAssertFalse(json.contains("session-c"), "session folder names must NOT leak: \(json)")
    }

    // MARK: - schema correctness

    func testCollectorAggregatesAcrossMixedStatuses() throws {
        // 1 complete, 2 pending, 1 failed, 1 retrying, with one
        // attempts=2 retrying session.
        try writePending("a")
        try writePending("b")
        try writeComplete("c")
        try writeFailed("d")
        try writeRetrying("e", attempts: 2)

        let summary = DiagnosticsCollector.collectSessions(under: root)
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.pending, 2)
        XCTAssertEqual(summary.complete, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.retrying, 1)
        XCTAssertEqual(summary.totalRetries, 2)
        XCTAssertEqual(summary.orphanedWithAudio, 0)
    }

    func testCollectorClassifiesUnreadableTranscriptAsUnknown() throws {
        let dir = SessionDirectory(url: root.appendingPathComponent("session-bad", isDirectory: true))
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        // Garbage transcript: no frontmatter at all.
        try "no frontmatter here, just body".write(to: dir.transcript, atomically: true, encoding: .utf8)

        let summary = DiagnosticsCollector.collectSessions(under: root)
        XCTAssertEqual(summary.unknown, 1)
        XCTAssertEqual(summary.total, 1)
    }

    func testHashPathIsDeterministicAndDoesNotLeakPath() {
        let url = URL(fileURLWithPath: "/Users/alice/Documents/Scribe", isDirectory: true)
        let h1 = DiagnosticsCollector.hashPath(url, instanceID: "test-instance")
        let h2 = DiagnosticsCollector.hashPath(url, instanceID: "test-instance")
        XCTAssertEqual(h1, h2, "same instanceID + path must produce same hash")
        XCTAssertEqual(h1.count, 64, "HMAC-SHA256 hex is 64 chars")
        XCTAssertFalse(h1.contains("alice"), "hash must not contain raw path")
        XCTAssertFalse(h1.contains("Documents"), h1)
    }

    func testHashPathDiffersAcrossInstances() {
        // Codex Phase θ P1.2: HMAC keyed by per-install secret means
        // two users with the same path get different hashes. This
        // defeats the rainbow-attack that plain SHA-256 of a low-entropy
        // path was vulnerable to.
        let url = URL(fileURLWithPath: "/Users/alice/Documents/Scribe", isDirectory: true)
        let userA = DiagnosticsCollector.hashPath(url, instanceID: "instance-A")
        let userB = DiagnosticsCollector.hashPath(url, instanceID: "instance-B")
        XCTAssertNotEqual(userA, userB, "different instance IDs must yield different hashes for the same path")
    }

    func testRecursiveSchemaShape() throws {
        // Codex Phase θ P1.1: top-level allowlist test doesn't catch a
        // PII-bearing field added to a NESTED struct. This test asserts
        // the EXACT shape of every nested object so a future
        // SettingsView.rawOutputRoot or EngineView.apiKeyPreview field
        // would trip the assertion.
        let snapshot = makeSnapshot(sessions: .zero)
        let data = try DiagnosticsExporter.encode(snapshot)
        let any = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let json = try XCTUnwrap(any)

        // Top-level keys.
        XCTAssertEqual(Set(json.keys), [
            "appVersion", "osVersion", "activeCalendarSource", "exportedAt", "settings", "permissions", "engine", "sessions", "liveLevels"
        ])

        let settings = try XCTUnwrap(json["settings"] as? [String: Any])
        XCTAssertEqual(Set(settings.keys), [
            "engineMode", "keepRawStreams", "aecEnabled", "privacyAcknowledged", "outputRootHash", "outputRootIsWritable"
        ])

        let permissions = try XCTUnwrap(json["permissions"] as? [String: Any])
        XCTAssertEqual(Set(permissions.keys), ["microphone", "screenRecording", "calendar"])

        let engine = try XCTUnwrap(json["engine"] as? [String: Any])
        XCTAssertEqual(Set(engine.keys), [
            "selectedEngine", "selectedEngineReady", "cloudKey", "localModelStatus",
            "localModelID", "localCachePathExists", "mlxAvailable", "localReady", "lastDownloadError"
        ])

        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        XCTAssertEqual(Set(sessions.keys), [
            "total", "pending", "retrying", "complete", "failed", "unknown", "orphanedWithAudio", "totalRetries",
            "cloudEngineSessions", "localEngineSessions", "unknownEngineSessions"
        ])

        let levels = try XCTUnwrap(json["liveLevels"] as? [String: Any])
        XCTAssertEqual(Set(levels.keys), ["micRMS", "systemRMS"])
    }


    func testDiagnosticsSchemaIncludesSafeOSVersionAndActiveCalendarSource() throws {
        let snapshot = makeSnapshot(sessions: .zero)
        let data = try DiagnosticsExporter.encode(snapshot)
        let any = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let json = try XCTUnwrap(any)
        let osVersion = try XCTUnwrap(json["osVersion"] as? [String: Any])

        XCTAssertEqual(osVersion["major"] as? Int, 26)
        XCTAssertEqual(osVersion["minor"] as? Int, 4)
        XCTAssertEqual(osVersion["patch"] as? Int, 1)
        XCTAssertEqual(json["appVersion"] as? String, "0.0.0-test")
        XCTAssertEqual(json["activeCalendarSource"] as? String, "appleCalendar")
    }

    func testActiveCalendarSourceNormalizationIsNonContentBearing() async throws {
        XCTAssertEqual(DiagnosticsCollector.activeCalendarSource(calendarPermission: "granted"), "appleCalendar")
        XCTAssertEqual(DiagnosticsCollector.activeCalendarSource(calendarPermission: "denied"), "none")
        XCTAssertEqual(DiagnosticsCollector.activeCalendarSource(calendarPermission: "notDetermined"), "none")
        XCTAssertEqual(DiagnosticsCollector.activeCalendarSource(calendarPermission: "unknown"), "unknown")
    }

    func testDiagnosticsSafeStateFieldsDoNotLeakCalendarOrPathSentinels() throws {
        let snapshot = DiagnosticsSnapshot(
            appVersion: "0.0.0-test",
            osVersion: .init(major: 26, minor: 4, patch: 1),
            activeCalendarSource: "appleCalendar",
            exportedAt: "2026-04-30T10:00:00Z",
            settings: .init(engineMode: "cloud", keepRawStreams: false, aecEnabled: true, privacyAcknowledged: true, outputRootHash: "hash", outputRootIsWritable: true),
            permissions: .init(microphone: "granted", screenRecording: "granted", calendar: "granted"),
            engine: .init(selectedEngine: "cloud", selectedEngineReady: true, cloudKey: "configured", localModelStatus: "notDownloaded", localModelID: CohereMLXBackend.modelID, localCachePathExists: false, mlxAvailable: true, localReady: false, lastDownloadError: ""),
            sessions: .zero,
            liveLevels: nil
        )
        let json = String(decoding: try DiagnosticsExporter.encode(snapshot), as: UTF8.self)
        for sentinel in ["Customer Secret Calendar Title", "Faris Sentinel", "/Users/alice", "session-folder", "sk_TEST", "keyterm"] {
            XCTAssertFalse(json.contains(sentinel), "safe-state field leaked sentinel: \(sentinel) in \(json)")
        }
    }

    func testLocalDiagnosticsSchemaIncludesReviewedSafeFields() throws {
        let snapshot = makeSnapshot(sessions: .zero)
        let data = try DiagnosticsExporter.encode(snapshot)
        let any = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let json = try XCTUnwrap(any)
        let engine = try XCTUnwrap(json["engine"] as? [String: Any])

        XCTAssertEqual(engine["selectedEngine"] as? String, "cloud")
        XCTAssertEqual(engine["selectedEngineReady"] as? Bool, true)
        XCTAssertEqual(engine["localModelStatus"] as? String, "notDownloaded")
        XCTAssertEqual(engine["localModelID"] as? String, CohereMLXBackend.modelID)
        XCTAssertEqual(engine["localCachePathExists"] as? Bool, false)
        XCTAssertEqual(engine["mlxAvailable"] as? Bool, true)
        XCTAssertEqual(engine["localReady"] as? Bool, false)
        XCTAssertEqual(engine["lastDownloadError"] as? String, "")
    }

    func testDiagnosticsEngineNormalizesLocalStatusAndReadiness() async throws {
        let cases: [(LocalModelCacheStatus, String, Bool, Bool, Bool)] = [
            (.notDownloaded(modelID: CohereMLXBackend.modelID), "notDownloaded", false, true, false),
            (.downloading(modelID: CohereMLXBackend.modelID, progress: .init(completedBytes: 1, totalBytes: 10)), "downloading", false, true, false),
            (.verifying(modelID: CohereMLXBackend.modelID), "verifying", false, true, false),
            (.verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: root.appendingPathComponent("SECRET-CACHE-PATH"), diskUsageBytes: 1)), "verified", true, true, true),
            (.failed(modelID: CohereMLXBackend.modelID, reason: .init(code: .downloadFailed, message: "ignored"), retryAvailable: true), "failed", false, true, false),
            (.unsupported(modelID: CohereMLXBackend.modelID, reason: .init(code: .unsupportedRuntime, message: "ignored")), "unsupported", false, false, false)
        ]
        for (status, expectedStatus, expectedCache, expectedMLX, expectedReady) in cases {
            let engine = await DiagnosticsCollector.engine(
                mode: .local,
                cloudProbe: { .missing },
                engineProbe: StubEngineReadiness(status: status)
            )
            XCTAssertEqual(engine.localModelStatus, expectedStatus)
            XCTAssertEqual(engine.localCachePathExists, expectedCache)
            XCTAssertEqual(engine.mlxAvailable, expectedMLX)
            XCTAssertEqual(engine.localReady, expectedReady)
            XCTAssertEqual(engine.selectedEngineReady, expectedReady)
        }
    }

    func testSelectedEngineReadinessIsIndependentForCloudAndLocal() async {
        let verified = LocalModelCacheStatus.verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: root, diskUsageBytes: 1))
        let cloudMissing = await DiagnosticsCollector.engine(
            mode: .cloud,
            cloudProbe: { .missing },
            engineProbe: StubEngineReadiness(status: verified)
        )
        XCTAssertEqual(cloudMissing.selectedEngine, "cloud")
        XCTAssertFalse(cloudMissing.selectedEngineReady, "Local readiness must not make selected Cloud ready")
        XCTAssertTrue(cloudMissing.localReady)

        let localReady = await DiagnosticsCollector.engine(
            mode: .local,
            cloudProbe: { .missing },
            engineProbe: StubEngineReadiness(status: verified)
        )
        XCTAssertEqual(localReady.selectedEngine, "local")
        XCTAssertTrue(localReady.selectedEngineReady)
        XCTAssertEqual(localReady.cloudKey, "missing")
    }

    func testLocalLastDownloadErrorIsBoundedAndRedacted() async throws {
        let raw = "Failed for /Users/alice/Library/Caches/Scribe/model.safetensors with token sk_TEST and calendar Customer Secret Agenda https://example.com?token=abc\nstack trace line"
        let engine = await DiagnosticsCollector.engine(
            mode: .local,
            cloudProbe: { .configured },
            engineProbe: StubEngineReadiness(status: .failed(
                modelID: CohereMLXBackend.modelID,
                reason: .init(code: .downloadFailed, message: raw),
                retryAvailable: true
            ))
        )
        let data = try DiagnosticsExporter.encode(DiagnosticsSnapshot(
            appVersion: "0.0.0-test",
            osVersion: .init(major: 26, minor: 4, patch: 1),
            activeCalendarSource: "appleCalendar",
            exportedAt: "2026-04-30T10:00:00Z",
            settings: .init(engineMode: "local", keepRawStreams: false, aecEnabled: true, privacyAcknowledged: true, outputRootHash: "hash", outputRootIsWritable: true),
            permissions: .init(microphone: "granted", screenRecording: "granted", calendar: "granted"),
            engine: engine,
            sessions: .zero,
            liveLevels: nil
        ))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(engine.lastDownloadError, "downloadFailed")
        for sentinel in ["/Users/alice", "Library/Caches", "model.safetensors", "sk_TEST", "Customer Secret Agenda", "example.com", "token=abc", "stack trace"] {
            XCTAssertFalse(json.contains(sentinel), "local error sentinel must not leak: \(sentinel) in \(json)")
        }
    }

    func testDiagnosticsSessionProvenanceCountsEnginesWithoutContent() throws {
        try writeComplete("cloud-session", engine: "elevenlabs")
        try writeComplete("local-session", engine: "cohere")
        try writeComplete("mystery-session", engine: "unexpected")

        let summary = DiagnosticsCollector.collectSessions(under: root)
        XCTAssertEqual(summary.cloudEngineSessions, 1)
        XCTAssertEqual(summary.localEngineSessions, 1)
        XCTAssertEqual(summary.unknownEngineSessions, 1)

        let data = try DiagnosticsExporter.encode(makeSnapshot(sessions: summary))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("cloud-session"))
        XCTAssertFalse(json.contains("local-session"))
        XCTAssertFalse(json.contains("mystery-session"))
    }

    func testLocalCachePathIsExposedOnlyAsExistence() async throws {
        let sentinelPath = root.appendingPathComponent("Users/alice/Secret/Cache", isDirectory: true)
        let engine = await DiagnosticsCollector.engine(
            mode: .local,
            cloudProbe: { .missing },
            engineProbe: StubEngineReadiness(status: .verified(.init(modelID: CohereMLXBackend.modelID, cacheURL: sentinelPath, diskUsageBytes: 123)))
        )
        let data = try DiagnosticsExporter.encode(DiagnosticsSnapshot(
            appVersion: "0.0.0-test",
            osVersion: .init(major: 26, minor: 4, patch: 1),
            activeCalendarSource: "appleCalendar",
            exportedAt: "2026-04-30T10:00:00Z",
            settings: .init(engineMode: "local", keepRawStreams: false, aecEnabled: true, privacyAcknowledged: true, outputRootHash: "hash", outputRootIsWritable: true),
            permissions: .init(microphone: "granted", screenRecording: "granted", calendar: "granted"),
            engine: engine,
            sessions: .zero,
            liveLevels: nil
        ))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(engine.localCachePathExists)
        for sentinel in ["Users", "alice", "Secret"] {
            XCTAssertFalse(json.contains(sentinel), "cache path fragment must not leak: \(sentinel) in \(json)")
        }
    }

    func testCollectorCountsAudioWithoutTranscriptAsOrphaned() throws {
        // Codex Phase θ P1.5: a session folder with mic.m4a/system.m4a
        // (or .partial) but no transcript.md is a recovery-window
        // orphan. Surface it distinctly in the diagnostic counts so
        // support sees pending recoverable bytes.
        let dir = SessionDirectory(url: root.appendingPathComponent("orphan-with-audio", isDirectory: true))
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: dir.micFinal)
        try Data("audio".utf8).write(to: dir.systemFinal)
        // No transcript.md.

        let summary = DiagnosticsCollector.collectSessions(under: root)
        XCTAssertEqual(summary.orphanedWithAudio, 1)
        XCTAssertEqual(summary.total, 1)
        XCTAssertEqual(summary.pending, 0)
        XCTAssertEqual(summary.complete, 0)
    }

    func testEncodedJSONHasOnlyAllowlistedTopLevelKeys() throws {
        let snapshot = makeSnapshot(sessions: .zero)
        let data = try DiagnosticsExporter.encode(snapshot)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        let topLevelKeys = Set(json!.keys)
        let allowed: Set<String> = ["appVersion", "osVersion", "activeCalendarSource", "exportedAt", "settings", "permissions", "engine", "sessions", "liveLevels"]
        XCTAssertEqual(topLevelKeys, allowed, "any new top-level key requires explicit security review")
    }

    // MARK: - fixtures

    private func writePending(_ name: String) throws {
        let dir = SessionDirectory(url: root.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try TranscriptWriter.writePending(at: dir.transcript, context: makeContext())
    }

    private func writeComplete(_ name: String, engine: String = "elevenlabs") throws {
        let dir = SessionDirectory(url: root.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        var context = makeContext()
        context = TranscriptContext(
            title: context.title,
            date: context.date,
            engine: engine,
            audioRelativePaths: context.audioRelativePaths,
            startedAt: context.startedAt,
            endedAt: context.endedAt,
            attendees: context.attendees,
            language: context.language
        )
        try TranscriptWriter.writeComplete(
            at: dir.transcript,
            context: context,
            utterances: [.init(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "Hi")],
            speakerMapping: [:]
        )
    }

    private func writeFailed(_ name: String) throws {
        let dir = SessionDirectory(url: root.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try TranscriptWriter.writeFailed(at: dir.transcript, context: makeContext(), errorMessage: "test error")
    }

    private func writeRetrying(_ name: String, attempts: Int) throws {
        // TranscriptionWorker writes the retrying frontmatter inline,
        // not via TranscriptWriter. Hand-craft just enough YAML for
        // TranscriptFrontmatterReader to parse status + attempts.
        let dir = SessionDirectory(url: root.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let yaml = """
        ---
        schema: transcriber/v1
        status: retrying
        title: "test"
        date: 2026-04-30
        engine: elevenlabs
        attempts: \(attempts)
        ---

        # test
        """
        try yaml.write(to: dir.transcript, atomically: true, encoding: .utf8)
    }
}

private struct StubEngineReadiness: EngineReadinessProbing {
    let status: LocalModelCacheStatus

    func cloudKeyAvailable() async -> Bool { false }
    func localModelStatus() async -> LocalModelCacheStatus { status }
    func localModelID() -> String { CohereMLXBackend.modelID }
}

