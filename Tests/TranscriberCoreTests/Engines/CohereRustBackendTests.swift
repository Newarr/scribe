import XCTest
@testable import TranscriberCore

/// Phase ο: the actual Rust subprocess integration is research-gated.
/// These tests pin the protocol contract: in rc1 the backend throws
/// `.binaryUnavailable` because the binary isn't bundled, and the
/// EngineSelector dispatch returns the right backend per mode.
final class CohereRustBackendTests: XCTestCase {
    func testNoBinaryThrowsBinaryUnavailable() async throws {
        let backend = CohereRustBackend(binaryURL: nil)
        let req = EngineRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            mode: .singleChannelDiarized(numSpeakers: 2),
            languageCode: nil,
            keyterms: []
        )
        do {
            _ = try await backend.transcribe(req)
            XCTFail("expected binaryUnavailable")
        } catch let err as CohereRustBackend.BackendError {
            XCTAssertEqual(err, .binaryUnavailable)
        }
    }

    /// Codex rc1-final P2.2: with a non-nil binaryURL but no
    /// implementation yet, the placeholder body throws
    /// `.notImplemented` (not `.binaryUnavailable`) so the error
    /// distinguishes "binary missing" from "subprocess integration
    /// pending."
    func testPlaceholderThrowsNotImplementedWhenBinaryProvided() async throws {
        let backend = CohereRustBackend(binaryURL: URL(fileURLWithPath: "/usr/local/bin/cohere_transcribe_rs"))
        let req = EngineRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            mode: .singleChannelDiarized(numSpeakers: 2),
            languageCode: nil,
            keyterms: []
        )
        do {
            _ = try await backend.transcribe(req)
            XCTFail("expected notImplemented")
        } catch let err as CohereRustBackend.BackendError {
            XCTAssertEqual(err, .notImplemented)
        }
    }

    func testEngineSelectorReturnsElevenLabsForCloudMode() {
        let engine = EngineSelector.makeEngine(
            for: .cloud,
            cloudAPIKey: { "test-key" },
            cohereBinary: nil
        )
        XCTAssertTrue(engine is ElevenLabsScribeBackend, "cloud mode → ElevenLabsScribeBackend")
    }

    func testEngineSelectorReturnsCohereForLocalMode() {
        let engine = EngineSelector.makeEngine(
            for: .local,
            cloudAPIKey: { "" },
            cohereBinary: nil
        )
        XCTAssertTrue(engine is CohereRustBackend, "local mode → CohereRustBackend")
    }
}
