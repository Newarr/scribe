# Codebase examination staging plan

Use this plan to inspect Scribe without getting lost in the size of the codebase.

## Stage 1: Map the product contract

Read only:

- `AGENTS.md`
- `docs/spec/SPEC.md`
- `README.md`
- `Package.swift`

Output: one short checklist of what Scribe must do.

## Stage 2: Trace the happy path

Follow one recording from click to saved transcript:

1. `AppDelegate.startRecording`
2. `CaptureSession`
3. `TranscriptionWorker`
4. `TranscriptWriter`
5. `MetadataJSONWriter`

Output: a simple sequence diagram plus what can break.

## Stage 3: Trace failure and recovery

Focus on the core promise: audio must never be lost.

Read:

- `SessionSupervisor`
- `OrphanRecoverer`
- `SessionClaim`
- `FailedSessionRetryCoordinator`
- failure transcript code paths

Output: recovery risk list.

## Stage 4: Trace meeting detection

Keep this separate from recording.

Read:

- `ProcessWatcher`
- `DetectionEngine`
- `CalendarWatcher`
- `StartPromptCoordinator`
- `EndGuard`

Output: prompt, start, and stop behavior audit.

## Stage 5: Trace setup and settings

Focus on blockers.

Read:

- `PermissionDoctor`
- `PermissionsService`
- `SettingsStore`
- `SettingsWindow`
- `KeychainStore`
- `LocalModelManager`

Output: a table of what blocks recording.

## Stage 6: UI pass

Only do this after the logic is understood.

Read:

- `RecordingMenu`
- onboarding windows
- prompt windows
- countdown HUD
- diagnostics

Output: UI versus spec drift list.

## Stage 7: Fix in small batches

Suggested first batches:

1. Remove stale spec drift or confirm it is real.
2. Fix start prompt shape and suppression behavior.
3. Add Quiet Meetings settings.
4. Tighten transcript contract drift.
5. QA recovery and failed retry paths.

## Bottom line

Start with the recording lifecycle, then recovery, then detection, then UI. That keeps each pass small and avoids getting lost in SwiftUI surface area.
