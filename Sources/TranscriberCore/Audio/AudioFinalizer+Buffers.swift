import AVFoundation
import Foundation

extension AudioFinalizer {
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
