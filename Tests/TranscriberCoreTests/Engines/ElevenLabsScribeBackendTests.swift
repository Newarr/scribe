import XCTest
import AVFoundation
@testable import TranscriberCore

final class ElevenLabsScribeBackendTests: XCTestCase {
    var mockSession: URLSession!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        MockURLProtocol.handler = nil
    }

    func testHappyPathParsesUtterancesGroupedBySpeaker() async throws {
        let body = try Data(contentsOf: fixture("elevenlabs-success"))
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.elevenlabs.io")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let backend = ElevenLabsScribeBackend(apiKey: "test-key", session: mockSession)
        let req = EngineRequest(
            audioURL: try makeTinyWAV(),
            mode: .singleChannelDiarized(numSpeakers: 2),
            languageCode: "en",
            keyterms: ["Faris"]
        )
        let response = try await backend.transcribe(req)

        XCTAssertEqual(response.utterances.count, 2)
        XCTAssertEqual(response.utterances[0].speaker, "speaker_0")
        XCTAssertEqual(response.utterances[0].text, "Hello there.")
        XCTAssertEqual(response.utterances[1].speaker, "speaker_1")
        XCTAssertEqual(response.utterances[1].text, "How are you doing today?")
        XCTAssertEqual(response.detectedLanguage, "en")
    }

    func testMultichannelResponseProducesChannelKeyedSpeakers() async throws {
        let body = try Data(contentsOf: fixture("elevenlabs-multichannel-success"))
        MockURLProtocol.handler = { request in
            // Note: Foundation strips httpBody by the time URLProtocol sees the request,
            // so request-side multipart params (use_multi_channel, diarize, num_speakers)
            // can't be asserted here. The backend's static mode->params switch is the
            // safety net; this test focuses on the response-parsing path that's
            // multichannel-specific (channel_index -> speaker_<n>).
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let backend = ElevenLabsScribeBackend(apiKey: "test-key", session: mockSession)
        let req = EngineRequest(
            audioURL: try makeTinyWAV(),
            mode: .multichannel,
            languageCode: "en",
            keyterms: []
        )
        let response = try await backend.transcribe(req)

        XCTAssertEqual(response.utterances.count, 2)
        XCTAssertEqual(response.utterances[0].speaker, "speaker_0")
        XCTAssertTrue(response.utterances[0].text.contains("Hi"))
        XCTAssertTrue(response.utterances[0].text.contains("Faris"))
        XCTAssertEqual(response.utterances[1].speaker, "speaker_1")
        XCTAssertTrue(response.utterances[1].text.contains("Yes"))
    }

    /// Defensive direct test of the mode->params dispatch since the URLProtocol mock
    /// can't see the request body. Calls the parser directly so this stays a unit test.
    func testParserGroupsByChannelIndex() throws {
        let body = try Data(contentsOf: fixture("elevenlabs-multichannel-success"))
        let response = try ElevenLabsScribeBackend.parse(body)
        XCTAssertEqual(response.utterances.count, 2)
        XCTAssertEqual(response.utterances.map(\.speaker), ["speaker_0", "speaker_1"])
    }

    /// Phase μ codex P1.12: ElevenLabs's actual multichannel response
    /// shape is a nested `transcripts: [{channel_index, words}, ...]`
    /// array — NOT a top-level `words[]` with per-word channel_index.
    /// v0 parser only handled the latter and would throw on the
    /// former, blocking the AEC-clean V1 multichannel path entirely.
    func testParserHandlesNestedTranscriptsShape() throws {
        let body = try Data(contentsOf: fixture("elevenlabs-multichannel-transcripts"))
        let response = try ElevenLabsScribeBackend.parse(body)

        // Two channels → two utterances, sorted by start time.
        XCTAssertEqual(response.utterances.count, 2)
        XCTAssertEqual(response.utterances[0].speaker, "speaker_0")
        XCTAssertTrue(response.utterances[0].text.contains("Hi Faris"), response.utterances[0].text)
        XCTAssertTrue(response.utterances[0].text.contains("hear me"), response.utterances[0].text)
        XCTAssertEqual(response.utterances[1].speaker, "speaker_1")
        XCTAssertTrue(response.utterances[1].text.contains("Yes"), response.utterances[1].text)
        XCTAssertTrue(response.utterances[1].text.contains("hear you"), response.utterances[1].text)

        // Detected language picks up from the per-channel field.
        XCTAssertEqual(response.detectedLanguage, "en")
    }

    /// Verifies the parser is shape-tolerant: empty `transcripts[]`
    /// (multichannel envelope but no channels populated) falls back
    /// to single-channel parsing rather than producing an empty
    /// utterance list silently.
    func testParserFallsBackWhenTranscriptsArrayIsEmpty() throws {
        let json = """
        {
            "transcripts": [],
            "language_code": "en",
            "words": [
                {"text": "Hello", "type": "word", "start": 0.0, "end": 0.5},
                {"text": ".", "type": "spacing", "start": 0.5, "end": 0.51}
            ]
        }
        """
        let response = try ElevenLabsScribeBackend.parse(Data(json.utf8))
        XCTAssertEqual(response.utterances.count, 1)
        XCTAssertEqual(response.utterances[0].text, "Hello.")
    }

    /// Interleaved word timings across channels must be sorted into a
    /// chronological transcript. Real meetings have overlapping
    /// speakers; the response carries channel-tagged words and the
    /// parser must group consecutive same-channel words into one
    /// utterance.
    func testParserSortsInterleavedMultichannelWordsByStartTime() throws {
        let json = """
        {
            "transcripts": [
                {
                    "channel_index": 0,
                    "language_code": "en",
                    "words": [
                        {"text": "First", "type": "word", "start": 0.0, "end": 0.3},
                        {"text": "later", "type": "word", "start": 2.0, "end": 2.3}
                    ]
                },
                {
                    "channel_index": 1,
                    "language_code": "en",
                    "words": [
                        {"text": "second", "type": "word", "start": 1.0, "end": 1.3},
                        {"text": "third", "type": "word", "start": 1.5, "end": 1.8}
                    ]
                }
            ]
        }
        """
        let response = try ElevenLabsScribeBackend.parse(Data(json.utf8))
        // Expected: [speaker_0:"First", speaker_1:"second third", speaker_0:"later"]
        XCTAssertEqual(response.utterances.count, 3)
        XCTAssertEqual(response.utterances[0].speaker, "speaker_0")
        XCTAssertEqual(response.utterances[0].text, "First")
        XCTAssertEqual(response.utterances[1].speaker, "speaker_1")
        XCTAssertEqual(response.utterances[1].text, "second third")
        XCTAssertEqual(response.utterances[2].speaker, "speaker_0")
        XCTAssertEqual(response.utterances[2].text, "later")
    }

    func testRateLimitMapsToRetryableError() async throws {
        let body = try Data(contentsOf: fixture("elevenlabs-rate-limit"))
        MockURLProtocol.handler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, body)
        }

        let backend = ElevenLabsScribeBackend(apiKey: "test-key", session: mockSession)
        let req = EngineRequest(
            audioURL: try makeTinyWAV(),
            mode: .singleChannelDiarized(numSpeakers: 2),
            languageCode: "en", keyterms: []
        )

        do {
            _ = try await backend.transcribe(req)
            XCTFail("expected error")
        } catch let err as ElevenLabsScribeBackend.BackendError {
            XCTAssertEqual(err, .rateLimited)
        }
    }

    private func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    }

    private func makeTinyWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        let f = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ])
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buf.frameLength = 1600
        try f.write(from: buf)
        return url
    }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else { fatalError("no handler") }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
