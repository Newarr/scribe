import XCTest
@testable import TranscriberCore

final class PTSMetadataTests: XCTestCase {
    func testRoundTripJSON() throws {
        let original = PTSMetadata(
            mic: PTSMetadata.Stream(
                firstPTSSeconds: 12345.678,
                sampleRate: 48000,
                channelCount: 1,
                frameCount: 480000
            ),
            system: PTSMetadata.Stream(
                firstPTSSeconds: 12345.679,
                sampleRate: 48000,
                channelCount: 1,
                frameCount: 480000
            )
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PTSMetadata.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    func testFrameAlignmentDeltaInSamples() {
        let m = PTSMetadata(
            mic: .init(firstPTSSeconds: 0.000, sampleRate: 48000, channelCount: 1, frameCount: 0),
            system: .init(firstPTSSeconds: 0.010, sampleRate: 48000, channelCount: 1, frameCount: 0)
        )
        // 10ms gap at 48kHz = 480 samples
        XCTAssertEqual(m.systemLeadInMicSamples, 480)
    }
}
