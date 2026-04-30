# Transcriber

Menu-bar macOS app that captures meeting audio (mic + system) and produces high-fidelity markdown transcripts via ElevenLabs Scribe v2 or Cohere Transcribe (local).

> Spec, decisions, open questions, and QA all live in `docs/SPEC.md`. Implementation roadmap: `docs/superpowers/plans/2026-04-29-MASTER-ROADMAP.md`.

## Build

Requires macOS 15+, Xcode 16, Swift 6.

### Library + tests

```bash
swift build
swift test
```

### App

Open `TranscriberApp/TranscriberApp.xcodeproj` in Xcode and Product → Run.

The first launch will prompt for microphone and screen-recording permissions on later slices once capture is wired up. Bundle identifier is `com.szymonsypniewicz.transcriber`.

The Xcode project is generated from `TranscriberApp/project.yml` via [`xcodegen`](https://github.com/yonaskolb/XcodeGen). The generated `.xcodeproj` is tracked, so you do **not** need `xcodegen` installed to build. If you need to regenerate the project (e.g. after editing `project.yml`):

```bash
brew install xcodegen
cd TranscriberApp && xcodegen generate
```

## Architecture

- `TranscriberCore` — pure-Swift library, no AppKit. All business logic, all unit-tested.
- `TranscriberApp` — Xcode app target. Thin shell: lifecycle, menu bar, permission flows.

Slices ship from `docs/superpowers/plans/`. See `MASTER-ROADMAP.md` for the slice list.
