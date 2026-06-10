import Foundation
import AVFoundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioVAD

public struct CohereMLXAdapterRequest: Sendable, Equatable {
    /// The durable, user-facing audio asset (`audio.m4a`). The native MLX
    /// adapter derives its in-memory mono 16 kHz input from this file and
    /// must never replace or mutate it.
    public let audioURL: URL
    public let modelID: String
    let modelDirectoryURL: URL
    public let languageCode: String
    public let keyterms: [String]
    let inputSampleRate: Int
    let inputChannelCount: Int
    let audioDurationSeconds: Double

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

/// Terminal errors surfaced by `CohereMLXBackend.transcribe(_:)`. Marked
/// terminal so `TranscriptionWorker.isTransient` (which classifies by type)
/// does not retry — deterministic local inference would just loop again.
///
/// `reason` is a structural summary only (tri-gram stats, unique-word fraction)
/// and never contains transcript content. `TranscriptionWorker` persists
/// `String(describing: error)` into `transcript.md`/`metadata.json` on
/// failure, so anything embedded in this case lands on disk — keep
/// transcript text out of the payload.
enum CohereMLXBackendError: Error, Sendable, Equatable {
    case degenerateOutput(reason: String)
}

extension CohereMLXBackendError: RetryClassifiableError {
    /// Deterministic local inference would just loop into the same
    /// degenerate decode, so nothing here is worth a retry.
    var isTransient: Bool { false }

    /// Without a typed code, the worker's reason-string sniff would see
    /// "rate" inside "degenerateOutput" and persist "rate_limited".
    var persistedErrorCode: String? {
        switch self {
        case .degenerateOutput: return "degenerate_output"
        }
    }
}

/// Heuristic guard against decode-loop output (model emits the same phrase
/// repeatedly instead of transcribing). Tri-gram density + unique-word
/// fraction are both cheap and either firing means the output is unusable.
enum DegenerateOutputDetector {
    /// Returns `nil` when the text looks like a healthy transcript; otherwise
    /// returns a short human-readable reason for logs and error payloads.
    /// Inputs under 30 words always return `nil` — the worker handles the
    /// "no speech detected" path separately.
    static func evaluate(_ text: String) -> String? {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
        guard words.count >= 30 else { return nil }

        var counts: [String: Int] = [:]
        let total = words.count - 2
        for i in 0..<total {
            let key = "\(words[i]) \(words[i + 1]) \(words[i + 2])"
            counts[key, default: 0] += 1
        }
        // Require BOTH an absolute minimum repeat count AND a high fraction.
        // The fraction alone would flag a 30-word transcript with three
        // repeats of "thank you very" (3/28 ≈ 11%) as degenerate; an
        // observed real-world loop has 12+ repeats, well above the floor.
        if let (top, n) = counts.max(by: { $0.value < $1.value }),
           n >= 5,
           Double(n) / Double(total) > 0.08 {
            return "tri-gram \"\(top)\" repeats \(n)/\(total) times"
        }

        let fraction = Double(Set(words).count) / Double(words.count)
        if fraction < 0.10 {
            return "unique-word fraction \(String(format: "%.3f", fraction)) below 0.10"
        }

        return nil
    }
}

public final class CohereMLXBackend: TranscriptionEngine, @unchecked Sendable {
    public static let modelID = "beshkenadze/cohere-transcribe-03-2026-mlx-fp16"
    static let defaultRequestModelID = modelID
    static let defaultLanguageCode = "en"
    static let nativeModelTypeName = "CohereTranscribeModel"
    static let nativeModuleNames = ["MLXAudioSTT", "MLXAudioCore"]

    public static let defaultModelCacheRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Scribe/Models", isDirectory: true)

    public static var defaultModelDirectoryURL: URL {
        defaultModelCacheRoot.appendingPathComponent(LocalModelManager.cacheDirectoryName(for: modelID), isDirectory: true)
    }

    public static var vadModelDirectoryURL: URL {
        defaultModelCacheRoot.appendingPathComponent(
            LocalModelManager.cacheDirectoryName(for: LocalModelManifest.sileroVADPinned.modelID),
            isDirectory: true
        )
    }

    public static var languageIDModelDirectoryURL: URL {
        defaultModelCacheRoot.appendingPathComponent(
            LocalModelManager.cacheDirectoryName(for: LocalModelManifest.ecapaLanguageIDPinned.modelID),
            isDirectory: true
        )
    }

    static let inferenceSampleRate = 16_000
    static let inferenceChannelCount = 1

