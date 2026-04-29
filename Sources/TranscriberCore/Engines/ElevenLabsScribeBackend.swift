import Foundation

public final class ElevenLabsScribeBackend: TranscriptionEngine, @unchecked Sendable {
    public enum BackendError: Error, Equatable {
        case missingAPIKey
        case unauthorized
        case rateLimited
        case httpError(Int)
        case malformedResponse
    }

    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func transcribe(_ request: EngineRequest) async throws -> EngineResponse {
        guard !apiKey.isEmpty else { throw BackendError.missingAPIKey }

        let audioData = try Data(contentsOf: request.audioURL)
        var body = MultipartBody()
        body.appendField(name: "model_id", value: request.modelID)

        switch request.mode {
        case .singleChannelDiarized(let numSpeakers):
            body.appendField(name: "diarize", value: "true")
            if let n = numSpeakers { body.appendField(name: "num_speakers", value: String(n)) }
        case .multichannel:
            body.appendField(name: "use_multi_channel", value: "true")
            body.appendField(name: "diarize", value: "false")
        }

        body.appendField(name: "timestamps_granularity", value: "word")
        if let lang = request.languageCode {
            body.appendField(name: "language_code", value: lang)
        }
        for term in request.keyterms {
            body.appendField(name: "keyterms", value: term)
        }
        body.appendFile(name: "file", filename: request.audioURL.lastPathComponent,
                        contentType: "audio/wav", data: audioData)

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

        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> EngineResponse {
        struct Word: Decodable {
            let text: String
            let type: String
            let start: Double
            let end: Double
            let speaker_id: String?
            let channel_index: Int?
        }
        struct Body: Decodable {
            let language_code: String?
            let words: [Word]
        }
        let decoded = try JSONDecoder().decode(Body.self, from: data)

        var utterances: [EngineResponse.Utterance] = []
        var current: (speaker: String, start: Double, end: Double, text: String)?

        for w in decoded.words {
            let speaker: String
            if let cidx = w.channel_index { speaker = "speaker_\(cidx)" }
            else if let sid = w.speaker_id { speaker = sid }
            else { speaker = "speaker_0" }

            if var c = current, c.speaker == speaker {
                c.end = w.end
                if w.type == "spacing" { c.text += w.text }
                else { c.text += (c.text.isEmpty ? "" : " ") + w.text }
                current = c
            } else {
                if let c = current {
                    utterances.append(.init(speaker: c.speaker, startSeconds: c.start, endSeconds: c.end, text: c.text))
                }
                current = (speaker, w.start, w.end, w.type == "spacing" ? w.text : w.text)
            }
        }
        if let c = current {
            utterances.append(.init(speaker: c.speaker, startSeconds: c.start, endSeconds: c.end, text: c.text))
        }

        return EngineResponse(utterances: utterances, detectedLanguage: decoded.language_code, modelID: "scribe_v2")
    }
}
