import AVFoundation
import Foundation

extension AudioFinalizer {
  struct TimelineSegment {
    let startFrame: Int
    let frameCount: Int
    let sourceDuration: Double
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
    for line in rawLines {
      guard let entry = try? decoder.decode(PTSLogEntry.self, from: Data(line.utf8)),
        entry.stream == "mic" || entry.stream == "system",
        entry.ptsSeconds.isFinite, entry.sampleRate > 0, entry.sampleCount > 0
      else { throw FinalizeError.invalidPTSLog }
      entries.append(entry)
    }
    let sidecar = url.deletingLastPathComponent().appendingPathComponent("pts.json")
    if FileManager.default.fileExists(atPath: sidecar.path) {
      let metadata = try decoder.decode(PTSMetadata.self, from: Data(contentsOf: sidecar))
      for (name, stream) in [("mic", metadata.mic), ("system", metadata.system)] {
        let streamEntries = entries.filter { $0.stream == name }
        guard streamEntries.allSatisfy({ $0.sampleRate == stream.sampleRate }),
          streamEntries.reduce(0.0, { $0 + Double($1.sampleCount) }) == Double(stream.frameCount)
        else { throw FinalizeError.invalidPTSLog }
      }
    }
    let sessionBasePTS = entries.map(\.ptsSeconds).min() ?? 0
    func segments(for stream: String) throws -> [TimelineSegment] {
      var sourceDuration = 0.0
      var sourceFrames = 0
      var endFrame = 0
      return try entries.filter { $0.stream == stream }.map { entry in
        let startValue = ((entry.ptsSeconds - sessionBasePTS) * outputSampleRate).rounded()
        let duration = Double(entry.sampleCount) / Double(entry.sampleRate)
        sourceDuration += duration
        let sourceEndValue = (sourceDuration * outputSampleRate).rounded()
        guard startValue.isFinite, startValue >= 0, startValue < Double(Int.max),
          sourceEndValue.isFinite, sourceEndValue < Double(Int.max)
        else { throw FinalizeError.invalidPTSLog }
        let start = Int(startValue)
        let sourceEnd = Int(sourceEndValue)
        let frames = sourceEnd - sourceFrames
        guard start >= endFrame - 1, frames >= 0, max(start, endFrame) <= Int.max - frames else {
          throw FinalizeError.invalidPTSLog
        }
        let alignedStart = max(start, endFrame)
        endFrame = alignedStart + frames
        sourceFrames = sourceEnd
        return TimelineSegment(startFrame: alignedStart, frameCount: frames, sourceDuration: duration)
      }
    }
    return try PTSTimeline(mic: segments(for: "mic"), system: segments(for: "system"))
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

  final class TimelineStreamReader {
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
      let loggedFrames = (segments.reduce(0.0) { $0 + $1.sourceDuration } * file.processingFormat.sampleRate).rounded()
      guard abs(loggedFrames - Double(file.length)) <= 1 else {
        throw FinalizeError.invalidPTSLog
      }
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
        guard produced.count == needed else { throw FinalizeError.invalidPTSLog }
        if !produced.isEmpty {
          let dest = overlapStart - outputStartFrame
          produced.withUnsafeBufferPointer { ptr in
            output.advanced(by: dest).update(from: ptr.baseAddress!, count: produced.count)
          }
        }
        if overlapEnd < segmentEnd && produced.count == needed { break }
        segmentIndex += 1
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
}
