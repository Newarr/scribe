import XCTest
import AVFoundation
@testable import TranscriberCore

final class CaptureSessionTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFullLifecycleProducesAllArtifacts() async throws {
        let mic = FakeAudioCaptureSource()
        let sys = FakeAudioCaptureSource()
        let id = SessionID(from: Date(timeIntervalSince1970: 1_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: root, id: id)

        let session = try CaptureSession(directory: dir, mic: mic, system: sys, sampleRate: 48000, channelCount: 1)
        try await session.start()

        for i in 0..<5 {
            let pts = Double(i) * 0.01
            mic.emit(SyntheticSampleBuffer.make(ptsSeconds: pts, sampleRate: 48000, channelCount: 1, frameCount: 480))
            sys.emit(SyntheticSampleBuffer.make(ptsSeconds: pts + 0.001, sampleRate: 48000, channelCount: 1, frameCount: 480))
        }

        try await session.stop()

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.micFinal.path), "mic.m4a missing")
        XCTAssertTrue(fm.fileExists(atPath: dir.systemFinal.path), "system.m4a missing")
        XCTAssertTrue(fm.fileExists(atPath: dir.ptsSidecar.path), "pts.json missing")
        XCTAssertTrue(fm.fileExists(atPath: dir.transcript.path), "transcript.md missing")

        let transcript = try String(contentsOf: dir.transcript, encoding: .utf8)
        XCTAssertTrue(transcript.contains("status: pending"))
        XCTAssertFalse(transcript.contains("pending_transcription"), "stub status should match TranscriptWriter.writePending")
        XCTAssertTrue(transcript.contains("- mic.m4a"))
        XCTAssertTrue(transcript.contains("- system.m4a"))

        let pts = try JSONDecoder().decode(PTSMetadata.self, from: try Data(contentsOf: dir.ptsSidecar))
        XCTAssertEqual(pts.mic.frameCount, 5 * 480)
        XCTAssertEqual(pts.system.frameCount, 5 * 480)
    }

    /// CDX-S2-CHAL.1 regression: directory.finalize() (atomic .partial -> .m4a rename)
    /// must run BEFORE writeTranscriptStub(), so the stub never references files that
    /// don't exist on disk. Verifies the stub's audio paths actually point at real files.
    func testTranscriptStubReferencesOnlyFinalizedAudio() async throws {
        let mic = FakeAudioCaptureSource()
        let sys = FakeAudioCaptureSource()
        let id = SessionID(from: Date(timeIntervalSince1970: 3_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: root, id: id)

        let session = try CaptureSession(directory: dir, mic: mic, system: sys, sampleRate: 48000, channelCount: 1)
        try await session.start()
        for i in 0..<3 {
            let pts = Double(i) * 0.01
            mic.emit(SyntheticSampleBuffer.make(ptsSeconds: pts, sampleRate: 48000, channelCount: 1, frameCount: 480))
            sys.emit(SyntheticSampleBuffer.make(ptsSeconds: pts, sampleRate: 48000, channelCount: 1, frameCount: 480))
        }
        try await session.stop()

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.micPartial.path), "mic.m4a.partial should be gone after stop")
        XCTAssertFalse(fm.fileExists(atPath: dir.systemPartial.path), "system.m4a.partial should be gone after stop")
        XCTAssertTrue(fm.fileExists(atPath: dir.micFinal.path))
        XCTAssertTrue(fm.fileExists(atPath: dir.systemFinal.path))
        // Stub references final names; both files must exist for the reference to be valid.
        let stub = try String(contentsOf: dir.transcript, encoding: .utf8)
        XCTAssertTrue(stub.contains("- mic.m4a"))
        XCTAssertTrue(stub.contains("- system.m4a"))
    }


    func testTranscriptStubDurablyPersistsSelectedLocalEngine() async throws {
        let mic = FakeAudioCaptureSource()
        let sys = FakeAudioCaptureSource()
        let id = SessionID(from: Date(timeIntervalSince1970: 6_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: root, id: id)

        let session = try CaptureSession(
            directory: dir,
            mic: mic,
            system: sys,
            sampleRate: 48000,
            channelCount: 1,
            sessionEngineIdentifier: "cohere"
        )
        try await session.start()
        mic.emit(SyntheticSampleBuffer.make(ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 480))
        sys.emit(SyntheticSampleBuffer.make(ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 480))
        try await session.stop()

        let transcript = try String(contentsOf: dir.transcript, encoding: .utf8)
        XCTAssertTrue(transcript.contains("status: pending"), transcript)
        XCTAssertTrue(transcript.contains("engine: cohere"), transcript)
        XCTAssertEqual(TranscriptFrontmatterReader.read(at: dir.transcript)?.context.engine, "cohere")
    }


    func testCaptureSessionReportsSafeLiveRMSLevelsWhenBuffersAppend() async throws {
        let mic = FakeAudioCaptureSource()
        let sys = FakeAudioCaptureSource()
        let id = SessionID(from: Date(timeIntervalSince1970: 7_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: root, id: id)
        let recorder = LiveLevelRecorder()

        let session = try CaptureSession(
            directory: dir,
            mic: mic,
            system: sys,
            sampleRate: 48000,
            channelCount: 1,
            liveLevelHandler: { stream, rms in
                Task { await recorder.record(stream: stream, rms: rms) }
            }
        )
        try await session.start()

        mic.emit(SyntheticSampleBuffer.make(ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 480, sampleValue: 0.25))
        sys.emit(SyntheticSampleBuffer.make(ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 480, sampleValue: 0.5))
        try await Task.sleep(nanoseconds: 50_000_000)

        let levels = await recorder.snapshot()
        XCTAssertEqual(try XCTUnwrap(levels[.mic]), Float(0.25), accuracy: Float(0.0001))
        XCTAssertEqual(try XCTUnwrap(levels[.system]), Float(0.5), accuracy: Float(0.0001))

        try await session.stop()
    }

    func testDiagnosticsLiveLevelsOmittedWhenNoCaptureLevelsWereObserved() throws {
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
        XCTAssertFalse(json.contains("\"micRMS\""), "unavailable production levels must remain absent/unknown instead of fabricated as zero")
        XCTAssertFalse(json.contains("\"systemRMS\""), "unavailable production levels must remain absent/unknown instead of fabricated as zero")
    }

    func testStartImmediatelyPersistsEngineManifestBeforeTranscriptExists() async throws {
        let mic = FakeAudioCaptureSource()
        let sys = FakeAudioCaptureSource()
        let id = SessionID(from: Date(timeIntervalSince1970: 6_500_000), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: root, id: id)

        let session = try CaptureSession(
            directory: dir,
            mic: mic,
            system: sys,
            sampleRate: 48000,
            channelCount: 1,
            sessionEngineIdentifier: "cohere"
        )
        try await session.start()

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.startManifest.path), "start-time provenance must exist before stop/finalize")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.transcript.path), "transcript.md should not be required for active-capture crash recovery")
        XCTAssertEqual(SessionStartManifest.read(at: dir.startManifest)?.engine, "cohere")

        // Do not stop: this test models the active-capture crash window before
        // finalize/transcript.md. The temporary directory teardown simulates
        // process death cleanup in the test environment.
    }

    func testStopWithInFlightBuffersDrainsCleanly() async throws {
        // Phase β.4: SCK output queue may have a buffer in flight when stop()
        // runs. The transactional stop chain (clear handler -> stop SCK ->
        // writer finalize-as-barrier) must absorb it without throwing AND
        // without silently losing samples. The β.2 counted no-op proves the
        // post-finalize append actually landed (vs being dropped earlier).
        let mic = FakeAudioCaptureSource()
        let sys = FakeAudioCaptureSource()
        let id = SessionID(from: Date(timeIntervalSince1970: 4_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: root, id: id)

        let session = try CaptureSession(directory: dir, mic: mic, system: sys, sampleRate: 48000, channelCount: 1)
        try await session.start()

        // Drive a few buffers BEFORE stop, then stop, then continue emitting
        // for 100ms simulating SCK queue catch-up.
        for i in 0..<10 {
            let pts = Double(i) * 0.01
            mic.emit(SyntheticSampleBuffer.make(ptsSeconds: pts, sampleRate: 48000, channelCount: 1, frameCount: 480))
            sys.emit(SyntheticSampleBuffer.make(ptsSeconds: pts, sampleRate: 48000, channelCount: 1, frameCount: 480))
        }

        try await session.stop()

        // Post-stop emission: simulating the SCK output queue still holding
        // a sample buffer at the moment stop() ran. Must NOT throw.
        for i in 0..<5 {
            let pts = 0.5 + Double(i) * 0.01
            mic.emit(SyntheticSampleBuffer.make(ptsSeconds: pts, sampleRate: 48000, channelCount: 1, frameCount: 480))
        }
        // No assertion crash, no thrown error. The earlier
        // testFullLifecycleProducesAllArtifacts already verifies the m4a
        // files exist; this test is purely about not blowing up on a
        // racing emit.
    }

    func testStopFailureLeavesRecoverableState() async throws {
        // Codex pass 1 + plan β.4: writer.finalize throwing must NOT write
        // status: failed mid-stop. The .partial files stay so
        // SessionSupervisor on next launch can rescue. To simulate a
        // failure cleanly we use a session whose output directory is made
        // read-only AFTER capture but BEFORE stop — directory.finalize()'s
        // rename throws, and we assert the .partial files survived.
        let mic = FakeAudioCaptureSource()
        let sys = FakeAudioCaptureSource()
        let id = SessionID(from: Date(timeIntervalSince1970: 5_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: root, id: id)
        let session = try CaptureSession(directory: dir, mic: mic, system: sys, sampleRate: 48000, channelCount: 1)
        try await session.start()
        for _ in 0..<3 {
            mic.emit(SyntheticSampleBuffer.make(ptsSeconds: 0.0, sampleRate: 48000, channelCount: 1, frameCount: 480))
            sys.emit(SyntheticSampleBuffer.make(ptsSeconds: 0.0, sampleRate: 48000, channelCount: 1, frameCount: 480))
        }

        // Pre-create the .m4a file with a directory at that path so the
        // rename inside SessionDirectory.finalize() throws.
        let micFinalAsDir = dir.url.appendingPathComponent("mic.m4a")
        try FileManager.default.createDirectory(at: micFinalAsDir, withIntermediateDirectories: true)

        do {
            try await session.stop()
            XCTFail("expected stop to throw because mic.m4a is occupied by a directory")
        } catch {
            // Expected. Now assert the .partial files stayed put for
            // recovery. micPartial got finalized + renamed before the
            // failing systemPartial->systemFinal step; check that at least
            // one partial OR final exists per stream so a future rescue
            // has audio to work with.
            let fm = FileManager.default
            let micPartialOrFinal = fm.fileExists(atPath: dir.micPartial.path) || fm.fileExists(atPath: dir.micFinal.path)
            let sysPartialOrFinal = fm.fileExists(atPath: dir.systemPartial.path) || fm.fileExists(atPath: dir.systemFinal.path)
            XCTAssertTrue(micPartialOrFinal, "mic audio must survive a stop failure for SessionSupervisor to rescue")
            XCTAssertTrue(sysPartialOrFinal, "system audio must survive a stop failure for SessionSupervisor to rescue")
            // CaptureSession state must NOT have been written as terminal-failed
            // mid-stop; status is .stopping (we never reached .finalized).
            let status = await session.status
            XCTAssertNotEqual(status, .finalized, "stop must not claim finalize when the rename failed")
        }
    }

    func testStartRollsBackWhenSystemSourceFails() async throws {
        let mic = FakeAudioCaptureSource()
        let sys = FakeAudioCaptureSource()
        sys.startError = FakeAudioCaptureSource.StartError()

        let id = SessionID(from: Date(timeIntervalSince1970: 2_000_000), timeZone: TimeZone(identifier: "UTC")!)
        let dir = try SessionDirectory.create(under: root, id: id)

        let session = try CaptureSession(directory: dir, mic: mic, system: sys, sampleRate: 48000, channelCount: 1)

        await XCTAssertThrowsErrorAsync(try await session.start())
        let status = await session.status
        XCTAssertEqual(status, .failed)
        XCTAssertTrue(mic.stopped, "mic should have been stopped during rollback")
    }
}

// Async XCTAssertThrowsError helper.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // expected
    }
}

private actor LiveLevelRecorder {
    private var levels: [PTSCollector.StreamID: Float] = [:]

    func record(stream: PTSCollector.StreamID, rms: Float) {
        levels[stream] = rms
    }

    func snapshot() -> [PTSCollector.StreamID: Float] {
        levels
    }
}
