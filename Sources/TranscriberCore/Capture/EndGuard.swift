import Foundation

/// Guards against runaway recordings. It prompts when both captured audio
/// streams are quiet, when active-call detection says the call ended, or when
/// the session exceeds the safety limit.
///
/// `tick()` is the test-friendly entry point: callers drive synthetic
/// audio levels + clock advance and assert state transitions, which means
/// the whole state machine is unit-testable without SCK or wall-clock.
public actor EndGuard {

    /// The reason a prompt or stop fired. Surfaces to the UI so it can
    /// render the appropriate sheet.
    public enum Reason: Sendable, Equatable {
        case bidirectionalSilence
        case callEnded
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
        case cancelSuppressed(until: Date) // Audio resumed; prevent immediate re-prompt
        case snoozed(until: Date)          // User chose Keep Recording
        case stopped(reason: Reason)       // Terminal
    }

    public typealias OnPrompt = @Sendable (Reason) async -> Void
    public typealias OnCountdownTick = @Sendable (TimeInterval) async -> Void
    public typealias OnAutoStop = @Sendable (Reason) async -> Void
    public typealias OnCancel = @Sendable () async -> Void

    public struct Config: Sendable {
        public let silenceThreshold: Float
        public let silenceWindow: TimeInterval
        public let countdownDuration: TimeInterval
        public let snoozeDuration: TimeInterval
        public let cancelSuppressionDuration: TimeInterval
        public let maxSessionDuration: TimeInterval

        public static let `default` = Config(
            silenceThreshold: 0.01,        // ~-40 dBFS RMS
            silenceWindow: 30,             // spec: 30s bidirectional silence
            countdownDuration: 10,         // spec: 10s countdown
            snoozeDuration: 15 * 60,       // spec: Keep Recording = 15min
            cancelSuppressionDuration: 60, // spec: audio-resume cancel suppresses re-prompt
            maxSessionDuration: 4 * 60 * 60  // 4h safety net (plan addition)
        )

        public init(
            silenceThreshold: Float,
            silenceWindow: TimeInterval,
            countdownDuration: TimeInterval,
            snoozeDuration: TimeInterval,
            cancelSuppressionDuration: TimeInterval = 60,
            maxSessionDuration: TimeInterval
        ) {
            self.silenceThreshold = silenceThreshold
            self.silenceWindow = silenceWindow
            self.countdownDuration = countdownDuration
            self.snoozeDuration = snoozeDuration
            self.cancelSuppressionDuration = cancelSuppressionDuration
            self.maxSessionDuration = maxSessionDuration
        }
    }

    public private(set) var state: State = .idle
    private let config: Config
    private let onPrompt: OnPrompt
    private let onCountdownTick: OnCountdownTick
    private let onAutoStop: OnAutoStop
    private let onCancel: OnCancel

    private var sessionStart: Date?
    private var lastMicLevel: Float = 1.0      // Start "loud" so we don't fire prompt before any audio
    private var lastSystemLevel: Float = 1.0
    private var lastSampleAt: Date?
    private var activePromptReason: Reason = .bidirectionalSilence

    public init(
        config: Config = .default,
        onPrompt: @escaping OnPrompt = { _ in },
        onCountdownTick: @escaping OnCountdownTick = { _ in },
        onAutoStop: @escaping OnAutoStop = { _ in },
        onCancel: @escaping OnCancel = {}
    ) {
        self.config = config
        self.onPrompt = onPrompt
        self.onCountdownTick = onCountdownTick
        self.onAutoStop = onAutoStop
        self.onCancel = onCancel
    }

    /// Called when capture starts. Resets the state machine to `watching`.
    public func start(at: Date) {
        sessionStart = at
        state = .watching
        lastMicLevel = 1.0
        lastSystemLevel = 1.0
        lastSampleAt = at
        activePromptReason = .bidirectionalSilence
    }

    /// Called when capture stops (regardless of who called it). Resets to
    /// idle so a re-record starts cleanly.
    public func reset() {
        sessionStart = nil
        state = .idle
        lastMicLevel = 1.0
        lastSystemLevel = 1.0
        lastSampleAt = nil
        activePromptReason = .bidirectionalSilence
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

    /// Active-call recognition can prove that the meeting app stopped
    /// using the input device before the audio-silence fallback has had
    /// time to accumulate. Use that signal to enter the same stop-prompt
    /// flow immediately; Keep Recording still snoozes it like any other
    /// suspected end.
    public func suspectCallEnded(at now: Date) async {
        switch state {
        case .idle, .stopped, .prompted, .counting:
            return
        case .cancelSuppressed(let until), .snoozed(let until):
            guard now >= until else { return }
        case .watching, .quiet:
            break
        }
        await startPrompt(reason: .callEnded, at: now)
    }

    /// Heartbeat for time-based transitions (countdown progress, snooze
    /// expiry, max-session safety). Callers drive this on a timer; tests
    /// drive it with synthetic dates.
    public func tick(now: Date) async {
        // 4h safety net first. It overrides everything except terminal state.
        if case .stopped = state {
            return
        }
        if let sessionStart, now.timeIntervalSince(sessionStart) >= config.maxSessionDuration {
            state = .stopped(reason: .maxSessionDurationReached)
            await onAutoStop(.maxSessionDurationReached)
            return
        }

        let bothQuiet = lastMicLevel < config.silenceThreshold && lastSystemLevel < config.silenceThreshold

        switch state {
        case .idle, .stopped:
            return

        case .cancelSuppressed(let until):
            guard now >= until else { return }
            state = bothQuiet ? .quiet(since: now) : .watching
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
                // Audio resumed. Go back to watching.
                state = .watching
                return
            }
            if now.timeIntervalSince(since) >= config.silenceWindow {
                await startPrompt(reason: .bidirectionalSilence, at: now)
            }

        case .prompted(let at):
            if activePromptReason == .bidirectionalSilence, !bothQuiet {
                // Spec line 179: audio resume during grace cancels.
                await cancelPromptAfterAudioResume(at: now)
                return
            }
            // After the prompt grace period (the 10s countdown UI runs in
            // parallel), enter the counting state.
            if now.timeIntervalSince(at) >= 0 {
                state = .counting(startedAt: now)
                await onCountdownTick(config.countdownDuration)
            }

        case .counting(let startedAt):
            if activePromptReason == .bidirectionalSilence, !bothQuiet {
                // Spec line 179: audio resume during countdown cancels.
                await cancelPromptAfterAudioResume(at: now)
                return
            }
            let elapsed = now.timeIntervalSince(startedAt)
            let remaining = config.countdownDuration - elapsed
            if remaining <= 0 {
                let reason = activePromptReason
                state = .stopped(reason: reason)
                await onAutoStop(reason)
            } else {
                await onCountdownTick(remaining)
            }
        }
    }

    private func startPrompt(reason: Reason, at now: Date) async {
        activePromptReason = reason
        promptGeneration += 1
        state = .prompted(at: now)
        await onPrompt(reason)
    }

    private func cancelPromptAfterAudioResume(at now: Date) async {
        state = .cancelSuppressed(until: now.addingTimeInterval(config.cancelSuppressionDuration))
        await onCancel()
    }

    /// Prompts run async, so the user's click can arrive after the state
    /// machine has already moved on. A late click must be ignored.
    ///
    /// The generation counter increments every time the state machine
    /// enters `.prompted`. UI handlers receive the generation along
    /// with the prompt; their click callback passes it back to
    /// keepRecording / stopNow. A mismatch is a no-op.
    public private(set) var promptGeneration: Int = 0

    /// User clicked "Keep Recording". The `generation` parameter must match
    /// the prompt that produced this click.
    @discardableResult
    public func keepRecording(now: Date, generation: Int? = nil) -> Bool {
        if let generation, generation != promptGeneration {
            // Stale click. Ignore it.
            return false
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
            activePromptReason = .bidirectionalSilence
            return true
        default:
            return false
        }
    }

    /// User clicked "Stop Now". The actual stop is driven by the parent
    /// (CaptureSession.stop); the guard just records the terminal state.
    @discardableResult
    public func stopNow(generation: Int? = nil) -> Bool {
        if let generation, generation != promptGeneration {
            return false
        }
        switch state {
        case .prompted, .counting:
            state = .stopped(reason: activePromptReason)
            return true
        default:
            return false
        }
    }
}
