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

        let pts = try JSONDecoder().decode(PTSMetadata.self, from: try Data(contentsOf: dir.ptsSidecar))
        XCTAssertEqual(pts.mic.frameCount, 5 * 480)
        XCTAssertEqual(pts.system.frameCount, 5 * 480)
    }
}
