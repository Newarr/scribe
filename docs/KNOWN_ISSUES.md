# Known Issues — V1.0-rc2

The four-parallel codex audit at the rc2 cut surfaced 15 P0 + 24 P1 + 9 P2 findings. The bounded fixes (privacy P0s, release-pipeline P0s, simpler capture P0s) landed in commits adjacent to this doc; this file tracks the architectural-change findings that need careful design rather than rapid-fix.

These issues are **release-blockers** for a final `v1.0.0` tag. They are NOT spike-validation concerns — they're correctness gaps in the runtime behavior. The user should NOT tag `v1.0.0` until each is either fixed or explicitly reclassified as acceptable.

## Capture pipeline

### CAP-1: AudioFileWriter backpressure drops audio silently

**Source**: rc2 audit 3 (pipeline) P0.

`AudioFileWriter.append()` returns `.droppedBackpressure` when the AVAssetWriter input isn't ready, and `CaptureSession.ingest()` skips PTS for that buffer without persisting any "session has gaps" marker. The session ends in `.complete` state with audio silently missing chunks.

**Fix paths** (need design):
- (a) Block the capture thread until input is ready (introduces stall risk)
- (b) Promote backpressure-drop to a hard error → session ends `.failed`
- (c) Continue capturing but persist a per-session "audio integrity: degraded" flag in metadata.json so consumers know the file isn't gap-free
- (d) Use a larger AVAssetWriterInput buffer + warn at high-water-mark

Recommendation: (b) for V1.0 (correctness over availability), (c) longer-term.

### CAP-2: AudioFinalizer ignores per-buffer PTS log

**Source**: rc2 audit 3 P0.

Phase β.1 introduced `pts.jsonl` so AudioFinalizer could insert silence for inter-buffer gaps. AudioFinalizer was supposed to consume it; instead it zips decoded chunks from frame zero. Any first-PTS offset between mic and system misaligns the mix.

**Fix path**: AudioFinalizer reads pts.jsonl, computes per-stream offset relative to session start, prepends silence to whichever stream started later. Test with synthetic offset + verify alignment.

### CAP-3: Double-stop race + stop during `.starting`

**Source**: rc2 audit 2 P0.

Two issues: (a) `CaptureSession.stop()` returns success while a prior stop is still finalizing; AppDelegate then clears its session reference and starts the worker against unfinalized .partial files. (b) Stop during `.starting` is a no-op but AppDelegate treats it as finalized; capture continues with no stoppable session reference.

**Fix path**: Latched stop task — `CaptureSession` tracks `stopTask: Task<Void, Error>?`; concurrent stops await the same task. State transitions: `.starting → .stopping → .finalized` is a real chain; `.starting + stop` cancels the in-flight start AND drains any partial state.

### CAP-4: SessionClaim heartbeat/release not CAS-protected

**Source**: rc2 audits 2+3 P0.

`SessionClaim.heartbeat()` reads ownership then re-writes the claim file atomically, but the read-write isn't atomic. A stale worker can overwrite a newly reclaimed claim, AND a heartbeat racing with `release()` can resurrect the claim after the owner has exited.

**Fix paths**:
- (a) Hold an advisory `flock()`/`lockf()` for the worker's lifetime and only validate via lock state
- (b) Add a unique claim UUID; heartbeat verifies UUID matches before write; release verifies before delete

Recommendation: (a) — `flock()` solves this without the UUID dance.

### CAP-5: Orphan recovery races active capture (no claim during capture)

**Source**: rc2 audit 3 P0.

`OrphanRecoverer.recover()` moves `.partial` files directly. If a second app instance (or a manually-triggered scan) runs while the active capture is mid-flight, the recoverer renames the .partial out from under AVAssetWriter. The session would corrupt.

**Fix path**: `CaptureSession.start()` writes a claim file (`session.claim`) marking the session as actively capturing. `OrphanRecoverer.recover()` checks for the claim and skips recovery if a live capture holds it. The existing `SessionClaim` infrastructure (CAP-4) extends naturally to this.

### CAP-6: writeRetrying failures swallowed → fresh budget on relaunch

**Source**: rc2 audit 3 P0.

`TranscriptionWorker.writeRetrying()` errors are logged and swallowed. If the disk is briefly unwritable mid-retry, the on-disk attempts count never increments, and the next launch's supervisor reads stale frontmatter and grants a fresh retry budget — possibly looping forever against an unfixable engine error.

