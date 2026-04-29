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

        var startedWriters = false
        var startedMic = false
        var startedSystem = false

        do {
            try micWriter.start()
            try systemWriter.start()
            startedWriters = true

            mic.setHandler { [weak self] buf in
                self?.ingest(stream: .mic, buffer: buf)
            }
            system.setHandler { [weak self] buf in
                self?.ingest(stream: .system, buffer: buf)
            }

            try await mic.start()
            startedMic = true
            try await system.start()
            startedSystem = true

            status = .recording
            Log.lifecycle.info("Capture started")
        } catch {
            Log.lifecycle.error("Start failed during partial setup, rolling back: \(String(describing: error), privacy: .public)")
            if startedSystem { await system.stop() }
            if startedMic { await mic.stop() }
            if startedWriters {
                try? await micWriter.finalize()
                try? await systemWriter.finalize()
            }
            status = .failed
            throw error
        }
    }

    public func stop() async throws {
        status = .stopping
        Log.lifecycle.info("Stopping capture")
        await mic.stop()
        await system.stop()
        try await micWriter.finalize()
        try await systemWriter.finalize()
        try collector.writeSidecar(to: directory.ptsSidecar)
        // Atomic rename .partial -> .m4a MUST happen before the transcript stub,
        // so the stub never references files that don't exist yet on disk.
        try directory.finalize()
        try writeTranscriptStub()
        status = .finalized
        Log.lifecycle.info("Capture finalized")
    }

    /// Writes the placeholder transcript that survives a crash before the cloud engine
    /// runs. Status is `pending` (matches TranscriptWriter.writePending) so the slice 7
    /// recovery scan finds both the stub and engine-written pending transcripts under
    /// one query.
    private nonisolated func writeTranscriptStub() throws {
        let stub = """
        ---
        schema: transcriber/v1
        status: pending
        audio:
          - mic.m4a
          - system.m4a
        pts: pts.json
        ---

        Transcription not yet performed. Awaiting transcription engine.
        """
        try stub.write(to: directory.transcript, atomically: true, encoding: .utf8)
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
