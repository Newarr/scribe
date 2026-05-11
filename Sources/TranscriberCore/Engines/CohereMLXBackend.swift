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

/// Terminal errors surfaced by `CohereMLXBackend.transcribe(_:)` that the
/// recovery layer must NOT treat as transient. The MLX path runs locally with
/// deterministic params, so a degenerate decode is a true failure — retrying
/// without changing inputs would loop again. `TranscriptionWorker.isTransient`
/// does not classify these, so they reach the user as a clear failed status.
public enum CohereMLXBackendError: Error, Sendable, Equatable {
    case degenerateOutput(reason: String, sample: String)
}

/// Heuristic guard against the Cohere/MLX decode-loop failure mode where the
/// model spends the entire 583-second recording emitting the same phrase
/// dozens of times. The two checks below are pure-Swift and cheap; either one
/// firing means the output is unusable as a transcript.
///
/// Compression-ratio (gzip) is intentionally omitted — it would require a new
/// dependency to catch a failure mode already covered by the two checks here.
/// Add it later only if the field shows misses.
enum DegenerateOutputDetector {
    /// Returns `nil` when the text looks like a healthy transcript; otherwise
    /// returns a short human-readable reason that callers can put in an error
    /// payload or log line. Texts shorter than 30 words always return `nil` —
    /// the worker has a separate "No speech detected" terminal path for those.
    static func evaluate(_ text: String) -> String? {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard words.count >= 30 else { return nil }

        if words.count >= 3 {
            var counts: [String: Int] = [:]
            let total = words.count - 2
            for i in 0..<total {
                let key = "\(words[i].lowercased()) \(words[i + 1].lowercased()) \(words[i + 2].lowercased())"
                counts[key, default: 0] += 1
            }
            if let (top, n) = counts.max(by: { $0.value < $1.value }),
               Double(n) / Double(total) > 0.08 {
                return "tri-gram \"\(top)\" repeats \(n)/\(total) times"
            }
        }

        let unique = Set(words.map { $0.lowercased() }).count
        let fraction = Double(unique) / Double(words.count)
        if fraction < 0.10 {
            return "unique-word fraction \(String(format: "%.3f", fraction)) below 0.10"
        }

        return nil
    }
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

    // Inference parameter overrides. The upstream `mlx-audio-swift` defaults
    // (`chunkDuration=1200`, `repetitionPenalty=1.0`) are unsafe for real
    // recordings: the model card documents 35 s training distribution and
    // greedy decoding without a penalty collapses into loop output on longer
    // audio. These values are deliberately wrapper-side so the upstream fork
    // can stay close to Blaizzy/mlx-audio-swift.
    public static let inferenceChunkDurationSeconds: Float = 30.0
    public static let inferenceMinChunkDurationSeconds: Float = 1.0
    public static let inferenceRepetitionPenalty: Float = 1.2
    public static let inferenceRepetitionContextSize: Int = 32

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
        if let reason = DegenerateOutputDetector.evaluate(output.text) {
            let sample = String(output.text.prefix(120))
            Log.engine.error("Cohere MLX produced degenerate output: \(reason, privacy: .public)")
            throw CohereMLXBackendError.degenerateOutput(reason: reason, sample: sample)
        }
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
        let parameters = Self.makeGenerationParameters(
            modelDefaults: model.defaultGenerationParameters,
            languageCode: request.languageCode
        )
        let output = model.generate(audio: audio, generationParameters: parameters)
        return CohereMLXAdapterResponse(
            text: output.text,
            segments: Self.segments(from: output.segments),
            detectedLanguage: output.language
        )
    }

    /// Builds the generation parameters used at inference time. Exposed as a
    /// pure static helper so tests can verify the wrapper overrides upstream
    /// defaults without instantiating MLX. Only `maxTokens` is taken from the
    /// model defaults; the other fields are pinned to wrapper-side constants.
    static func makeGenerationParameters(
        modelDefaults: STTGenerateParameters,
        languageCode: String
    ) -> STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: modelDefaults.maxTokens,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            verbose: false,
            language: languageCode,
            chunkDuration: CohereMLXBackend.inferenceChunkDurationSeconds,
            minChunkDuration: CohereMLXBackend.inferenceMinChunkDurationSeconds,
            repetitionPenalty: CohereMLXBackend.inferenceRepetitionPenalty,
            repetitionContextSize: CohereMLXBackend.inferenceRepetitionContextSize
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
