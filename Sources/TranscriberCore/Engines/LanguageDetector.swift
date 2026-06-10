import Foundation
import MLX
import MLXAudioCore
import MLXAudioLID
import MLXAudioVAD

/// Spec line 129: Whisper-tiny pre-pass for language identification
/// before the engine call. Phase ν ships the protocol surface and the
/// integration point in `TranscriptionWorker`; the WhisperKit-backed
/// implementation is gated on the user supplying the bundled model
/// (see SPEC § Engine selection / Phase ν deferral notes).
///
/// Until WhisperKit lands, the worker is constructed with a
/// `NullLanguageDetector` (or `nil`) and passes `languageCode: nil` to
/// the engine, which then auto-detects. The architectural seam is
/// here so dropping WhisperKit in is a one-line change at the
/// AppDelegate worker factory.
public protocol LanguageDetector: Sendable {
    /// Returns a BCP-47 tag (e.g. "en", "pl") for the dominant
    /// language detected in the first ~60 seconds of `audioURL`, or
    /// `nil` if detection failed (corrupt audio, model unavailable,
    /// audio shorter than the model's minimum window, etc.). Callers
    /// fall back to engine auto-detect on `nil`.
    func detect(from audioURL: URL) async -> String?
}

/// No-op detector. Always returns `nil` so the worker passes through
/// to engine auto-detect. Used by default until the user wires in a
/// real implementation.
struct NullLanguageDetector: LanguageDetector {
    init() {}
    func detect(from audioURL: URL) async -> String? { nil }
}

/// ECAPA-TDNN VoxLingua107 language identification (MLXAudioLID, same
/// pinned `mlx-audio-swift` package as the Cohere engine). Chosen over
/// the originally planned WhisperKit detector: no extra dependency, the
/// 81 MB model rides the existing pinned-SHA `LocalModelManager` download
/// path, and inference is ~15 ms.
///
/// Detection runs on the first ~60 s of SPEECH, not the first 60 s of
/// file — meetings routinely open with a silent minute, and silence (or
/// hold music) would dominate a naive window. The Silero VAD locates the
/// speech onset; when the VAD model isn't on disk the window degrades to
/// the start of the file.
///
/// Every failure path returns `nil`, which the worker treats as "fall
/// through to engine auto-detect" — detection is an optimization, never
/// a gate.
public struct EcapaLanguageDetector: LanguageDetector {
    static let detectionWindowSeconds = 60
    static let sampleRate = 16_000

    private let modelDirectoryURL: URL
    private let vadModelDirectoryURL: URL

    public init(
        modelDirectoryURL: URL = CohereMLXBackend.languageIDModelDirectoryURL,
        vadModelDirectoryURL: URL = CohereMLXBackend.vadModelDirectoryURL
    ) {
        self.modelDirectoryURL = modelDirectoryURL
        self.vadModelDirectoryURL = vadModelDirectoryURL
    }

    public func detect(from audioURL: URL) async -> String? {
        guard let model = try? EcapaTdnn.fromModelDirectory(modelDirectoryURL) else {
            Log.engine.warning("EcapaLanguageDetector: LID model unavailable at \(self.modelDirectoryURL.path, privacy: .public); falling back to engine auto-detect")
            return nil
        }
        guard let (_, audio) = try? loadAudioArray(from: audioURL, sampleRate: Self.sampleRate) else {
            Log.engine.warning("EcapaLanguageDetector: could not load \(audioURL.lastPathComponent, privacy: .public)")
            return nil
        }
        let sampleCount = audio.ndim == 1 ? audio.dim(0) : audio.dim(-1)
        guard sampleCount >= Self.sampleRate else {
            // Under a second of audio — too little signal to outperform
            // the engine's own fallback.
            return nil
        }
        let window = Self.detectionWindow(
            audio: audio,
            sampleCount: sampleCount,
            vadModelDirectoryURL: vadModelDirectoryURL
        )
        let output = model.predict(waveform: window, topK: 5)
        guard let code = Self.bestSupportedCode(from: output.topLanguages) else {
            Log.engine.info("EcapaLanguageDetector: no confident Cohere-supported language in top predictions (top: \(output.language, privacy: .public) @ \(String(format: "%.2f", output.confidence), privacy: .public)); falling back to engine auto-detect")
            return nil
        }
        Log.engine.info("EcapaLanguageDetector: detected \(code, privacy: .public) (top label \(output.language, privacy: .public) @ \(String(format: "%.2f", output.confidence), privacy: .public))")
        return code
    }

    /// VoxLingua107 covers 107 languages but the Cohere tokenizer only 14,
    /// and confusable neighbors land in the top slot for real calls (e.g.
    /// "no: Norwegian" for accented English). Forcing a WRONG supported
    /// token is the failure mode this whole feature exists to fix, so:
    /// scan the top-K for the best prediction that Cohere can actually
    /// honor, and require a modest confidence floor before forcing it.
    /// Returning nil costs nothing — the engine's own fallback applies.
    static let minimumConfidence: Float = 0.25

    static func bestSupportedCode(from predictions: [LanguagePrediction]) -> String? {
        for prediction in predictions {
            guard let code = languageCode(fromLabel: prediction.language),
                  CohereMLXBackend.supportedLanguageCodes.contains(code) else {
                continue
            }
            return prediction.confidence >= minimumConfidence ? code : nil
        }
        return nil
    }

    /// VoxLingua107 labels are `"pl: Polish"`; the ISO code is the prefix.
    /// Fallback labels (`"unknown_42"`) contain non-letters and map to nil.
    static func languageCode(fromLabel label: String) -> String? {
        guard let raw = label.split(separator: ":").first else { return nil }
        let code = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty, code.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        return code
    }

    static func detectionWindow(audio: MLXArray, sampleCount: Int, vadModelDirectoryURL: URL) -> MLXArray {
        var start = 0
        if let vad = try? SileroVAD.fromModelDirectory(vadModelDirectoryURL),
           let firstSpeech = try? vad.getSpeechTimestamps(audio, sampleRate: sampleRate).first {
            // Keep at least a second of audio after the chosen start so a
            // speech onset near EOF can't produce an empty window.
            start = min(firstSpeech.start, max(0, sampleCount - sampleRate))
        }
        let end = min(sampleCount, start + detectionWindowSeconds * sampleRate)
        return audio[start ..< end]
    }
}
