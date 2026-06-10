# Agent Context

Use this directory as the source of truth for the Scribe product spec.

## Product priorities (read first)

Scribe's intent is convenience: every meeting captured so the transcripts can
feed agentic workflows later. Priority order for any product, design, or
roadmap decision:

1. **Seamlessness and beautiful, simple UI.** Zero-friction capture is the
   product. Anything that adds a step, a prompt, or visual noise to the
   capture path needs to justify itself against this.
2. **Outputs as agent inputs.** `transcript.md` frontmatter and
   `metadata.json` are designed for downstream automation; machine
   consumability is a first-class concern.
3. **Privacy is a feature, not the mission.** Local mode exists for ease of
   mind on sensitive calls; it is a function of seamlessness, not an
   ideology. Keep the hard invariants (Keychain-only secrets, no secrets in
   logs, diagnostics redaction), but do not rank privacy posture above
   convenience, frame the product around it, or propose features primarily
   on privacy grounds.

## GStack

Future agents should use GStack workflows for this project when the task matches them:

- Use `plan-ceo-review` for product scope, defaults, reminders, and v1/v2 tradeoffs.
- Use `plan-eng-review` for architecture, state machine, EventKit, ScreenCaptureKit, output durability, and failure modes.
- Use `plan-design-review` for menu bar UX, prompts, settings, permission recovery, and stop countdown flows.
- Use `cso` for audio/privacy/security review, Keychain handling, calendar metadata, ElevenLabs context, retention, and diagnostics redaction.
- Use `qa` for browser/app QA once there is a runnable UI to test and fix.
- Use `qa-only` for report-only QA when fixes are not requested.
- Use `review` before landing meaningful implementation changes.
- Use `document-release` after product or architecture changes so docs stay aligned.
- Use `ship` only when the user asks to commit/push/create a PR.

If the user asks for broad planning, run the relevant GStack plan reviews before editing implementation. If the user asks for implementation, read the docs below first and then use GStack review/QA as verification where appropriate.

Before implementing, read `docs/spec/SPEC.md` — the consolidated single source of truth (product spec, design decisions, open questions, acceptance criteria, references).

Important constraints:

- Every session ends with `transcript.md`.
- Product is record-only. Do not add import.
- Default behavior is transcribe and save audio.
- Missing system audio permission blocks recording.
- No mic-only fallback.
- No live transcript UI.
- No transcript history UI.
- No LLM notes, summaries, polishing, vector DB, or chat.
- Calendar context sent to ElevenLabs is keyterms-only by default.
- ElevenLabs key belongs only in Keychain.
- Audio is the durable asset; transcription failure must not lose it.

When adding open questions, use stable unique IDs in the `## Open Questions` section of `docs/spec/SPEC.md`.

## Dev Build Signing (TCC persistence)

Local dev builds are signed with a stable identity so TCC grants
(Screen Recording, Microphone, Calendar) and Keychain item ACLs survive
every rebuild. Without a stable identity, every `xcodebuild` /
`swift build` produces a new cdhash and macOS treats it as a different
app — the "Scribe" toggle stays on in System Settings but the running
binary can't see the grant.

- Identity: `$SCRIBE_DEV_IDENTITY` if set, else the first
  "Apple Development" identity in the default keychain search list
  (the earlier self-signed `Scribe Dev Signer 2` cert is retired; its
  locked custom keychain hung codesign and its NULL Team ID broke
  Keychain ACL matching)
- Install + sign script: `scripts/dev-install.sh`

Usage:

```bash
scripts/dev-install.sh                # re-sign /Applications/Scribe.app
scripts/dev-install.sh --build        # xcodegen + xcodebuild Debug + install + sign
scripts/dev-install.sh path/to/Scribe.app
```

On a fresh machine, install an Apple Development certificate via Xcode
(Settings → Accounts → Manage Certificates) or set `SCRIBE_DEV_IDENTITY`
to any code-signing identity in the login keychain. Without one the
script falls back to ad-hoc signing with a loud warning (TCC grants and
the cloud-key Keychain ACL will not survive).

`scripts/release.sh` still uses Developer ID + notarization for shipping
releases; the dev identity is for local /Applications installs only.
