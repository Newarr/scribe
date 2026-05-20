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
DEV_ENTITLEMENTS=""

cleanup_dev_entitlements() {
    if [[ -n "${DEV_ENTITLEMENTS}" ]]; then
        rm -f "${DEV_ENTITLEMENTS}" "${DEV_ENTITLEMENTS%.plist}"
    fi
}

canonical_app_path() {
    local path="$1"
    if [[ ! -d "${path}" ]]; then
        echo "App path not found: ${path}" >&2
        return 1
    fi
    (cd "${path}" && pwd -P)
}

assert_distinct_source_and_target() {
    local source="$1"
    local target="$2"
    local canonical_source canonical_target
    canonical_source="$(canonical_app_path "${source}")"
    if [[ -d "${target}" ]]; then
        canonical_target="$(canonical_app_path "${target}")"
    else
        local parent base
        parent="$(dirname "${target}")"
        base="$(basename "${target}")"
        if [[ ! -d "${parent}" ]]; then
            echo "Install target parent does not exist: ${parent}" >&2
            return 1
        fi
        canonical_target="$(cd "${parent}" && pwd -P)/${base}"
    fi

    if [[ "${canonical_source}" == "${canonical_target}" ]]; then
        echo "Refusing to install ${source}: source and target both resolve to ${target}." >&2
        echo "Build a fresh app elsewhere or run without a source path to sign the installed app in place." >&2
        return 1
    fi
}

build_dev_entitlements() {
    local production_entitlements="$1"
    local output_entitlements="$2"
    if [[ ! -f "${production_entitlements}" ]]; then
        echo "Production entitlements missing: ${production_entitlements}" >&2
        return 1
    fi

    cp "${production_entitlements}" "${output_entitlements}"
    /usr/libexec/PlistBuddy \
        -c "Set :com.apple.security.cs.disable-library-validation true" \
        "${output_entitlements}" >/dev/null
    plutil -lint "${output_entitlements}" >/dev/null
}

make_temp_dev_entitlements() {
    local template
    template="$(mktemp -t scribe-dev-ents)"
    DEV_ENTITLEMENTS="${template}.plist"
    rm -f "${template}"
    build_dev_entitlements "${ENTITLEMENTS}" "${DEV_ENTITLEMENTS}"
}

if [[ "${1:-}" == "--make-dev-entitlements" ]]; then
    if [[ $# -ne 3 ]]; then
        echo "Usage: $0 --make-dev-entitlements production.entitlements output.plist" >&2
        exit 64
    fi
    build_dev_entitlements "$2" "$3"
    exit 0
fi

if [[ "${1:-}" == "--assert-distinct-apps" ]]; then
    if [[ $# -ne 3 ]]; then
        echo "Usage: $0 --assert-distinct-apps source.app target.app" >&2
        exit 64
    fi
    assert_distinct_source_and_target "$2" "$3"
    exit 0
fi

trap cleanup_dev_entitlements EXIT

if [[ -n "${SCRIBE_DEV_INSTALL_TEST_EXIT_AFTER_ENTITLEMENTS:-}" ]]; then
    echo "==> Building dev entitlements (library validation disabled)"
    make_temp_dev_entitlements
    case "${SCRIBE_DEV_INSTALL_TEST_EXIT_AFTER_ENTITLEMENTS}" in
        success)
            exit 0
            ;;
        failure)
            echo "Forced failure after dev entitlement generation" >&2
            exit 42
            ;;
        *)
            echo "Unknown SCRIBE_DEV_INSTALL_TEST_EXIT_AFTER_ENTITLEMENTS value: ${SCRIBE_DEV_INSTALL_TEST_EXIT_AFTER_ENTITLEMENTS}" >&2
            exit 64
            ;;
    esac
fi

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
    assert_distinct_source_and_target "${SOURCE}" "${TARGET}"
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
make_temp_dev_entitlements

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
