# Slice 2 — Single-Channel Cloud Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After Slice 1 captures `mic.m4a` + `system.m4a`, mix them into a single-channel WAV, upload to ElevenLabs Scribe v2 with `diarize=true, num_speakers=2`, parse the response, write `transcript.md` with frontmatter. End-to-end: click record → click stop → wait ~30s → markdown file appears with diarized transcript.

**Why single-channel before multichannel:** Single-channel exercises the entire engine layer (Keychain key storage, multipart upload, retry, response parsing, transcript writer, lifecycle status) on the simplest payload. Slice 3 then changes only the WAV builder and the call params, so any bug in Slice 3 is isolated to multichannel-specific code.

**Architecture:** A `TranscriptionEngine` protocol (cloud + future local). `ElevenLabsScribeBackend` is the V1 implementation. `AudioMixer` collapses two `.m4a` files to a single WAV. `KeychainStore` reads the API key. `TranscriptWriter` emits markdown with the schema from spec. `CaptureSession.stop()` from Slice 1 is extended to call the engine and write the transcript.

**Tech Stack:** URLSession with `data(for:)`, AVFoundation (AVAudioFile / AVAssetReader for mixing), Security framework (Keychain), no third-party HTTP libs.

**Spec sections covered:** Engines (lines 105-134 partial — single-channel ElevenLabs only), Finalization (lines 192-201 partial — without AEC), `transcript.md` Contract (lines 227-273), Privacy & Security (lines 339-352).

---

## File Structure

After this slice:

```
Sources/TranscriberCore/
  Storage/
    KeychainStore.swift          # Wraps Security framework
    TranscriptWriter.swift       # YAML frontmatter + body builder
  Engines/
    TranscriptionEngine.swift    # Protocol
    EngineRequest.swift          # Input bundle: audio path, language, keyterms
    EngineResponse.swift         # Output: utterances, speaker map, errors
    ElevenLabsScribeBackend.swift # Cloud V1 implementation
    MultipartBody.swift          # Reusable form-data builder
  Audio/
    AudioMixer.swift             # mic.m4a + system.m4a -> mixed mono WAV

Tests/TranscriberCoreTests/
  Storage/
    KeychainStoreTests.swift
    TranscriptWriterTests.swift
  Engines/
    MultipartBodyTests.swift
    ElevenLabsScribeBackendTests.swift  # Uses URLProtocol mock
  Audio/
    AudioMixerTests.swift               # Synthesized input
  Fixtures/
    elevenlabs-success.json             # Recorded happy-path response
    elevenlabs-rate-limit.json          # 429 response

TranscriberApp/TranscriberApp/
  AppDelegate.swift                     # MODIFY: chain engine after stop()
```

---

## Task 1: KeychainStore

**Files:**
- Create: `Sources/TranscriberCore/Storage/KeychainStore.swift`
- Create: `Tests/TranscriberCoreTests/Storage/KeychainStoreTests.swift`

Reads/writes a single value keyed by service+account. Spec rule: API keys live ONLY in Keychain, never UserDefaults/plist/logs.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TranscriberCore

final class KeychainStoreTests: XCTestCase {
    let service = "com.szymonsypniewicz.transcriber.test"
    let account = "test-account-\(UUID().uuidString)"

    override func tearDown() {
        try? KeychainStore(service: service, account: account).delete()
    }

