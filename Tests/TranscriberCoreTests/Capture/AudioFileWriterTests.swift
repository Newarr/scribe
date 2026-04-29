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
}
