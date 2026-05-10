import Foundation
import AVFoundation
import MLXAudioCore
import MLXAudioSTT

public struct CohereMLXAdapterRequest: Sendable, Equatable {
    /// The durable, user-facing audio asset (`audio.m4a`). The native MLX
    /// adapter derives its in-memory mono 16 kHz input from this file and
    /// must never replace or mutate it.
    public let audioURL: URL
    public let modelID: String
    public let modelDirectoryURL: URL
    public let languageCode: String
    public let keyterms: [String]
    public let inputSampleRate: Int
    public let inputChannelCount: Int
    public let audioDurationSeconds: Double

    public init(
        audioURL: URL,
        modelID: String,
        modelDirectoryURL: URL,
        languageCode: String,
        keyterms: [String],
        inputSampleRate: Int = 16_000,
        inputChannelCount: Int = 1,
        audioDurationSeconds: Double = 0
    ) {
        self.audioURL = audioURL
        self.modelID = modelID
        self.modelDirectoryURL = modelDirectoryURL
        self.languageCode = languageCode
        self.keyterms = keyterms
        self.inputSampleRate = inputSampleRate
        self.inputChannelCount = inputChannelCount
        self.audioDurationSeconds = audioDurationSeconds
    }
}

public struct CohereMLXSegment: Sendable, Equatable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct CohereMLXAdapterResponse: Sendable, Equatable {
    public let text: String
    public let segments: [CohereMLXSegment]
    public let detectedLanguage: String?

    public init(text: String, segments: [CohereMLXSegment], detectedLanguage: String?) {
        self.text = text
        self.segments = segments
        self.detectedLanguage = detectedLanguage
    }
}

public protocol CohereMLXTranscribing: Sendable {
    func transcribe(_ request: CohereMLXAdapterRequest) async throws -> CohereMLXAdapterResponse
}

public protocol CohereMLXAudioDurationReading: Sendable {
    func durationSeconds(for audioURL: URL) async throws -> Double
}

public final class CohereMLXBackend: TranscriptionEngine, @unchecked Sendable {
    public static let modelID = "beshkenadze/cohere-transcribe-03-2026-mlx-fp16"
    public static let defaultRequestModelID = modelID
    public static let defaultLanguageCode = "en"
    public static let nativeModelTypeName = "CohereTranscribeModel"
    public static let nativeModuleNames = ["MLXAudioSTT", "MLXAudioCore"]

    public static let defaultModelCacheRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Scribe/Models", isDirectory: true)

    public static var defaultModelDirectoryURL: URL {
        defaultModelCacheRoot.appendingPathComponent(LocalModelManager.cacheDirectoryName(for: modelID), isDirectory: true)
    }

    public static let inferenceSampleRate = 16_000
    public static let inferenceChannelCount = 1

    private let adapter: any CohereMLXTranscribing
    private let durationReader: any CohereMLXAudioDurationReading
    private let modelDirectoryURL: URL

    public init(
        adapter: any CohereMLXTranscribing = NativeCohereMLXAdapter(),
        durationReader: any CohereMLXAudioDurationReading = AVAssetAudioDurationReader(),
        modelDirectoryURL: URL = CohereMLXBackend.defaultModelDirectoryURL
    ) {
        self.adapter = adapter
        self.durationReader = durationReader
        self.modelDirectoryURL = modelDirectoryURL
    }

    public func transcribe(_ request: EngineRequest) async throws -> EngineResponse {
        let language = Self.normalizedLanguageCode(from: request.languageCode)
        let duration = try await durationReader.durationSeconds(for: request.audioURL)
        let localRequest = CohereMLXAdapterRequest(
            audioURL: request.audioURL,
            modelID: Self.modelID,
            modelDirectoryURL: modelDirectoryURL,
            languageCode: language,
            keyterms: [],
            inputSampleRate: Self.inferenceSampleRate,
            inputChannelCount: Self.inferenceChannelCount,
            audioDurationSeconds: duration
        )
        let output = try await adapter.transcribe(localRequest)
        let utterances: [EngineResponse.Utterance]
        if output.segments.isEmpty {
            utterances = [EngineResponse.Utterance(
                speaker: "Speaker A",
                startSeconds: 0,
                endSeconds: duration,
                text: output.text
            )]
        } else {
            utterances = output.segments.map { segment in
                EngineResponse.Utterance(
                    speaker: "Speaker A",
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds,
                    text: segment.text
                )
            }
        }

        return EngineResponse(
            utterances: utterances,
            detectedLanguage: output.detectedLanguage ?? language,
            modelID: Self.modelID
        )
    }