    func testSetReadDelete() throws {
        let store = KeychainStore(service: service, account: account)
        XCTAssertNil(try store.read())

        try store.write("super-secret-value")
        XCTAssertEqual(try store.read(), "super-secret-value")

        try store.write("updated-value")
        XCTAssertEqual(try store.read(), "updated-value")

        try store.delete()
        XCTAssertNil(try store.read())
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `swift test --filter KeychainStoreTests`
Expected: FAIL — `KeychainStore` undefined.

- [ ] **Step 3: Write implementation**

```swift
import Foundation
import Security

public final class KeychainStore: Sendable {
    public enum KeychainError: Error { case osStatus(OSStatus) }

    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func write(_ value: String) throws {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    public func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.osStatus(status)
        }
    }
}
```

- [ ] **Step 4: Run to pass**

Run: `swift test --filter KeychainStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Storage/KeychainStore.swift Tests/TranscriberCoreTests/Storage/KeychainStoreTests.swift
git commit -m "storage: KeychainStore with set/read/delete"
```

---

## Task 2: AudioMixer

**Files:**
- Create: `Sources/TranscriberCore/Audio/AudioMixer.swift`
- Create: `Tests/TranscriberCoreTests/Audio/AudioMixerTests.swift`

Reads two `.m4a` files, decodes both, sums frame-by-frame at equal gain (no LUFS yet — that comes in Slice 4 finalization), writes a 16 kHz 16-bit mono WAV (Whisper-friendly default). PCM not AAC for the upload — ElevenLabs accepts both, but PCM avoids any silent re-encoding loss.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AVFoundation
@testable import TranscriberCore

final class AudioMixerTests: XCTestCase {
    var tmp: URL!
    let sampleRate: Double = 16000

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testMixesTwoSilentFilesIntoSilentOutput() async throws {
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("mixed.wav")

        try writeSilent(to: micURL, durationSec: 1.0)
        try writeSilent(to: sysURL, durationSec: 1.0)

        try await AudioMixer.mix(mic: micURL, system: sysURL, output: outURL, sampleRate: 16000)

        let file = try AVAudioFile(forReading: outURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
    }

    private func writeSilent(to url: URL, durationSec: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frameCount = AVAudioFrameCount(durationSec * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // floatChannelData[0] is already zeroed by allocator -> silence
        try file.write(from: buffer)
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `swift test --filter AudioMixerTests`
Expected: FAIL — `AudioMixer` undefined.

- [ ] **Step 3: Write implementation**

```swift
import AVFoundation
import Foundation

public enum AudioMixer {
    public enum MixerError: Error { case readFailed(URL), writeFailed(URL) }

    /// Mix two mono input files into a single mono PCM WAV at the target sample rate.
    /// Uses simple equal-gain sum with safe peak clipping at +/- 1.0.
    public static func mix(
        mic: URL,
        system: URL,
        output: URL,
        sampleRate: Double = 16000
    ) async throws {
        let micFile = try AVAudioFile(forReading: mic)
        let sysFile = try AVAudioFile(forReading: system)

        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
        let outFile = try AVAudioFile(forWriting: output, settings: outFormat.settings)

        let resampleFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        let micBuf = try resampleFully(file: micFile, to: resampleFormat)
        let sysBuf = try resampleFully(file: sysFile, to: resampleFormat)

        let frames = max(micBuf.frameLength, sysBuf.frameLength)
        let mixed = AVAudioPCMBuffer(pcmFormat: resampleFormat, frameCapacity: frames)!
        mixed.frameLength = frames

        let micPtr = micBuf.floatChannelData![0]
        let sysPtr = sysBuf.floatChannelData![0]
        let mixPtr = mixed.floatChannelData![0]
        for i in 0..<Int(frames) {
            let m = i < Int(micBuf.frameLength) ? micPtr[i] : 0
            let s = i < Int(sysBuf.frameLength) ? sysPtr[i] : 0
            let sum = (m + s) * 0.5
            mixPtr[i] = max(-1.0, min(1.0, sum))
        }

        // Convert float buffer to int16 for output WAV.
        let int16Buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frames)!
        int16Buf.frameLength = frames
        let int16Ptr = int16Buf.int16ChannelData![0]
        for i in 0..<Int(frames) {
            int16Ptr[i] = Int16(mixPtr[i] * 32767.0)
        }
        try outFile.write(from: int16Buf)
    }

    private static func resampleFully(file: AVAudioFile, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let totalFrames = AVAudioFrameCount(
            Double(file.length) * format.sampleRate / file.fileFormat.sampleRate
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames + 1024)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!

        let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!

        var endOfFile = false
        var status: AVAudioConverterOutputStatus = .haveData
        while status == .haveData && !endOfFile {
            var error: NSError?
            status = converter.convert(to: buffer, error: &error) { _, outStatus in
                do {
                    try file.read(into: readBuffer)
                } catch {
                    outStatus.pointee = .endOfStream
                    endOfFile = true
                    return nil
                }
                if readBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    endOfFile = true
                    return nil
                }
                outStatus.pointee = .haveData
                return readBuffer
            }
            if let err = error { throw err }
        }
        return buffer
    }
}
```

- [ ] **Step 4: Run to pass**

Run: `swift test --filter AudioMixerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Audio/AudioMixer.swift Tests/TranscriberCoreTests/Audio/AudioMixerTests.swift
git commit -m "audio: AudioMixer collapses two .m4a inputs to mixed mono PCM WAV"
```

---

## Task 3: MultipartBody builder

**Files:**
- Create: `Sources/TranscriberCore/Engines/MultipartBody.swift`
- Create: `Tests/TranscriberCoreTests/Engines/MultipartBodyTests.swift`

Reusable across single-channel and multichannel uploads. Pure data, easy to test.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TranscriberCore

final class MultipartBodyTests: XCTestCase {
    func testSimpleFieldsAndFile() {
        var body = MultipartBody(boundary: "BOUNDARY")
        body.appendField(name: "model_id", value: "scribe_v2")
        body.appendField(name: "diarize", value: "true")
        body.appendFile(
            name: "file",
            filename: "audio.wav",
            contentType: "audio/wav",
            data: Data("FAKEAUDIO".utf8)
        )

        let s = String(data: body.finalize(), encoding: .utf8)!
        XCTAssertTrue(s.contains("--BOUNDARY\r\nContent-Disposition: form-data; name=\"model_id\""))
        XCTAssertTrue(s.contains("scribe_v2\r\n"))
        XCTAssertTrue(s.contains("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(s.contains("Content-Type: audio/wav"))
        XCTAssertTrue(s.contains("FAKEAUDIO"))
        XCTAssertTrue(s.hasSuffix("--BOUNDARY--\r\n"))
    }

    func testRepeatedFieldsForArrayValues() {
        var body = MultipartBody(boundary: "B")
        body.appendField(name: "keyterms", value: "Faris")
        body.appendField(name: "keyterms", value: "Ramp Network")
        let s = String(data: body.finalize(), encoding: .utf8)!
        XCTAssertEqual(s.components(separatedBy: "name=\"keyterms\"").count, 3)
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `swift test --filter MultipartBodyTests`
Expected: FAIL.

- [ ] **Step 3: Write implementation**

```swift
import Foundation

public struct MultipartBody {
    public let boundary: String
    private var data = Data()

    public init(boundary: String = UUID().uuidString) { self.boundary = boundary }

    public mutating func appendField(name: String, value: String) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(value)\r\n".data(using: .utf8)!)
    }

    public mutating func appendFile(name: String, filename: String, contentType: String, data fileData: Data) {
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        data.append(fileData)
        data.append("\r\n".data(using: .utf8)!)
    }

    public func finalize() -> Data {
        var out = data
        out.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return out
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
}
```

- [ ] **Step 4: Run to pass**

Run: `swift test --filter MultipartBodyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Engines/MultipartBody.swift Tests/TranscriberCoreTests/Engines/MultipartBodyTests.swift
git commit -m "engines: MultipartBody builder with repeated-field support"
```

---

## Task 4: Engine protocol + value types

**Files:**
- Create: `Sources/TranscriberCore/Engines/TranscriptionEngine.swift`
- Create: `Sources/TranscriberCore/Engines/EngineRequest.swift`
- Create: `Sources/TranscriberCore/Engines/EngineResponse.swift`

No tests yet; these are pure data shapes. Tests come with the backend implementations.

- [ ] **Step 1: Write EngineRequest**

```swift
import Foundation

public struct EngineRequest: Sendable {
    public enum Mode: Sendable, Equatable {
        case singleChannelDiarized(numSpeakers: Int?)         // diarize=true
        case multichannel                                     // use_multi_channel=true, diarize=false
    }

    public let audioURL: URL
    public let mode: Mode
    public let languageCode: String?       // ISO 639-1, nil = auto
    public let keyterms: [String]
    public let modelID: String             // "scribe_v2"

    public init(audioURL: URL, mode: Mode, languageCode: String?, keyterms: [String], modelID: String = "scribe_v2") {
        self.audioURL = audioURL
        self.mode = mode
        self.languageCode = languageCode
        self.keyterms = keyterms
        self.modelID = modelID
    }
}
```

- [ ] **Step 2: Write EngineResponse**

```swift
import Foundation

public struct EngineResponse: Sendable, Equatable {
    public struct Utterance: Sendable, Equatable {
        public let speaker: String      // "speaker_0", "speaker_1", or attendee name after mapping
        public let startSeconds: Double
        public let endSeconds: Double
        public let text: String
    }

    public let utterances: [Utterance]
    public let detectedLanguage: String?
    public let modelID: String
}
```

- [ ] **Step 3: Write Engine protocol**

```swift
import Foundation

public protocol TranscriptionEngine: Sendable {
    func transcribe(_ request: EngineRequest) async throws -> EngineResponse
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Engines/TranscriptionEngine.swift \
        Sources/TranscriberCore/Engines/EngineRequest.swift \
        Sources/TranscriberCore/Engines/EngineResponse.swift
git commit -m "engines: TranscriptionEngine protocol + EngineRequest/Response value types"
```

---

## Task 5: ElevenLabsScribeBackend (single-channel path only)

**Files:**
- Create: `Sources/TranscriberCore/Engines/ElevenLabsScribeBackend.swift`
- Create: `Tests/TranscriberCoreTests/Engines/ElevenLabsScribeBackendTests.swift`
- Create: `Tests/TranscriberCoreTests/Engines/Fixtures/elevenlabs-success.json`
- Create: `Tests/TranscriberCoreTests/Engines/Fixtures/elevenlabs-rate-limit.json`

Tests use `URLProtocol` mock — no real network. The fixtures are recorded happy-path and rate-limit responses.

- [ ] **Step 1: Create fixture files**

`Tests/TranscriberCoreTests/Engines/Fixtures/elevenlabs-success.json`:

```json
{
  "language_code": "en",
  "language_probability": 0.99,
  "text": "Hello there. How are you doing today?",
  "words": [
    {"text": "Hello", "type": "word", "start": 0.10, "end": 0.45, "speaker_id": "speaker_0"},
    {"text": "there", "type": "word", "start": 0.46, "end": 0.80, "speaker_id": "speaker_0"},
    {"text": ".", "type": "spacing", "start": 0.80, "end": 0.81, "speaker_id": "speaker_0"},
    {"text": "How", "type": "word", "start": 1.20, "end": 1.40, "speaker_id": "speaker_1"},
    {"text": "are", "type": "word", "start": 1.41, "end": 1.55, "speaker_id": "speaker_1"},
    {"text": "you", "type": "word", "start": 1.56, "end": 1.70, "speaker_id": "speaker_1"},
    {"text": "doing", "type": "word", "start": 1.71, "end": 1.95, "speaker_id": "speaker_1"},
    {"text": "today", "type": "word", "start": 1.96, "end": 2.30, "speaker_id": "speaker_1"},
    {"text": "?", "type": "spacing", "start": 2.30, "end": 2.31, "speaker_id": "speaker_1"}
  ]
}
```

`Tests/TranscriberCoreTests/Engines/Fixtures/elevenlabs-rate-limit.json`:

```json
{"detail": {"status": "too_many_concurrent_requests", "message": "Concurrency limit reached."}}
```

These need to be embedded as test resources. Add to `Package.swift`:

```swift
.testTarget(
    name: "TranscriberCoreTests",
    dependencies: ["TranscriberCore"],
    path: "Tests/TranscriberCoreTests",
    resources: [.copy("Engines/Fixtures")]
)
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
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
        let body = try Data(contentsOf: fixture("elevenlabs-success.json"))
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

    func testRateLimitMapsToRetryableError() async throws {
        let body = try Data(contentsOf: fixture("elevenlabs-rate-limit.json"))
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
        Bundle.module.url(forResource: name.replacingOccurrences(of: ".json", with: ""), withExtension: "json", subdirectory: "Fixtures")!
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

// Test helper
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
```

- [ ] **Step 3: Run to fail**

Run: `swift test --filter ElevenLabsScribeBackendTests`
Expected: FAIL — backend type undefined.

- [ ] **Step 4: Write implementation**

```swift
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
```

- [ ] **Step 5: Run to pass**

Run: `swift test --filter ElevenLabsScribeBackendTests`
Expected: PASS, both tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranscriberCore/Engines/ElevenLabsScribeBackend.swift \
        Tests/TranscriberCoreTests/Engines/ElevenLabsScribeBackendTests.swift \
        Tests/TranscriberCoreTests/Engines/Fixtures/ \
        Package.swift
git commit -m "engines: ElevenLabsScribeBackend with single-channel diarized + multichannel modes, URL protocol mock tests"
```

---

## Task 6: TranscriptWriter

**Files:**
- Create: `Sources/TranscriberCore/Storage/TranscriptWriter.swift`
- Create: `Tests/TranscriberCoreTests/Storage/TranscriptWriterTests.swift`

Writes `transcript.md` per the spec contract (frontmatter + body). Status field updates atomically.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TranscriberCore

final class TranscriptWriterTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    func testStubWrittenWithStatusPending() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "Test",
            date: "2026-04-29",
            engine: "elevenlabs",
            audioRelativePath: "audio.m4a",
            startedAt: "2026-04-29T14:30:00Z",
            endedAt: "2026-04-29T15:00:00Z",
            attendees: ["[[Szymon]]", "[[Faris]]"],
            language: nil
        )

        try TranscriptWriter.writePending(at: url, context: context)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("status: pending"))
        XCTAssertTrue(content.contains("title: \"Test\""))
        XCTAssertTrue(content.contains("audio: audio.m4a"))
        XCTAssertTrue(content.contains("# Test"))
    }

    func testCompleteOverwritesWithBody() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "Faris Sync", date: "2026-04-29",
            engine: "elevenlabs", audioRelativePath: "audio.m4a",
            startedAt: "2026-04-29T14:30:00Z", endedAt: "2026-04-29T15:00:00Z",
            attendees: ["[[Szymon Sypniewicz]]", "[[Faris Riaz]]"],
            language: "en"
        )
        try TranscriptWriter.writePending(at: url, context: context)

        let utterances = [
            EngineResponse.Utterance(speaker: "speaker_0", startSeconds: 0, endSeconds: 1, text: "Hi"),
            EngineResponse.Utterance(speaker: "speaker_1", startSeconds: 1, endSeconds: 2, text: "Hello")
        ]
        let mapping = ["speaker_0": "Szymon Sypniewicz", "speaker_1": "Faris Riaz"]
        try TranscriptWriter.writeComplete(at: url, context: context, utterances: utterances, speakerMapping: mapping)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("status: complete"))
        XCTAssertTrue(content.contains("language: en"))
        XCTAssertTrue(content.contains("**Szymon Sypniewicz** [00:00]: Hi"))
        XCTAssertTrue(content.contains("**Faris Riaz** [00:01]: Hello"))
    }

    func testFailedTranscriptStillValid() throws {
        let url = tmp.appendingPathComponent("transcript.md")
        let context = TranscriptContext(
            title: "T", date: "2026-04-29", engine: "elevenlabs",
            audioRelativePath: "audio.m4a",
            startedAt: "...", endedAt: "...", attendees: [], language: nil
        )
        try TranscriptWriter.writePending(at: url, context: context)
        try TranscriptWriter.writeFailed(at: url, context: context, errorMessage: "Rate limited after 3 retries")

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("status: failed"))
        XCTAssertTrue(content.contains("Rate limited after 3 retries"))
        XCTAssertTrue(content.contains("Audio was captured and saved as `audio.m4a`."))
    }
}
```

- [ ] **Step 2: Run to fail**

Run: `swift test --filter TranscriptWriterTests`
Expected: FAIL.

- [ ] **Step 3: Write implementation**

```swift
import Foundation

public struct TranscriptContext: Sendable {
    public let title: String
    public let date: String          // YYYY-MM-DD
    public let engine: String        // "elevenlabs" | "cohere"
    public let audioRelativePath: String
    public let startedAt: String     // ISO8601
    public let endedAt: String
    public let attendees: [String]   // wikilink-formatted, e.g. "[[Faris Riaz]]"
    public let language: String?

    public init(title: String, date: String, engine: String, audioRelativePath: String,
                startedAt: String, endedAt: String, attendees: [String], language: String?) {
        self.title = title; self.date = date; self.engine = engine
        self.audioRelativePath = audioRelativePath
        self.startedAt = startedAt; self.endedAt = endedAt
        self.attendees = attendees; self.language = language
    }
}

public enum TranscriptWriter {
    public static func writePending(at url: URL, context c: TranscriptContext) throws {
        let body = """
        \(frontmatter(status: "pending", context: c))

        # \(c.title)

        > Transcription pending. Audio captured at `\(c.audioRelativePath)`.
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeComplete(
        at url: URL,
        context c: TranscriptContext,
        utterances: [EngineResponse.Utterance],
        speakerMapping: [String: String]
    ) throws {
        var body = "\(frontmatter(status: "complete", context: c))\n\n# \(c.title)\n\n## Transcript\n\n"
        for u in utterances {
            let displayName = speakerMapping[u.speaker] ?? u.speaker
            let timestamp = formatMMSS(u.startSeconds)
            body += "**\(displayName)** [\(timestamp)]: \(u.text)\n\n"
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeFailed(at url: URL, context c: TranscriptContext, errorMessage: String) throws {
        let body = """
        \(frontmatter(status: "failed", context: c))

        # Transcription Failed

        Audio was captured and saved as `\(c.audioRelativePath)`.

        Error: \(errorMessage)
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func frontmatter(status: String, context c: TranscriptContext) -> String {
        var lines: [String] = ["---", "schema: transcriber/v1", "status: \(status)"]
        lines.append("title: \"\(yamlEscape(c.title))\"")
        lines.append("date: \(c.date)")
        lines.append("engine: \(c.engine)")
        if let lang = c.language { lines.append("language: \(lang)") }
        lines.append("audio: \(c.audioRelativePath)")
        lines.append("started_at: \(c.startedAt)")
        lines.append("ended_at: \(c.endedAt)")
        if !c.attendees.isEmpty {
            lines.append("attendees:")
            for a in c.attendees { lines.append("  - \"\(a)\"") }
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private static func formatMMSS(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static func yamlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 4: Run to pass**

Run: `swift test --filter TranscriptWriterTests`
Expected: PASS, all three tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriberCore/Storage/TranscriptWriter.swift Tests/TranscriberCoreTests/Storage/TranscriptWriterTests.swift
git commit -m "storage: TranscriptWriter with pending/complete/failed lifecycle and YAML frontmatter"
```

---

## Task 7: Wire engine into AppDelegate finalization

**Files:**
- Modify: `TranscriberApp/TranscriberApp/AppDelegate.swift`

After `CaptureSession.stop()`, run mix → upload → write transcript. No retry logic in this slice (added in Slice 7); on failure, just write a `status: failed` transcript.

- [ ] **Step 1: Add helper to AppDelegate**

Append to `AppDelegate.swift`:

```swift
extension AppDelegate {
    @MainActor
    func transcribe(directory dir: SessionDirectory, startedAt: Date, endedAt: Date) async {
        let mixedURL = dir.url.appendingPathComponent("mixed.wav")
        let transcriptURL = dir.url.appendingPathComponent("transcript.md")
        let isoFmt = ISO8601DateFormatter()
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        let context = TranscriptContext(
            title: "Manual recording \(dir.url.lastPathComponent)",
            date: dayFmt.string(from: startedAt),
            engine: "elevenlabs",
            audioRelativePath: "audio.m4a",
            startedAt: isoFmt.string(from: startedAt),
            endedAt: isoFmt.string(from: endedAt),
            attendees: [],
            language: nil
        )
        try? TranscriptWriter.writePending(at: transcriptURL, context: context)

        do {
            try await AudioMixer.mix(mic: dir.micFinal, system: dir.systemFinal, output: mixedURL, sampleRate: 16000)

            let keychain = KeychainStore(service: "com.szymonsypniewicz.transcriber", account: "elevenlabs-api-key")
            guard let apiKey = try keychain.read(), !apiKey.isEmpty else {
                try TranscriptWriter.writeFailed(at: transcriptURL, context: context, errorMessage: "ElevenLabs API key not found in Keychain. Set it with: security add-generic-password -s 'com.szymonsypniewicz.transcriber' -a 'elevenlabs-api-key' -w '<your-key>'")
                Log.engine.error("API key missing")
                return
            }

            let backend = ElevenLabsScribeBackend(apiKey: apiKey)
            let req = EngineRequest(
                audioURL: mixedURL,
                mode: .singleChannelDiarized(numSpeakers: 2),
                languageCode: nil,
                keyterms: []
            )
            Log.engine.info("Uploading to ElevenLabs, size=\(try? Int((try? mixedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), privacy: .public)")
            let response = try await backend.transcribe(req)

            try TranscriptWriter.writeComplete(
                at: transcriptURL,
                context: TranscriptContext(
                    title: context.title, date: context.date, engine: context.engine,
                    audioRelativePath: context.audioRelativePath,
                    startedAt: context.startedAt, endedAt: context.endedAt,
                    attendees: context.attendees, language: response.detectedLanguage
                ),
                utterances: response.utterances,
                speakerMapping: [:] // calendar-derived in Slice 3
            )
            Log.engine.info("Transcript complete, utterances=\(response.utterances.count, privacy: .public)")
        } catch {
            Log.engine.error("Transcription failed: \(String(describing: error), privacy: .public)")
            try? TranscriptWriter.writeFailed(at: transcriptURL, context: context, errorMessage: String(describing: error))
        }
    }
}
```

- [ ] **Step 2: Modify `stopRecording()` to call `transcribe()`**

Replace the existing `stopRecording()` body in `AppDelegate.swift`:

```swift
@MainActor
private func stopRecording() async {
    guard let session, let dir = currentSessionDirectory else { return }
    let endedAt = Date()
    do {
        try await session.stop()
        self.status = .finalized
    } catch {
        Log.lifecycle.error("Stop failed: \(String(describing: error), privacy: .public)")
        self.status = .failed
    }
    self.session = nil
    await rebuildMenu()

    // Fire-and-forget transcription (Slice 7 will add proper queueing)
    let started = currentSessionStartedAt ?? endedAt
    Task.detached { [weak self] in
        await self?.transcribe(directory: dir, startedAt: started, endedAt: endedAt)
    }
}
```

You'll need to add stored properties:
```swift
private var currentSessionDirectory: SessionDirectory?
private var currentSessionStartedAt: Date?
```

And set them in `startRecording()`:
```swift
self.currentSessionDirectory = dir
self.currentSessionStartedAt = Date()
```

- [ ] **Step 3: Build the app**

In Xcode: ⌘B. Should compile clean.

- [ ] **Step 4: Commit**

```bash
git add TranscriberApp/
git commit -m "app: chain mix + ElevenLabs upload + transcript writer after capture stop"
```

---

## Task 8: Manual smoke test

- [ ] **Step 1: Set the API key**

```bash
security add-generic-password \
  -s 'com.szymonsypniewicz.transcriber' \
  -a 'elevenlabs-api-key' \
  -w 'YOUR-ELEVENLABS-API-KEY' \
  -U
```

(`-U` updates if exists.)

- [ ] **Step 2: Record a 1-minute test call**

Quit the app. ⌘R from Xcode. Click `Record Now` → grant any new permissions if prompted. Hold a fake call for ~60 seconds: speak yourself, play a short YouTube clip with someone else's voice. Click `Stop`.

- [ ] **Step 3: Check the session folder**

```bash
ls -la ~/Documents/Transcriber/$(ls -t ~/Documents/Transcriber/ | head -1)/
```

Expected within ~1-3 minutes:
- `mic.m4a`
- `system.m4a`
- `mixed.wav`
- `pts.json`
- `transcript.md` — with `status: complete` and a real diarized transcript

- [ ] **Step 4: Read the transcript**

```bash
cat ~/Documents/Transcriber/$(ls -t ~/Documents/Transcriber/ | head -1)/transcript.md
```

Expected:
- Frontmatter with `status: complete`, `engine: elevenlabs`, `language: en` (or whatever you spoke)
- Body with `**speaker_0** [00:00]: ...` and `**speaker_1** [00:??]: ...` lines
- Speakers correctly attributed (your voice on one speaker_id, system audio on the other)

- [ ] **Step 5: Test the failure path**

Delete the keychain entry to simulate missing key:
```bash
security delete-generic-password -s 'com.szymonsypniewicz.transcriber' -a 'elevenlabs-api-key'
```

Re-record briefly. Expected: `transcript.md` written with `status: failed` and a clear error message pointing at the `security add-generic-password` command. Restore the key after.

---

## Task 9: Slice acceptance + tag

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: All tests pass — at least 30+ tests now (carryover from Slices 0-1 + new ones from Slice 2).

- [ ] **Step 2: Update master roadmap**

Edit `docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md`:
- Slice 2 status: `2 | ✅ ... | — | shipped YYYY-MM-DD`

- [ ] **Step 3: Commit and tag**

```bash
git add docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md
git commit -m "roadmap: Slice 2 shipped"
git push origin main

git tag -a v0.2.0-slice-2 -m "Slice 2: single-channel ElevenLabs cloud transcription"
git push origin v0.2.0-slice-2
```

---

## Definition of done for Slice 2

- [ ] Click `Record Now` → speak ~60 seconds → click `Stop` → wait → `transcript.md` appears with `status: complete` and a coherent diarized body.
- [ ] `transcript.md` contains valid YAML frontmatter conforming to the schema in `docs/spec/SPEC.md` (lines 233-251).
- [ ] Speaker IDs are `speaker_0` and `speaker_1` (real names come in Slice 3 with calendar enrichment).
- [ ] Failure path writes `status: failed` with a clear actionable error message; the `mic.m4a` and `system.m4a` files are preserved.
- [ ] All XCTest tests pass.
- [ ] CI green.
- [ ] No API key visible in any log line, plist, UserDefaults, or transcript file.

When all checked, this slice is done. Start Slice 3 (multichannel + calendar attendee mapping).
