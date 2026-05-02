# V1 Acceptance Testing

V1.0-rc4 is **code-complete**, not V1-shippable. The user (you) validates every box below before tagging `v1.0.0`. Until then, the build is `v1.0.0-rc4`.

Each checkpoint below maps to a `q_*_validation` answer or a Done-state requirement from the V1 plan. Mark each one Pass/Fail/Blocked. If anything fails as a code bug, file an issue and re-tag rc2. If something fails on quality (e.g. Polish transcription is worse than expected), capture the result and gate-flip via `EngineSelector` rather than rebuilding.

## How to use this doc

For each section:
1. Run the steps verbatim against a clean install (`brew uninstall --cask scribe && brew install --cask scribe`) or, in development, against an ad-hoc-signed build (`xcodebuild -project TranscriberApp/Scribe.xcodeproj`).
2. Tick the box in your local copy.
3. Capture diagnostics export at the end via menu → Diagnostics… → Export…; attach to the validation log.

## Build + smoke launch (CI-checkable)

- [ ] `swift test` passes (221+ tests).
- [ ] `xcodebuild -project TranscriberApp/Scribe.xcodeproj -scheme Scribe -configuration Release build` produces `Scribe.app`.
- [ ] First launch shows the privacy acknowledgement modal. Modal text mentions audio upload, calendar keyterms upload, local storage, and that calendar is optional.
- [ ] Title-bar close button is absent on the privacy modal (no closable). Cmd-W does not dismiss it.

## Permission preflight (`q_permission_doctor_validation`)

Revoke each permission in System Settings → Privacy & Security, attempt to record, verify the Setup Required popover surfaces the right reason and links to the right pane.

- [ ] **Mic denied** — popover shows "Microphone access denied" and "Open System Settings" jumps to the Microphone pane.
- [ ] **Screen & System Audio Recording denied** — popover shows "Screen & System Audio Recording access denied" and links to the Screen Recording / Screen & System Audio Recording pane.
- [ ] **API key cleared** in cloud mode — popover shows "ElevenLabs API key missing" and instructs to set it in Settings → Engine.
- [ ] **Output folder unwritable** — popover shows "Output folder isn't writable" with the full path.
- [ ] **Output folder in iCloud Drive / Dropbox / Google Drive** — popover shows the synced-storage warning but recording is allowed.
- [ ] **Calendar denied** — recording proceeds (calendar is optional). Popover surfaces the Calendar permission as a warning, never as a blocker.
- [ ] After fixing each one, "Recheck" inside the popover refreshes and (when all clear) lets the user dismiss.

## Engine readiness

