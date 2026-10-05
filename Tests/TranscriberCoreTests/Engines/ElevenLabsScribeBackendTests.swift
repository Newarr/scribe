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

    func testChannelSpeakersSplitWhatDiarizationMergedIntoOneVoice() throws {
        let json = """
        {
            "language_code": "pl",
            "words": [
                {"text": "Dzień", "type": "word", "start": 1.0, "end": 1.4, "speaker_id": "speaker_0"},
                {"text": " ", "type": "spacing", "start": 1.4, "end": 1.5, "speaker_id": "speaker_0"},
                {"text": "dobry.", "type": "word", "start": 1.5, "end": 2.0, "speaker_id": "speaker_0"},
                {"text": " ", "type": "spacing", "start": 2.0, "end": 11.0, "speaker_id": "speaker_0"},
                {"text": "Cześć!", "type": "word", "start": 11.0, "end": 11.6, "speaker_id": "speaker_0"}
            ]
        }
        """
        let activity = try XCTUnwrap(ChannelActivity.scripted([
            (seconds: 10, micDecibels: -20, systemDecibels: -120),
            (seconds: 10, micDecibels: -50, systemDecibels: -20),
            (seconds: 10, micDecibels: -50, systemDecibels: -120),
        ]))
        let response = try ElevenLabsScribeBackend.parse(Data(json.utf8), channelActivity: activity)

        XCTAssertEqual(response.utterances.map(\.speaker), [ChannelActivity.micSpeaker, ChannelActivity.systemSpeaker])
        XCTAssertEqual(response.utterances.map { $0.text.trimmingCharacters(in: .whitespaces) }, ["Dzień dobry.", "Cześć!"])
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
