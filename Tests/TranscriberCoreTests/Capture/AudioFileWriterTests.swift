import XCTest
import AVFoundation
@testable import TranscriberCore

final class AudioFileWriterTests: XCTestCase {
    var tmpURL: URL!

    override func setUpWithError() throws {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a.partial")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testWriteAndFinalizeProducesNonEmptyFile() async throws {
        let writer = try AudioFileWriter(url: tmpURL, sampleRate: 48000, channelCount: 1)
        try writer.start()

        for i in 0..<10 {
            let buf = SyntheticSampleBuffer.make(
                ptsSeconds: Double(i) * 0.01,
                sampleRate: 48000, channelCount: 1, frameCount: 480
            )
            try writer.append(buf)
        }
        try await writer.finalize()

        let attrs = try FileManager.default.attributesOfItem(atPath: tmpURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "writer should produce non-empty file")
    }

    func testAppendBeforeStartThrows() {
        let writer = try? AudioFileWriter(url: tmpURL, sampleRate: 48000, channelCount: 1)
        let buf = SyntheticSampleBuffer.make(ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 480)
        XCTAssertThrowsError(try writer?.append(buf))
    }

    func testPostFinalizeAppendIsCountedNoOp() async throws {
        // Phase β: SCK sample-handler queue can dispatch a buffer AFTER
        // finalize() has run (in-flight at the moment stop() ran). The
        // writer must not throw — propagating an error up into the
        // SCStreamOutput callback would crash the capture path. Instead it
        // counts the call so the test can prove the no-op fired (vs silent
        // buffer loss masked as "no error").
        let writer = try AudioFileWriter(url: tmpURL, sampleRate: 48000, channelCount: 1)
        try writer.start()

        let buf = SyntheticSampleBuffer.make(ptsSeconds: 0.0, sampleRate: 48000, channelCount: 1, frameCount: 480)
        try writer.append(buf)
        try await writer.finalize()

        XCTAssertEqual(writer.postFinalizeAppendCounter, 0)
        // Throws nothing; counts the call.
        try writer.append(buf)
        try writer.append(buf)
        XCTAssertEqual(writer.postFinalizeAppendCounter, 2,
                       "post-finalize append must increment the counter so the drain barrier proves itself")
    }

    func testAppendOutcomeReportsDroppedPostFinalize() async throws {
        // Codex Phase β review P1.4 + P1.5: callers must see whether the
        // buffer actually landed so they can skip downstream side effects
        // (PTS observation in particular).
        let writer = try AudioFileWriter(url: tmpURL, sampleRate: 48000, channelCount: 1)
        try writer.start()
        let buf = SyntheticSampleBuffer.make(ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 480)
        XCTAssertEqual(try writer.append(buf), .appended)
        try await writer.finalize()
        XCTAssertEqual(try writer.append(buf), .droppedPostFinalize,
                       "post-finalize append must report droppedPostFinalize so PTS log doesn't claim audio that didn't land")
    }

    func testFinalizeIsIdempotent() async throws {
        // Codex pass 2 P1 #4: explicit happens-before chain. finalize()
        // running twice must not double-finish-writing the AVAssetWriter
        // (which would crash) — the serial queue + finalized flag block it.
        let writer = try AudioFileWriter(url: tmpURL, sampleRate: 48000, channelCount: 1)
        try writer.start()
        let buf = SyntheticSampleBuffer.make(ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 480)
        try writer.append(buf)
        try await writer.finalize()
        try await writer.finalize()  // Must not crash.
    }

    /// CDX-3 regression: writer must defer startSession to the first appended buffer's PTS.
    /// If startSession were pinned to .zero, this 100-second-PTS clip would produce a ~100s
    /// asset (mostly silence). With the fix, asset duration tracks audio content only.
    func testNonZeroPTSProducesShortDuration() async throws {
        // AVURLAsset infers format from extension, so use .m4a (not .m4a.partial).
        let m4aURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: m4aURL) }

        let writer = try AudioFileWriter(url: m4aURL, sampleRate: 48000, channelCount: 1)
        try writer.start()

        for i in 0..<10 {
            let buf = SyntheticSampleBuffer.make(
                ptsSeconds: 100.0 + Double(i) * 0.01,
                sampleRate: 48000, channelCount: 1, frameCount: 480
            )
            try writer.append(buf)
        }
        try await writer.finalize()

        let asset = AVURLAsset(url: m4aURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertLessThan(seconds, 1.0, "asset duration must reflect audio content, not zero->first-PTS gap. Got \(seconds)s")
    }
}
