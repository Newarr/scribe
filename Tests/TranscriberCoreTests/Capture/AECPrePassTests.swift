import XCTest
@testable import TranscriberCore

/// Phase ξ: the actual WebRTC-rs / AUVoiceProcessing backend is
/// research-gated. These tests pin the protocol contract and the
/// no-op default behavior so a future replacement of the placeholder
/// body has explicit expectations to honor.
final class AECPrePassTests: XCTestCase {
    func testDisabledAECReportsFailure() async {
        let aec = DisabledAECPrePass()
        let url = URL(fileURLWithPath: "/tmp/notreal.m4a")
        let result = await aec.process(mic: url, system: url, output: url)
        XCTAssertEqual(result.status, .failed, "rc1 default AEC must report failure so worker takes single-channel fallback")
        XCTAssertNil(result.cleanedMicURL, ".failed must NOT carry a cleaned URL")
        XCTAssertNotNil(result.failureReason)
    }

    func testWhisperKitPlaceholderReportsFailureUntilSpikeIntegrates() async {
        // Documents the deferral: rc1 ships this as a placeholder.
        // Replacing the body unlocks the spec-line-117 multichannel
        // path.
        let aec = WebRTCAECBackend()
        let url = URL(fileURLWithPath: "/tmp/notreal.m4a")
        let result = await aec.process(mic: url, system: url, output: url)
        XCTAssertEqual(result.status, .failed)
    }

    func testStatusCodableRoundTrip() throws {
        // AECStatus appears in metadata.json (spec line 117 / 119);
        // pin the wire format so a future schema reader can parse rc1
        // exports verbatim.
        XCTAssertEqual(AECStatus.succeeded.rawValue, "succeeded")
        XCTAssertEqual(AECStatus.failed.rawValue, "failed")

        let encoded = try JSONEncoder().encode(AECStatus.succeeded)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"succeeded\"")
        let decoded = try JSONDecoder().decode(AECStatus.self, from: Data("\"failed\"".utf8))
        XCTAssertEqual(decoded, .failed)
    }
}
