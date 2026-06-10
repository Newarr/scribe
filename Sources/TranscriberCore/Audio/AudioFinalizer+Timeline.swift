import AVFoundation
import Foundation

extension AudioFinalizer {
  struct TimelineSegment {
    let startFrame: Int
    let frameCount: Int
  }

  struct PTSTimeline {
    let mic: [TimelineSegment]
    let system: [TimelineSegment]
  }

  static func readPTSTimeline(at url: URL, outputSampleRate: Double) throws -> PTSTimeline {
    let content = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    let rawLines = content.split(separator: "\n", omittingEmptySubsequences: true)
    var entries: [PTSLogEntry] = []
    entries.reserveCapacity(rawLines.count)
    for (index, line) in rawLines.enumerated() {
      do {
        entries.append(try decoder.decode(PTSLogEntry.self, from: Data(line.utf8)))
      } catch {
        if index == rawLines.count - 1 { break }
        throw FinalizeError.invalidPTSLog
      }
    }
    let relevantPTS =
      entries
      .filter { $0.stream == "mic" || $0.stream == "system" }
      .map(\.ptsSeconds)
    let sessionBasePTS = relevantPTS.min() ?? 0
    func segments(for stream: String) -> [TimelineSegment] {
      entries.filter { $0.stream == stream }.map { entry in
        let relativePTS = entry.ptsSeconds - sessionBasePTS
        let start = Int((relativePTS * outputSampleRate).rounded())
        let frames = Int(
          (Double(entry.sampleCount) * outputSampleRate / Double(entry.sampleRate)).rounded())
        return TimelineSegment(startFrame: max(0, start), frameCount: max(0, frames))
      }
    }
    return PTSTimeline(mic: segments(for: "mic"), system: segments(for: "system"))
  }

