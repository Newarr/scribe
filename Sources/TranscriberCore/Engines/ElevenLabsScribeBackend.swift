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
        // Trim whitespace + newlines so users who store keys via `security
        // add-generic-password -w` (which preserves trailing newlines from
        // some shells) don't get confusing 401s or header rejections.
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
        /// Single-channel diarized shape: `{"language_code": "...",
        /// "words": [...]}`.
        struct SingleChannelBody: Decodable {
            let language_code: String?
            let words: [Word]
        }
        /// Multichannel shape: `{"transcripts": [{"channel_index": N,
        /// "language_code": "...", "words": [...]}, ...]}`. Codex
        /// Phase μ P1.12 — v0 parser only handled single-channel and
        /// returned `malformedResponse` for any multichannel call,
        /// which spec line 117 mandates as the AEC-clean V1 path.
        struct ChannelTranscript: Decodable {
            let channel_index: Int?
            let language_code: String?
            let words: [Word]
        }
        struct MultichannelBody: Decodable {
            let transcripts: [ChannelTranscript]
        }

        let decoder = JSONDecoder()
        let words: [Word]
        let detectedLanguage: String?

        if let multi = try? decoder.decode(MultichannelBody.self, from: data),
           !multi.transcripts.isEmpty {
            // Flatten + tag each word with the channel-derived speaker
            // index. Sort by start time so the utterance grouping below
            // produces a chronological transcript.
            var flattened: [Word] = []
            for transcript in multi.transcripts {
                let cidx = transcript.channel_index
                for w in transcript.words {
                    // Stamp channel_index from the parent if the word
                    // didn't already carry one (defensive — some
                    // backends inline it, others put it on the parent).
                    let stamped = Word(
                        text: w.text,
                        type: w.type,
                        start: w.start,
                        end: w.end,
                        speaker_id: w.speaker_id,
                        channel_index: w.channel_index ?? cidx
                    )
                    flattened.append(stamped)
                }
            }
            flattened.sort { $0.start < $1.start }
            words = flattened
            // Detected language: prefer the first transcript that has
            // one (channels usually agree on language; if not, the
            // first non-nil is a reasonable default).
            detectedLanguage = multi.transcripts.compactMap { $0.language_code }.first
        } else {
            // Fallback: single-channel diarized shape.
            let single = try decoder.decode(SingleChannelBody.self, from: data)
            words = single.words
            detectedLanguage = single.language_code
        }

        var utterances: [EngineResponse.Utterance] = []
        var current: (speaker: String, start: Double, end: Double, text: String)?

        for w in words {
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

        return EngineResponse(utterances: utterances, detectedLanguage: detectedLanguage, modelID: "scribe_v2")
    }
}
