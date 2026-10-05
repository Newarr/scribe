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

protocol SCKStreaming: AnyObject, Sendable {
    func addStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue?) throws
    func startCapture() async throws
    func stopCapture() async throws
}

protocol SCKStreamFactory: Sendable {
    func makeStream(sampleRate: Int, channelCount: Int, capturesAudio: Bool, capturesMicrophone: Bool) async throws -> SCKStreaming
}

private struct LiveSCKStreamFactory: SCKStreamFactory {
    func makeStream(sampleRate: Int, channelCount: Int, capturesAudio: Bool, capturesMicrophone: Bool) async throws -> SCKStreaming {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw SCKDualOutputStream.SCKError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = capturesAudio
        config.captureMicrophone = capturesMicrophone
        config.excludesCurrentProcessAudio = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.sampleRate = sampleRate
        config.channelCount = channelCount
        return SCStream(filter: filter, configuration: config, delegate: nil)
    }
}

extension SCStream: SCKStreaming {}

public final class SCKDualOutputStream: @unchecked Sendable {
    public enum Kind: Hashable, Sendable { case microphone, system }

    enum SCKError: Error {
        case noShareableContent
        case noDisplay
        case streamFailedToStart(Error)
    }

    private struct Registration {
        let kind: Kind
        let output: WeakOutput
        let queue: DispatchQueue
    }

    private final class WeakOutput: NSObject, SCStreamOutput, @unchecked Sendable {
        weak var target: (any SCStreamOutput)?

        init(target: any SCStreamOutput) { self.target = target }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            target?.stream?(stream, didOutputSampleBuffer: sampleBuffer, of: type)
        }
    }

    /// Serial dispatch queue around mutable state. Same pattern as
    /// `AudioFileWriter` (β.2) — Swift 6 disallows NSLock in async
    /// contexts, and a DispatchQueue gives us the same single-writer
    /// guarantee with cleaner ergonomics.
    private let queue = DispatchQueue(label: "sck.dual-output-stream")
    private var registrations: [Registration] = []
    private var stream: (any SCKStreaming)?
    /// Single in-flight start task. Codex Phase β review P0.1 + P1.2:
    /// without this, parallel mic.start() + system.start() each see
    /// `stream == nil`, both build a new SCStream, and the loser leaks (or
    /// races with stop). Sharing the Task means both callers await the
    /// same start, and stopIfRunning() can wait for it to finish before
    /// tearing the stream down.
    private var inFlightStart: Task<Void, Error>?
    private var inFlightStop: Task<Void, Error>?
    private var startFailure: Error?
    private var sampleRate: Int
    private var channelCount: Int
    private let streamFactory: any SCKStreamFactory

    public convenience init(sampleRate: Int = 48000, channelCount: Int = 1) {
        self.init(sampleRate: sampleRate, channelCount: channelCount, streamFactory: LiveSCKStreamFactory())
    }

    init(sampleRate: Int = 48000, channelCount: Int = 1, streamFactory: any SCKStreamFactory) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.streamFactory = streamFactory
    }

    /// Synchronous registration so each `SCKAudioCaptureSource` can register
    /// itself during construction without racing the first `start()`.
    public func register(kind: Kind, output: SCStreamOutput, queue handlerQueue: DispatchQueue) {
        queue.sync {
            registrations.append(.init(kind: kind, output: WeakOutput(target: output), queue: handlerQueue))
        }
    }

    func startIfNeeded() async throws {
        if let stopping = queue.sync(execute: { inFlightStop }) {
            try await stopping.value
        }
        let task: Task<Void, Error> = queue.sync {
            if let existing = inFlightStart { return existing }
            if let failure = startFailure { return Task { throw failure } }
            if stream != nil { return Task {} }
            let snapshot = registrations
            let sr = sampleRate
            let cc = channelCount
            let task = Task<Void, Error> { [self] in
                defer { queue.sync { inFlightStart = nil } }
                try await performStart(snapshot: snapshot, sampleRate: sr, channelCount: cc)
            }
            inFlightStart = task
            return task
        }
        try await task.value
    }

    func stopIfRunning() async throws {
        let task: Task<Void, Error> = queue.sync {
            if let existing = inFlightStop { return existing }
            let pendingStart = inFlightStart
            let task = Task<Void, Error> { [self] in
                defer { queue.sync { inFlightStop = nil } }
                if let pendingStart { _ = try? await pendingStart.value }
                if let active = queue.sync(execute: { stream }) {
                    try await active.stopCapture()
                    queue.sync {
                        stream = nil
                        startFailure = nil
                    }
                }
            }
            inFlightStop = task
            return task
        }
        try await task.value
    }

    private func performStart(snapshot: [Registration], sampleRate: Int, channelCount: Int) async throws {
        let activeRegistrations = snapshot.filter { $0.output.target != nil }
        let newStream = try await streamFactory.makeStream(
            sampleRate: sampleRate,
            channelCount: channelCount,
            capturesAudio: activeRegistrations.contains { $0.kind == .system },
            capturesMicrophone: activeRegistrations.contains { $0.kind == .microphone }
        )
        queue.sync { stream = newStream }
        do {
            for registration in activeRegistrations {
                let outputType: SCStreamOutputType = registration.kind == .microphone ? .microphone : .audio
                try newStream.addStreamOutput(registration.output, type: outputType, sampleHandlerQueue: registration.queue)
            }
            try await newStream.startCapture()
        } catch {
            let failure = SCKError.streamFailedToStart(error)
            queue.sync { startFailure = failure }
            do {
                try await newStream.stopCapture()
                queue.sync {
                    stream = nil
                    startFailure = nil
                }
            } catch {
                throw error
            }
            throw failure
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

    public func stop() async throws {
        // Both mic + system call stop(); the coordinator drops the second
        // call cheaply. Clear the handler on the per-output queue so any
        // in-flight SCK callback sees nil and exits early instead of
        // delivering into a torn-down ingest path.
        handlerQueue.sync { self.handler = nil }
        try await stream.stopIfRunning()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        // Already on `handlerQueue` per addStreamOutput contract.
        handler?(sampleBuffer)
    }
}
