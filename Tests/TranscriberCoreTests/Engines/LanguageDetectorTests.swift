import XCTest
import AVFoundation
@testable import TranscriberCore

/// Phase ν: tests cover the detector PROTOCOL surface and the
/// TranscriptionWorker wire-through. The production implementation is
/// `EcapaLanguageDetector` (MLXAudioLID VoxLingua107); model-dependent
/// behavior is exercised offline only via its failure paths and pure
/// label parsing.
final class LanguageDetectorTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNullDetectorReturnsNil() async {
        let detector = NullLanguageDetector()
        let url = root.appendingPathComponent("mic.m4a")
        let result = await detector.detect(from: url)
        XCTAssertNil(result, "Null detector must always return nil")
    }

    func testEcapaDetectorReturnsNilWhenModelIsMissing() async {
        // No LID model on disk → detection must degrade to nil (engine
        // auto-detect), never throw or block.
        let detector = EcapaLanguageDetector(
            modelDirectoryURL: root.appendingPathComponent("missing-lid-model"),
            vadModelDirectoryURL: root.appendingPathComponent("missing-vad-model")
        )
        let url = root.appendingPathComponent("mic.m4a")
        let result = await detector.detect(from: url)
        XCTAssertNil(result)
    }

    func testVoxLinguaLabelParsing() {
        XCTAssertEqual(EcapaLanguageDetector.languageCode(fromLabel: "pl: Polish"), "pl")
        XCTAssertEqual(EcapaLanguageDetector.languageCode(fromLabel: "en: English"), "en")
        XCTAssertEqual(EcapaLanguageDetector.languageCode(fromLabel: "zh: Chinese"), "zh")
        XCTAssertNil(EcapaLanguageDetector.languageCode(fromLabel: "unknown_42"), "fallback labels must not become language codes")
        XCTAssertNil(EcapaLanguageDetector.languageCode(fromLabel: ""), "empty label must map to nil")
    }

    // MARK: - TranscriptionWorker integration (Phase ν wire-through)

    func testWorkerSeedsLanguageWhenDetectorReturnsValue() async throws {
        let session = makeSession("a")
        try writePCMAudio(at: session.micFinal, durationSec: 1.0)
        try writePCMAudio(at: session.systemFinal, durationSec: 1.0)
        try Data().write(to: session.url.appendingPathComponent("audio.m4a"))

        // Detector returns "pl" — the worker must construct a new
        // request with languageCode="pl" before calling the engine.
        let detector = StubDetector(value: "pl")
        let engine = SpyEngine(response: makeResponse())
        let worker = TranscriptionWorker(
            directory: session,
            context: makeContext(),
            engine: engine,
            request: EngineRequest(
                audioURL: session.url.appendingPathComponent("audio.m4a"),
                mode: .singleChannelDiarized(numSpeakers: 2),
                languageCode: nil,  // unspecified — detector must fill in
                keyterms: []
            ),
            policy: RetryPolicy(delays: [0.001]),
            languageDetector: detector
        )
        _ = await worker.run()

        let captured = await engine.lastRequest
        XCTAssertEqual(captured?.languageCode, "pl", "engine must receive the detector-resolved language")
    }

    func testWorkerSkipsDetectorWhenLanguageAlreadySet() async throws {
        let session = makeSession("b")
        try writePCMAudio(at: session.micFinal, durationSec: 1.0)
        try writePCMAudio(at: session.systemFinal, durationSec: 1.0)
        try Data().write(to: session.url.appendingPathComponent("audio.m4a"))

        let detector = StubDetector(value: "pl")  // would say polish
        let engine = SpyEngine(response: makeResponse())
        let worker = TranscriptionWorker(
            directory: session,
            context: makeContext(),
            engine: engine,
            request: EngineRequest(
                audioURL: session.url.appendingPathComponent("audio.m4a"),
                mode: .singleChannelDiarized(numSpeakers: 2),
                languageCode: "en",  // user already chose English
                keyterms: []
            ),
            policy: RetryPolicy(delays: [0.001]),
            languageDetector: detector
        )
        _ = await worker.run()

        let captured = await engine.lastRequest
        XCTAssertEqual(captured?.languageCode, "en", "explicit language must NOT be overridden by detector")
        let detectorCallCount = await detector.callCount
        XCTAssertEqual(detectorCallCount, 0, "detector must not run when language already specified")
    }

    func testWorkerFallsBackToAutoDetectWhenDetectorReturnsNil() async throws {
        let session = makeSession("c")
        try writePCMAudio(at: session.micFinal, durationSec: 1.0)
        try writePCMAudio(at: session.systemFinal, durationSec: 1.0)
        try Data().write(to: session.url.appendingPathComponent("audio.m4a"))

        let detector = StubDetector(value: nil)  // detection failed
        let engine = SpyEngine(response: makeResponse())
        let worker = TranscriptionWorker(
            directory: session,
            context: makeContext(),
            engine: engine,
            request: EngineRequest(
                audioURL: session.url.appendingPathComponent("audio.m4a"),
                mode: .singleChannelDiarized(numSpeakers: 2),
                languageCode: nil,
                keyterms: []
            ),
            policy: RetryPolicy(delays: [0.001]),
            languageDetector: detector
        )
        _ = await worker.run()

        let captured = await engine.lastRequest
        XCTAssertNil(captured?.languageCode, "nil detector result must NOT be coerced into a language tag")
    }

    func testWorkerSkipsDetectorWhenMicMissing() async throws {
        let session = makeSession("d")
        // No mic file — recovery-deferred case. Detector should not
        // run; engine receives nil language for auto-detect.
        try writePCMAudio(at: session.systemFinal, durationSec: 1.0)
        try Data().write(to: session.url.appendingPathComponent("audio.m4a"))

        let detector = StubDetector(value: "pl")
        let engine = SpyEngine(response: makeResponse())
        let worker = TranscriptionWorker(
            directory: session,
            context: makeContext(),
            engine: engine,
            request: EngineRequest(
                audioURL: session.url.appendingPathComponent("audio.m4a"),
                mode: .singleChannelDiarized(numSpeakers: 2),
                languageCode: nil,
                keyterms: []
            ),
            policy: RetryPolicy(delays: [0.001]),
            languageDetector: detector
        )
        _ = await worker.run()

        let captured = await engine.lastRequest
        XCTAssertNil(captured?.languageCode, "no mic → no detection → engine auto-detect")
        let detectorCallCount = await detector.callCount
        XCTAssertEqual(detectorCallCount, 0)
    }

    // MARK: - fixtures

    private func makeSession(_ name: String) -> SessionDirectory {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SessionDirectory(url: url)
    }

    private func makeContext() -> TranscriptContext {
        TranscriptContext(
            title: "Lang test",
            date: "2026-04-30",
            engine: "elevenlabs",
            audioRelativePaths: ["mic.m4a", "system.m4a"],
            startedAt: "2026-04-30T10:00:00Z",
            endedAt: "2026-04-30T10:05:00Z",
            attendees: [],
            language: nil
        )
    }

    private func makeResponse() -> EngineResponse {
        EngineResponse(
            utterances: [.init(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "Hi")],
            detectedLanguage: "en",
            modelID: "scribe_v2"
        )
    }

    private func writePCMAudio(at url: URL, durationSec: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(durationSec * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}

private actor StubDetector: LanguageDetector {
    let value: String?
    private(set) var callCount = 0
    init(value: String?) { self.value = value }
    func detect(from audioURL: URL) async -> String? {
        callCount += 1
        return value
    }
}

private actor SpyEngine: TranscriptionEngine {
    private(set) var lastRequest: EngineRequest?
    private let response: EngineResponse
    init(response: EngineResponse) { self.response = response }
    func transcribe(_ request: EngineRequest) async throws -> EngineResponse {
        self.lastRequest = request
        return response
    }
}
