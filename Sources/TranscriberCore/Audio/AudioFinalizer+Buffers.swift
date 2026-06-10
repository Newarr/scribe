import AVFoundation
import Foundation

extension AudioFinalizer {
  static func aacMonoSettings(sampleRate: Double) -> [String: Any] {
    var settings: [String: Any] = [:]
    settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
    settings[AVNumberOfChannelsKey] = 1
    settings[AVSampleRateKey] = sampleRate
    settings[AVEncoderBitRateKey] = 64_000
    return settings
  }

  private static func readAllSamples(
    from url: URL, target: AVAudioFormat, chunkFrames: AVAudioFrameCount
  ) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let reader = try StreamReader(file: file, target: target, chunkFrames: chunkFrames)
    let chunk = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunkFrames)!
    var samples: [Float] = []
    while !reader.isExhausted {
      let frames = try reader.produce(into: chunk, target: chunkFrames)
      if frames == 0 { break }
      let ptr = chunk.floatChannelData![0]
      samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(frames)))
    }
    return samples
  }

  private static func mix(
    samples: [Float], segments: [TimelineSegment], into out: UnsafeMutablePointer<Float>,
    activeCounts: inout [UInt8], peakLimit: Float
  ) {
    var cursor = 0
    let invSqrt2 = Float(1.0 / 2.0.squareRoot())
    for segment in segments {
      let take = min(segment.frameCount, max(0, samples.count - cursor))
      guard take > 0 else { break }
      for i in 0..<take {
        let target = segment.startFrame + i
        guard target >= 0 && target < activeCounts.count else { continue }
        let value = samples[cursor + i]
        if activeCounts[target] == 0 {
          out[target] = value
        } else {
          out[target] = (out[target] + value) * invSqrt2
        }
        activeCounts[target] = min(activeCounts[target] + 1, 2)
        out[target] = max(-peakLimit, min(peakLimit, out[target]))
      }
      cursor += take
    }
  }

  private static func writeBuffer(_ buffer: AVAudioPCMBuffer, to url: URL, settings: [String: Any])
    throws
  {
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
  }

  /// The PCM format never changes within a finalize pass; build the
  /// CoreMedia description once per pass instead of once per chunk
  /// (~36k creations per hour of audio at 100 ms chunks).
  static func makeFormatDescription(for format: AVAudioFormat) throws -> CMAudioFormatDescription {
    var asbdCopy = format.streamDescription.pointee
    var formatDesc: CMFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbdCopy,
      layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDesc
    )
    guard formatStatus == noErr, let formatDesc else {
      throw FinalizeError.writerSetupFailed
    }
    return formatDesc
  }

  static func makeSampleBuffer(
    from buffer: AVAudioPCMBuffer,
    presentationTimeStamp: CMTime,
    format: CMAudioFormatDescription
  ) throws -> CMSampleBuffer {
    let asbd = buffer.format.streamDescription.pointee
    let bytesPerFrame = Int(asbd.mBytesPerFrame)
    let frameCount = Int(buffer.frameLength)
    let totalBytes = bytesPerFrame * frameCount

    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: totalBytes,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: totalBytes,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
      throw FinalizeError.writerSetupFailed
    }

    if let floatPtr = buffer.floatChannelData?[0] {
      CMBlockBufferReplaceDataBytes(
        with: floatPtr, blockBuffer: block, offsetIntoDestination: 0, dataLength: totalBytes)
    }

    let timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)),
      presentationTimeStamp: presentationTimeStamp,
      decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    let createStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: block,
      formatDescription: format,
      sampleCount: CMItemCount(frameCount),
      sampleTimingEntryCount: 1,
      sampleTimingArray: [timing],
      sampleSizeEntryCount: 1,
      sampleSizeArray: [bytesPerFrame],
      sampleBufferOut: &sampleBuffer
    )
    guard createStatus == noErr, let sample = sampleBuffer else {
      throw FinalizeError.writerSetupFailed
    }
    return sample
  }
}