    // Inference parameter overrides. The upstream `mlx-audio-swift` defaults
    // (`chunkDuration=1200`, `repetitionPenalty=1.0`) are unsafe for real
    // recordings: the model card documents 35 s training distribution and
    // greedy decoding without a penalty collapses into loop output on longer
    // audio. These values are deliberately wrapper-side so the upstream fork
    // can stay close to Blaizzy/mlx-audio-swift.
    static let inferenceChunkDurationSeconds: Float = 30.0
    static let inferenceMinChunkDurationSeconds: Float = 1.0
    static let inferenceRepetitionPenalty: Float = 1.2
    static let inferenceRepetitionContextSize: Int = 32

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
            // Sample stays in the unified log at `.private` for live debugging
            // and is intentionally NOT carried on the thrown error — the
            // worker persists `String(describing:)` to disk and meeting
            // content must not land in the failure artifact.
            Log.engine.error("Cohere MLX produced degenerate output: \(reason, privacy: .public); sample: \(output.text.prefix(120), privacy: .private)")
            throw CohereMLXBackendError.degenerateOutput(reason: reason)
        }
        let utterances: [EngineResponse.Utterance]
        if output.segments.isEmpty && output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // VAD found zero speech. Empty utterances routes the worker to
            // its "no speech detected" failure path instead of writing an
            // empty transcript.
            utterances = []
        } else if output.segments.isEmpty {
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

    static func normalizedLanguageCode(from hint: String?) -> String {
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
    /// Padding around each VAD speech span. Generous (vs the 30 ms model
    /// default) so quiet word onsets/tails aren't clipped at chunk edges.
    static let vadSpeechPadMs = 200

    private let vadModelDirectoryURL: URL

    public init(vadModelDirectoryURL: URL = CohereMLXBackend.vadModelDirectoryURL) {
        self.vadModelDirectoryURL = vadModelDirectoryURL
    }

    public func transcribe(_ request: CohereMLXAdapterRequest) async throws -> CohereMLXAdapterResponse {
        let (_, audio) = try loadAudioArray(from: request.audioURL, sampleRate: request.inputSampleRate)
        let model = try CohereTranscribeModel.fromDirectory(request.modelDirectoryURL)
        let parameters = Self.makeGenerationParameters(
            modelDefaults: model.defaultGenerationParameters,
            languageCode: request.languageCode
        )

        // VAD gating: the model deterministically hallucinates filler text
        // on silent input, so silence must never reach it. If the VAD model
        // isn't on disk (first run before the aux download lands), fall back
        // to whole-file generation rather than failing the session.
        guard let vad = try? SileroVAD.fromModelDirectory(vadModelDirectoryURL) else {
            Log.engine.warning("NativeCohereMLXAdapter: Silero VAD unavailable at \(self.vadModelDirectoryURL.path, privacy: .public); transcribing without silence gating")
            let output = model.generate(audio: audio, generationParameters: parameters)
            return CohereMLXAdapterResponse(
                text: output.text,
                segments: Self.segments(from: output.segments),
                detectedLanguage: output.language
            )
        }

        let sampleRate = request.inputSampleRate
        let timestamps = try vad.getSpeechTimestamps(
            audio,
            sampleRate: sampleRate,
            speechPadMs: Self.vadSpeechPadMs
        )
        guard !timestamps.isEmpty else {
            // Empty response; CohereMLXBackend maps it to zero utterances
            // and the worker's "no speech detected" path takes over.
            return CohereMLXAdapterResponse(text: "", segments: [], detectedLanguage: nil)
        }

        let sampleCount = audio.ndim == 1 ? audio.dim(0) : audio.dim(-1)
        let chunks = SpeechChunkPlanner.plan(
            spans: timestamps.map { SpeechSpan(start: $0.start, end: $0.end) },
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            maxChunkSeconds: Double(CohereMLXBackend.inferenceChunkDurationSeconds),
            splitPoint: { Self.lowestEnergySplitPoint(in: audio, searchRange: $0, sampleRate: sampleRate) }
        )

        var texts: [String] = []
        var segments: [CohereMLXSegment] = []
        var detectedLanguage: String?
        for chunk in chunks {
            let slice = audio[chunk.startSample ..< chunk.endSample]
            let output = model.generate(audio: slice, generationParameters: parameters)
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            texts.append(text)
            segments.append(CohereMLXSegment(
                text: text,
                startSeconds: chunk.startSeconds(sampleRate: sampleRate),
                endSeconds: chunk.endSeconds(sampleRate: sampleRate)
            ))
            if detectedLanguage == nil { detectedLanguage = output.language }
        }
        return CohereMLXAdapterResponse(
            text: texts.joined(separator: "\n"),
            segments: segments,
            detectedLanguage: detectedLanguage
        )
    }

    /// Finds the quietest point inside `searchRange` using 100 ms RMS
    /// windows, so oversized speech spans split mid-pause rather than
    /// mid-word. Only called for spans exceeding the 30 s cap, so the
    /// `asArray` materialization is bounded and rare.
    static func lowestEnergySplitPoint(in audio: MLXArray, searchRange: Range<Int>, sampleRate: Int) -> Int {
        let window = max(1, sampleRate / 10)
        guard searchRange.count > window else {
            return searchRange.lowerBound + searchRange.count / 2
        }
        let samples = audio[searchRange.lowerBound ..< searchRange.upperBound].asArray(Float.self)
        var bestStart = 0
        var bestEnergy = Float.greatestFiniteMagnitude
        var index = 0
        while index + window <= samples.count {
            var sum: Float = 0
            for i in index ..< (index + window) {
                sum += samples[i] * samples[i]
            }
            if sum < bestEnergy {
                bestEnergy = sum
                bestStart = index
            }
            index += window
        }
        return searchRange.lowerBound + bestStart + window / 2
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
