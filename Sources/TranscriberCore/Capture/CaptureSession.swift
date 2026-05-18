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
    private nonisolated let sessionEngineIdentifier: String
    private nonisolated let liveLevelHandler: (@Sendable (PTSCollector.StreamID, Float) -> Void)?
    /// Codex rc2-audit CAP-3: latched stop task. Concurrent stop()
    /// callers await the SAME task instead of returning immediately
    /// when status is `.stopping`. Without this, a Stop-during-Stop
    /// returned success while the first stop was still finalizing,
    /// and the caller would tear down session state + start the
    /// transcription worker against unfinalized .partial files.
    private var inFlightStop: Task<Void, Error>?
    /// Codex rc2-audit CAP-5: capture-time claim. CaptureSession
    /// holds the same SessionClaim a TranscriptionWorker would. While
    /// the claim is held, `OrphanRecoverer` sees `.activeCapture` and
    /// skips moving the `.partial` files out from under
    /// AVAssetWriter. Released on stop / failure.
    private var captureClaim: SessionClaim.Token?
    private var stopRequestedDuringStart = false

    public init(
        directory: SessionDirectory,
        mic: AudioCaptureSource,
        system: AudioCaptureSource,
        sampleRate: Int,
        channelCount: Int,
        sessionEngineIdentifier: String = "elevenlabs",
        liveLevelHandler: (@Sendable (PTSCollector.StreamID, Float) -> Void)? = nil
    ) throws {
        self.directory = directory
        self.mic = mic
        self.system = system
        self.sessionEngineIdentifier = sessionEngineIdentifier
        self.liveLevelHandler = liveLevelHandler
        self.micWriter = try AudioFileWriter(url: directory.micPartial, sampleRate: sampleRate, channelCount: channelCount)
        self.systemWriter = try AudioFileWriter(url: directory.systemPartial, sampleRate: sampleRate, channelCount: channelCount)
        // Per-buffer PTS log feeds streaming finalize (Phase ε) and AEC
        // (Phase ξ). Lives next to the m4a partials inside the session dir.
        self.collector = PTSCollector(streamingLogURL: directory.ptsStreamingLog)
    }

    public func start() async throws {
        status = .starting
        Log.lifecycle.info("Starting capture, dir=\(self.directory.url.lastPathComponent, privacy: .public)")

        // Codex rc2-audit CAP-5: claim the session BEFORE writers
        // start. The flock-backed claim signals "live capture" to
        // OrphanRecoverer; without it, a peer scan could rename our
        // .partial files mid-capture. Failing to claim is a hard
        // start failure — the user should never be in a state where
        // a session has both an active CaptureSession and a worker
        // writing to the same files.
        guard let claim = SessionClaim.acquire(at: directory.claim) else {
            status = .failed
            throw CaptureError.alreadyClaimed
        }
        captureClaim = claim

        do {
            try SessionStartManifest.write(engine: sessionEngineIdentifier, at: directory.startManifest)
        } catch {
            SessionClaim.release(claim)
            captureClaim = nil
            status = .failed
            throw error
        }

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
            if stopRequestedDuringStart || status == .failed {
                throw CaptureError.startCancelled
            }
            try await system.start()
            startedSystem = true
            if stopRequestedDuringStart || status == .failed {
                throw CaptureError.startCancelled
            }

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
            // Release the capture claim so a future scan can recover.
            if let claim = captureClaim {
                SessionClaim.release(claim)
                captureClaim = nil
            }
            status = .failed
            throw error
        }
    }

    public enum CaptureError: Error, Equatable {
        /// Another process / app instance already holds the
        /// SessionClaim for this directory. Codex rc2-audit CAP-5.
        case alreadyClaimed
        case startCancelled
        case noDurableAudio
    }

    public func stop() async throws {
        // Codex rc2-audit CAP-3: concurrent stop callers await the
        // SAME inFlightStop task. v0 returned success on the second
        // call (status == .stopping branch) while the first stop was
        // still finalizing — the caller would then tear down session
        // state and start the worker against unfinalized .partial
        // files. With the latch, every stop call observes the same
        // success/failure outcome.
        if let inFlightStop {
            try await inFlightStop.value
            return
        }
        switch status {
        case .finalized, .failed:
            return
        case .idle:
            status = .failed
            throw CaptureError.noDurableAudio
        case .starting:
            // Stop during startup is a cancellation, not a successful finalization.
            // Latch it so a suspended start cannot later win and transition to recording.
            stopRequestedDuringStart = true
            status = .failed
            throw CaptureError.startCancelled
        case .recording:
            break
        case .stopping:
            // A previous stop attempt failed after clearing the latched task. Retry the
            // same finalization path so transient filesystem obstructions are recoverable.
            break
        }

        status = .stopping
        let task = Task<Void, Error> { [weak self] in
            try await self?.performStop()
        }
        inFlightStop = task
        defer { inFlightStop = nil }
        try await task.value
    }

    /// Body of the stop sequence, called once per stop generation.
    /// Codex rc2-audit CAP-3: extracted from `stop()` so the latched
    /// `inFlightStop` task can run it without re-entering the
    /// guard-and-set logic.
    private func performStop() async throws {
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
        // Codex rc2-audit P0 (audit 3): finalize BOTH writers before
        // failing. v0 awaited mic.finalize THEN system.finalize, so a
        // mic-throw left system as an unclosed .partial that
        // OrphanRecoverer would then merely rename — never recovered.
        // Run both, capture errors separately, throw the first one
        // after both have been attempted.
        var firstError: Error?
        do { try await micWriter.finalize() } catch { firstError = error }
        do { try await systemWriter.finalize() } catch { firstError = firstError ?? error }
        collector.flushLog()
        do { try collector.writeSidecar(to: directory.ptsSidecar) } catch { firstError = firstError ?? error }
        do { try directory.finalize() } catch { firstError = firstError ?? error }
        if finalRawAudioIsReadable() {
            do { try writeTranscriptStub() } catch { firstError = firstError ?? error }
        } else if firstError == nil {
            firstError = CaptureError.noDurableAudio
        }
        // Codex rc2-audit CAP-5: release the capture claim regardless
        // of whether the stop chain succeeded — leaving it held would
        // block future supervisor recovery on this directory.
        if let claim = captureClaim {
            SessionClaim.release(claim)
            captureClaim = nil
        }
        if let firstError {
            try? writeFailedCaptureTranscript(reason: "Capture could not finalize durable microphone and system audio. Scribe will retry cleanup before transcription starts.")
            // Keep the stopped session retryable in-process: a later stop() with
            // the obstruction removed will re-run finalize/verify/stub publication.
            status = .stopping
            throw firstError
        }
        status = .finalized
        Log.lifecycle.info("Capture finalized")
    }

    /// Writes the placeholder transcript that survives a crash before the cloud engine
    /// runs. Status is `pending` (matches TranscriptWriter.writePending) so the slice 7
    /// recovery scan finds both the stub and engine-written pending transcripts under
    /// one query.
    private nonisolated func finalRawAudioIsReadable() -> Bool {
        let fm = FileManager.default
        for url in [directory.micFinal, directory.systemFinal] {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isReadableFile(atPath: url.path) else {
                return false
            }
        }
        return true
    }

    private nonisolated func writeFailedCaptureTranscript(reason: String) throws {
        let audioLines = [directory.micFinal, directory.systemFinal, directory.micPartial, directory.systemPartial]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { "  - \($0.lastPathComponent)" }
            .joined(separator: "\n")
        let audioBlock = audioLines.isEmpty ? "[]" : "\n\(audioLines)"
        let stub = """
        ---
        status: failed
        engine: \(sessionEngineIdentifier)
        audio: \(audioBlock)
        error_code: "capture_finalization_failed"
        error_message: "\(reason)"
        ---

        # Transcription Failed

        \(reason)
        """
        try stub.write(to: directory.transcript, atomically: true, encoding: .utf8)
    }

    private nonisolated func writeTranscriptStub() throws {
        let stub = """
        ---
        schema: transcriber/v1
        status: pending
        engine: \(sessionEngineIdentifier)
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
        // Codex rc2-audit CAP-1: backpressure-drop is data loss. v0
        // returned silently and the session ended in `.complete` with
        // missing audio — the user has no way to know their recording
        // is gap-ridden. Treat as terminal: drive the same cleanup
        // path as a writer-level append failure.
        if outcome == .droppedBackpressure {
            Log.capture.error("Audio writer dropped a buffer under backpressure — terminating session to surface data loss")
            Task { await self.failAndCleanup() }
            return
        }
        guard outcome == .appended else { return }
        collector.observe(stream, buffer: buffer)
        if let rms = Self.rmsLevel(from: buffer) {
            liveLevelHandler?(stream, rms)
        }
    }

    private nonisolated static func rmsLevel(from buffer: CMSampleBuffer) -> Float? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(buffer) else { return nil }

        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr,
              let dataPointer,
              totalLength >= MemoryLayout<Float32>.size else {
            return nil
        }

        let sampleCount = totalLength / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return nil }

        let samples = dataPointer.withMemoryRebound(to: Float32.self, capacity: sampleCount) { pointer in
            UnsafeBufferPointer(start: pointer, count: sampleCount)
        }
        var sumSquares: Float = 0
        for sample in samples {
            guard sample.isFinite else { continue }
            sumSquares += sample * sample
        }
        return min(max(sqrt(sumSquares / Float(sampleCount)), 0), 1)
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
        try? writeFailedCaptureTranscript(reason: "Capture stopped because audio writing failed before Scribe could safely complete the recording.")
        if let claim = captureClaim {
            SessionClaim.release(claim)
            captureClaim = nil
        }
    }

    private func markFailed() {
        status = .failed
    }
}
