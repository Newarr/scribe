Fix the installed Scribe smoke snapshot UI so the menu popover, privacy acknowledgement, ElevenLabs key entry, and onboarding evidence are production-ready when viewed as generated PNGs.

The shared facts are in `goals/visual-smoke-polish/facts.md`. The execution plan is in `goals/visual-smoke-polish/plan.md`.

Done means the requested UI fixes are implemented, the installed smoke snapshots are regenerated into `/tmp/scribe-installed-smoke`, the relevant PNGs are visually inspected, targeted tests pass, and smoke/build commands no longer leave path-dependent project churn.
