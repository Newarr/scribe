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

# Codex rc1-final P1.6: refuse to release from a dirty worktree or
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

# 4. Regenerate the Xcode project so any new sources are picked up.
echo "==> Regenerating Xcode project via xcodegen"
(cd "${PROJECT_DIR}/TranscriberApp" && xcodegen)

# 5. Archive. Codex rc1-final P0.4: do NOT mask xcodebuild failures.
#    Wipe stale build dir first so a prior failed archive doesn't leak
#    into this run.
echo "==> Cleaning build directory + xcodebuild archive"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}"
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

# 8. Codesign + entitlement verification.
echo "==> codesign --verify"
codesign --verify --verbose=4 --strict --deep "${APP_PATH}"

# 9. Notarize.
echo "==> Submitting to notarytool (this can take several minutes)"
ZIP_PATH="${EXPORT_PATH}/TranscriberApp.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile transcriber-notary \
    --wait

# 10. Staple + verify the staple actually applied (codex rc1-final P0.4).
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

# 11. Build the DMG. Codex rc1-final P1.7: create-dmg's invocation
#     order is `<output.dmg> <source-folder>`, NOT `<source.app>
#     <output-folder>`. Stage the .app in a temp folder so the
#     resulting DMG only contains it.
echo "==> Wrapping in DMG"
if command -v create-dmg >/dev/null 2>&1; then
    STAGE_DIR="${PROJECT_DIR}/build/dmg-stage-${VERSION}"
    rm -rf "${STAGE_DIR}"
    mkdir -p "${STAGE_DIR}"
    cp -R "${APP_PATH}" "${STAGE_DIR}/"
    rm -f "${DMG_PATH}"
    create-dmg \
        --volname "Transcriber" \
        --window-size 540 380 \
        --icon-size 100 \
        --app-drop-link 360 180 \
        "${DMG_PATH}" \
        "${STAGE_DIR}/"
    rm -rf "${STAGE_DIR}"
    [[ -f "${DMG_PATH}" ]] || { echo "DMG was not produced at ${DMG_PATH}"; exit 1; }
else
    echo "    WARN: create-dmg not installed; skipping DMG build."
    echo "    Install via 'brew install create-dmg' if you need a DMG release artifact."
    DMG_PATH=""
fi

# 12. Verify Gatekeeper acceptance. Codex rc1-final P0.4: never mask.
echo "==> spctl --assess"
spctl --assess --verbose=4 --type execute "${APP_PATH}"

cat <<EOF

===
Release ${VERSION} built.
  app:  ${APP_PATH}
  dmg:  ${DMG_PATH:-(skipped)}

Next steps:
  - Tag the release:  git tag -s v${VERSION} -m 'Release ${VERSION}'
  - Push:             git push origin v${VERSION}
  - Update CHANGELOG.md.
EOF
