# Slice 7 — Recovery + Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Make the cloud transcription path production-ready. Three things ship together because they share one filesystem-as-queue model: (1) **retry on transient failures** — HTTP 429/5xx/timeout retry per spec's 1m/5m/30m policy; (2) **survival across app quits / crashes** — a supervisor scans `~/Documents/Transcriber/` on launch and resumes any session whose `transcript.md` shows `status: pending` or `status: retrying`; (3) **orphan recovery** — sessions where `session.stop()` threw and left `.partial` audio files get rescued by renaming to `.m4a` and queuing for transcription.

**Why this slice now (vs slice 4 AEC):** slice 4 needs the AEC3 spike (real call without headphones, listen to `mic.cleaned.wav`, judge bleed) which is a manual user task. Slice 7 is fully unblocked, addresses bugs codex already flagged in the slice-2 challenge round (P1.3 cancellation, P1.6 retry, P2.9 record-during-upload), and gives slice 8's local engine a working queue model to plug into.

**Architecture:**
- **`TranscriptStatus` enum** — formalize `pending | retrying | complete | failed` (slice 2's `TranscriptWriter` uses raw strings; consolidate now).
- **`RetryPolicy`** — pure value type. Schedule = `[60, 300, 1800]` seconds. `nextAttempt(after:)` returns either a delay or `.terminal` after attempt 3.
- **`TranscriptionWorker`** — actor that owns one session's retry loop. Reads/writes transcript status as it cycles. Knows nothing about UI.
- **`SessionSupervisor`** — actor scanned at app launch. Walks `~/Documents/Transcriber/`, parses each `transcript.md`'s frontmatter status, dispatches a `TranscriptionWorker` for any `pending` / `retrying` session and any session with orphan `.partial` files.
- **`OrphanRecoverer`** — small helper: if a session has `.partial` files but no finalized `.m4a`, rename `.partial → .m4a` (best-effort) so transcription can proceed. Sessions with totally absent audio are marked `status: failed`.

**Tech stack:** Foundation (Date math, FileManager scan, simple YAML parsing). No new third-party deps. Retry timing uses `Task.sleep` so it stops cleanly when the app quits — losing in-flight retry timers is fine because the supervisor on next launch re-detects `status: retrying` and reschedules.

**Spec sections covered:** Engines lines 114 (retry policy), Lifecycle lines 148-149 (`Retrying` state), Recovery lines 212-216, transcript contract lines 244-251 (status enum).

---

## File Structure

After this slice:

```
Sources/TranscriberCore/
  Engines/
    RetryPolicy.swift              # NEW
  Storage/
    TranscriptStatus.swift         # NEW (enum extracted from TranscriptWriter strings)
    TranscriptStatusReader.swift   # NEW (parse frontmatter status from disk)
  Recovery/
    OrphanRecoverer.swift          # NEW
    SessionSupervisor.swift        # NEW
    TranscriptionWorker.swift      # NEW

Tests/TranscriberCoreTests/
  Engines/
    RetryPolicyTests.swift
  Storage/
    TranscriptStatusReaderTests.swift
  Recovery/
    OrphanRecovererTests.swift
    SessionSupervisorTests.swift
    TranscriptionWorkerTests.swift  # uses a fake engine

TranscriberApp/TranscriberApp/
  AppDelegate.swift                 # MODIFY: launch supervisor at startup; use worker
```

---

## Task 1: TranscriptStatus enum + status reader

**Files:**
- Create: `Sources/TranscriberCore/Storage/TranscriptStatus.swift`
- Create: `Sources/TranscriberCore/Storage/TranscriptStatusReader.swift`
- Create: `Tests/TranscriberCoreTests/Storage/TranscriptStatusReaderTests.swift`
- Modify: `Sources/TranscriberCore/Storage/TranscriptWriter.swift` (use new enum, no behavior change)

The reader parses minimal YAML frontmatter — just `status:` and `engine:`. Don't pull in a YAML library; the writer's output shape is fixed and known.

- [ ] **Step 1: Create TranscriptStatus**

```swift
public enum TranscriptStatus: String, Sendable, Codable, Equatable {
    case pending
    case retrying
    case complete
    case failed
}
```

- [ ] **Step 2: Create TranscriptStatusReader**

Parses `transcript.md`. Reads only the lines between the first `---` and the second `---`. Looks for `status: <value>` in particular.

- [ ] **Step 3: Failing tests**

Three reader tests: a real complete transcript, a pending stub, a malformed file (returns nil). One test asserts `TranscriptWriter.writePending` produces a file the reader correctly classifies as `.pending`.

- [ ] **Step 4: Implement reader; refactor TranscriptWriter to call `status.rawValue`**

- [ ] **Step 5: Commit**
```bash
git add Sources/TranscriberCore/Storage/TranscriptStatus.swift \
        Sources/TranscriberCore/Storage/TranscriptStatusReader.swift \
        Sources/TranscriberCore/Storage/TranscriptWriter.swift \
        Tests/TranscriberCoreTests/Storage/TranscriptStatusReaderTests.swift
git commit -m "storage: TranscriptStatus enum + frontmatter reader"
```

---

## Task 2: RetryPolicy

**Files:**
- Create: `Sources/TranscriberCore/Engines/RetryPolicy.swift`
- Create: `Tests/TranscriberCoreTests/Engines/RetryPolicyTests.swift`

Pure value type. The schedule is `[60, 300, 1800]` seconds (1m / 5m / 30m). `nextDelay(afterAttempt: Int) -> Duration?` returns `nil` after the 3rd failure.

```swift
public struct RetryPolicy: Sendable {
    public static let cloud = RetryPolicy(delays: [60, 300, 1800])
    public let delays: [TimeInterval]
    public var maxAttempts: Int { delays.count + 1 }

    public init(delays: [TimeInterval]) { self.delays = delays }

    /// Returns the delay to wait before attempt `n+1`, where `n` is the number of
    /// failed attempts so far. Returns nil when `n >= delays.count` (terminal).
    public func nextDelay(afterFailedAttempts n: Int) -> TimeInterval? {
        guard n < delays.count else { return nil }
        return delays[n]
    }
}
```

Tests cover: `nextDelay(afterFailedAttempts: 0) == 60`, attempt 2 == 300, attempt 3 == 1800, attempt 4 == nil. Plus a custom-delay-array test.

---

## Task 3: TranscriptionWorker

**Files:**
- Create: `Sources/TranscriberCore/Recovery/TranscriptionWorker.swift`
- Create: `Tests/TranscriberCoreTests/Recovery/TranscriptionWorkerTests.swift`

An `actor` that owns one session's retry loop. Constructor takes the session directory, the `TranscriptionEngine`, and a `RetryPolicy`. Public method `run()`:
1. Read current status from disk. If `complete` or `failed`, return immediately.
2. Determine `attemptNumber` from the transcript frontmatter (or 1 for fresh).
3. Try the engine. On success: write `status: complete`, return.
4. On error classified as transient (rate-limited, HTTP 5xx, network/timeout): write `status: retrying` with `attempt: <n>`, sleep `RetryPolicy.cloud.nextDelay(afterFailedAttempts: n) ?? terminal`, retry.
5. On terminal failure (non-transient, or out of retries): write `status: failed`, return.

**Cancellation:** uses `Task.sleep`, so an actor cancellation (app quit) breaks the loop cleanly. The on-disk state stays at `status: retrying` and the supervisor resumes on next launch.

**Transient classification:**
```swift
extension ElevenLabsScribeBackend.BackendError {
    var isTransient: Bool {
        switch self {
        case .rateLimited: return true
        case .httpError(let code): return (500...599).contains(code)
        case .unauthorized, .missingAPIKey, .malformedResponse: return false
        }
    }
}
```
URLSession errors with `URLError.timedOut`, `URLError.networkConnectionLost`, `URLError.cannotConnectToHost`, `URLError.notConnectedToInternet` are transient. Everything else is terminal.

Tests:
- happy path: fake engine returns success on attempt 1 → `status: complete`
- transient failure once, success on retry: fake engine throws `rateLimited` then succeeds → `status: complete`, attempt counted
- 3 transient failures: fake engine throws `rateLimited` 3x → `status: failed`, no 4th attempt
- terminal failure: fake engine throws `unauthorized` → `status: failed` immediately, no retries
- cancellation: `Task.cancel()` mid-sleep → no state corruption, status remains `retrying`

Use a `FakeTranscriptionEngine` with a queue of preconfigured responses. Inject a `Clock` so tests don't actually wait 60+ seconds — the worker takes a `Clock` (Swift 5.7+ `ContinuousClock` or a `TestClock` shim). Simpler: take a `sleep: (TimeInterval) async throws -> Void` closure.

---

## Task 4: OrphanRecoverer

**Files:**
- Create: `Sources/TranscriberCore/Recovery/OrphanRecoverer.swift`
- Create: `Tests/TranscriberCoreTests/Recovery/OrphanRecovererTests.swift`

A pure function-style helper. Given a `SessionDirectory`, scan its files:
- If `mic.m4a` exists → no recovery needed.
- If `mic.m4a.partial` exists but `mic.m4a` does not → rename `.partial` to `.m4a` (and likewise for system).
- If neither exists → return `RecoveryResult.noAudio` so the supervisor can mark the session `failed`.

```swift
public enum OrphanRecoverer {
    public enum Result {
        case alreadyFinalized
        case rescued
        case noAudio
    }
    public static func recover(_ dir: SessionDirectory) -> Result {
        let fm = FileManager.default
        let micFinalExists = fm.fileExists(atPath: dir.micFinal.path)
        let sysFinalExists = fm.fileExists(atPath: dir.systemFinal.path)
        if micFinalExists && sysFinalExists { return .alreadyFinalized }

        let micPartialExists = fm.fileExists(atPath: dir.micPartial.path)
        let sysPartialExists = fm.fileExists(atPath: dir.systemPartial.path)

        if !micFinalExists && micPartialExists {
            try? fm.moveItem(at: dir.micPartial, to: dir.micFinal)
        }
        if !sysFinalExists && sysPartialExists {
            try? fm.moveItem(at: dir.systemPartial, to: dir.systemFinal)
        }

        let nowMicExists = fm.fileExists(atPath: dir.micFinal.path)
        let nowSysExists = fm.fileExists(atPath: dir.systemFinal.path)
        if nowMicExists || nowSysExists {
            return .rescued
        }
        return .noAudio
    }
}
```

Tests cover all four shapes: nothing, only `.partial`, only `.m4a`, mix.

---

## Task 5: SessionSupervisor

**Files:**
- Create: `Sources/TranscriberCore/Recovery/SessionSupervisor.swift`
- Create: `Tests/TranscriberCoreTests/Recovery/SessionSupervisorTests.swift`

An `actor`. Public method `scanAndResume(under root: URL, engine: TranscriptionEngine)`:
1. Enumerate subdirectories of `root`.
2. For each, build a `SessionDirectory` (the type is just a URL wrapper).
3. Run `OrphanRecoverer.recover(dir)`. If `.noAudio`, write `status: failed` with "audio missing" message and skip.
4. Read the existing `transcript.md` status. If `.complete` or `.failed`, skip. If `.pending` or `.retrying` (or absent altogether after a fresh `.rescued`), dispatch a `TranscriptionWorker` for that session.
5. Workers run concurrently, each in their own Task.

Tests use a fake engine + temp directories with prepared fixture sessions:
- A `complete` session → skipped, untouched.
- A `pending` session with valid audio → worker runs, completes.
- A `retrying` session that's exhausted attempts (worker writes `failed`).
- An orphan session with only `.partial` → recovered, queued, transcribed.
- A session with no audio at all → marked `failed`, no worker.

---

## Task 6: AppDelegate integration

**Files:**
- Modify: `TranscriberApp/TranscriberApp/AppDelegate.swift`

Three changes:
1. **Launch supervisor at startup.** In `applicationDidFinishLaunching`, after setting up the menu, kick off `SessionSupervisor.scanAndResume(under: outputRoot, engine: makeBackend())` on a background `Task`. Handles the "previous run crashed mid-transcribe" case.
2. **Replace inline transcribe with worker.** The existing `transcribe(directory:startedAt:endedAt:event:)` extension hands off to `TranscriptionWorker.run()` instead of running the upload pipeline directly. The worker reads/writes transcript status; AppDelegate just builds the engine and passes the directory.
3. **Cancellation on quit.** Wire `applicationShouldTerminate(_:)` to `Task.cancel` the in-flight worker(s) and return `.terminateLater` until they observe cancellation. Cap the wait at 3 seconds to avoid hanging Quit if a worker is stuck mid-network. The on-disk `status: retrying` survives, so the next launch supervisor picks it up.

Build via xcodegen + xcodebuild as in prior slices.

---

## Task 7: Acceptance + codex + merge + tag

- [ ] `swift test` — should be 50+ tests now (46 + ~10 new from slice 7).
- [ ] `xcodebuild` — app must build.
- [ ] Manual smoke (optional, depends on user TCC + API key state):
  - Set an invalid Keychain API key; record briefly; verify `transcript.md` lands at `status: failed` (not retrying — auth is terminal).
  - Set a valid key, hit Record/Stop, then immediately quit the app while transcription is still in flight. Relaunch. Verify the supervisor picks up the `pending`/`retrying` state and resumes; final `transcript.md` is `complete`.
- [ ] Update master roadmap row 7 to shipped.
- [ ] Run `codex review --base v0.3.0-slice-3 -c 'model_reasoning_effort="high"'` — fix P1 inline.
- [ ] Merge to main, push, tag `v0.4.0-slice-7`.

---

## Definition of done

- [ ] `RetryPolicy.cloud` matches spec's 1m/5m/30m schedule.
- [ ] HTTP 429 → retry; 5xx → retry; timeout → retry; auth error → fail immediately.
- [ ] After 3 failed attempts the transcript ends at `status: failed`.
- [ ] Quitting the app mid-retry leaves `status: retrying` on disk; relaunch resumes from there.
- [ ] Orphaned `.partial` files (from slice 1's failed-stop bug or any future failure) are renamed and the session is queued for transcription.
- [ ] Sessions with no audio at all (the truly broken case) get `status: failed` instead of staying invisible.
- [ ] All XCTest tests pass; CI green; codex review passes (P1 = 0 unresolved).

When all checked, slice 7 is done. Slice 5 (Detection) can run independently next; slice 4 (AEC) requires the spike to unblock first.
