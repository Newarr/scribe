# Codebase examination report

Source plan: `docs/working/CODEBASE-EXAMINATION-PLAN.md`

Test command run:

```bash
swift test --parallel
```

Result: command exited successfully.

## Stage 1: product contract checklist

* Scribe is a macOS 15 menu bar app for recording meetings to durable Markdown transcripts.
* The product is record only. No import, live transcript UI, history UI, summaries, vector store, chat, or notes generation.
* Recording starts only after an explicit user action. Only one active recording is allowed.
* Capture must include microphone and system audio through ScreenCaptureKit. There is no mic only fallback.
* Audio must be durably saved before transcription starts.
* The default output root is `~/Scribe/`.
* Each session folder must end with `transcript.md`, `audio.m4a`, and `metadata.json`.
* Transcription uses the explicit session engine snapshot: ElevenLabs cloud or Cohere local. No silent engine fallback.
* ElevenLabs keys live only in Keychain. Calendar context sent to cloud is bounded keyterms only.
* Start prompts are aggressive and redundant: modal, notification, and menu bar recovery.
* End prompts are non focus stealing: HUD, notification, countdown, and Keep Recording snooze.
* Recovery must preserve audio across crash, force quit, power loss, and mid transcription failure.
* Scribe owned windows should set confidential sharing so prompts and windows do not appear in screen shared video.

## Stage 2: happy path trace

### Sequence

1. `AppDelegate.startRecording`
   * Checks privacy acknowledgement.
   * Runs `PermissionDoctor.audit` with current settings.
   * Applies the extra low disk check.
   * Creates a `SessionDirectory` under `outputRoot`.
   * Creates one `SCKDualOutputStream`, two `SCKAudioCaptureSource`s, and a `CaptureSession`.
   * Captures the session engine snapshot and optional calendar event.
2. `CaptureSession.start`
   * Acquires `SessionClaim` for the session directory.
   * Writes `session.json` engine provenance.
   * Starts mic and system `AudioFileWriter`s.
   * Wires SCK callbacks to `ingest`.
   * Starts mic and system capture.
3. `CaptureSession.ingest`
   * Appends each buffer to the matching writer.
   * Records PTS only after a successful append.
   * Sends live RMS levels back to the app.
4. `AppDelegate.stopRecording`
   * Tears down `EndGuard`.
   * Calls `CaptureSession.stop`.
5. `CaptureSession.stop`
   * Stops mic and system sources.
   * Finalizes both writers.
   * Flushes `pts.jsonl` and writes `pts.json`.
   * Renames `mic.m4a.partial` and `system.m4a.partial` to final files.
   * Writes a pending transcript stub.
   * Releases the capture claim.
6. `AppDelegate.stopRecording`
   * Builds `TranscriptContext` from the session, engine snapshot, and calendar event.
   * Writes a richer pending transcript.
   * Creates `TranscriptionWorker` and runs it in a tracked task.
7. `TranscriptionWorker.run`
   * Skips terminal sessions unless this is explicit retry.
   * Acquires the same session claim for transcription.
   * Finalizes `audio.m4a` through `AudioFinalizer`.
   * Writes pending transcript and `metadata.json` for recoverability.
   * Runs language detection if configured.
   * Calls the selected engine with `audio.m4a` and bounded keyterms.
   * Retries transient cloud errors using persisted attempt count.
8. `TranscriptWriter` and `MetadataJSONWriter`
   * Success: write statusless `transcript.md`, write complete `metadata.json`, then delete raw streams if policy allows.
   * Failure: write failed `transcript.md`, preserve audio, write failed `metadata.json`.

### What can break

* Privacy acknowledgement can block the whole path before capture.
* Preflight can block on mic, screen and system audio permission, output writability, missing cloud key, local model readiness, local runtime, or low disk.
* `SessionDirectory.create` can fail on permissions or filesystem errors.
* ScreenCaptureKit can fail because there is no display, no shareable content, permission problems, or start failure.
* `AudioFileWriter` setup, append, backpressure, and finalize can fail.
* Stop can fail in source stop, writer finalize, PTS write, partial rename, or transcript stub write.
* `AudioFinalizer` can fail reading source audio, converting, writing AAC, or waiting for backpressure. The worker then falls back to raw stream references.
* Engine calls can fail transiently or terminally. Transient cloud failures persist `retrying`; terminal errors write failure artifacts.
* Transcript or metadata writes can fail independently. Audio is usually preserved, but JSON consumers can lag if metadata write fails.
* Raw stream cleanup is best effort and only happens after complete transcript plus metadata success.

## Stage 3: recovery risk list

### Strong controls already present

* Capture and worker phases share `SessionClaim`, backed by `flock`, so live capture and relaunch recovery do not race the same files.
* Capture writes `session.json` before recording starts, so orphan recovery has engine provenance even before `transcript.md` exists.
* `OrphanRecoverer` distinguishes finalized, rescued, one sided audio, no audio, deferred rename, and active capture.
* One sided audio is stamped failed and is not sent to the engine.
* Rename failures keep `.partial` files and mark recovery deferred for the next scan.
* `TranscriptionWorker` persists pending and retrying state before engine calls.
* Explicit failed retry reuses the existing session directory and persisted engine.