    public static func normalizedLanguageCode(from hint: String?) -> String {
        guard let hint else { return defaultLanguageCode }
        let normalized = hint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        return supportedLanguageCodes.contains(normalized) ? normalized : defaultLanguageCode
    }

    /// Cohere tokenizer-supported language codes. Keep this exact set aligned
    /// with the upstream CohereTranscribe tokenizer map; unsupported hints
    /// default to English before reaching MLX generation or Local metadata.
    public static let supportedLanguageCodes: Set<String> = [
        "en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar",
        "ja", "zh", "vi", "ko"
    ]
}

public struct AVAssetAudioDurationReader: CohereMLXAudioDurationReading {
    public init() {}

    public func durationSeconds(for audioURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}

public struct NativeCohereMLXAdapter: CohereMLXTranscribing {
    public init() {}

    public func transcribe(_ request: CohereMLXAdapterRequest) async throws -> CohereMLXAdapterResponse {
        let (_, audio) = try loadAudioArray(from: request.audioURL, sampleRate: request.inputSampleRate)
        let model = try CohereTranscribeModel.fromDirectory(request.modelDirectoryURL)
        var parameters = model.defaultGenerationParameters
        parameters = STTGenerateParameters(
            maxTokens: parameters.maxTokens,
            temperature: parameters.temperature,
            topP: parameters.topP,
            topK: parameters.topK,
            verbose: parameters.verbose,
            language: request.languageCode,
            chunkDuration: parameters.chunkDuration,
            minChunkDuration: parameters.minChunkDuration,
            repetitionPenalty: parameters.repetitionPenalty,
            repetitionContextSize: parameters.repetitionContextSize
        )
        let output = model.generate(audio: audio, generationParameters: parameters)
        return CohereMLXAdapterResponse(
            text: output.text,
            segments: Self.segments(from: output.segments),
            detectedLanguage: output.language
        )
    }

    public static func segments(from rawSegments: [[String: Any]]?) -> [CohereMLXSegment] {
        guard let rawSegments else { return [] }
        return rawSegments.compactMap { raw in
            let text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty,
                  let start = seconds(from: raw["start"] ?? raw["startTime"] ?? raw["start_seconds"]),
                  let end = seconds(from: raw["end"] ?? raw["endTime"] ?? raw["end_seconds"]),
                  end >= start else {
                return nil
            }
            return CohereMLXSegment(text: text, startSeconds: start, endSeconds: end)
        }
    }

    private static func seconds(from value: Any?) -> Double? {
        switch value {
        case let double as Double: return double.isFinite ? double : nil
        case let float as Float: return float.isFinite ? Double(float) : nil
        case let int as Int: return Double(int)
        case let int64 as Int64: return Double(int64)
        case let number as NSNumber: return number.doubleValue.isFinite ? number.doubleValue : nil
        case let string as String:
            let parsed = Double(string)
            return parsed?.isFinite == true ? parsed : nil
        default: return nil
        }
    }
}

public enum EngineSelector {
    public static func makeEngine(
        for mode: EngineMode,
        cloudAPIKey: () -> String,
        cohereBinary: URL? = nil,
        urlSession: URLSession = .shared
    ) -> TranscriptionEngine {
        switch mode {
        case .cloud:
            return ElevenLabsScribeBackend(apiKey: cloudAPIKey(), session: urlSession)
        case .local:
            _ = cohereBinary
            return CohereMLXBackend()
        }
    }
}
