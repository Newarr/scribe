#!/usr/bin/env bash
# Dev install: build (optional), copy to /Applications/, and sign with the
# local self-signed code-signing cert so TCC grants persist across rebuilds.
#
# Without a stable code-signing identity, every rebuild of Scribe gets a
# new cdhash and macOS treats it as a different app — Screen Recording,
# Microphone, etc. grants vanish even though the toggle in System Settings
# stays on. Signing with a self-signed cert that has a stable Subject Key
# Identifier solves this: TCC keys grants by the cert's leaf, not cdhash.
#
# One-time setup that produced the cert + dedicated keychain:
#   - openssl self-signed cert with CA:TRUE, keyUsage digitalSignature +
#     keyCertSign, extendedKeyUsage codeSigning (CN "Scribe Dev Signer 2")
#   - imported to ~/Library/Keychains/scribe-dev.keychain-db
#   - add-trusted-cert with policy codeSign
#
# Usage:
#   scripts/dev-install.sh                  # signs /Applications/Scribe.app in place
#   scripts/dev-install.sh path/to/Scribe.app
#       e.g. scripts/dev-install.sh build/Debug/Scribe.app
#   scripts/dev-install.sh --build          # xcodebuild Debug, then install + sign

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEV_KEYCHAIN="$HOME/Library/Keychains/scribe-dev.keychain-db"
IDENTITY="Scribe Dev Signer 2"
ENTITLEMENTS="${PROJECT_DIR}/TranscriberApp/Scribe/Scribe.entitlements"
TARGET="/Applications/Scribe.app"

if [[ ! -f "${DEV_KEYCHAIN}" ]]; then
    echo "Dev keychain missing: ${DEV_KEYCHAIN}" >&2
    echo "Re-run the one-time cert setup before using this script." >&2
    exit 1
fi

if ! security find-identity -v -p codesigning "${DEV_KEYCHAIN}" | grep -q "${IDENTITY}"; then
    echo "Code-signing identity '${IDENTITY}' not found in ${DEV_KEYCHAIN}" >&2
    exit 1
fi

if [[ ! -f "${ENTITLEMENTS}" ]]; then
    echo "Entitlements missing: ${ENTITLEMENTS}" >&2
    exit 1
fi

SOURCE=""
if [[ $# -gt 0 ]]; then
    case "$1" in
        --build)
            echo "==> xcodegen + xcodebuild Debug"
            (cd "${PROJECT_DIR}/TranscriberApp" && xcodegen)
            BUILD_DIR="${PROJECT_DIR}/build/dev"
            rm -rf "${BUILD_DIR}"
            mkdir -p "${BUILD_DIR}"
            xcodebuild \
                -project "${PROJECT_DIR}/TranscriberApp/Scribe.xcodeproj" \
                -scheme Scribe \
                -configuration Debug \
                -derivedDataPath "${BUILD_DIR}" \
                build
            SOURCE="$(find "${BUILD_DIR}/Build/Products/Debug" -maxdepth 2 -name 'Scribe.app' -type d | head -1)"
            if [[ -z "${SOURCE}" || ! -d "${SOURCE}" ]]; then
                echo "Could not locate built Scribe.app under ${BUILD_DIR}" >&2
                exit 1
            fi
            ;;
        *)
            SOURCE="$1"
            if [[ ! -d "${SOURCE}" ]]; then
                echo "Source app not found: ${SOURCE}" >&2
                exit 1
            fi
            ;;
    esac
fi

# Guard against signing a running app.
if pgrep -x Scribe >/dev/null; then
    echo "Scribe is running. Quit it first (or run: pkill -9 -x Scribe)." >&2
    exit 1
fi

if [[ -n "${SOURCE}" ]]; then
    echo "==> Installing ${SOURCE} → ${TARGET}"
    rm -rf "${TARGET}"
    cp -R "${SOURCE}" "${TARGET}"
fi

echo "==> Building dev entitlements (library validation disabled)"
# Self-signed certs have no Team ID. With library validation enabled
# (the production entitlement), macOS refuses to load the bundle's
# own dylibs because their NULL Team ID doesn't match the main
# binary's NULL Team ID. Dev signing flips this one bit; release.sh
# uses the unmodified TranscriberApp/Scribe/Scribe.entitlements.
DEV_ENTITLEMENTS="$(mktemp -t scribe-dev-ents).plist"
trap "rm -f '${DEV_ENTITLEMENTS}'" EXIT
cat > "${DEV_ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
    <!-- DEV ONLY: disabled because self-signed certs have no Team ID
         and library validation would reject the bundle's own dylibs.
         release.sh keeps this false in TranscriberApp/Scribe/Scribe.entitlements. -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Signing ${TARGET} with '${IDENTITY}'"
codesign --force --deep \
    --sign "${IDENTITY}" \
    --keychain "${DEV_KEYCHAIN}" \
    --options runtime \
    --entitlements "${DEV_ENTITLEMENTS}" \
    "${TARGET}"

echo "==> Verifying signature"
codesign --verify --verbose=2 "${TARGET}"

echo "==> Verifying entitlements include audio-input"
if ! codesign -d --entitlements - "${TARGET}" 2>/dev/null | grep -q "com.apple.security.device.audio-input"; then
    echo "WARNING: audio-input entitlement missing from signed app." >&2
    exit 1
fi

echo
echo "Done. Stable code-signing identity now applied."
echo "TCC grants for Screen Recording / Microphone / Calendar will persist across rebuilds"
echo "as long as you sign with '${IDENTITY}'."
