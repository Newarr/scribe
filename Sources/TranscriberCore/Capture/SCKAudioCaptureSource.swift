import ScreenCaptureKit
import AVFoundation
import Foundation

/// Coordinator that owns a single `SCStream` shared by both mic + system
/// `SCKAudioCaptureSource` instances. Replaces the v0 architecture where
/// each source created its own `SCStream` — codex pass 2 P0 #3 caught that
/// two independent streams give mic and system independent timebases, which
/// makes per-buffer PTS alignment (and therefore AEC) impossible. Apple's
/// SCK example uses one `SCStream` with `.audio` + `.microphone` outputs
/// driven from a single sync clock; this coordinator implements that.
///
/// Lifecycle:
/// - `register(...)` is synchronous and idempotent (call from each source's
///   init before `start`).
/// - `startIfNeeded()` brings the stream up exactly once even if both
///   sources call it; subsequent calls return without re-starting.
/// - `stopIfRunning()` tears the stream down once; the second caller is a
///   no-op.
public final class SCKDualOutputStream: @unchecked Sendable {
    public enum Kind: Hashable, Sendable { case microphone, system }

    public enum SCKError: Error {
        case noShareableContent
        case noDisplay
        case streamFailedToStart(Error)
    }

    private struct Registration {
        let kind: Kind
        let output: SCStreamOutput
        let queue: DispatchQueue
    }

    /// Serial dispatch queue around mutable state. Same pattern as
    /// `AudioFileWriter` (β.2) — Swift 6 disallows NSLock in async
    /// contexts, and a DispatchQueue gives us the same single-writer
    /// guarantee with cleaner ergonomics.
    private let queue = DispatchQueue(label: "sck.dual-output-stream")
    private var registrations: [Registration] = []
    private var stream: SCStream?
    private var sampleRate: Int
    private var channelCount: Int

    public init(sampleRate: Int = 48000, channelCount: Int = 1) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Synchronous registration so each `SCKAudioCaptureSource` can register
    /// itself during construction without racing the first `start()`.
    public func register(kind: Kind, output: SCStreamOutput, queue handlerQueue: DispatchQueue) {
        queue.sync {
            registrations.append(.init(kind: kind, output: output, queue: handlerQueue))
        }
    }

    /// Builds the `SCStream`, adds every registered output, and starts capture.
    /// Idempotent: a second call after the stream is already running returns
    /// without creating a new stream.
    public func startIfNeeded() async throws {
        // Snapshot under the queue; SCK calls run outside it so async
        // startCapture doesn't block the next register/stop.
        let result: (existing: SCStream?, snapshot: [Registration]) = queue.sync {
            (self.stream, self.registrations)
        }
        if result.existing != nil { return }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw SCKError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = result.snapshot.contains(where: { $0.kind == .system })
        config.captureMicrophone = result.snapshot.contains(where: { $0.kind == .microphone })
        config.excludesCurrentProcessAudio = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.sampleRate = sampleRate
        config.channelCount = channelCount

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        for reg in result.snapshot {
            let outputType: SCStreamOutputType = (reg.kind == .microphone) ? .microphone : .audio
            try newStream.addStreamOutput(reg.output, type: outputType, sampleHandlerQueue: reg.queue)
        }

        do {
            try await newStream.startCapture()
        } catch {
            throw SCKError.streamFailedToStart(error)
        }

        // A concurrent caller may have populated `stream` while we awaited;
        // if so, stop the one we just created to avoid leaking a stream.
        let shouldRollBack: Bool = queue.sync {
            if self.stream != nil { return true }
            self.stream = newStream
            return false
        }
        if shouldRollBack {
            try? await newStream.stopCapture()
        }
    }

    /// Stops the shared stream once. The second caller (the other source's
    /// stop()) is a no-op.
    public func stopIfRunning() async {
        let toStop: SCStream? = queue.sync {
            let s = self.stream
            self.stream = nil
            return s
        }
        if let toStop {
            try? await toStop.stopCapture()
        }
    }
}

/// Adapter from the shared `SCKDualOutputStream` coordinator to the
/// per-source `AudioCaptureSource` contract. Each instance handles one
/// output kind (mic OR system) and forwards the SCK callback to the
/// `CaptureSession` ingest path on its own serial dispatch queue.
public final class SCKAudioCaptureSource: NSObject, AudioCaptureSource, SCStreamOutput, @unchecked Sendable {
    public enum Kind { case microphone, system }

    private let kind: Kind
    private let stream: SCKDualOutputStream
    /// Distinct per-output handler queue. Codex pass 2 P1 #4 — clearing the
    /// handler closure on stop wasn't real serialization; SCStreamOutput
    /// callbacks land on whatever queue we pass to `addStreamOutput`. A
    /// per-output serial queue gives the writer + ingest path a coherent
    /// happens-before chain to drain against during stop().
    private let handlerQueue: DispatchQueue
    /// Atomically-replaceable handler. Reads + writes all run on
    /// `handlerQueue` so the SCK callback (also on `handlerQueue`) sees a
    /// consistent value without locking.
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?

    public init(kind: Kind, stream: SCKDualOutputStream) {
        self.kind = kind
        self.stream = stream
        let label = "sck.handler.\(kind == .microphone ? "mic" : "sys")"
        self.handlerQueue = DispatchQueue(label: label, qos: .userInitiated)
        super.init()
        let coordinatorKind: SCKDualOutputStream.Kind = (kind == .microphone) ? .microphone : .system
        stream.register(kind: coordinatorKind, output: self, queue: handlerQueue)
    }

    public func setHandler(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        handlerQueue.async { [self] in
            self.handler = handler
        }
    }

    public func start() async throws {
        try await stream.startIfNeeded()
    }

    public func stop() async {
        // Both mic + system call stop(); the coordinator drops the second
        // call cheaply. Clear the handler on the per-output queue so any
        // in-flight SCK callback sees nil and exits early instead of
        // delivering into a torn-down ingest path.
        handlerQueue.sync { self.handler = nil }
        await stream.stopIfRunning()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        // Already on `handlerQueue` per addStreamOutput contract.
        handler?(sampleBuffer)
    }
}
