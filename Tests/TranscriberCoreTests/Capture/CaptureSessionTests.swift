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
