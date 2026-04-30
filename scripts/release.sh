#!/usr/bin/env bash
# Phase σ: build + sign + notarize the Transcriber app.
#
# Reads credentials from macOS Keychain only — never accepts inline
# secrets or environment variables for sensitive values. If a credential
# is missing, aborts with a per-credential message naming the Keychain
# entry it expected.
#
# Required Keychain entries:
#   - service "codesign-identity", account "claude"
#       value: "Developer ID Application: <Your Name> (<Team ID>)"
#       look up via `security find-identity -v -p codesigning`
#   - notarytool credential profile named "transcriber-notary"
#       create via:
#         xcrun notarytool store-credentials transcriber-notary \
#             --apple-id <email> --team-id <team> --password <app-pwd>
#
# Required tools (verified before any work):
#   - xcodegen, xcodebuild, codesign, ditto, xcrun (notarytool, stapler)
#   - security
#   - create-dmg (brew install create-dmg)
#
# Usage:
#   scripts/release.sh <version>
#       e.g. scripts/release.sh 1.0.0-rc1

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>" >&2
    echo "  e.g. $0 1.0.0-rc1" >&2
    exit 64
fi
VERSION="$1"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="${PROJECT_DIR}/build/TranscriberApp-${VERSION}.xcarchive"
EXPORT_PATH="${PROJECT_DIR}/build/TranscriberApp-${VERSION}.export"
DMG_PATH="${PROJECT_DIR}/build/Transcriber-${VERSION}.dmg"

# Codex rc2-audit P0: required-tool check happens BEFORE worktree
# state, so a missing tool aborts cleanly without ever modifying the
# project. create-dmg is mandatory — the release channel is a DMG +
# Homebrew cask, so a release without one is a broken release.
echo "==> Verifying required tools"
for tool in xcodegen xcodebuild codesign ditto security create-dmg; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool '$tool' is not on PATH." >&2
        case "$tool" in
            create-dmg) echo "  Install: brew install create-dmg" >&2 ;;
            xcodegen)   echo "  Install: brew install xcodegen" >&2 ;;
        esac
        exit 78
    fi
done

# Codex rc2-audit P1.6: refuse to release from a dirty worktree or
# one whose version surfaces don't match the requested version.
echo "==> Checking release-state integrity"
if [[ -n "$(git -C "${PROJECT_DIR}" status --porcelain)" ]]; then
    echo "Worktree has uncommitted changes. Commit or stash before releasing." >&2
    exit 65
