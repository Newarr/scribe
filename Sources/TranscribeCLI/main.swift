import Foundation
import TranscriberCore

// Dev-only verification harness for the local engine pipeline:
//   swift build --product transcribe-cli
//   cp -R <app build>/mlx-swift_Cmlx.bundle .build/debug/
//   .build/debug/transcribe-cli <audio file> [language-code]
//
// With no language argument it runs the production path: ECAPA LID
// detect → VAD chunk planning → per-chunk Cohere MLX generation.
// Passing a code (e.g. "pl") mimics the Settings override.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: transcribe-cli <audio-file> [language-code]\n".utf8))
    exit(64)
}
let audioURL = URL(fileURLWithPath: arguments[1])
guard FileManager.default.fileExists(atPath: audioURL.path) else {
    FileHandle.standardError.write(Data("no such file: \(audioURL.path)\n".utf8))
    exit(66)
}
let forcedLanguage: String? = arguments.count >= 3 ? arguments[2] : nil

func format(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

let started = Date()
let language: String?
if let forcedLanguage {
    language = forcedLanguage
    print("language: \(forcedLanguage) (forced)")
} else {
    language = await EcapaLanguageDetector().detect(from: audioURL)
    print("language: \(language ?? "nil") (detected)")
}

let backend = CohereMLXBackend()
let request = EngineRequest(
    audioURL: audioURL,
    mode: .singleChannelDiarized(numSpeakers: 2),
    languageCode: language,
    keyterms: [],
    modelID: CohereMLXBackend.modelID
)

do {
    let response = try await backend.transcribe(request)
    print("engine language: \(response.detectedLanguage ?? "nil")")
    print("utterances: \(response.utterances.count)")
    print("---")
    var wordCount = 0
    var speechSeconds = 0.0
    for utterance in response.utterances {
        print("[\(format(utterance.startSeconds))-\(format(utterance.endSeconds))] \(utterance.text)")
        wordCount += utterance.text.split(whereSeparator: { $0.isWhitespace }).count
        speechSeconds += utterance.endSeconds - utterance.startSeconds
    }
    print("---")
    let wpm = speechSeconds > 0 ? Double(wordCount) * 60.0 / speechSeconds : 0
    print(String(format: "words: %d, speech: %.0fs, density: %.0f wpm, wall: %.0fs", wordCount, speechSeconds, wpm, Date().timeIntervalSince(started)))
} catch {
    FileHandle.standardError.write(Data("transcribe failed: \(error)\n".utf8))
    exit(70)
}
