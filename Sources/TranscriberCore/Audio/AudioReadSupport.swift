import AVFoundation
import Foundation

protocol AudioPCMReadable {
    var sourceURL: URL { get }
    var length: AVAudioFramePosition { get }
    var framePosition: AVAudioFramePosition { get }
    var fileFormat: AVAudioFormat { get }
    var processingFormat: AVAudioFormat { get }

    func read(into buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: AudioPCMReadable {
    var sourceURL: URL { url }
}

enum AudioReadSupport {
    static func resampleFully(reader: AudioPCMReadable, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let declaredFrames = max(reader.length, 0)
        let totalFrames = AVAudioFrameCount(
            Double(declaredFrames) * format.sampleRate / reader.fileFormat.sampleRate
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames + 1024)!
        let converter = AVAudioConverter(from: reader.processingFormat, to: format)!
        let readBuffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8192)!

        var endOfFile = false
        var readError: Error?
        var status: AVAudioConverterOutputStatus = .haveData
        while status == .haveData && !endOfFile {
            var converterError: NSError?
            status = converter.convert(to: buffer, error: &converterError) { _, outStatus in
                do {
                    try reader.read(into: readBuffer)
                } catch {
                    if reader.framePosition >= reader.length {
                        outStatus.pointee = .endOfStream
                        endOfFile = true
                        return nil
                    }
                    readError = error
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
            if let error = readError { throw error }
            if let error = converterError { throw error }
        }
        if let error = readError { throw error }
        return buffer
    }

    static func writeAtomically(output: URL, settings: [String: Any], body: (AVAudioFile) throws -> Void) throws {
        let temporary = temporaryURLPreservingExtension(for: output)
        do {
            let outFile = try AVAudioFile(forWriting: temporary, settings: settings)
            try body(outFile)
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func temporaryURLPreservingExtension(for output: URL) -> URL {
        let directory = output.deletingLastPathComponent()
        let fileExtension = output.pathExtension
        let baseName = output.deletingPathExtension().lastPathComponent
        let inflightName = ".\(baseName).inflight-\(UUID().uuidString)"

        guard !fileExtension.isEmpty else {
            return directory.appendingPathComponent(inflightName)
        }

        return directory.appendingPathComponent(inflightName).appendingPathExtension(fileExtension)
    }
}
