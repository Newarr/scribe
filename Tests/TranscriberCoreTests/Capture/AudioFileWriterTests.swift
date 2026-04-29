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