### Risks

1. `CaptureSession.failAndCleanup` does not release `captureClaim` and does not notify `AppDelegate`. A backpressure drop or append failure can leave the app UI thinking it is still recording while recovery sees an active claim until the process exits or the claim goes stale.
2. If `CaptureSession.stop` throws, `AppDelegate.stopRecording` shows failure and returns without writing an immediate failed transcript. Recovery can repair on next launch, but the current run can violate the visible `every session ends with transcript.md` promise.
3. The pending stub written by `CaptureSession` has a `schema` frontmatter field and raw audio list. The worker overwrites it, but a crash between stop and worker can leave a stub that does not match the Markdown contract.
4. Orphan sessions with only `session.json` fall back to a placeholder context like `Resumed session ...`, so title, actual times, attendees, and calendar metadata can be lost when no transcript was written before crash.
5. Explicit retry requires `audio.m4a`. If `AudioFinalizer` failed and the failed transcript references raw streams only, Recents cannot retry even though audio may exist.
6. `writeRetrying` writes `String(describing: lastError)` into the transcript body without the same redaction path used by final failure details.
7. Persisted Local sessions remain pending when Cohere is not ready. That is fail closed, but those sessions depend on the setup repair UI to escape the pending state.
8. Missing or invalid engine provenance increments `missingEngineProvenance` and skips the worker. It avoids silent fallback, but can leave a recoverable session in limbo instead of a terminal failed transcript.

## Stage 4: meeting detection audit

### Prompt and start behavior

* `ProcessWatcher` filters to `MeetingApps.allowlist`, observes launch and terminate notifications, emits recent native launches, and rechecks already running apps every 5 seconds.
* App launch, wake from sleep, and EventKit store change all force detection reevaluation through `AppDelegate`.
* `DetectionEngine` applies a 30 second dwell, then asks `CoreAudioInputProbe` whether the app is active.
* Probe `true` fires a candidate. Probe `false` retries every 5 seconds until the 2 minute observation window expires. Probe `nil` takes the conservative path and fires.
* Calendar enrichment is implemented through `triggerIdentity(for:)` and `eventOverlapping(Date())`. Calendar alone does not emit candidates.
* Active recording or starting suppresses intrusive prompts and queues the candidate in the active popover.
* After stop, the queued candidate is released and reevaluated if still active.
* `StartPromptCoordinator` uses a custom confidential modal panel, activates the app, and places the window near the meeting app screen.
* Backup notifications are registered with Start Recording and Not now actions.
* Dismissed modals and notifications do not resolve the prompt. Menu bar recovery remains active.
* Ignored prompt policy exists: reminder at 60 seconds, then one final reminder around 3 minutes if call activity is still positive.

### Suppression behavior

* App level suppression for 30 minutes is in memory through `SkipState`.
* Suppression cancels pending observations and active candidates for that app.
* A rearm task handles long running apps when suppression expires.
* The modal itself has only Start Recording and Not now. App suppression is exposed from the menu bar recovery disclosure.
* Recurring meeting suppression and Quiet Meetings management are not implemented.

### Stop behavior

* End detection is separate from start detection.
* An ended current detection candidate calls `EndGuard.suspectCallEnded`.
* `EndGuard` also prompts after both mic and system levels are below 0.01 RMS for 30 seconds.
* `EndGuard` force stops at 4 hours from session start.
* The HUD is a nonactivating floating panel with confidential sharing.
* A notification is posted in parallel when possible.
* Audio resume cancels silence based prompts and suppresses immediate reprompt for 60 seconds.
* Keep Recording snoozes for 15 minutes.

## Stage 5: setup and settings blockers

| Condition | Blocks recording | Code path | Notes |
| --- | --- | --- | --- |
| Privacy acknowledgement missing | Yes | `AppDelegate.startRecording` | Presents onboarding and never starts capture. |
| Microphone missing or denied | Yes | `PermissionDoctor.audit` | Routes to permissions onboarding or setup popover. |
| Screen and system audio permission missing | Yes | `PermissionDoctor.audit` | No mic only fallback. |
| Output folder unwritable | Yes | `PermissionDoctor.audit` | Uses a write probe. |
| Free disk below 1 GB | Yes | `AppDelegate.startRecording` | Separate from `PermissionDoctor`. |
| Cloud selected and ElevenLabs key missing | Yes | `PermissionDoctor.audit` | Key is read from Keychain. |
| Local selected and model not verified | Yes | `PermissionDoctor.audit` | Covers not downloaded, downloading, verifying, and failed. |
| Local runtime unavailable | Yes | `PermissionDoctor.audit` | Blocks Local without Cloud fallback. |
| Calendar missing or denied | No | `PermissionDoctor.audit` | Warning only. |
| Notifications missing or denied | No | `PermissionDoctor.audit` | Warning only. |
| Output in synced storage | No | `PermissionDoctor.audit` | Warning exists, but current start path mostly logs it instead of showing a user acknowledgement. |
| Active or starting recording | Yes for new recording | `AppDelegate.startRecording`, `handleDetectionCandidate` | Manual start is ignored. Detection candidates queue instead. |
| Recovered Local session needs Cohere setup | Blocks recovery worker | `SessionSupervisor`, `SessionRepairRouting` | Session stays pending and setup repair is surfaced. |