**Fix path**: Make `writeRetrying` throw; on persistence failure, treat as a terminal failure (the retry budget must be durable; a session that can't persist its retry count has bigger problems).

### CAP-7: SCK stop failure swallowed after dropping stream reference

**Source**: rc2 audits 2+3 P0/P1.

`SCKAudioCaptureSource.stopIfRunning` sets `stream = nil` BEFORE attempting `stopCapture()`. If the stop throws, capture continues with no way to stop or report it.

**Fix path**: Retain `stream` until `stopCapture()` succeeds; on failure, log and either retry or transition to a `.failed-but-uncloseable` state that gates future starts.

## Audio pipeline

### AUDIO-1: AudioFinalizer.StreamReader relies on undocumented synchronous AVAudioConverter callback behavior

**Source**: rc2 audit 2 P1.

The mutable state (`readBuffer`, `fileEOF`, `errorBox`) is captured by a `@Sendable` closure but the actual safety relies on AVAudioConverter invoking the callback synchronously on the calling thread of `convert(...)`. This is observed behavior, not contract.

**Fix path**: Wrap the StreamReader in a serial dispatch queue and `queue.sync { ... }` the callback's mutations. Adds latency per-callback but makes the contract robust against a future converter that batches input requests.

### AUDIO-2: audio.m4a replacement is not atomic

**Source**: rc2 audit 3 P1.

`AudioFinalizer.finalize()` removes the existing `audio.m4a` BEFORE moving the temp `.inflight` into place. A crash in that window loses the previous good canonical file.

**Fix path**: Use `FileManager.replaceItem(at:withItemAt:...)` which is atomic on macOS, OR rename old → backup, move temp → final, delete backup on success.

## Concurrency / state

### STATE-1: AudioFileWriter `finalized = true` before `finishWriting()` completes

**Source**: rc2 audit 2 P1.3.

**Status**: ADDRESSED in the rc2-audit fix commit via `finishingTask: Task<Void, Error>?`. Concurrent finalize callers now await the same Task. (Listed for completeness.)

### STATE-2: AppDelegate `@unchecked Sendable` claim too broad

**Source**: rc2 audit 2 P1.4.

Delegate methods aren't all explicitly `@MainActor`; `scheduleRearm` touches `NSWorkspace` from a generic Task.

**Fix path**: Annotate `AppDelegate` with `@MainActor`; verify every NSApplicationDelegate callback is main-thread-safe. Move `NSWorkspace` accesses inside `MainActor.run` blocks.

### STATE-3: Start failure leaves session fields set

**Source**: rc2 audit 2 P1.5.

If `SCStream.startCapture()` fails after `self.session = session` assignment, a later Stop/Quit can write a pending transcript for a never-started capture.

**Fix path**: Catch path of `startRecording()` clears `session`, `currentSessionDirectory`, `currentSessionStartedAt`, `currentCalendarEvent` BEFORE updating menu/status.

### STATE-4: EndGuard reentrancy

**Source**: rc2 audit 2 P1.6.

Async callbacks (`onAutoStop`, `onPrompt`) can suspend; meanwhile state transitions to `.stopped`; the resumed callback then mutates terminal state via `keepRecording()`.

**Fix path**: Generation counter — `keepRecording()` accepts a `generation: Int` matching the prompt that fired; mismatched generation returns no-op.

## Privacy

### PRIVACY-1: Diagnostics collector loads full transcripts

**Source**: rc2 audit 1 P1.

`TranscriptFrontmatterReader.read(at:)` calls `String(contentsOf: url)` — loads the entire transcript into memory, scans for frontmatter delimiters. The diagnostics output doesn't leak the body, but the redaction boundary is weaker than documented.

**Fix path**: Streaming frontmatter reader that reads byte-by-byte until the second `---` line, then closes the file. Preserves the privacy invariant under stricter readings.

### PRIVACY-2: DiagnosticsInstanceID falls back to ephemeral secret on Keychain failure

**Source**: rc2 audit 1 P1.

`try? keychain.read()` and `try? keychain.write(secret)` both swallow errors; the cached secret never persists, so two diagnostics exports across app restarts have different `outputRootHash` values — defeating the cross-export correlation invariant.

**Fix path**: Distinguish missing-from-Keychain vs unreadable-Keychain. On unreadable, surface a "diagnostics unavailable" state in the export rather than silently using a fresh ephemeral secret.

## Release pipeline

All four release P0s addressed in the rc2-audit fix commit. P1s deferred:

### RELEASE-1: bump-version.sh doesn't validate SemVer

**Source**: rc2 audit 4 P1.

The script accepts any string as the version. Invalid characters (quotes, shell metacharacters) end up injected into Swift / YAML / file paths.

**Fix path**: Regex-validate against SemVer 2.0 BNF before any sed.

## How this list shrinks

Each fix should land as a focused commit referencing the issue ID above (e.g. `capture: address CAP-4 SessionClaim CAS via flock`). When all issues are either fixed or explicitly reclassified, run a final codex audit and tag `v1.0.0`.
