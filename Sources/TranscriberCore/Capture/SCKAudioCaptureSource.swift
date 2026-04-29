import ScreenCaptureKit
import AVFoundation
import Foundation

public final class SCKAudioCaptureSource: NSObject, AudioCaptureSource, SCStreamOutput, @unchecked Sendable {
    public enum Kind { case microphone, system }

    public enum SCKError: Error {
        case noShareableContent
        case noDisplay
        case streamFailedToStart(Error)
    }

    private let kind: Kind
    private var stream: SCStream?
    private var handler: ((CMSampleBuffer) -> Void)?

    public init(kind: Kind) {
        self.kind = kind
        super.init()
    }

    public func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    public func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw SCKError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = (kind == .system)
        config.captureMicrophone = (kind == .microphone)
        config.excludesCurrentProcessAudio = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.sampleRate = 48000
        config.channelCount = 1

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let outputType: SCStreamOutputType = (kind == .microphone) ? .microphone : .audio
        try stream.addStreamOutput(self, type: outputType, sampleHandlerQueue: .global(qos: .userInitiated))

        do {
            try await stream.startCapture()
        } catch {
            throw SCKError.streamFailedToStart(error)
        }
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        handler?(sampleBuffer)
    }
}