  static func finalizeWithTimeline(
    mic: URL,
    system: URL,
    output: URL,
    sampleRate: Double,
    monoFormat: AVAudioFormat,
    timeline: PTSTimeline,
    options: Options,
    writerSettings: [String: Any]
  ) async throws {
    let tempName = ".\(output.lastPathComponent).inflight-\(UUID().uuidString.prefix(8))"
    let tempOutput = output.deletingLastPathComponent().appendingPathComponent(tempName)
    try? FileManager.default.removeItem(at: tempOutput)

    let micFile = try AVAudioFile(forReading: mic)
    let sysFile = try AVAudioFile(forReading: system)
    let micReader = try TimelineStreamReader(
      file: micFile, target: monoFormat, segments: timeline.mic, chunkFrames: options.chunkFrames)
    let sysReader = try TimelineStreamReader(
      file: sysFile, target: monoFormat, segments: timeline.system, chunkFrames: options.chunkFrames
    )

    let writer = try AVAssetWriter(outputURL: tempOutput, fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw FinalizeError.writerSetupFailed }
    writer.add(input)

    guard writer.startWriting() else {
      throw FinalizeError.writerFailed(writer.error.map { String(describing: $0) })
    }
    writer.startSession(atSourceTime: .zero)

    let micChunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: options.chunkFrames)!
    let sysChunk = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: options.chunkFrames)!
    // Reused across chunks: makeSampleBuffer copies the PCM bytes into its
    // own CMBlockBuffer, so mutating `mixed` on the next iteration is safe.
    let mixed = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: options.chunkFrames)!
    let formatDescription = try makeFormatDescription(for: monoFormat)
    let invSqrt2 = Float(1.0 / 2.0.squareRoot())
    let peakLimit: Float = 0.891
    var outputCursor = 0

    do {
      while !micReader.isExhausted || !sysReader.isExhausted {
        let frames = Int(options.chunkFrames)
        micChunk.frameLength = options.chunkFrames
        sysChunk.frameLength = options.chunkFrames
        let micPtr = micChunk.floatChannelData![0]
        let sysPtr = sysChunk.floatChannelData![0]
        try micReader.render(into: micPtr, outputStartFrame: outputCursor, frameCount: frames)
        try sysReader.render(into: sysPtr, outputStartFrame: outputCursor, frameCount: frames)

        let remaining = max(micReader.endFrame, sysReader.endFrame) - outputCursor
        let outFrames = min(frames, max(0, remaining))
        if outFrames == 0 { break }
        mixed.frameLength = AVAudioFrameCount(outFrames)
        let mixPtr = mixed.floatChannelData![0]
        for i in 0..<outFrames {
          let micActive = abs(micPtr[i]) > 0
          let sysActive = abs(sysPtr[i]) > 0
          let sum: Float
          if micActive && sysActive {
            sum = (micPtr[i] + sysPtr[i]) * invSqrt2
          } else {
            sum = micPtr[i] + sysPtr[i]
          }
          mixPtr[i] = max(-peakLimit, min(peakLimit, sum))
        }

        let pts = CMTime(value: Int64(outputCursor), timescale: Int32(sampleRate))
        let sample = try Self.makeSampleBuffer(
          from: mixed, presentationTimeStamp: pts, format: formatDescription)
        let waitStart = Date()
        while !(options.forceWriterInputNotReady ? false : input.isReadyForMoreMediaData) {
          if Task.isCancelled { throw CancellationError() }
          if options.forcedWriterFailure == .statusDuringReadinessPolling {
            throw FinalizeError.writerStatusFailed
          }
          if writer.status == .failed || writer.status == .cancelled {
            throw FinalizeError.writerStatusFailed
          }
          if Date().timeIntervalSince(waitStart) > options.backpressureTimeout {
            throw FinalizeError.backpressureTimeout
          }
          try await Task.sleep(nanoseconds: UInt64(options.backpressureSleep * 1_000_000_000))
        }
        if options.forcedWriterFailure == .append {
          throw FinalizeError.writerFailed("forced append failure")
        }
        if !input.append(sample) {
          throw FinalizeError.writerFailed(writer.error.map { String(describing: $0) })
        }
        outputCursor += outFrames
      }

      input.markAsFinished()
      await writer.finishWriting()
      if options.forcedWriterFailure == .finishWriting {
        throw FinalizeError.writerFailed("forced finish failure")
      }
      if writer.status == .failed {
        throw FinalizeError.writerFailed(writer.error.map { String(describing: $0) })
      }
      if FileManager.default.fileExists(atPath: output.path) {
        _ = try FileManager.default.replaceItemAt(output, withItemAt: tempOutput)
      } else {
        try FileManager.default.moveItem(at: tempOutput, to: output)
      }
    } catch {
      if writer.status == .writing { writer.cancelWriting() }
      try? FileManager.default.removeItem(at: tempOutput)
      throw error
    }
  }

  private final class TimelineStreamReader {
    let segments: [TimelineSegment]
    let endFrame: Int
    private let reader: StreamReader
    private let scratch: AVAudioPCMBuffer
    private var segmentIndex = 0
    private var bufferedSamples: [Float] = []

    init(
      file: AVAudioFile, target: AVAudioFormat, segments: [TimelineSegment],
      chunkFrames: AVAudioFrameCount
    ) throws {
      self.segments = segments
      self.endFrame = segments.map { $0.startFrame + $0.frameCount }.max() ?? 0
      self.reader = try StreamReader(file: file, target: target, chunkFrames: chunkFrames)
      self.scratch = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunkFrames)!
    }

    var isExhausted: Bool { segmentIndex >= segments.count }

    func render(into output: UnsafeMutablePointer<Float>, outputStartFrame: Int, frameCount: Int)
      throws
    {
      memset(output, 0, frameCount * MemoryLayout<Float>.size)
      while segmentIndex < segments.count {
        let segment = segments[segmentIndex]
        let segmentEnd = segment.startFrame + segment.frameCount
        if segmentEnd <= outputStartFrame {
          segmentIndex += 1
          continue
        }
        if segment.startFrame >= outputStartFrame + frameCount { break }
        let overlapStart = max(outputStartFrame, segment.startFrame)
        let overlapEnd = min(outputStartFrame + frameCount, segmentEnd)
        let needed = overlapEnd - overlapStart
        let produced = try readSamples(count: needed)
        if !produced.isEmpty {
          let dest = overlapStart - outputStartFrame
          produced.withUnsafeBufferPointer { ptr in
            output.advanced(by: dest).update(from: ptr.baseAddress!, count: produced.count)
          }
        }
        if overlapEnd >= segmentEnd || produced.count < needed { segmentIndex += 1 }
        if produced.count < needed { continue }
      }
    }

    private func readSamples(count: Int) throws -> [Float] {
      while bufferedSamples.count < count, !reader.isExhausted {
        let frames = try reader.produce(
          into: scratch, target: AVAudioFrameCount(scratch.frameCapacity))
        if frames == 0 { break }
        let ptr = scratch.floatChannelData![0]
        bufferedSamples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(frames)))
      }
      let take = min(count, bufferedSamples.count)
      guard take > 0 else { return [] }
      let result = Array(bufferedSamples.prefix(take))
      bufferedSamples.removeFirst(take)
      return result
    }
  }

  /// Codex rc2-audit CAP-2: parses the per-buffer PTS log to find
  /// the first PTS of each stream, then returns a frame-count
  /// offset for whichever stream started later. The mix loop
  /// prepends that many silence frames to the on-time stream so
  /// both align at session start.
  private static func readFirstPTSAlignment(at url: URL, sampleRate: Double) throws -> (
    micPrependFrames: Int, systemPrependFrames: Int
  ) {
    let content = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    var micFirst: Double?
    var sysFirst: Double?
    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let entry = try? decoder.decode(PTSLogEntry.self, from: Data(line.utf8)) else {
        continue
      }
      switch entry.stream {
      case "mic":
        if micFirst == nil { micFirst = entry.ptsSeconds }
      case "system":
        if sysFirst == nil { sysFirst = entry.ptsSeconds }
      default: break
      }
      if micFirst != nil && sysFirst != nil { break }
    }
    guard let micFirst, let sysFirst else { return (0, 0) }
    // The stream with the EARLIER first-PTS is the reference.
    // The other stream needs (delta) silence prepended so its
    // first audible frame lines up at the same output time.
    let delta = abs(micFirst - sysFirst)
    let prependFrames = Int((delta * sampleRate).rounded())
    if micFirst <= sysFirst {
      // mic started first; system needs prepended silence.
      return (0, prependFrames)
    } else {
      return (prependFrames, 0)
    }
  }
}