- [ ] **Cloud mode without API key** → preflight denies with `cloudKey: missing` in the diagnostics export.
- [ ] **Local mode** (Settings → Engine → Local) → preflight denies with `missingLocalEngineBinary` (rc1 doesn't bundle the Cohere binary).
- [ ] **Cloud mode with valid key** → preflight allows; recording starts.

## End-to-end recording (`q_audio_capture_validation`)

Run a 2-minute test call (English) using cloud mode, headphones connected:

- [ ] Recording starts within 2 seconds of clicking Record.
- [ ] Menu bar reflects recording state ("Stop" appears, status icon changes if implemented).
- [ ] Stopping yields:
  - [ ] `mic.m4a` and `system.m4a` were present mid-session (check via `ls` while recording).
  - [ ] `audio.m4a` exists post-stop, mono AAC 48kHz, plays back at consistent volume.
  - [ ] `transcript.md` body has utterances grouped by speaker.
  - [ ] `metadata.json` `status: complete`, `audio: "audio.m4a"`.
  - [ ] Default `keep_raw_streams=false` → `mic.m4a` and `system.m4a` are deleted post-success (spec line 102).

## Recovery (`q_recovery_validation`)

- [ ] Force-quit (`kill -9`) the app mid-recording. Relaunch.
  - [ ] Supervisor scan log shows the orphan was rescued (`rescued > 0`).
  - [ ] The session ends in `complete` after a few seconds.
- [ ] Manually rename `mic.m4a` → `mic.m4a.partial` post-recording. Relaunch.
  - [ ] Recoverer renames it back; session completes.
- [ ] `chflags uchg` on `mic.m4a.partial` to force a rename failure. Relaunch.
  - [ ] Supervisor logs `recoveryDeferred=1`. NO `failed` transcript is written.
  - [ ] `chflags nouchg` and relaunch — supervisor recovers + completes.
- [ ] One-sided session (delete one of `mic.m4a` / `system.m4a` before transcription):
  - [ ] Supervisor writes a failed transcript naming the surviving file.
  - [ ] Frontmatter `audio:` references only the surviving file (NOT both).

## End Guard (`q_end_guard_validation`)

- [ ] Recording running, both streams silent for 30 seconds → "Call seems over" prompt appears.
- [ ] Click "Keep Recording" → snoozes for 15 minutes; no re-prompt during snooze.
- [ ] Audio resumes during the 10-second countdown → countdown cancels, recording continues.
- [ ] No interaction during countdown → auto-stop fires.
- [ ] 4-hour session safety net (set via debug build with shorter window) → auto-stops with `maxSessionDurationReached`.

## Detection (`q_detection_validation`)

- [ ] Open Zoom (or any meeting-app from `MeetingApps.allowlist`).
- [ ] Within 30 seconds, the start prompt appears with the correct app name.
- [ ] Calendar event matching: if a calendar event is currently active, the prompt title is the event title (`"Start recording 'Acme Weekly'?"`).
- [ ] Click "Not a meeting" → prompt suppresses for 30 minutes; re-arms after.
- [ ] Click "Skip for now" → prompt closes; re-fires on next launch of the app.
- [ ] Don't click anything for 60 seconds → prompt auto-dismisses with .skipForNow logged.

## Spike A: Polish quality (`spike_polish_quality`)

Cloud mode + Polish call:

- [ ] Record a 5-minute Polish-language call.
- [ ] Open the resulting `transcript.md`. Compare quality against your subjective ear:
  - [ ] Pass: Polish utterances are mostly correct. Speaker diarization is reasonable.
  - [ ] Fail: Polish quality is unacceptable. Switch to local-mode Cohere or WhisperKit (when bundled) and re-test.
  - [ ] Blocked: Local engine binary not yet bundled.

If cloud-mode Polish fails AND local-mode Cohere isn't ready yet, this is the gating spike that delays `v1.0.0` until the local engine ships.

## Spike B: AEC quality (`spike_aec_quality`)

Two-speaker call WITHOUT headphones:

- [ ] Record a 3-minute call where the remote speaker's voice is audible from your speakers (no headphones).
- [ ] Inspect `metadata.json`. `aec_status` should be:
  - [ ] `succeeded` if AEC backend is bundled (post-rc1 spike).
  - [ ] `failed` in rc1 — single-channel diarized fallback per spec line 119.
- [ ] In the failed case, transcript should still be readable. Diarization may collapse the two speakers but content is captured.

## Diagnostics (mandatory redaction)

- [ ] Open menu → Diagnostics… → Export…
- [ ] `~/Library/Logs/Scribe/diagnostics-*.json` is created.
- [ ] Open the JSON. Verify it contains ONLY the keys: `appVersion`, `exportedAt`, `settings`, `permissions`, `engine`, `sessions`, `liveLevels`.
- [ ] Verify it does NOT contain:
  - [ ] Any transcript body text from a recent session.
  - [ ] Any attendee name from a recent calendar event.
  - [ ] Any fragment of your API key (search for `sk_` prefix).
  - [ ] Any path component like `Users/<name>` (the `outputRootHash` is HMAC-SHA256, not the raw path).
- [ ] Two diagnostics exports from the same install produce the same `outputRootHash` (the HMAC key is stable per install).

## Settings UI

- [ ] Settings → Engine → switch from cloud to local. Save. The Settings window closes.
- [ ] Try to record. Preflight denies (local binary missing). Setup Required popover surfaces the missing-binary reason.
- [ ] Switch back to cloud. Save. Recording works again.
- [ ] Settings → Output → Choose new folder. Save. Next session writes there.
- [ ] Settings → Output → toggle "Keep raw mic / system streams." Verify next session preserves raws.

## Sign + notarize

- [ ] `scripts/release.sh 1.0.0-rc1` succeeds end-to-end on a Mac with the Developer ID cert and `scribe-notary` keychain profile.
- [ ] Result `Scribe.app` passes `spctl --assess`:
  ```
  /Volumes/.../Scribe.app: accepted
  source=Notarized Developer ID
  ```
- [ ] Drag-install to a clean Mac. Launch. Privacy modal appears. No "unsigned developer" Gatekeeper prompt.

## Homebrew install

- [ ] Run `scripts/release.sh` to substitute `Casks/scribe.rb.template` and publish to your tap.
- [ ] On a clean Mac, `brew install --cask scribe` succeeds.
- [ ] `brew uninstall --cask scribe --zap` removes app + Logs + Preferences. Verify Keychain entries (`elevenlabs-api-key`, `diagnostics-instance-id` under service `com.szymonsypniewicz.transcriber`) are NOT removed automatically. Homebrew Cask's zap stanza only deletes filesystem paths. The user wipes Keychain manually via `security delete-generic-password` per `docs/user/PRIVACY.md`.

## Final tag

When every box above is ticked Pass:

```
scripts/bump-version.sh 1.0.0
cd TranscriberApp && xcodegen
git add -A && git commit -m "release: v1.0.0"
git tag -s v1.0.0 -m "Release v1.0.0"
git push origin main v1.0.0
scripts/release.sh 1.0.0
```

Until then: rc1 stays rc1.
