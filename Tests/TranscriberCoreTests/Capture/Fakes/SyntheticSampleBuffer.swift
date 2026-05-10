import CoreMedia
import AVFoundation

enum SyntheticSampleBuffer {
    static func make(
        ptsSeconds: Double,
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int,
        sampleValue: Float32 = 0
    ) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )

        let bytesPerFrame = MemoryLayout<Float32>.size * channelCount
        let totalBytes = bytesPerFrame * frameCount

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
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
        if sampleValue == 0 {
            CMBlockBufferFillDataBytes(
                with: 0,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        } else {
            var samples = Array(repeating: sampleValue, count: frameCount * channelCount)
            samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!,
                    blockBuffer: blockBuffer!,
                    offsetIntoDestination: 0,
                    dataLength: totalBytes
                )
            }
        }

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(seconds: ptsSeconds, preferredTimescale: 48000),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: [timing],
            sampleSizeEntryCount: 1,
            sampleSizeArray: [bytesPerFrame],
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer!
    }
}
