# Scribe

A menu-bar macOS app that records your meetings and turns them into Markdown transcripts you can search, paste, feed to your agents, and forget you took.

Every session lands as plain Markdown with structured frontmatter plus a `metadata.json` mirror, so transcripts work as inputs for downstream automation without any export step. It stays out of the way until it matters: a meeting starts, audio drops, a permission breaks, a recording's been running too long. Then it asks one clear question with one obvious answer.

## What it does today (V1.0)

- **Records mic + call audio** simultaneously via ScreenCaptureKit.
- **Auto-detects** supported native calls (Zoom, Microsoft Teams, Signal, FaceTime) and browser-based calls (Google Meet and other meeting tabs in supported browsers), then asks once whether to record. Ignores you for 30 minutes if you say it's not a meeting.
- **Auto-stops** after 30 seconds of silence, with a 10-second countdown HUD you can cancel.
- **Transcribes** with your selected engine: ElevenLabs (cloud) or Cohere (local), then saves Markdown next to the audio in `~/Scribe/`.
- **Recovers** from a crash, relaunch and any session that was mid-recording or mid-transcription resumes itself.
- **Survives quit**, Cmd-Q during a recording asks first, then finalizes audio and transcript before exit.

## What it does NOT do

- Import existing audio. Scribe is record-only by design.
- Live transcript display, summaries, AI follow-ups, chat, vector search, or a transcript history UI. Open Finder; Markdown files don't need a browser.
- Native Google Calendar or Outlook. Use Apple Calendar (which can sync from anywhere).

## Install

### From Homebrew (when published)

```bash
brew install --cask scribe
```

### From source (developer build)

Requires macOS 15+, Xcode 26.3 (or another Swift 6.2-capable Xcode 26 toolchain matching CI).

```bash
git clone https://github.com/Newarr/scribe.git
cd scribe
swift test                                     # 592 tests as of rc4
open TranscriberApp/Scribe.xcodeproj           # Xcode → Run
```

The Xcode project is generated from `TranscriberApp/project.yml` via [`xcodegen`](https://github.com/yonaskolb/XcodeGen). It's checked in, so you don't need `xcodegen` installed unless you're editing `project.yml`.

## First run

1. Launch Scribe. A welcome window explains what data goes where. Click **Start using Scribe**.
2. The menu bar gains a wave icon. Click it → **Record now**.
3. macOS asks for microphone permission. Grant it.
4. macOS asks for **Screen & System Audio Recording** (this is what captures the audio of the *other* people on the call). Grant it, then **restart Scribe**.
5. Choose an engine in Settings → Engine. **Cohere (local)** uses the pinned `beshkenadze/cohere-transcribe-03-2026-mlx-fp16` model through `mlx-audio-swift`; **ElevenLabs (cloud)** requires an API key saved securely in your macOS Keychain.
6. Calendar permission is **optional**. In Cloud mode, granting it sends bounded keyterms (title/attendee names only) as transcription hints; in Local mode, calendar context stays on your Mac.

After that, Scribe sits in the menu bar and either: (a) prompts when a supported native app or browser appears to be in an active call, using Apple Calendar only to label the prompt when an eligible event overlaps, or (b) waits for you to click **Record now**.

## Where files live

```
~/Scribe/
  2026-04-30-1430 - 1:1 with Faris/
    audio.m4a         ← mono AAC, 48kHz
    transcript.md     ← Markdown with frontmatter
    metadata.json     ← machine-readable mirror
```

The transcript is the source of truth. Markdown opens in any editor.

## Privacy

- **Local mode uses Cohere (local) on your Mac.** Transcription sends no audio, transcript text, calendar context, keyterms, or API keys off device. Model setup may download the pinned public Cohere/MLX artifacts; it does not upload user content.
- **Cloud mode sends recordings to ElevenLabs** for transcription and they are deleted from their servers after processing. Calendar event titles + attendee names may be sent as bounded keyterms if Calendar is granted. Notes, links, emails, dial-in codes, and passwords are never sent.
- **No silent fallback.** Local never silently switches to Cloud, and Cloud never silently switches to Local. Engine changes are explicit user actions; failures preserve `audio.m4a` and write a failed transcript.
- **Local model cache is repairable.** Downloads use `.partial` files, verify pinned artifacts before Local becomes selectable, expose Retry on failure/low disk/corrupt cache, and Remove only deletes model cache files, not sessions.
- **No telemetry.** The app doesn't phone home. Diagnostics export is local-only and PII-redacted (transcripts, attendees, API keys, full paths all stripped).
- **Wipe everything**: delete `~/Scribe/`, remove the `elevenlabs-api-key` and `diagnostics-instance-id` Keychain entries under `com.szymonsypniewicz.scribe`, drag the app to Trash.

Full details in [`docs/user/PRIVACY.md`](docs/user/PRIVACY.md).

## Troubleshooting

If something's not working: menu bar → **Diagnostics… → Export…** writes a JSON file to `~/Library/Logs/Scribe/`. The export is safe to share with support, no transcript content, no attendee names, no API key, no paths.

Common issues + fixes: [`docs/user/TROUBLESHOOTING.md`](docs/user/TROUBLESHOOTING.md).

## Architecture

- **`TranscriberCore`**: pure-Swift library, no AppKit. Capture, audio, recovery, engine clients, settings. Fully unit-tested. (Library name kept stable across the product rename.)
- **`Scribe`**: menu bar shell. Lifecycle, SwiftUI windows, permission flows.

Spec: [`docs/spec/SPEC.md`](docs/spec/SPEC.md). Roadmap: [`docs/archive/superpowers/plans/2026-04-29-MASTER-ROADMAP.md`](docs/archive/superpowers/plans/2026-04-29-MASTER-ROADMAP.md).

## Status

`v1.0.0-rc4`, code-complete, pending user acceptance testing per [`docs/contributing/TESTING.md`](docs/contributing/TESTING.md).
