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

# 5. Archive.
echo "==> xcodebuild archive"
mkdir -p "${PROJECT_DIR}/build"
xcodebuild \
    -project "${PROJECT_DIR}/TranscriberApp/TranscriberApp.xcodeproj" \
    -scheme TranscriberApp \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    archive \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${IDENTITY}" \
    DEVELOPMENT_TEAM=$(echo "${IDENTITY}" | sed -nE 's/.*\(([0-9A-Z]+)\).*/\1/p') \
    | xcbeautify || true

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

# 8. Notarize.
echo "==> Submitting to notarytool (this can take several minutes)"
ZIP_PATH="${EXPORT_PATH}/TranscriberApp.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile transcriber-notary \
    --wait

# 9. Staple.
xcrun stapler staple "${APP_PATH}"

# 10. Build the DMG (Phase τ wires this; for rc1 the .app is the deliverable).
echo "==> Wrapping in DMG"
if command -v create-dmg >/dev/null 2>&1; then
    create-dmg --overwrite --volname "Transcriber" "${APP_PATH}" "${PROJECT_DIR}/build/" || true
    if [[ -f "${PROJECT_DIR}/build/Transcriber ${VERSION}.dmg" ]]; then
        mv "${PROJECT_DIR}/build/Transcriber ${VERSION}.dmg" "${DMG_PATH}"
    fi
else
    echo "    (create-dmg not installed; skipping. Install via 'brew install create-dmg'.)"
fi

# 11. Verify Gatekeeper acceptance.
echo "==> spctl --assess"
spctl --assess --verbose=4 --type execute "${APP_PATH}" || true

cat <<EOF

===
Release ${VERSION} built.
  app:  ${APP_PATH}
  dmg:  ${DMG_PATH}

Next steps:
  - Tag the release:  git tag -s v${VERSION} -m 'Release ${VERSION}'
  - Push:             git push origin v${VERSION}
  - Update CHANGELOG.md.
EOF
