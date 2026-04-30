# Known Issues — V1.0-rc3

The four-parallel codex audit at the rc2 cut surfaced 15 P0 + 24 P1 + 9 P2 findings across privacy, concurrency, pipeline, and release dimensions. The bounded fixes landed in commit `b657c49`. This file used to track the remaining architectural-change findings; rc3 (commit pending) addresses every entry.

## All issues — RESOLVED

| ID | Title | Resolution |
|---|---|---|
| **CAP-1** | AudioFileWriter backpressure drops audio silently | `CaptureSession.ingest` now treats `.droppedBackpressure` as terminal and routes through `failAndCleanup` (same as a writer-level append failure). |
| **CAP-2** | AudioFinalizer ignores per-buffer PTS log | New `readFirstPTSAlignment` reads `pts.jsonl`, computes per-stream first-PTS, prepends silence frames to the on-time stream so mic and system align at session start. Optional parameter; missing log falls back to legacy zip-from-frame-zero. |
| **CAP-3** | Double-stop race + stop during `.starting` | Latched `inFlightStop: Task<Void, Error>?` — concurrent stops await the same task. `.starting + stop` transitions to `.failed` instead of silent no-op. |
| **CAP-4** | SessionClaim heartbeat/release not CAS-protected | Now uses `flock(LOCK_EX | LOCK_NB)` on a held FD for the worker's lifetime. OS releases the lock on process death. Heartbeat writes through the same FD so read-modify-write can't be interleaved with another process's reclaim. |
| **CAP-5** | OrphanRecoverer races active capture | `CaptureSession.start` acquires the same SessionClaim a worker would. `OrphanRecoverer.recover` probes the claim non-blocking; if held, returns new `.activeCapture` case which the supervisor maps to `skipped`. |
| **CAP-6** | writeRetrying failures swallowed → fresh budget on relaunch | `writeRetrying` now returns `Bool`; the worker treats persistence failure as terminal (`writeFailed` + `.failed(reason:)`) so an unfixable engine error can't loop forever via lost retry-counts. |
| **CAP-7** | SCK stop swallow + stream-ref drop | `stopIfRunning` retains `stream` until `stopCapture` succeeds. On failure, `stream` stays populated for the next stop attempt + `stopRequested` stays set so the coordinator is in a "stop pending" state. |
| **AUDIO-1** | StreamReader relies on undocumented sync converter callback | Re-entry guard via `NSLock + inProduce: Int32`. `produce()` increments on entry, decrements on exit; concurrent calls fatalError with a clear message rather than silently racing. |
| **AUDIO-2** | audio.m4a replacement not atomic | `FileManager.replaceItemAt` for the existing-file path (atomic rename); `moveItem` for the new-file path. |
| **STATE-2** | AppDelegate `@unchecked Sendable` claim too broad | Class is now annotated `@MainActor`. NSApplicationDelegate methods run on main per AppKit's contract; Swift strict concurrency now enforces it. `nonisolated(unsafe)` on the immutable Keychain-service-name constants for the `nonisolated static func makeWorker` access. |
| **STATE-3** | Start failure leaves session fields set | Catch path in `startRecording` clears `session`, `currentSessionDirectory`, `currentSessionStartedAt`, `currentCalendarEvent`. |
| **STATE-4** | EndGuard reentrancy via async prompts | `promptGeneration: Int` increments on every transition into `.prompted`. `keepRecording` and `stopNow` accept an optional `generation` parameter and no-op on mismatch. |
| **PRIVACY-1** | Diagnostics collector loads full transcripts | New `TranscriptFrontmatterReader.readStatusAndAttemptsStreaming(at:)` uses `InputStream` to read byte-by-byte until the second `---` line. `DiagnosticsCollector.collectSessions` switches to it. |
| **PRIVACY-2** | DiagnosticsInstanceID falls back to ephemeral on Keychain failure | New `currentState() -> State` returns `.configured(secret)` or `.unreadable`. `AppDelegate.buildDiagnosticsSnapshot` writes the literal string `"unreadable"` to `outputRootHash` when the keychain is unreadable, surfacing the failure to support without using a phantom-keyed hash. |
| **RELEASE-1** | bump-version.sh doesn't validate SemVer | Regex check against the SemVer 2.0 BNF (`MAJOR.MINOR.PATCH[-prerelease][+build]`) before any sed. |

## How this list grew

Each codex review (8 total over the autonomous run) produced findings, the bounded ones were fixed in adjacent commits, the architectural ones landed here. rc3 is the first release candidate with no outstanding KNOWN_ISSUES.

## Tagging v1.0.0

With this list empty, the user can tag `v1.0.0` once `docs/TESTING.md` is walked through. Until then the build stays at `v1.0.0-rc3` (or `rc4` if a new audit finds more).
