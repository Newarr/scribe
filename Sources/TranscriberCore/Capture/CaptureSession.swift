import AVFoundation
import Foundation

public actor CaptureSession {
    public private(set) var status: SessionStatus = .idle

    private nonisolated let directory: SessionDirectory
    private nonisolated let mic: AudioCaptureSource
    private nonisolated let system: AudioCaptureSource
    private nonisolated let micWriter: AudioFileWriter
    private nonisolated let systemWriter: AudioFileWriter
    private nonisolated let collector: PTSCollector

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
        // Per-buffer PTS log feeds streaming finalize (Phase ε) and AEC
        // (Phase ξ). Lives next to the m4a partials inside the session dir.
        self.collector = PTSCollector(streamingLogURL: directory.ptsStreamingLog)
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
        // Codex extensive-review P2.1 fix: actor reentrance during await means a
        // double Stop (double-click, keyboard shortcut, Quit-while-stopping)
        // could re-enter and double-finalize. Guard against any non-recording
        // state up front; if .stopping is already in progress, return cleanly.
        // If the session already finalized, return success without re-running.
        switch status {
        case .stopping, .finalized:
            Log.lifecycle.info("Stop ignored: already \(self.status.rawValue, privacy: .public)")
            return
        case .failed:
            return
        case .idle, .starting:
            // Stop called before start completed — odd but recoverable. Skip.
            return
        case .recording:
            break
        }

        status = .stopping
        Log.lifecycle.info("Stopping capture")

        // Phase β.4 transactional stop. Explicit happens-before chain:
        //   (1) source.stop() clears the per-output handler closure on its
        //       SCK handler queue (synchronous queue.sync barrier inside
        //       SCKAudioCaptureSource), so any new SCK callback after this
        //       line sees nil and exits before reaching ingest.
        //   (2) source.stop() then calls SCKDualOutputStream.stopIfRunning,
        //       which calls SCStream.stopCapture; the second source's call
        //       is a cheap no-op (coordinator stops once).
        //   (3) AudioFileWriter.finalize implicitly drains its serial
        //       queue: any append() that landed before finalize completes
        //       first; any append() that lands after is the counted no-op
        //       from β.2 (writer.postFinalizeAppendCounter > 0 is fine).
        //   (4) Collector.flushLog blocks on the PTS log queue so the
        //       JSONL is fully on disk before the snapshot sidecar is
        //       written.
        //   (5) directory.finalize atomically renames .partial -> .m4a so
        //       the transcript stub never references a file that doesn't
        //       yet exist.
        // Failures inside this chain leave the .partial files in place so
        // SessionSupervisor can rescue on next launch (codex pass 1 P1).
        // We do NOT write status: failed mid-stop here.
        await mic.stop()
        await system.stop()
        try await micWriter.finalize()
        try await systemWriter.finalize()
        collector.flushLog()
        try collector.writeSidecar(to: directory.ptsSidecar)
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
        // Codex Phase β review P1.4 + P1.5: observe AFTER the writer
        // commits the buffer. Otherwise the JSONL records audio that
        // didn't make it to the m4a (post-finalize + backpressure drops).
        let outcome: AudioFileWriter.AppendOutcome
        do {
            switch stream {
            case .mic:    outcome = try micWriter.append(buffer)
            case .system: outcome = try systemWriter.append(buffer)
            }
        } catch {
            Log.capture.error("Append failed: \(String(describing: error), privacy: .public)")
            // P1.3: a writer-level append failure means the m4a is wedged.
            // Drive the full stop chain (release SCK + finalize + rename)
            // instead of just flipping status — leaving SCK running while
            // the UI thinks recording is done would orphan a live capture.
            Task { await self.failAndCleanup() }
            return
        }
        guard outcome == .appended else { return }
        collector.observe(stream, buffer: buffer)
    }

    private func failAndCleanup() async {
        // Codex Phase β review P1.3: a writer-level append failure is
        // terminal. Stop sources, finalize writers (idempotent if already
        // finalized), flush PTS log, attempt directory rename. Any step
        // that throws is logged but doesn't escape — we're already in a
        // failure path and SessionSupervisor will rescue any unrenamed
        // .partial files on next launch.
        guard status == .recording else { return }
        status = .failed
        Log.lifecycle.error("Capture failure: tearing down sources + writers")
        await mic.stop()
        await system.stop()
        try? await micWriter.finalize()
        try? await systemWriter.finalize()
        collector.flushLog()
        try? collector.writeSidecar(to: directory.ptsSidecar)
        try? directory.finalize()
    }

    private func markFailed() {
        status = .failed
    }
}