## Stage 6: UI versus spec drift

### Markdown and transcript contract

* `CaptureSession.writeTranscriptStub` writes `schema: transcriber/v1` in `transcript.md`. The spec says Markdown frontmatter has no schema field.
* `TranscriptWriter.frontmatter` writes `started_at` and `ended_at` aliases. The spec frontmatter contract uses `actual_start` and `actual_end`.
* Calendar descriptions and sanitized `## Notes from calendar` are not represented in `CalendarEvent`, `TranscriptContext`, or `TranscriptWriter`.
* Organizer and location are supported by `TranscriptContext`, but `AppDelegate.makeContext` does not populate them from EventKit.
* Failure transcripts do not keep the same body shape as success. They omit metadata blockquote, attendees, and calendar notes.
* Complete transcripts list attendee names only in the body, not emails or organizer markers.
* Speaker blocks are emitted per utterance and use engine speaker IDs unless mapped. The spec wants grouped consecutive same speaker blocks with `Speaker A`, `Speaker B`, etc.

### Menu bar and popover

* The status item swaps icons only. It does not show elapsed time or MIC and SYS live indicators next to elapsed time.
* `RecordingMenu` stores `micLevel` and `systemLevel`, but the popover does not render MIC and SYS meters. The visible waveform is decorative.
* Active recording popover lacks an `Open Folder` secondary action.
* The Privacy Status block shows a folder name, not the full destination path requested by the spec.
* Recents are limited to 3 entries in `RecordingMenuModel.refreshRecents`, while the spec says 5.
* Recents row click opens the transcript, and folder opening is in a context menu. The spec asks for inline `Open Folder` and `Open Transcript` actions.

### Start prompt and Quiet Meetings

* The modal prompt has two buttons, but no `More options` disclosure on the modal itself.
* App suppression exists only through menu bar recovery after a pending prompt.
* `Stop asking about this meeting` is not implemented.
* Suppressed recurring series persistence is not implemented.
* Settings has no Quiet Meetings panel.

### Settings and storage

* Default output root drift is stale: code now defaults to `~/Scribe/`.
* The Settings window has General, Audio, Shortcuts, Vault, Privacy, Permissions, and About. No Quiet Meetings page exists.
* Vault shows location, reveal, and an on disk stat. It does not offer `Delete all audio (keep transcripts)`.
* Synced storage detection exists, but folder selection and recording start do not show the spec's one time provider acknowledgement flow.
* iCloud Drive is treated as a synced storage warning by `DefaultOutputFolderProbe`; the spec wants only a passive iCloud note.

### Onboarding

* The flow order mostly matches the spec and starts Cohere download on the Screen Recording step.
* The ElevenLabs API key step does not provide a key entry surface in this window.
* The Output Folder step accepts the default `~/Scribe/` directly instead of presenting folder choice and synced storage warning.
* Permission result display is minimal and advances immediately when granted; the spec asks to hold the result briefly.
* The Screen Recording explanation exists, but is much simpler than the specified two column captured versus not captured visual.

### Stop HUD and diagnostics

* Stop HUD is confidential, floating, nonactivating, and has the large countdown. It lacks the spec's progress ring.
* Stop HUD body copy says `10 seconds` statically even when the countdown changes.
* Diagnostics export is redacted, but the in app Diagnostics window shows a folder fingerprint rather than the output path. The spec asks the Diagnostics surface to show output path, with hashing reserved for export.

## Stage 7: recommended small batches

1. Clean the stale `Known Code-vs-Spec Drift` section in `docs/spec/SPEC.md`: remove the output root bullet, rewrite the start prompt bullet to match the current partial state, keep Quiet Meetings as real drift.
2. Tighten the transcript contract: remove Markdown `schema`, remove frontmatter aliases if not needed, add calendar notes plumbing, fill organizer and location, fix failure body shape, and normalize speaker grouping.
3. Implement the menu trust surface: elapsed text plus MIC and SYS indicators on the status item, and live MIC and SYS meters in the active popover.
4. Bring Recents to the spec: limit 5 and inline Open Folder and Open Transcript actions.
5. Finish suppression: add recurring meeting suppression persistence and Settings to Quiet Meetings.
6. Finish storage warnings: one time third party provider acknowledgement, passive iCloud note, and Delete all audio while keeping transcripts.
7. QA recovery edge cases: append failure, stop failure, raw only failed sessions, missing engine provenance, and retrying transcript redaction.
