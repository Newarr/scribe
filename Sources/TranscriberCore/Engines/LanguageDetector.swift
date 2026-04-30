import Foundation

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
public struct NullLanguageDetector: LanguageDetector {
    public init() {}
    public func detect(from audioURL: URL) async -> String? { nil }
}

/// Placeholder for the future WhisperKit-backed detector. Currently
/// returns `nil` (engine auto-detects); replacing this with a real
/// implementation is a post-rc1 spike (Polish quality validation,
/// `spike_polish_quality` line 138).
///
/// To wire WhisperKit:
///   1. Add `WhisperKit` as a Swift Package dependency in Package.swift.
///   2. Bundle Whisper-tiny (~39 MB) into the app's resources, with a
///      pinned SHA-256 verified at build time.
///   3. Replace the body of `detect(from:)` with WhisperKit's
///      `detectLanguage(audioPath:)` call, taking the first 60 s.
///   4. Map WhisperKit's BCP-47 output through to the return value.
public struct WhisperKitLanguageDetector: LanguageDetector {
    public init() {}
    public func detect(from audioURL: URL) async -> String? {
        // TODO Phase ν.next: integrate WhisperKit here.
        Log.engine.info("WhisperKitLanguageDetector: deferred to spike — returning nil for engine auto-detect")
        return nil
    }
}
