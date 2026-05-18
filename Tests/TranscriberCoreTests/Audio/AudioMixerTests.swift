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

    func testMidReadFailureThrowsAndPreservesExistingOutput() throws {
        let outURL = tmp.appendingPathComponent("mixed.wav")
        try Data("prior".utf8).write(to: outURL)
        let prior = try Data(contentsOf: outURL)

        XCTAssertThrowsError(
            try AudioMixer.mix(
                micReader: ContractAudioReader(name: "mic.m4a", failBeforeEOF: true),
                systemReader: ContractAudioReader(name: "system.m4a"),
                output: outURL,
                sampleRate: 16_000
            )
        ) { error in
            guard case AudioMixer.MixerError.readFailed = error else {
                return XCTFail("Expected readFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: outURL), prior)
    }

    func testMissingOrOneSidedInputIsRejected() throws {
        let outURL = tmp.appendingPathComponent("mixed.wav")

        XCTAssertThrowsError(
            try AudioMixer.mix(
                micReader: ContractAudioReader(name: "empty-mic.m4a", empty: true),
                systemReader: ContractAudioReader(name: "system.m4a"),
                output: outURL,
                sampleRate: 16_000
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outURL.path))
    }

    func testReadErrorAtDeclaredEOFRemainsBenign() throws {
        let outURL = tmp.appendingPathComponent("mixed.wav")

        try AudioMixer.mix(
            micReader: ContractAudioReader(name: "mic.m4a", throwAtEOF: true),
            systemReader: ContractAudioReader(name: "system.m4a", throwAtEOF: true),
            output: outURL,
            sampleRate: 16_000
        )

        try assertRIFFWAVEHeader(at: outURL)
        let file = try AVAudioFile(forReading: outURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
    }

    func testMixesTwoSilentFilesIntoSilentOutput() async throws {
        let micURL = tmp.appendingPathComponent("mic.m4a")
        let sysURL = tmp.appendingPathComponent("system.m4a")
        let outURL = tmp.appendingPathComponent("mixed.wav")

        try writeSilent(to: micURL, durationSec: 1.0)
        try writeSilent(to: sysURL, durationSec: 1.0)

        try await AudioMixer.mix(mic: micURL, system: sysURL, output: outURL, sampleRate: 16000)

        try assertRIFFWAVEHeader(at: outURL)
        let file = try AVAudioFile(forReading: outURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
    }

    private func assertRIFFWAVEHeader(at url: URL) throws {
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(data.count, 12, "WAV output must be non-empty and include a RIFF/WAVE header")
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self), "WAVE")
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
        try file.write(from: buffer)
    }
}


final class ContractAudioReader: AudioPCMReadable {
    enum ReaderError: Error { case injected }

    let sourceURL: URL
    let length: AVAudioFramePosition
    private(set) var framePosition: AVAudioFramePosition = 0
    let fileFormat: AVAudioFormat
    let processingFormat: AVAudioFormat
    private let failBeforeEOF: Bool
    private let empty: Bool
    private let throwAtEOF: Bool
    private var didThrowAtEOF = false

    init(
        name: String,
        length: AVAudioFramePosition = 4_800,
        failBeforeEOF: Bool = false,
        empty: Bool = false,
        throwAtEOF: Bool = false
    ) {
        self.sourceURL = URL(fileURLWithPath: "/tmp/\(name)")
        self.length = empty ? 0 : length
        self.fileFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        self.processingFormat = fileFormat
        self.failBeforeEOF = failBeforeEOF
        self.empty = empty
        self.throwAtEOF = throwAtEOF
    }

    func read(into buffer: AVAudioPCMBuffer) throws {
        if throwAtEOF, framePosition == length, !didThrowAtEOF {
            didThrowAtEOF = true
            throw ReaderError.injected
        }
        if failBeforeEOF, framePosition < length {
            throw ReaderError.injected
        }
        if empty || framePosition >= length {
            framePosition = length
            buffer.frameLength = 0
            return
        }
        let frames = min(AVAudioFrameCount(length - framePosition), buffer.frameCapacity)
        buffer.frameLength = frames
        let ptr = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { ptr[i] = 0.25 }
        framePosition += AVAudioFramePosition(frames)
    }
}
