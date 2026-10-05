import Foundation

final class ElevenLabsScribeBackend: TranscriptionEngine, @unchecked Sendable {
    enum BackendError: Error, Equatable {
        case missingAPIKey
        case unauthorized
        case rateLimited
        case httpError(Int)
        case malformedResponse
    }

    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    init(apiKey: String, session: URLSession = .shared) {
        // Trim whitespace + newlines so users who store keys via `security
        // add-generic-password -w` (which preserves trailing newlines from
        // some shells) don't get confusing 401s or header rejections.
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func transcribe(_ request: EngineRequest) async throws -> EngineResponse {
        guard !apiKey.isEmpty else { throw BackendError.missingAPIKey }

        let audioData = try Data(contentsOf: request.audioURL)
        var body = MultipartBody()
        body.appendField(name: "model_id", value: request.modelID)

        switch request.mode {
        case .singleChannelDiarized(let numSpeakers):
            body.appendField(name: "diarize", value: "true")
            if let n = numSpeakers { body.appendField(name: "num_speakers", value: String(n)) }
        case .speakersByChannel:
            body.appendField(name: "diarize", value: "false")
        }

        body.appendField(name: "timestamps_granularity", value: "word")
        if let lang = request.languageCode {
            body.appendField(name: "language_code", value: lang)
        }
        for term in request.keyterms {
            body.appendField(name: "keyterms", value: term)
        }
        // Codex rc2-audit P1 (audit 3): rc2 uploads audio.m4a (mono
        // AAC) directly. Labelling it audio/wav was a v0 holdover from
        // when prepareAudio wrote a 16kHz WAV. Pick the Content-Type
        // from the URL extension; default to audio/m4a to match the
        // canonical artifact.
        let ext = request.audioURL.pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "wav": contentType = "audio/wav"
        case "m4a", "mp4", "aac": contentType = "audio/m4a"
        case "mp3": contentType = "audio/mpeg"
        case "flac": contentType = "audio/flac"
        default: contentType = "audio/m4a"
        }
        body.appendFile(name: "file", filename: request.audioURL.lastPathComponent,
                        contentType: contentType, data: audioData)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body.finalize()
        urlRequest.timeoutInterval = 600

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw BackendError.malformedResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw BackendError.unauthorized
        case 429: throw BackendError.rateLimited
        default: throw BackendError.httpError(http.statusCode)
        }

        return try Self.parse(data, channelActivity: request.mode.channelActivity)
    }

    static func parse(_ data: Data, channelActivity: ChannelActivity? = nil) throws -> EngineResponse {
        struct Word: Decodable {
            let text: String
            let type: String
            let start: Double
            let end: Double
            let speaker_id: String?
        }
        struct Body: Decodable {
            let language_code: String?
            let words: [Word]
        }

        let body = try JSONDecoder().decode(Body.self, from: data)
        var utterances: [EngineResponse.Utterance] = []
        var current: (speaker: String, start: Double, end: Double, text: String)?

        for w in body.words {
            let speaker: String
            if w.type == "spacing", let c = current {
                speaker = c.speaker
            } else if let channelActivity {
                speaker = channelActivity.speaker(from: w.start, to: w.end)
            } else {
                speaker = w.speaker_id ?? "speaker_0"
            }

            if var c = current, c.speaker == speaker {
                c.end = w.end
                if w.type == "spacing" { c.text += w.text }
                else { c.text += (c.text.isEmpty || c.text.last!.isWhitespace ? "" : " ") + w.text }
                current = c
            } else {
                if let c = current {
                    utterances.append(.init(speaker: c.speaker, startSeconds: c.start, endSeconds: c.end, text: c.text))
                }
                current = (speaker, w.start, w.end, w.text)
            }
        }
        if let c = current {
            utterances.append(.init(speaker: c.speaker, startSeconds: c.start, endSeconds: c.end, text: c.text))
        }

        return EngineResponse(utterances: utterances, detectedLanguage: body.language_code, modelID: "scribe_v2")
    }
}

extension ElevenLabsScribeBackend.BackendError: RetryClassifiableError {
    /// Transient: rate-limited, HTTP 5xx. Terminal: auth failures,
    /// missing API key, malformed responses, 4xx.
    var isTransient: Bool {
        switch self {
        case .rateLimited: return true
        case .httpError(let code): return (500...599).contains(code)
        case .unauthorized, .missingAPIKey, .malformedResponse: return false
        }
    }

    var persistedErrorCode: String? {
        switch self {
        case .unauthorized: return "elevenlabs_unauthorized"
        case .rateLimited: return "rate_limited"
        case .httpError, .missingAPIKey, .malformedResponse: return nil
        }
    }
}
