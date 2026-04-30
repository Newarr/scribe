import Foundation
import XCTest
@testable import TranscriberCore

final class EndGuardTests: XCTestCase {

    private let testConfig = EndGuard.Config(
        silenceThreshold: 0.01,
        silenceWindow: 30,
        countdownDuration: 10,
        snoozeDuration: 15 * 60,
        maxSessionDuration: 4 * 60 * 60
    )

    private func t(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    // MARK: spec-mandated transitions

    func testHappyPathDoesNotTriggerPrompt() async {
        let guard1 = await EndGuard(config: testConfig)
        await guard1.start(at: t(0))

        // Loud audio for 60s; should never trigger.
        for s in stride(from: 0.0, through: 60, by: 5) {
            await guard1.observeAudioLevel(stream: .mic, rms: 0.5, at: t(s))
            await guard1.observeAudioLevel(stream: .system, rms: 0.4, at: t(s))
        }

        let state = await guard1.state
        if case .watching = state {} else {
            XCTFail("expected .watching after loud audio; got \(state)")
        }
    }

    func testThirtySecondsBidirectionalSilencePromptsStop() async {
        let promptCount = AsyncCounter()
        let guard1 = await EndGuard(config: testConfig, onPrompt: { _ in await promptCount.increment() })
        await guard1.start(at: t(0))

        // Both quiet starting at t=0.
        await guard1.observeAudioLevel(stream: .mic, rms: 0.001, at: t(0))
        await guard1.observeAudioLevel(stream: .system, rms: 0.001, at: t(0))

        // Tick at 30s — silence window elapsed → prompt.
        await guard1.tick(now: t(30))

        let count = await promptCount.value
        XCTAssertEqual(count, 1, "spec line 170: 30s bidirectional silence triggers prompt")
    }

    func testOneSidedAudioDoesNotTriggerPrompt() async {
        let promptCount = AsyncCounter()
        let guard1 = await EndGuard(config: testConfig, onPrompt: { _ in await promptCount.increment() })
        await guard1.start(at: t(0))

        // Mic loud, system silent for 60s — must NOT prompt (spec says
        // BIDIRECTIONAL). One-sided audio is the "you're listening" or
        // "you're talking" case; recording continues.
        for s in stride(from: 0.0, through: 60, by: 5) {
            await guard1.observeAudioLevel(stream: .mic, rms: 0.4, at: t(s))
            await guard1.observeAudioLevel(stream: .system, rms: 0.0, at: t(s))
        }
        let count = await promptCount.value
        XCTAssertEqual(count, 0, "one-sided audio (mic active, system silent) is NOT a prompt trigger")
    }

    func testAudioResumeDuringGraceCancelsStopFlow() async {
        let autoStops = AsyncCounter()
        let guard1 = await EndGuard(config: testConfig, onAutoStop: { _ in await autoStops.increment() })
        await guard1.start(at: t(0))

        await guard1.observeAudioLevel(stream: .mic, rms: 0.001, at: t(0))
        await guard1.observeAudioLevel(stream: .system, rms: 0.001, at: t(0))
        await guard1.tick(now: t(30))  // prompted

        // Audio resumes during grace.
        await guard1.observeAudioLevel(stream: .mic, rms: 0.5, at: t(31))
        await guard1.tick(now: t(35))

        let state = await guard1.state
        if case .watching = state {} else {
            XCTFail("audio resume must cancel prompt; state is \(state)")
        }
        let stops = await autoStops.value
        XCTAssertEqual(stops, 0, "spec line 179: audio resume cancels stop flow")
    }

    func testTenSecondCountdownAutoStopsWhenSilencePersists() async {
        let autoStops = AsyncCounter()
        let guard1 = await EndGuard(config: testConfig, onAutoStop: { _ in await autoStops.increment() })
        await guard1.start(at: t(0))

        await guard1.observeAudioLevel(stream: .mic, rms: 0.001, at: t(0))
        await guard1.observeAudioLevel(stream: .system, rms: 0.001, at: t(0))
        await guard1.tick(now: t(30))  // prompted
        await guard1.tick(now: t(31))  // counting

        // Continue ticking with audio still silent through countdown.
        await guard1.observeAudioLevel(stream: .mic, rms: 0.001, at: t(35))
        await guard1.observeAudioLevel(stream: .system, rms: 0.001, at: t(35))
        await guard1.tick(now: t(45))  // 10s countdown elapsed

        let state = await guard1.state
        if case .stopped(let reason) = state {
            XCTAssertEqual(reason, .bidirectionalSilence)
        } else {
            XCTFail("expected .stopped; got \(state)")
        }
        let stops = await autoStops.value
        XCTAssertEqual(stops, 1)
    }

    func testKeepRecordingSnoozesFifteenMinutes() async {
        let promptCount = AsyncCounter()
        let guard1 = await EndGuard(config: testConfig, onPrompt: { _ in await promptCount.increment() })
        await guard1.start(at: t(0))
        await guard1.observeAudioLevel(stream: .mic, rms: 0.001, at: t(0))
        await guard1.observeAudioLevel(stream: .system, rms: 0.001, at: t(0))
        await guard1.tick(now: t(30))  // prompt #1

        await guard1.keepRecording(now: t(31))
        let snoozed = await guard1.state
        if case .snoozed(let until) = snoozed {
            XCTAssertEqual(until.timeIntervalSinceReferenceDate, 31 + 15 * 60, accuracy: 0.001)
        } else {
            XCTFail("expected .snoozed after Keep Recording; got \(snoozed)")
        }

        // 5 minutes later, still silent — must NOT re-prompt during snooze.
        await guard1.observeAudioLevel(stream: .mic, rms: 0.001, at: t(31 + 5 * 60))
        await guard1.observeAudioLevel(stream: .system, rms: 0.001, at: t(31 + 5 * 60))
        await guard1.tick(now: t(31 + 5 * 60))
        let countDuringSnooze = await promptCount.value
        XCTAssertEqual(countDuringSnooze, 1, "snoozed window must not re-prompt; spec line 180 = 15min")

        // After snooze expires, silence should re-prompt.
        let postSnooze = 31 + 15 * 60 + 1
        await guard1.observeAudioLevel(stream: .mic, rms: 0.001, at: t(Double(postSnooze)))
        await guard1.observeAudioLevel(stream: .system, rms: 0.001, at: t(Double(postSnooze)))
        await guard1.tick(now: t(Double(postSnooze)))  // exits snooze → watching → quiet
        await guard1.tick(now: t(Double(postSnooze + 31)))  // 30s of quiet
        let countAfterSnooze = await promptCount.value
        XCTAssertEqual(countAfterSnooze, 2, "snooze must end at the configured time")
    }

    func testFourHourMaxSessionAutoStops() async {
        let autoStops = AsyncCounter()
        var capturedReason: EndGuard.Reason?
        let captured = AsyncBox<EndGuard.Reason>()
        let guard1 = await EndGuard(config: testConfig, onAutoStop: { reason in
            await captured.set(reason)
            await autoStops.increment()
        })
        await guard1.start(at: t(0))
        await guard1.observeAudioLevel(stream: .mic, rms: 0.5, at: t(0))
        await guard1.observeAudioLevel(stream: .system, rms: 0.5, at: t(0))

        // 4 hours later, even with audio still loud, the safety net fires.
        await guard1.tick(now: t(4 * 3600 + 1))
        capturedReason = await captured.value

        let stops = await autoStops.value
        XCTAssertEqual(stops, 1, "4h safety net must auto-stop even on loud audio")
        XCTAssertEqual(capturedReason, .maxSessionDurationReached)
    }

    func testHysteresisPreventsRapidFlapping() async {
        // Sub-30s blips of audio resume must reset the silence timer to
        // avoid prompting when there's clearly still activity. This is an
        // implicit consequence of the spec but worth a regression test.
        let promptCount = AsyncCounter()
        let guard1 = await EndGuard(config: testConfig, onPrompt: { _ in await promptCount.increment() })
        await guard1.start(at: t(0))

        // Silent at t=0, brief audio at t=20, silent again at t=21.
        await guard1.observeAudioLevel(stream: .mic, rms: 0.001, at: t(0))
        await guard1.observeAudioLevel(stream: .system, rms: 0.001, at: t(0))
        await guard1.observeAudioLevel(stream: .mic, rms: 0.5, at: t(20))
        await guard1.observeAudioLevel(stream: .mic, rms: 0.001, at: t(21))
        // From t=21 we have ~30s of silence; tick at t=51 → should prompt now,
        // not at t=30 (which would have been pre-blip silence).
        await guard1.tick(now: t(50))
        let pre = await promptCount.value
        XCTAssertEqual(pre, 0, "must NOT prompt at t=50 (only ~29s post-blip silence)")
        await guard1.tick(now: t(52))
        let post = await promptCount.value
        XCTAssertEqual(post, 1, "must prompt at t=52 (>30s post-blip silence)")
    }
}

// MARK: - test helpers

private actor AsyncCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

private actor AsyncBox<T: Sendable> {
    private(set) var value: T?
    func set(_ v: T) { value = v }
}
