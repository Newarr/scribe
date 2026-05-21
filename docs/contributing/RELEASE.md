# Release Process

V1.0-rc4 is the current code-complete release candidate. Tagging `v1.0.0` requires the user to validate against [`TESTING.md`](TESTING.md) (Phase υ).

## Prerequisites

- Apple Developer ID Application certificate installed in your Keychain. Identity name available via `security find-identity -v -p codesigning` (look for `Developer ID Application: <your name>`).
- App-specific password for `notarytool`, stored in Keychain via `xcrun notarytool store-credentials scribe-notary --apple-id <email> --team-id <team>`.
- `xcodegen` for project regeneration: `brew install xcodegen`.
- `wrangler` is NOT used for this app (Scribe is local-only; no cloud deploys).

## Version bump

`scripts/bump-version.sh <new-version>` updates the canonical version surfaces in lockstep:

- `Sources/TranscriberCore/BuildInfo.swift` — `BuildInfo.version`.
- `TranscriberApp/project.yml` — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- `CHANGELOG.md` — adds a header for the new version.

After running, regenerate the Xcode project (`cd TranscriberApp && xcodegen`) and commit.

## Build + sign + notarize (release flow)

`scripts/release.sh` wraps the full pipeline (Phase σ):

1. `swift test` against the package.
2. `xcodegen` to regenerate the Xcode project.
3. `xcodebuild archive` produces `Scribe.xcarchive`.
4. `xcodebuild -exportArchive` with a `Developer ID` profile signs the bundled binaries with the same Team ID as the app. Local Cohere uses the Swift/MLX dependency path and pinned model artifacts rather than a bundled Rust executable.
5. `xcrun notarytool submit ... --keychain-profile scribe-notary --wait` notarizes; on success the staple is attached.
6. The notarized `.app` is wrapped in a DMG via `create-dmg` (Phase σ, not yet wired).

The release script reads credentials from Keychain only — it never accepts inline secrets. If credentials are missing, the script aborts with a per-credential message naming the Keychain entry it expected.

## Distribution

V1.0 distribution channels:

- **Direct download** — `releases.scribe.app/v1.0.0/Scribe-v1.0.0.dmg`. Hash + signing fingerprint published in the release notes.
- **Homebrew Cask** — Phase τ ships `Casks/scribe.rb.template`. The release script substitutes version + sha256 and submits to the user's tap.

## Post-release verification

After a release tag goes up:

1. Download the DMG from the published URL.
2. Run `spctl --assess --verbose=4 /Volumes/Scribe/Scribe.app` — should report `accepted` with `source=Notarized Developer ID`.
3. Drag-install + launch on a clean Mac. Click through the privacy acknowledgement, hit Record, verify the menu bar transitions to "Stop." Run the V1 acceptance walkthrough in [`TESTING.md`](TESTING.md).

## Hotfix flow

For a security or correctness fix that needs to ship faster than the next minor:

1. Branch from the latest release tag (e.g. `v1.0.0`).
2. Apply the fix + tests.
3. Bump version to `v1.0.<patch+1>`.
4. Run `scripts/release.sh` exactly as above.
5. Update CHANGELOG and tag.

Cherry-pick the fix back into `main` afterwards.

## Rollback

Releases are immutable; to revert, publish a new patch release with the offending change reverted. The download URL stays at the latest version; users on older versions will pick up the fix via Homebrew (`brew upgrade --cask scribe`) or by re-downloading the DMG.

## Reproducible builds

The build pipeline aims for reproducible binaries given the same source tree, signing identity, and Xcode toolchain. Differences in timestamps inside the codesigning data are expected. The non-codesign portion of the binary should hash identically across two clean builds at the same git SHA.