fi
EXPECTED_VERSION="$(grep -E 'public static let version' "${PROJECT_DIR}/Sources/TranscriberCore/BuildInfo.swift" | sed -nE 's/.*"([^"]+)".*/\1/p')"
if [[ "${EXPECTED_VERSION}" != "${VERSION}" ]]; then
    echo "BuildInfo.version is ${EXPECTED_VERSION}, but you asked to release ${VERSION}." >&2
    echo "Run scripts/bump-version.sh ${VERSION} first." >&2
    exit 65
fi

# Codex rc2-audit P0: project.yml MARKETING_VERSION must also match.
PROJECT_VERSION="$(grep -E 'MARKETING_VERSION:' "${PROJECT_DIR}/TranscriberApp/project.yml" | sed -nE 's/.*"([^"]+)".*/\1/p')"
if [[ "${PROJECT_VERSION}" != "${VERSION}" ]]; then
    echo "project.yml MARKETING_VERSION is ${PROJECT_VERSION}, but BuildInfo says ${VERSION}." >&2
    exit 65
fi

# 1. Locate the codesigning identity.
echo "==> Locating Developer ID identity in Keychain"
if ! IDENTITY="$(security find-generic-password -a claude -s codesign-identity -w 2>/dev/null)"; then
    cat >&2 <<EOF
Codesigning identity missing.
Add it to Keychain:
  security add-generic-password \\
    -a claude -s codesign-identity \\
    -w "Developer ID Application: <Your Name> (<Team ID>)"
Look up the exact identity string via:
  security find-identity -v -p codesigning
EOF
    exit 78
fi
echo "    using identity: ${IDENTITY}"

# 2. Verify the notarytool keychain profile exists.
echo "==> Verifying notarytool keychain profile"
if ! xcrun notarytool history --keychain-profile transcriber-notary >/dev/null 2>&1; then
    cat >&2 <<EOF
notarytool keychain profile 'transcriber-notary' missing.
Create it:
  xcrun notarytool store-credentials transcriber-notary \\
    --apple-id <email> --team-id <team> --password <app-specific-password>
EOF
    exit 78
fi

# 3. Run package tests.
echo "==> Running swift test"
cd "${PROJECT_DIR}"
swift test --quiet

# 4. Regenerate the Xcode project so any new sources are picked up,
#    THEN re-check the worktree. Codex rc2-audit P0: xcodegen
#    happens after the initial worktree check, which lets a stale
#    committed .xcodeproj diverge from the freshly-generated one.
#    The post-xcodegen check ensures the .xcodeproj on disk matches
#    what would be tagged.
echo "==> Regenerating Xcode project via xcodegen"
(cd "${PROJECT_DIR}/TranscriberApp" && xcodegen)

if [[ -n "$(git -C "${PROJECT_DIR}" status --porcelain)" ]]; then
    echo "xcodegen produced uncommitted changes:" >&2
    git -C "${PROJECT_DIR}" status --short >&2
    echo "Commit the regenerated .xcodeproj before releasing — otherwise the release artifact's source tree differs from the tagged commit." >&2
    exit 65
fi

# 5. Archive. Codex rc1-final P0: do NOT mask xcodebuild failures.
#    Wipe stale build dir first so a prior failed archive doesn't leak
#    into this run.
echo "==> Cleaning build directory + xcodebuild archive"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}" "${DMG_PATH}"
mkdir -p "${PROJECT_DIR}/build"
DEVELOPMENT_TEAM=$(echo "${IDENTITY}" | sed -nE 's/.*\(([0-9A-Z]+)\).*/\1/p')
if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild \
        -project "${PROJECT_DIR}/TranscriberApp/TranscriberApp.xcodeproj" \
        -scheme TranscriberApp \
        -configuration Release \
        -archivePath "${ARCHIVE_PATH}" \
        archive \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="${IDENTITY}" \
        DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
        | xcbeautify
else
    xcodebuild \
        -project "${PROJECT_DIR}/TranscriberApp/TranscriberApp.xcodeproj" \
        -scheme TranscriberApp \
        -configuration Release \
        -archivePath "${ARCHIVE_PATH}" \
        archive \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="${IDENTITY}" \
        DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}"
fi

# 6. Sign any bundled third-party binaries before exportArchive runs.
#    Currently a no-op; future Cohere/WebRTC binaries plug in here.
if [[ -x "${PROJECT_DIR}/scripts/sign-bundled-binaries.sh" ]]; then
    echo "==> Signing bundled binaries"
    "${PROJECT_DIR}/scripts/sign-bundled-binaries.sh" "${ARCHIVE_PATH}" "${IDENTITY}"
fi

# 7. Export with Developer ID profile.
EXPORT_PLIST="${PROJECT_DIR}/build/ExportOptions.plist"
cat > "${EXPORT_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>${IDENTITY}</string>
</dict>
</plist>
EOF

echo "==> xcodebuild -exportArchive"
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${EXPORT_PLIST}"

APP_PATH="${EXPORT_PATH}/TranscriberApp.app"
[[ -d "${APP_PATH}" ]] || { echo "Export did not produce ${APP_PATH}"; exit 1; }

# 8. Codesign + entitlement verification. Codex rc2-audit P1: actually
#    inspect the entitlements (not just verify signature integrity)
#    so a missing audio-input entitlement is caught before notarization.
echo "==> codesign --verify"
codesign --verify --verbose=4 --strict --deep "${APP_PATH}"

echo "==> Verifying audio-input entitlement is present in signed app"
ENTITLEMENTS_OUT="$(codesign -d --entitlements :- "${APP_PATH}" 2>/dev/null || true)"
if ! echo "${ENTITLEMENTS_OUT}" | grep -q "com.apple.security.device.audio-input"; then
    echo "Signed app is missing com.apple.security.device.audio-input entitlement." >&2
    echo "Hardened-runtime mic capture would fail at runtime." >&2
    echo "Check TranscriberApp/TranscriberApp/TranscriberApp.entitlements + project.yml CODE_SIGN_ENTITLEMENTS." >&2
    exit 1
fi

# 9. Notarize.
echo "==> Submitting to notarytool (this can take several minutes)"
ZIP_PATH="${EXPORT_PATH}/TranscriberApp.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile transcriber-notary \
    --wait

# 10. Staple + verify the staple actually applied.
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

# 11. Build the DMG. Codex rc2-audit P0: create-dmg is mandatory (we
#     verified at step 0); failure is fatal. Stage the .app in a
#     dedicated folder so the DMG only contains it.
echo "==> Wrapping in DMG"
STAGE_DIR="${PROJECT_DIR}/build/dmg-stage-${VERSION}"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cp -R "${APP_PATH}" "${STAGE_DIR}/"
create-dmg \
    --volname "Transcriber" \
    --window-size 540 380 \
    --icon-size 100 \
    --app-drop-link 360 180 \
    "${DMG_PATH}" \
    "${STAGE_DIR}/"
rm -rf "${STAGE_DIR}"
[[ -f "${DMG_PATH}" ]] || { echo "DMG was not produced at ${DMG_PATH}"; exit 1; }

# 12. Verify DMG contents (codex rc2-audit P0): mount, check the .app
#     has the right version, run spctl on the mounted app, unmount.
#     "DMG exists" is not the same as "DMG ships a working app."
echo "==> Verifying DMG contents"
MOUNT_OUT="$(hdiutil attach -nobrowse -noverify -noautoopen "${DMG_PATH}")"
MOUNT_DIR="$(echo "${MOUNT_OUT}" | tail -1 | awk '{$1=$2=""; print substr($0,3)}')"
trap "hdiutil detach \"${MOUNT_DIR}\" -quiet >/dev/null 2>&1 || true" EXIT

DMG_APP="${MOUNT_DIR}/TranscriberApp.app"
[[ -d "${DMG_APP}" ]] || { echo "DMG missing TranscriberApp.app"; exit 1; }

DMG_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${DMG_APP}/Contents/Info.plist" 2>/dev/null || true)"
if [[ "${DMG_BUNDLE_VERSION}" != "${VERSION}" ]]; then
    echo "DMG ships TranscriberApp.app with CFBundleShortVersionString=${DMG_BUNDLE_VERSION}, expected ${VERSION}." >&2
    exit 1
fi

# Gatekeeper assess on the mounted app — that's the artifact a user
# would actually drag-install.
spctl --assess --verbose=4 --type execute "${DMG_APP}"

hdiutil detach "${MOUNT_DIR}" -quiet >/dev/null 2>&1 || true
trap - EXIT

# 13. Compute DMG sha256 for the cask and emit a substituted
#     transcriber.rb adjacent to the DMG. The caller still has to
#     publish the DMG somewhere and copy the rb file into a tap repo,
#     but the SHA stamp is reproducible from this artifact.
echo "==> Producing concrete cask"
DMG_SHA256="$(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)"
CASK_OUT="${PROJECT_DIR}/build/transcriber-${VERSION}.rb"
sed \
    -e "s/{{VERSION}}/${VERSION}/g" \
    -e "s|{{DOWNLOAD_URL}}|REPLACE_WITH_PUBLISHED_DMG_URL|g" \
    -e "s/{{SHA256}}/${DMG_SHA256}/" \
    "${PROJECT_DIR}/Casks/transcriber.rb.template" > "${CASK_OUT}"

cat <<EOF

===
Release ${VERSION} built.
  app:     ${APP_PATH}
  dmg:     ${DMG_PATH}
  sha256:  ${DMG_SHA256}
  cask:    ${CASK_OUT}

Next steps:
  - Tag the release:  git tag -s v${VERSION} -m 'Release ${VERSION}'
  - Push:             git push origin v${VERSION}
  - Update CHANGELOG.md (must already be committed — release.sh
    refuses to run on a dirty worktree).
  - Publish the DMG and replace REPLACE_WITH_PUBLISHED_DMG_URL in
    ${CASK_OUT} before submitting to your tap.
EOF
