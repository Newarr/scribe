import XCTest
import AVFoundation
import MLXAudioSTT
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

    // MARK: - Decode-loop fix regression guards

    func testGenerationParametersOverrideUpstreamDefaults() {
        // Fabricate the upstream model defaults exactly as Blaizzy/mlx-audio-swift
        // returns them today: chunkDuration=1200, repetitionPenalty=1.0. The
        // wrapper MUST replace those before generation runs.
        let upstreamDefaults = STTGenerateParameters(
            maxTokens: 1024,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            verbose: false,
            language: "en",
            chunkDuration: 1200.0,
            minChunkDuration: 1.0,
            repetitionPenalty: 1.0,
            repetitionContextSize: 32
        )

        let parameters = NativeCohereMLXAdapter.makeGenerationParameters(
            modelDefaults: upstreamDefaults,
            languageCode: "en"
        )

        XCTAssertEqual(parameters.chunkDuration, CohereMLXBackend.inferenceChunkDurationSeconds)
        XCTAssertEqual(parameters.chunkDuration, 30.0, "30 s matches the Cohere model card's training distribution; 1200 s loops")
        XCTAssertEqual(parameters.minChunkDuration, CohereMLXBackend.inferenceMinChunkDurationSeconds)
        XCTAssertEqual(parameters.repetitionPenalty, CohereMLXBackend.inferenceRepetitionPenalty)
        XCTAssertEqual(parameters.repetitionPenalty, 1.2, "Penalty must be active to break the degenerate decode")
        XCTAssertEqual(parameters.repetitionContextSize, CohereMLXBackend.inferenceRepetitionContextSize)
        XCTAssertEqual(parameters.temperature, 0.0, "Local transcription stays deterministic")
        XCTAssertEqual(parameters.topP, 1.0)
        XCTAssertEqual(parameters.topK, 0)
        XCTAssertEqual(parameters.language, "en")
        XCTAssertEqual(parameters.maxTokens, 1024, "maxTokens is the only value taken from model defaults")
    }

    func testDegenerateOutputDetectorFlagsRepetitiveTranscripts() throws {
        let looped = String(repeating: "I think that's what I'm hearing ", count: 50)
        let loopedReason = DegenerateOutputDetector.evaluate(looped)
        XCTAssertNotNil(loopedReason, "Detector must catch the observed 'I think that's what I'm hearing' loop")
        XCTAssertTrue(loopedReason?.contains("tri-gram") ?? false, "Reason should identify the dominant tri-gram, got: \(loopedReason ?? "nil")")

        // A clean ≥30-word sentence with healthy unique-word distribution.
        // Cribbed from the pangram zoo plus padding to exceed the 30-word floor.
        let healthy = """
        The quick brown fox jumps over the lazy dog while sphinx of black quartz \
        judges my vow and pack my box with five dozen liquor jugs as vexingly \
        quick daft zebras jump over a chilled fence near the meadow at dawn.
        """
        XCTAssertNil(DegenerateOutputDetector.evaluate(healthy), "Detector must not fire on natural diverse text")

        // Fixture used by the cloud backend — guards against the detector
        // accidentally flagging legitimate short transcripts.
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/elevenlabs-success.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtureText = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        let cloudText = (fixtureText?["text"] as? String) ?? ""
        XCTAssertFalse(cloudText.isEmpty, "Fixture must still be present")
        XCTAssertNil(DegenerateOutputDetector.evaluate(cloudText), "Detector must not fire on cloud fixture text")

        XCTAssertNil(DegenerateOutputDetector.evaluate(""), "Empty input is handled by the worker's 'no speech' path")
        XCTAssertNil(DegenerateOutputDetector.evaluate("only a few words here"), "Below 30-word floor")
    }

    /// Real-MLX integration: load the actual model and run it against the
    /// recording that surfaced the loop bug. Skipped unless
    /// `SCRIBE_RUN_MLX_INTEGRATION=1` is set in the environment because it
    /// needs the model weights downloaded and takes ~minutes to complete.
    func testFailingRecordingTranscribesWithoutDegenerationIntegration() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCRIBE_RUN_MLX_INTEGRATION"] == "1",
            "Integration test; set SCRIBE_RUN_MLX_INTEGRATION=1 to run"
        )

        let env = ProcessInfo.processInfo.environment
        let audioURL: URL
        if let override = env["SCRIBE_MLX_INTEGRATION_AUDIO"], !override.isEmpty {
            audioURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            audioURL = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Scribe/2026-05-11-1756/audio.m4a")
        }
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: audioURL.path),
            "Real recording fixture missing at \(audioURL.path); set SCRIBE_MLX_INTEGRATION_AUDIO to point at one"
        )

        let modelDir = CohereMLXBackend.defaultModelDirectoryURL
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelDir.path),
            "Cohere MLX model weights missing at \(modelDir.path)"
        )

        let backend = CohereMLXBackend()
        let response = try await backend.transcribe(EngineRequest(
            audioURL: audioURL,
            mode: .singleChannelDiarized(numSpeakers: nil),
            languageCode: "en",
            keyterms: [],
            modelID: CohereMLXBackend.modelID
        ))

        let combined = response.utterances.map(\.text).joined(separator: " ")
        let wordCount = combined.split(whereSeparator: { $0.isWhitespace }).count
        print("MLX integration: \(wordCount) words; first 200 chars: \(combined.prefix(200))")

        XCTAssertGreaterThan(
            wordCount,
            1_000,
            "Local engine must produce >1000 words on the 583s recording (got \(wordCount))"
        )
        XCTAssertNil(
            DegenerateOutputDetector.evaluate(combined),
            "Local engine output must not look degenerate"
        )
    }

    func testBackendThrowsDegenerateOutputErrorOnLoopedAdapterOutput() async {
        let looped = String(repeating: "I think that's what I'm hearing ", count: 50)
        let adapter = RecordingLocalAdapter(output: .init(text: looped, detectedLanguage: "en"))
        let backend = CohereMLXBackend(adapter: adapter, durationReader: FixedDurationReader(duration: 583))

        do {
            _ = try await backend.transcribe(EngineRequest(
                audioURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
                mode: .singleChannelDiarized(numSpeakers: nil),
                languageCode: "en",
                keyterms: [],
                modelID: CohereMLXBackend.modelID
            ))
            XCTFail("Backend must throw on degenerate output, not silently return")
        } catch let error as CohereMLXBackendError {
            switch error {
            case .degenerateOutput(let reason, let sample):
                XCTAssertTrue(reason.contains("tri-gram") || reason.contains("unique-word"),
                              "Reason should identify the failure mode, got: \(reason)")
                XCTAssertFalse(sample.isEmpty, "Sample should include a snippet of the failing transcript")
                XCTAssertLessThanOrEqual(sample.count, 120, "Sample is capped at 120 chars")
            }
        } catch {
            XCTFail("Expected CohereMLXBackendError.degenerateOutput, got \(error)")
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
