# Slice 5 — Detection Layer (Light) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans`.

**Goal:** Auto-trigger a "Start recording <App>?" prompt when an allowlisted meeting app launches and stays running. User clicks **Start Recording** to begin a capture, **Not a meeting** to suppress prompts for that app for 30 minutes, or dismisses to defer. Skip semantics are in-memory only (slice 7's filesystem-as-queue model isn't extended here).

**Why "light":** The spec's full detection signal is `allowlisted app has mic active AND bidirectional audio observed ≥15s`. Both signals require either privileged macOS APIs (mic-usage-by-other-process is not cleanly exposed) or a continuously-running SCK stream pre-recording (annoying orange dot, TCC dependency, energy cost). Slice 5 light ships the high-value 80% — process-running detection with a debounce and skip — and defers true audio-activity detection to a follow-up. False positives (Zoom open but not in a call) are mitigated by Skip-for-30-min semantics.

**What's deferred:** mic-active detection per allowlisted app, bidirectional audio activity threshold, 15s sustained-signal dwell time (currently a fixed process-running debounce), re-prompt-after-60s behavior. Should ship as a slice 5b once the underlying APIs are scoped.

**Architecture:**
- **MeetingApps** — declarative allowlist (struct array keyed by bundle ID)
- **ProcessWatcher** — wraps `NSWorkspace.shared` notifications, filters to allowlisted bundles
- **SkipState** — actor tracking suppressed bundle IDs with TTL
- **DetectionEngine** — actor wiring watcher events through debounce + skip check
- **StartPromptCoordinator** (app target) — NSAlert UI
- **AppDelegate** — instantiate engine + coordinator, hook callback to startRecording

**Spec sections covered:** lines 52-75 (Detection signal + V1 allowlist), 164-171 (Start prompt — partial), `decision_allowlist_single_source`.

---

## File structure

```
Sources/TranscriberCore/Detection/
  MeetingApps.swift
  ProcessWatcher.swift
  SkipState.swift
  DetectionEngine.swift
Tests/TranscriberCoreTests/Detection/
  MeetingAppsTests.swift
  SkipStateTests.swift
  DetectionEngineTests.swift
TranscriberApp/TranscriberApp/
  StartPromptCoordinator.swift  # NEW
  AppDelegate.swift              # MODIFY
```

---

## Tasks (terse — full spec is implicit in tests)

**T1. MeetingApps + tests** — struct + allowlist constant. Bundle IDs: `us.zoom.xos`, `com.microsoft.teams2`, `org.whispersystems.signal-desktop`, `com.google.Chrome`, `com.apple.Safari`, `company.thebrowser.Browser`, `com.microsoft.Edge`, `org.mozilla.firefox`, `com.brave.Browser`, `im.helium.helium`. Tests: lookup by ID, lookup miss, allowlist count.

**T2. SkipState actor + tests** — `suppress(id, for: TTL, now:)`, `isSuppressed(id, now:)`. Tests: suppress + check, expire after TTL, clear.

**T3. ProcessWatcher** — NSWorkspace observer pattern. Cold-start emits launches for already-running allowlisted apps. No XCTest (NSWorkspace can't be driven headlessly); manual smoke.

**T4. DetectionEngine actor + tests** — Per-bundle dwell timer with `Task.sleep`. `handleLaunch(of:)` cancels any existing dwell, kicks off a new one. `handleQuit(of:)` cancels dwell. `suppress(_:for:)` cancels dwell + adds to SkipState. Tests with `dwellTime: 0.05`:
- launch → callback fires after dwell
- launch + quit before dwell → no callback
- launch when suppressed → no callback
- launch + suppress → callback never fires
- redundant launch events → only one callback

**T5. StartPromptCoordinator** — `@MainActor` class with `prompt(for:) async -> Choice`. NSAlert with 3 buttons: Start Recording / Not a meeting / Skip for now. No XCTest.

**T6. AppDelegate integration** — in `applicationDidFinishLaunching`: create SkipState + DetectionEngine + ProcessWatcher + StartPromptCoordinator. Engine's `onCandidate` closure presents prompt then routes choice. Don't fire prompts while already recording.

**T7. Acceptance + codex review + merge + tag v0.5.0-slice-5-light**.

---

## Definition of done

- [ ] Allowlisted app launch → after 30s of being open, NSAlert prompt appears
- [ ] "Not a meeting" suppresses re-prompts for that app for 30 minutes
- [ ] Quitting the app during dwell cancels the prompt
- [ ] Already-recording sessions ignore launch events
- [ ] All XCTest tests pass; CI green; codex review clean
- [ ] Deferred items flagged for slice 5b
