import AVFoundation
import Foundation

public struct ChannelActivity: Sendable, Equatable {
  public static let micSpeaker = "Me"
  public static let systemSpeaker = "Them"

  static let windowSeconds = 0.05
  static let analysisSampleRate = 16_000.0
  static let echoHoldWindows = 3
  static let speechAboveFloorDecibels: Float = 10
  static let micAboveEchoDecibels: Float = 10
  static let minimumSpeechWindowsPerChannel = 40

  enum Vote: Sendable, Equatable {
    case mic, system, silence
  }

  let votes: [Vote]
  let micDecibels: [Float]
  let systemDecibels: [Float]

  /// Returns nil unless both channels carried speech, because a one-sided
  /// recording (an in-person meeting, a muted call) is better served by
  /// acoustic diarization than by channel labels.
  init?(micMeanSquares: [Float], systemMeanSquares: [Float]) {
    let count = max(micMeanSquares.count, systemMeanSquares.count)
    guard count > 0 else { return nil }
    let mic = (0..<count).map { Self.decibels(meanSquareAt: $0, in: micMeanSquares) }
    let system = (0..<count).map { Self.decibels(meanSquareAt: $0, in: systemMeanSquares) }
    // Holding the system peak covers the speaker-to-mic delay and room reverb.
    let heldSystem = (0..<count).map { system[max(0, $0 - Self.echoHoldWindows + 1)...$0].max()! }
    let micSpeechLevel = Self.speechLevel(mic)
    let systemSpeechLevel = Self.speechLevel(system)
    let echoGain = Self.median(
      (0..<count).filter { heldSystem[$0] > systemSpeechLevel }.map { mic[$0] - heldSystem[$0] })

    let votes = (0..<count).map { i -> Vote in
      let echoLevel = echoGain.map { heldSystem[i] + $0 } ?? -.infinity
      if mic[i] > micSpeechLevel && mic[i] > echoLevel + Self.micAboveEchoDecibels { return .mic }
      if system[i] > systemSpeechLevel { return .system }
      return .silence
    }
    guard votes.count(where: { $0 == .mic }) >= Self.minimumSpeechWindowsPerChannel,
      votes.count(where: { $0 == .system }) >= Self.minimumSpeechWindowsPerChannel
    else { return nil }

    self.votes = votes
    self.micDecibels = mic
    self.systemDecibels = system
  }

  public func speaker(from start: Double, to end: Double) -> String {
    let first = min(max(0, Int(start / Self.windowSeconds)), votes.count - 1)
    let last = min(max(first + 1, Int((end / Self.windowSeconds).rounded(.up))), votes.count)
    let window = first..<last
    let micVotes = votes[window].count(where: { $0 == .mic })
    let systemVotes = votes[window].count(where: { $0 == .system })
    let micWins =
      micVotes == systemVotes
      ? micDecibels[window].max()! > systemDecibels[window].max()!
      : micVotes > systemVotes
    return micWins ? Self.micSpeaker : Self.systemSpeaker
  }

  static func measure(mic: URL, system: URL, ptsLog: URL) throws -> ChannelActivity? {
    let timeline = try AudioFinalizer.readPTSTimeline(
      at: ptsLog, outputSampleRate: analysisSampleRate)
    let format = AVAudioFormat(standardFormatWithSampleRate: analysisSampleRate, channels: 1)!
    let windowFrames = Int(analysisSampleRate * windowSeconds)
    let chunkFrames = windowFrames * 20
    let micReader = try AudioFinalizer.TimelineStreamReader(
      file: AVAudioFile(forReading: mic), target: format, segments: timeline.mic,
      chunkFrames: AVAudioFrameCount(chunkFrames))
    let systemReader = try AudioFinalizer.TimelineStreamReader(
      file: AVAudioFile(forReading: system), target: format, segments: timeline.system,
      chunkFrames: AVAudioFrameCount(chunkFrames))

    let endFrame = max(micReader.endFrame, systemReader.endFrame)
    var micChunk = [Float](repeating: 0, count: chunkFrames)
    var systemChunk = [Float](repeating: 0, count: chunkFrames)
    var micMeanSquares: [Float] = []
    var systemMeanSquares: [Float] = []
    for chunkStart in stride(from: 0, to: endFrame, by: chunkFrames) {
      try micChunk.withUnsafeMutableBufferPointer {
        try micReader.render(into: $0.baseAddress!, outputStartFrame: chunkStart, frameCount: chunkFrames)
      }
      try systemChunk.withUnsafeMutableBufferPointer {
        try systemReader.render(into: $0.baseAddress!, outputStartFrame: chunkStart, frameCount: chunkFrames)
      }
      let frames = min(chunkFrames, endFrame - chunkStart)
      for windowStart in stride(from: 0, to: frames, by: windowFrames) {
        let window = windowStart..<min(windowStart + windowFrames, frames)
        micMeanSquares.append(meanSquare(micChunk[window]))
        systemMeanSquares.append(meanSquare(systemChunk[window]))
      }
    }
    return ChannelActivity(micMeanSquares: micMeanSquares, systemMeanSquares: systemMeanSquares)
  }

  private static func meanSquare(_ samples: ArraySlice<Float>) -> Float {
    samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
  }

  private static func decibels(meanSquareAt index: Int, in meanSquares: [Float]) -> Float {
    let meanSquare = index < meanSquares.count ? meanSquares[index] : 0
    return 10 * log10(max(meanSquare, 1e-12))
  }

  private static func speechLevel(_ decibels: [Float]) -> Float {
    let noiseFloor = decibels.sorted()[decibels.count / 10]
    return max(noiseFloor + speechAboveFloorDecibels, -60)
  }

  private static func median(_ values: [Float]) -> Float? {
    guard values.count >= minimumSpeechWindowsPerChannel else { return nil }
    return values.sorted()[values.count / 2]
  }
}
