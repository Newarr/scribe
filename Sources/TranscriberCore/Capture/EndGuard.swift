import Foundation

/// Guards against runaway recordings (spec section 162-180). Watches the
/// bidirectional audio level on the SCK stream we're already capturing and
/// fires a stop-prompt callback when both mic and system have been quiet
/// for `silenceWindow` seconds. The UI (Phase η) drives a 10s countdown
/// after the prompt; if no audio resumes and the user doesn't dismiss the
/// prompt, the guard auto-stops.
///
/// "Process mic-release" detection (spec's primary signal) is research-
/// gated — codex pass 2 P0 #7 and the plan's Phase δ honest-ceiling note.
/// `kAudioDevicePropertyHogMode` is exclusive ownership, not normal use;
/// `kAudioDevicePropertyDeviceIsRunning` is device-level not per-process;
/// `ProcessObjectList` enumerates HAL clients but doesn't say which is
/// producing audio right now. The macOS public API for "is this PID using
/// the mic" is not exposed. So V1 ships with bidirectional silence as the
/// primary signal; process-mic-release is V1.1.
///
/// `tick()` is the test-friendly entry point: callers drive synthetic
/// audio levels + clock advance and assert state transitions, which means
/// the whole state machine is unit-testable without SCK or wall-clock.
public actor EndGuard {

    /// The reason a prompt or stop fired. Surfaces to the UI so it can
    /// render the appropriate sheet.
    public enum Reason: Sendable, Equatable {
        case bidirectionalSilence
        case maxSessionDurationReached
    }

    /// State machine. Each transition is exposed via `currentState` for
    /// tests; production code consumes the callbacks and shouldn't peek.
    public enum State: Sendable, Equatable {
        case idle                          // Not yet started or after stop
        case watching                      // Recording, no concerning silence yet
        case quiet(since: Date)            // Bidirectional silence accumulating
        case prompted(at: Date)            // Stop prompt shown, awaiting user
        case counting(startedAt: Date)     // 10s countdown active
        case snoozed(until: Date)          // User chose Keep Recording
        case stopped(reason: Reason)       // Terminal
    }

    public typealias OnPrompt = @Sendable (Reason) async -> Void
    public typealias OnCountdownTick = @Sendable (TimeInterval) async -> Void
    public typealias OnAutoStop = @Sendable (Reason) async -> Void

    public struct Config: Sendable {
        public let silenceThreshold: Float
        public let silenceWindow: TimeInterval
        public let countdownDuration: TimeInterval
        public let snoozeDuration: TimeInterval
        public let maxSessionDuration: TimeInterval

        public static let `default` = Config(
            silenceThreshold: 0.01,        // ~-40 dBFS RMS
            silenceWindow: 30,             // spec: 30s bidirectional silence
            countdownDuration: 10,         // spec: 10s countdown
            snoozeDuration: 15 * 60,       // spec: Keep Recording = 15min
            maxSessionDuration: 4 * 60 * 60  // 4h safety net (plan addition)
        )

        public init(
            silenceThreshold: Float,
            silenceWindow: TimeInterval,
            countdownDuration: TimeInterval,
            snoozeDuration: TimeInterval,
            maxSessionDuration: TimeInterval
        ) {
            self.silenceThreshold = silenceThreshold
            self.silenceWindow = silenceWindow
            self.countdownDuration = countdownDuration
            self.snoozeDuration = snoozeDuration
            self.maxSessionDuration = maxSessionDuration
        }
    }

    public private(set) var state: State = .idle
    private let config: Config
    private let onPrompt: OnPrompt
    private let onCountdownTick: OnCountdownTick
    private let onAutoStop: OnAutoStop

    private var sessionStart: Date?
    private var lastMicLevel: Float = 1.0      // Start "loud" so we don't fire prompt before any audio
    private var lastSystemLevel: Float = 1.0
    private var lastSampleAt: Date?

    public init(
        config: Config = .default,
        onPrompt: @escaping OnPrompt = { _ in },
        onCountdownTick: @escaping OnCountdownTick = { _ in },
        onAutoStop: @escaping OnAutoStop = { _ in }
    ) {
        self.config = config
        self.onPrompt = onPrompt
        self.onCountdownTick = onCountdownTick
        self.onAutoStop = onAutoStop
    }

    /// Called when capture starts. Resets the state machine to `watching`.
    public func start(at: Date) {
        sessionStart = at
        state = .watching
        lastMicLevel = 1.0
        lastSystemLevel = 1.0
        lastSampleAt = at
    }

    /// Called when capture stops (regardless of who called it). Resets to
    /// idle so a re-record starts cleanly.
    public func reset() {
        sessionStart = nil
        state = .idle
        lastMicLevel = 1.0
        lastSystemLevel = 1.0
        lastSampleAt = nil
    }

    /// CaptureSession.ingest computes the per-buffer RMS and feeds it here
    /// once per arrived buffer. We sample independently per stream so a
    /// loud-mic-but-silent-system case never trips the silence rule.
    public func observeAudioLevel(stream: AudioStream, rms: Float, at now: Date) async {
        switch stream {
        case .mic: lastMicLevel = rms
        case .system: lastSystemLevel = rms
        }
        lastSampleAt = now
        await tick(now: now)
    }

    /// Public stream identifier so callers don't have to import
    /// PTSCollector to drive the guard.
    public enum AudioStream: Sendable, Equatable {
        case mic
        case system
    }

    /// Heartbeat for time-based transitions (countdown progress, snooze
    /// expiry, max-session safety). Callers drive this on a timer; tests
    /// drive it with synthetic dates.
    public func tick(now: Date) async {
        // 4h safety net first — it overrides everything except terminal.
        if let sessionStart, case .stopped = state {} else {
            if let sessionStart, now.timeIntervalSince(sessionStart) >= config.maxSessionDuration {
                state = .stopped(reason: .maxSessionDurationReached)
                await onAutoStop(.maxSessionDurationReached)
                return
            }
        }

        let bothQuiet = lastMicLevel < config.silenceThreshold && lastSystemLevel < config.silenceThreshold

        switch state {
        case .idle, .stopped:
            return

        case .snoozed(let until):
            if now >= until {
                state = .watching
            }
            return

        case .watching:
            if bothQuiet {
                state = .quiet(since: now)
            }

        case .quiet(let since):
            if !bothQuiet {
                // Audio resumed — back to watching.
                state = .watching
                return
            }
            if now.timeIntervalSince(since) >= config.silenceWindow {
                // Codex rc2-audit STATE-4: bump generation BEFORE
                // firing the async onPrompt callback. The UI handler
                // captures the current generation and feeds it back
                // to keepRecording / stopNow so a late click against
                // a stale prompt is ignored.
                promptGeneration += 1
                state = .prompted(at: now)
                await onPrompt(.bidirectionalSilence)
            }

        case .prompted(let at):
            if !bothQuiet {
                // Spec line 179: audio resume during grace cancels.
                state = .watching
                return
            }
            // After the prompt grace period (the 10s countdown UI runs in
            // parallel), enter the counting state.
            if now.timeIntervalSince(at) >= 0 {
                state = .counting(startedAt: now)
                await onCountdownTick(config.countdownDuration)
            }

        case .counting(let startedAt):
            if !bothQuiet {
                // Spec line 179: audio resume during countdown cancels.
                state = .watching
                return
            }
            let elapsed = now.timeIntervalSince(startedAt)
            let remaining = config.countdownDuration - elapsed
            if remaining <= 0 {
                state = .stopped(reason: .bidirectionalSilence)
                await onAutoStop(.bidirectionalSilence)
            } else {
                await onCountdownTick(remaining)
            }
        }
    }

    /// Codex rc2-audit STATE-4: prompts run async; the user's click
    /// arrives some time after the prompt fired. Between the fire and
    /// the click, the state machine may have transitioned (audio
    /// resumed → .watching, countdown elapsed → .stopped, snooze
    /// expired → .quiet). A late "Keep Recording" click against a
    /// terminal state would silently mutate it.
    ///
    /// The generation counter increments every time the state machine
    /// enters `.prompted`. UI handlers receive the generation along
    /// with the prompt; their click callback passes it back to
    /// keepRecording / stopNow. A mismatch is a no-op.
    private(set) var promptGeneration: Int = 0

    /// User clicked "Keep Recording". Spec line 180: snooze 15
    /// minutes. Codex rc2-audit STATE-4: the `generation` parameter
    /// must match the prompt that produced this click; otherwise the
    /// click is stale (audio resumed, countdown elapsed, snooze
    /// expired since the prompt).
    public func keepRecording(now: Date, generation: Int? = nil) {
        if let generation, generation != promptGeneration {
            // Stale click — log and ignore.
            return
        }
        // Only honor keepRecording when we're actually showing a
        // prompt or counting down. Otherwise the click is for a
        // prompt the state machine has moved past.
        switch state {
        case .prompted, .counting:
            let until = now.addingTimeInterval(config.snoozeDuration)
            state = .snoozed(until: until)
            // Reset levels so we're not stuck in quiet at the moment of snooze.
            lastMicLevel = 1.0
            lastSystemLevel = 1.0
        default:
            return
        }
    }

    /// User clicked "Stop Now". The actual stop is driven by the parent
    /// (CaptureSession.stop); the guard just records the terminal state.
    /// Codex rc2-audit STATE-4: same generation gate as keepRecording.
    public func stopNow(generation: Int? = nil) {
        if let generation, generation != promptGeneration {
            return
        }
        switch state {
        case .prompted, .counting:
            state = .stopped(reason: .bidirectionalSilence)
        default:
            return
        }
    }
}
