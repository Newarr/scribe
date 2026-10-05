import AVFoundation
import XCTest

@testable import TranscriberCore

final class ChannelActivityTests: XCTestCase {
  func testUserTalkingAloneIsMe() throws {
    let activity = try XCTUnwrap(
      ChannelActivity.scripted([
        (seconds: 10, micDecibels: -20, systemDecibels: -120),
        (seconds: 10, micDecibels: -50, systemDecibels: -20),
        (seconds: 10, micDecibels: -50, systemDecibels: -120),
      ]))
    XCTAssertEqual(activity.speaker(from: 1, to: 9), ChannelActivity.micSpeaker)
    XCTAssertEqual(activity.speaker(from: 11, to: 19), ChannelActivity.systemSpeaker)
  }

  func testRemoteVoiceLeakingIntoTheMicLouderThanSystemAudioIsThem() throws {
    let activity = try XCTUnwrap(
      ChannelActivity.scripted([
        (seconds: 10, micDecibels: -20, systemDecibels: -120),
        (seconds: 10, micDecibels: -17, systemDecibels: -20),
        (seconds: 10, micDecibels: -50, systemDecibels: -120),
      ]))
    XCTAssertEqual(activity.speaker(from: 11, to: 19), ChannelActivity.systemSpeaker)
  }

  func testUserTalkingOverTheRemoteThroughSpeakersIsMe() throws {
    let activity = try XCTUnwrap(
      ChannelActivity.scripted([
        (seconds: 10, micDecibels: -20, systemDecibels: -120),
        (seconds: 10, micDecibels: -17, systemDecibels: -20),
        (seconds: 5, micDecibels: -2, systemDecibels: -20),
        (seconds: 10, micDecibels: -50, systemDecibels: -120),
      ]))
    XCTAssertEqual(activity.speaker(from: 21, to: 24), ChannelActivity.micSpeaker)
  }

  func testRecordingWithoutRemoteSpeechHasNoChannelSpeakers() {
    XCTAssertNil(
      ChannelActivity.scripted([
        (seconds: 20, micDecibels: -20, systemDecibels: -120),
        (seconds: 10, micDecibels: -50, systemDecibels: -120),
      ]))
  }

  func testMeasureAlignsRawStreamsOnTheCaptureTimeline() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = SessionDirectory(url: dir)
    try writeMicThenSystemTurns(into: session)

    let activity = try XCTUnwrap(
      ChannelActivity.measure(
        mic: session.micFinal, system: session.systemFinal, ptsLog: session.ptsStreamingLog))
    XCTAssertEqual(activity.speaker(from: 0.5, to: 2.5), ChannelActivity.micSpeaker)
    XCTAssertEqual(activity.speaker(from: 3.5, to: 5.5), ChannelActivity.systemSpeaker)
  }
}

extension ChannelActivity {
  static func scripted(
    _ turns: [(seconds: Double, micDecibels: Float, systemDecibels: Float)]
  ) -> ChannelActivity? {
    let windows = turns.flatMap { turn in
      Array(
        repeating: (turn.micDecibels, turn.systemDecibels),
        count: Int(turn.seconds / windowSeconds))
    }
    return ChannelActivity(
      micMeanSquares: windows.map { pow(10, $0.0 / 10) },
      systemMeanSquares: windows.map { pow(10, $0.1 / 10) })
  }
}

func writeMicThenSystemTurns(into session: SessionDirectory) throws {
  try writeAACTurns(to: session.micFinal, amplitudes: [0.4, 0])
  try writeAACTurns(to: session.systemFinal, amplitudes: [0, 0.4])
  let entries = ["mic", "system"].map {
    PTSLogEntry(stream: $0, ptsSeconds: 100, sampleCount: 6 * 48000, sampleRate: 48000)
  }
  let encoder = JSONEncoder()
  let lines = try entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
  try (lines.joined(separator: "\n") + "\n").write(
    to: session.ptsStreamingLog, atomically: true, encoding: .utf8)
}

private func writeAACTurns(to url: URL, amplitudes: [Float]) throws {
  let sampleRate = 48000.0
  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
  let file = try AVAudioFile(
    forWriting: url,
    settings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ])
  let turnFrames = Int(3 * sampleRate)
  let buffer = AVAudioPCMBuffer(
    pcmFormat: format, frameCapacity: AVAudioFrameCount(turnFrames * amplitudes.count))!
  buffer.frameLength = buffer.frameCapacity
  let samples = buffer.floatChannelData![0]
  for (turn, amplitude) in amplitudes.enumerated() {
    for i in 0..<turnFrames {
      samples[turn * turnFrames + i] = amplitude * Float(sin(2 * .pi * 440 * Double(i) / sampleRate))
    }
  }
  try file.write(from: buffer)
}
