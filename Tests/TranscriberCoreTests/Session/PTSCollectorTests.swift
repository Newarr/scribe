import XCTest
import CoreMedia
@testable import TranscriberCore

final class PTSCollectorTests: XCTestCase {
    func testAccumulatesFirstPTSAndFrameCount() {
        let collector = PTSCollector()

        let buf1 = SyntheticSampleBuffer.make(
            ptsSeconds: 100.0, sampleRate: 48000, channelCount: 1, frameCount: 480
        )
        let buf2 = SyntheticSampleBuffer.make(
            ptsSeconds: 100.01, sampleRate: 48000, channelCount: 1, frameCount: 480
        )

        collector.observe(.mic, buffer: buf1)
        collector.observe(.mic, buffer: buf2)

        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.mic.firstPTSSeconds, 100.0, accuracy: 1e-6)
        XCTAssertEqual(snapshot.mic.sampleRate, 48000)
        XCTAssertEqual(snapshot.mic.channelCount, 1)
        XCTAssertEqual(snapshot.mic.frameCount, 960)
    }

    func testAcceptsBothStreamsIndependently() {
        let collector = PTSCollector()
        let micBuf = SyntheticSampleBuffer.make(ptsSeconds: 50.0, sampleRate: 48000, channelCount: 1, frameCount: 1000)
        let sysBuf = SyntheticSampleBuffer.make(ptsSeconds: 50.005, sampleRate: 48000, channelCount: 1, frameCount: 2000)
        collector.observe(.mic, buffer: micBuf)
        collector.observe(.system, buffer: sysBuf)

        let snap = collector.snapshot()
        XCTAssertEqual(snap.mic.frameCount, 1000)
        XCTAssertEqual(snap.system.frameCount, 2000)
        XCTAssertEqual(snap.systemLeadInMicSamples, 240) // 5ms at 48kHz
    }

    func testWritesSidecarJSON() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let collector = PTSCollector()
        collector.observe(.mic, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0, sampleRate: 48000, channelCount: 1, frameCount: 100
        ))
        collector.observe(.system, buffer: SyntheticSampleBuffer.make(
            ptsSeconds: 0.001, sampleRate: 48000, channelCount: 1, frameCount: 200
        ))

        try collector.writeSidecar(to: tmp)
        let data = try Data(contentsOf: tmp)
        let decoded = try JSONDecoder().decode(PTSMetadata.self, from: data)
        XCTAssertEqual(decoded.mic.frameCount, 100)
        XCTAssertEqual(decoded.system.frameCount, 200)
    }
}
