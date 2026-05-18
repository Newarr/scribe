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
    private var stream: (any SCKStreaming)?
    /// Single in-flight start task. Codex Phase β review P0.1 + P1.2:
    /// without this, parallel mic.start() + system.start() each see
    /// `stream == nil`, both build a new SCStream, and the loser leaks (or
    /// races with stop). Sharing the Task means both callers await the
    /// same start, and stopIfRunning() can wait for it to finish before
    /// tearing the stream down.
    private var inFlightStart: Task<Void, Error>?
    /// Latched when stopIfRunning runs while a start is still in flight.
    /// The start task checks this after startCapture and skips storing
    /// the stream if a stop is pending — closing codex P0.1's
    /// "stop-during-start orphans the SCStream" hole.
    private var stopRequested: Bool = false
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
            registrations.append(.init(kind: kind, output: output, queue: handlerQueue))
        }
    }

    /// Builds the `SCStream`, adds every registered output, and starts capture.
    /// Idempotent: a second call after the stream is already running returns
    /// without creating a new stream. Concurrent calls share the same start
    /// Task so only one SCStream is ever built per coordinator.
    public func startIfNeeded() async throws {
        let task: Task<Void, Error> = queue.sync {
            if let existing = inFlightStart { return existing }
            if stream != nil {
                // Already running — return a no-op task so callers wait on
                // a value rather than branching.
                return Task<Void, Error> { }
            }
            let snapshot = registrations
            let sr = sampleRate
            let cc = channelCount
            let newTask = Task<Void, Error> { [weak self] in
                try await self?.performStart(snapshot: snapshot, sampleRate: sr, channelCount: cc)
            }
            inFlightStart = newTask
            return newTask
        }
        try await task.value
    }

    /// Stops the shared stream once. Waits for any in-flight start so the
    /// stop never races a stream that hasn't been stored yet.
    ///
    /// Codex rc2-audit P1 (audits 2+3): the v0 path set
    /// `stopRequested = true` for every stop and only cleared it on a
    /// later start's cleanup branch. Reusing one coordinator after a
    /// normal start/stop/start cycle made the second start
    /// self-stop. Now: only mark the stop request while there's an
    /// in-flight start to drain (so performStart can self-clean), and
    /// clear it after the stop completes so the next start runs to
    /// completion.
    public func stopIfRunning() async {
        let pendingStart: Task<Void, Error>? = queue.sync {
            // Only signal stop to an in-flight start; if no start is
            // racing us, there's nothing to cancel via the flag.
            if inFlightStart != nil {
                stopRequested = true
            }
            return inFlightStart
        }
        if let pendingStart {
            _ = try? await pendingStart.value
        }
        // Codex rc2-audit CAP-7: the v0 path nil'd `stream` BEFORE
        // calling stopCapture(). If stopCapture threw, capture
        // continued running with no way to retry the stop or report
        // it. New flow: keep `stream` populated while attempting stop;
        // only nil it after a successful stopCapture. On failure, log
        // and leave `stream` intact so a later stop attempt has
        // something to operate on.
        let toStop: (any SCKStreaming)? = queue.sync { self.stream }
        if let toStop {
            do {
                try await toStop.stopCapture()
                queue.sync { self.stream = nil }
            } catch {
                Log.capture.error("SCStream stopCapture failed: \(String(describing: error), privacy: .public). Stream retained for next stop attempt.")
                // Don't clear stopRequested in this branch — leave
                // the coordinator in a "stop pending" state so a
                // subsequent stopIfRunning() can try again.
                return
            }
        }
        // Clear so the NEXT start isn't poisoned by this stop's flag.
        queue.sync { stopRequested = false }
    }

    private func performStart(snapshot: [Registration], sampleRate: Int, channelCount: Int) async throws {
        let newStream: any SCKStreaming
        do {
            newStream = try await streamFactory.makeStream(
                sampleRate: sampleRate,
                channelCount: channelCount,
                capturesAudio: snapshot.contains(where: { $0.kind == .system }),
                capturesMicrophone: snapshot.contains(where: { $0.kind == .microphone })
            )
        } catch {
            queue.sync { inFlightStart = nil }
            throw error
        }

        do {
            for reg in snapshot {
                let outputType: SCStreamOutputType = (reg.kind == .microphone) ? .microphone : .audio
                try newStream.addStreamOutput(reg.output, type: outputType, sampleHandlerQueue: reg.queue)
            }
            try await newStream.startCapture()
        } catch {
            queue.sync { inFlightStart = nil }
            try? await newStream.stopCapture()
            throw SCKError.streamFailedToStart(error)
        }

        // Codex Phase β review P0.1: stop arrived during start. Don't
        // store the stream — clean up immediately and let stopIfRunning
        // see stream == nil so it can return.
        let shouldStop: Bool = queue.sync {
            inFlightStart = nil
            if stopRequested {
                stopRequested = false
                return true
            }
            self.stream = newStream
            return false
        }
        if shouldStop {
            try? await newStream.stopCapture()
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
