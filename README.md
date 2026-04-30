# Transcriber

A menu-bar macOS app that records your meetings and turns them into Markdown transcripts you can search, paste, and forget you took.

It stays out of the way until it matters: a meeting starts, audio drops, a permission breaks, a recording's been running too long. Then it asks one clear question with one obvious answer.

## What it does today (V1.0)

- **Records mic + call audio** simultaneously via ScreenCaptureKit.
- **Auto-detects** Zoom, Google Meet, FaceTime, Microsoft Teams, etc., and asks once whether to record. Ignores you for 30 minutes if you say it's not a meeting.
- **Auto-stops** after 30 seconds of silence, with a 10-second countdown HUD you can cancel.
- **Transcribes** through ElevenLabs Scribe and saves Markdown next to the audio in `~/Transcriber/`.
- **Recovers** from a crash — relaunch and any session that was mid-recording or mid-transcription resumes itself.
- **Survives quit** — Cmd-Q during a recording asks first, then finalizes audio and transcript before exit.

## What it does NOT do (yet)

- Run transcription locally on your Mac. Cloud-only in V1.0; a local engine ships in a later release.
- Live transcript display, summaries, AI follow-ups, or a transcript history UI. Open Finder; Markdown files don't need a browser.
- Native Google Calendar or Outlook. Use Apple Calendar (which can sync from anywhere).

## Install

### From Homebrew (when published)

```bash
brew install --cask transcriber
```

### From source (developer build)

Requires macOS 15+, Xcode 16, Swift 6.

```bash
git clone https://github.com/Newarr/transcriber.git
cd transcriber
swift test                                     # 223+ tests
open TranscriberApp/TranscriberApp.xcodeproj   # Xcode → Run
```

The Xcode project is generated from `TranscriberApp/project.yml` via [`xcodegen`](https://github.com/yonaskolb/XcodeGen). It's checked in, so you don't need `xcodegen` installed unless you're editing `project.yml`.

## First run

1. Launch Transcriber. A welcome window explains what data goes where. Click **Start using Transcriber**.
2. The menu bar gains a `T` icon. Click it → **Record now**.
3. macOS asks for microphone permission. Grant it.
4. macOS asks for **Screen & System Audio Recording** (this is what captures the audio of the *other* people on the call). Grant it, then **restart Transcriber**.
5. Settings → enter your **ElevenLabs API key**. Saved securely in your macOS Keychain.
6. Calendar permission is **optional** — granting it adds the meeting title and attendee names as transcription hints.

After that, Transcriber sits in the menu bar and either: (a) prompts when a meeting app launches during a calendar event, or (b) waits for you to click **Record now**.

## Where files live

```
~/Transcriber/
  2026-04-30-1430 - 1:1 with Faris/
    audio.m4a         ← mono AAC, 48kHz
    transcript.md     ← Markdown with frontmatter
    metadata.json     ← machine-readable mirror
```

The transcript is the source of truth. Markdown opens in any editor.

## Privacy

- **Recordings go to ElevenLabs** for transcription and are deleted from their servers after processing.
- **Calendar event titles + attendee names may be sent** as transcription hints if Calendar is granted. Notes, links, emails, dial-in codes, and passwords are never sent.
- **No telemetry.** The app doesn't phone home. Diagnostics export is local-only and PII-redacted (transcripts, attendees, API keys, full paths all stripped).
- **Wipe everything**: delete `~/Transcriber/`, run `security delete-generic-password -s com.szymonsypniewicz.transcriber -a elevenlabs-api-key`, drag the app to Trash.

Full details in [`docs/PRIVACY.md`](docs/PRIVACY.md).

## Troubleshooting

If something's not working: menu bar → **Diagnostics… → Export…** writes a JSON file to `~/Library/Logs/TranscriberApp/`. The export is safe to share with support — no transcript content, no attendee names, no API key, no paths.

Common issues + fixes: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Architecture

- **`TranscriberCore`** — pure-Swift library, no AppKit. Capture, audio, recovery, engine clients, settings. Fully unit-tested.
- **`TranscriberApp`** — menu bar shell. Lifecycle, SwiftUI windows, permission flows.

Spec: [`docs/SPEC.md`](docs/SPEC.md). Roadmap: [`docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md`](docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md).

## Status

`v1.0.0-rc4` — code-complete, pending user acceptance testing per [`docs/TESTING.md`](docs/TESTING.md).
