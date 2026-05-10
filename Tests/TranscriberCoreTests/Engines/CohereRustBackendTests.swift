import XCTest
import AVFoundation
@testable import TranscriberCore

final class CohereMLXBackendTests: XCTestCase {
    func testEngineSelectorReturnsNativeCohereMLXForLocalMode() {
        let engine = EngineSelector.makeEngine(
            for: .local,
            cloudAPIKey: { "" }
        )
        XCTAssertTrue(engine is CohereMLXBackend, "local mode → native CohereMLXBackend")
    }

    func testPinnedModelIdentityIsExposedConsistently() {
        XCTAssertEqual(CohereMLXBackend.modelID, "beshkenadze/cohere-transcribe-03-2026-mlx-fp16")
        XCTAssertEqual(CohereMLXBackend.defaultRequestModelID, CohereMLXBackend.modelID)

        let request = EngineRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            mode: .singleChannelDiarized(numSpeakers: nil),
            languageCode: nil,
            keyterms: [],
            modelID: CohereMLXBackend.defaultRequestModelID
        )
        XCTAssertEqual(request.modelID, CohereMLXBackend.modelID)
    }

    func testBackendBindsNativeMLXCohereModelType() {
        XCTAssertEqual(CohereMLXBackend.nativeModelTypeName, "CohereTranscribeModel")
        XCTAssertTrue(CohereMLXBackend.nativeModuleNames.contains("MLXAudioSTT"))
        XCTAssertTrue(CohereMLXBackend.nativeModuleNames.contains("MLXAudioCore"))
    }

    func testInjectedAdapterReceivesPinnedModelDeterministicLanguageAndMono16kInputContract() async throws {
        let adapter = RecordingLocalAdapter(output: .init(text: "hello", detectedLanguage: "en"))
        let durationReader = FixedDurationReader(duration: 42.5)
        let backend = CohereMLXBackend(adapter: adapter, durationReader: durationReader)
        let response = try await backend.transcribe(EngineRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            mode: .singleChannelDiarized(numSpeakers: nil),
            languageCode: "EN_us",
            keyterms: ["must", "not", "leak"],
            modelID: "ignored-by-local"
        ))

        XCTAssertEqual(adapter.lastRequest?.audioURL.path, "/tmp/audio.m4a")
        XCTAssertEqual(adapter.lastRequest?.modelID, CohereMLXBackend.modelID)
        XCTAssertEqual(adapter.lastRequest?.modelDirectoryURL, CohereMLXBackend.defaultModelDirectoryURL)
        XCTAssertEqual(adapter.lastRequest?.languageCode, "en")
        XCTAssertEqual(adapter.lastRequest?.inputSampleRate, 16_000)
        XCTAssertEqual(adapter.lastRequest?.inputChannelCount, 1)
        XCTAssertEqual(adapter.lastRequest?.audioDurationSeconds, 42.5)
        XCTAssertEqual(adapter.lastRequest?.keyterms ?? [], [], "Local mode must not pass calendar keyterms/provider context to the adapter")
        XCTAssertEqual(response.modelID, CohereMLXBackend.modelID)
        XCTAssertEqual(response.detectedLanguage, "en")
        XCTAssertEqual(response.utterances, [
            EngineResponse.Utterance(speaker: "Speaker A", startSeconds: 0, endSeconds: 42.5, text: "hello")
        ])
    }

    func testUnsupportedLanguageFallsBackToDefaultEnglishDeterministically() async throws {
        let adapter = RecordingLocalAdapter(output: .init(text: "bonjour", detectedLanguage: nil))
        let backend = CohereMLXBackend(adapter: adapter, durationReader: FixedDurationReader(duration: 1))
        _ = try await backend.transcribe(EngineRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            mode: .singleChannelDiarized(numSpeakers: nil),
            languageCode: "kl",
            keyterms: [],
            modelID: CohereMLXBackend.modelID
        ))

        XCTAssertEqual(adapter.lastRequest?.languageCode, CohereMLXBackend.defaultLanguageCode)
    }



    func testSupportedLanguageCodesMatchCohereTokenizerSupportedSetExactly() {
        XCTAssertEqual(
            CohereMLXBackend.supportedLanguageCodes,
            Set(["en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko"]),
            "Local language support must stay aligned with Cohere tokenizer support. Update this guard only after verifying upstream tokenizer support."
        )
    }

    func testTokenizerSupportedGreekAndVietnameseHintsReachAdapter() async throws {
        for hint in ["el", "EL-gr", "vi", "VI_vn"] {
            let adapter = RecordingLocalAdapter(output: .init(text: "localized", detectedLanguage: nil))
            let backend = CohereMLXBackend(adapter: adapter, durationReader: FixedDurationReader(duration: 2))

            let response = try await backend.transcribe(EngineRequest(
                audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
                mode: .singleChannelDiarized(numSpeakers: nil),
                languageCode: hint,
                keyterms: ["private"],
                modelID: "ignored"
            ))

            let expected = hint.prefix(2).lowercased()
            XCTAssertEqual(adapter.lastRequest?.languageCode, expected, "\(hint) should pass through as a tokenizer-supported Local language")
            XCTAssertEqual(response.detectedLanguage, expected, "metadata should record the normalized supported Local language for \(hint)")
        }
    }

    func testUnsupportedLanguageHintsDefaultToEnglishAndDoNotPersistUnsupportedMetadata() async throws {
        for hint in ["ru", "hi", "tr", "sv", "da", "fi", "no", "uk"] {
            let adapter = RecordingLocalAdapter(output: .init(text: "defaulted", detectedLanguage: nil))
            let backend = CohereMLXBackend(adapter: adapter, durationReader: FixedDurationReader(duration: 2))

            let response = try await backend.transcribe(EngineRequest(
                audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
                mode: .singleChannelDiarized(numSpeakers: nil),
                languageCode: hint,
                keyterms: ["must-not-leak"],
                modelID: "ignored"
            ))

            XCTAssertEqual(adapter.lastRequest?.languageCode, CohereMLXBackend.defaultLanguageCode, "Unsupported hint \(hint) must default before reaching MLX")
            XCTAssertEqual(response.detectedLanguage, CohereMLXBackend.defaultLanguageCode, "Unsupported hint \(hint) must not be persisted as Local metadata")
            XCTAssertEqual(adapter.lastRequest?.keyterms, [], "Local language defaulting must not involve cloud/keyterm payloads")
        }
    }


    func testAdapterRequestCanCarryVerifiedLocalCacheDirectory() async throws {
        let verifiedCache = URL(fileURLWithPath: "/tmp/verified-cohere-cache", isDirectory: true)
        let adapter = RecordingLocalAdapter(output: .init(text: "cache", detectedLanguage: "en"))
        let backend = CohereMLXBackend(
            adapter: adapter,
            durationReader: FixedDurationReader(duration: 3),
            modelDirectoryURL: verifiedCache
        )

        _ = try await backend.transcribe(EngineRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            mode: .singleChannelDiarized(numSpeakers: nil),
            languageCode: "en-US",
            keyterms: ["private"],
            modelID: "ignored"
        ))

        XCTAssertEqual(adapter.lastRequest?.modelDirectoryURL, verifiedCache)
        XCTAssertEqual(adapter.lastRequest?.modelID, CohereMLXBackend.modelID)
        XCTAssertEqual(adapter.lastRequest?.keyterms, [])
    }

    func testNativeAdapterSourceUsesFromDirectoryOnlyForModelLoading() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TranscriberCore/Engines/CohereMLXBackend.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("CohereTranscribeModel.fromDirectory(request.modelDirectoryURL)"))
        XCTAssertFalse(source.contains("CohereTranscribeModel.fromPretrained"), "Transcription must not resolve or download model artifacts at inference time")
    }

    func testNativeSegmentDictionaryMappingAcceptsSTTOutputTimingKeys() {
        let segments = NativeCohereMLXAdapter.segments(from: [
            ["text": "first", "start": 5.0, "end": 6.25],
            ["text": "second", "startTime": NSNumber(value: 6.25), "endTime": "7.5"],
            ["text": "", "start": 8.0, "end": 9.0],
            ["text": "bad", "start": 10.0]
        ])

        XCTAssertEqual(segments, [
            .init(text: "first", startSeconds: 5.0, endSeconds: 6.25),
            .init(text: "second", startSeconds: 6.25, endSeconds: 7.5)
        ])
    }

    func testTimingSegmentsMapIntoEngineResponse() async throws {
        let adapter = RecordingLocalAdapter(output: .init(
            text: "hello world",
            segments: [
                .init(text: "hello", startSeconds: 5.0, endSeconds: 6.25),
                .init(text: "world", startSeconds: 6.25, endSeconds: 7.5)
            ],
            detectedLanguage: "en"
        ))
        let backend = CohereMLXBackend(adapter: adapter, durationReader: FixedDurationReader(duration: 20))

        let response = try await backend.transcribe(EngineRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            mode: .singleChannelDiarized(numSpeakers: nil),
            languageCode: "en",
            keyterms: ["Calendar", "Payload"],
            modelID: "ignored"
        ))

        XCTAssertEqual(response.utterances, [
            .init(speaker: "Speaker A", startSeconds: 5.0, endSeconds: 6.25, text: "hello"),
            .init(speaker: "Speaker A", startSeconds: 6.25, endSeconds: 7.5, text: "world")
        ])
        XCTAssertEqual(adapter.lastRequest?.keyterms, [])
    }

    func testNoTimingFallsBackToOneDurationSpanningUtterance() async throws {
        let adapter = RecordingLocalAdapter(output: .init(text: "single local transcript", segments: [], detectedLanguage: nil))
        let backend = CohereMLXBackend(adapter: adapter, durationReader: FixedDurationReader(duration: 123.75))

        let response = try await backend.transcribe(EngineRequest(
            audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            mode: .singleChannelDiarized(numSpeakers: nil),
            languageCode: nil,
            keyterms: [],
            modelID: "ignored"
        ))

        XCTAssertEqual(response.utterances, [
            .init(speaker: "Speaker A", startSeconds: 0, endSeconds: 123.75, text: "single local transcript")
        ])
        XCTAssertEqual(response.detectedLanguage, CohereMLXBackend.defaultLanguageCode)
    }

    func testDurableAudioFileRemainsUnchangedAfterAdapterTranscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("audio.m4a")
        let originalBytes = Data("durable-audio-must-stay-intact".utf8)
        try originalBytes.write(to: audioURL)

        let adapter = RecordingLocalAdapter(output: .init(text: "done", detectedLanguage: "en"))
        let backend = CohereMLXBackend(adapter: adapter, durationReader: FixedDurationReader(duration: 2.0))
        _ = try await backend.transcribe(EngineRequest(
            audioURL: audioURL,
            mode: .singleChannelDiarized(numSpeakers: nil),
            languageCode: "en",
            keyterms: ["private-calendar-term"],
            modelID: "ignored"
        ))

        XCTAssertEqual(try Data(contentsOf: audioURL), originalBytes)
        XCTAssertEqual(adapter.lastRequest?.audioURL, audioURL)
    }

    func testAVAssetDurationReaderReturnsAudioM4ADuration() async throws {
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let writer = try AudioFileWriter(url: audioURL, sampleRate: 48_000, channelCount: 1)
        try writer.start()
        for i in 0..<25 {
            let buffer = SyntheticSampleBuffer.make(
                ptsSeconds: Double(i) * 0.01,
                sampleRate: 48_000,
                channelCount: 1,
                frameCount: 480
            )
            try writer.append(buffer)
        }
        try await writer.finalize()

        let duration = try await AVAssetAudioDurationReader().durationSeconds(for: audioURL)
        XCTAssertEqual(duration, 0.25, accuracy: 0.15)
    }

    func testNativeLocalSourceDoesNotUseSubprocessInference() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TranscriberCore/Engines/CohereMLXBackend.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in ["Process(", "/bin/sh", "python", "rust", "cohere_transcribe_rs", "fromPretrained"] {
            XCTAssertFalse(source.localizedCaseInsensitiveContains(forbidden), "Local Cohere/MLX backend must not depend on subprocess inference: \(forbidden)")
        }
    }
}

private final class RecordingLocalAdapter: CohereMLXTranscribing, @unchecked Sendable {
    struct Output: Sendable {
        var text: String
        var segments: [CohereMLXSegment] = []
        var detectedLanguage: String?
    }

    private let output: Output
    private(set) var lastRequest: CohereMLXAdapterRequest?

    init(output: Output) {
        self.output = output
    }

    func transcribe(_ request: CohereMLXAdapterRequest) async throws -> CohereMLXAdapterResponse {
        lastRequest = request
        return CohereMLXAdapterResponse(
            text: output.text,
            segments: output.segments,
            detectedLanguage: output.detectedLanguage
        )
    }
}


private struct FixedDurationReader: CohereMLXAudioDurationReading {
    let duration: Double
    func durationSeconds(for audioURL: URL) async throws -> Double { duration }
}
