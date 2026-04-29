import AVFoundation
import Foundation

public actor CaptureSession {
    public private(set) var status: SessionStatus = .idle

    private nonisolated let directory: SessionDirectory
    private nonisolated let mic: AudioCaptureSource
    private nonisolated let system: AudioCaptureSource
    private nonisolated let micWriter: AudioFileWriter
    private nonisolated let systemWriter: AudioFileWriter
    private nonisolated let collector = PTSCollector()

    public init(
        directory: SessionDirectory,
        mic: AudioCaptureSource,
        system: AudioCaptureSource,
        sampleRate: Int,
        channelCount: Int
    ) throws {
        self.directory = directory
        self.mic = mic
        self.system = system
        self.micWriter = try AudioFileWriter(url: directory.micPartial, sampleRate: sampleRate, channelCount: channelCount)
        self.systemWriter = try AudioFileWriter(url: directory.systemPartial, sampleRate: sampleRate, channelCount: channelCount)
    }

    public func start() async throws {
        status = .starting
        Log.lifecycle.info("Starting capture, dir=\(self.directory.url.lastPathComponent, privacy: .public)")

        try micWriter.start()
        try systemWriter.start()

        mic.setHandler { [weak self] buf in
            self?.ingest(stream: .mic, buffer: buf)
        }
        system.setHandler { [weak self] buf in
            self?.ingest(stream: .system, buffer: buf)
        }

        try await mic.start()
        try await system.start()
        status = .recording
        Log.lifecycle.info("Capture started")
    }

    public func stop() async throws {
        status = .stopping
        Log.lifecycle.info("Stopping capture")
        await mic.stop()
        await system.stop()
        try await micWriter.finalize()
        try await systemWriter.finalize()
        try collector.writeSidecar(to: directory.ptsSidecar)
        try directory.finalize()
        status = .finalized
        Log.lifecycle.info("Capture finalized")
    }

    private nonisolated func ingest(stream: PTSCollector.StreamID, buffer: CMSampleBuffer) {
        collector.observe(stream, buffer: buffer)
        do {
            switch stream {
            case .mic:    try micWriter.append(buffer)
            case .system: try systemWriter.append(buffer)
            }
        } catch {
            Log.capture.error("Append failed: \(String(describing: error), privacy: .public)")
            Task { await self.markFailed() }
        }
    }

    private func markFailed() {
        status = .failed
    }
}
