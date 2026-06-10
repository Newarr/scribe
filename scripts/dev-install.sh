#!/usr/bin/env bash
# Dev install: build (optional), copy to /Applications/, and sign with a
# stable code-signing identity so TCC grants and Keychain item ACLs
# persist across rebuilds.
#
# Without a stable code-signing identity, every rebuild of Scribe gets a
# new cdhash and macOS treats it as a different app — Screen Recording,
# Microphone, etc. grants vanish even though the toggle in System Settings
# stays on, and the ElevenLabs key in Keychain becomes unreadable (the
# item ACL stores the app's designated requirement, which an ad-hoc
# signature can never satisfy twice). Signing with the login-keychain
# Apple Development certificate solves both: TCC and Keychain key off
# the cert leaf / team, not the cdhash.
#
# Identity resolution: $SCRIBE_DEV_IDENTITY if set, else the first
# "Apple Development" identity in the default keychain search list,
# else ad-hoc with a loud warning (cloud-key reads will break).
#
# Usage:
#   scripts/dev-install.sh                  # signs /Applications/Scribe.app in place
#   scripts/dev-install.sh path/to/Scribe.app
#       e.g. scripts/dev-install.sh build/Debug/Scribe.app
#   scripts/dev-install.sh --build          # xcodebuild Debug, then install + sign

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

IDENTITY="${SCRIBE_DEV_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
if [[ -z "${IDENTITY}" ]]; then
    echo "WARNING: no Apple Development identity found; falling back to ad-hoc signing." >&2
    echo "TCC grants and the ElevenLabs Keychain item will NOT survive this install." >&2
    IDENTITY="-"
fi

if [[ ! -f "${ENTITLEMENTS}" ]]; then
    echo "Entitlements missing: ${ENTITLEMENTS}" >&2
    exit 1
fi

SOURCE=""
BUILD_DIR=""
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
                CODE_SIGNING_ALLOWED=NO \
                CODE_SIGNING_REQUIRED=NO \
                CODE_SIGN_IDENTITY= \
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
    if [[ -n "${BUILD_DIR}" ]]; then
        rm -rf "${BUILD_DIR}"
    fi
fi

echo "==> Building dev entitlements (library validation disabled)"
# Self-signed certs have no Team ID. With library validation enabled
# (the production entitlement), macOS refuses to load the bundle's
# own dylibs because their NULL Team ID doesn't match the main
# binary's NULL Team ID. Dev signing flips this one bit; release.sh
# uses the unmodified TranscriberApp/Scribe/Scribe.entitlements.
make_temp_dev_entitlements

echo "==> Signing ${TARGET} with identity: ${IDENTITY}"
# Interrupted codesign runs can leave .cstemp files in the app bundle; remove
# only those codesign-owned temp files before resealing so verification stays
# deterministic across repeated dev-install/smoke attempts.
find "${TARGET}" -name '*.cstemp' -type f -delete
# Sign nested code first (Xcode's Debug product ships preview/debug dylibs in
# Contents/MacOS and Contents/Frameworks); signing the bundle does not re-sign
# nested Mach-O files, and the bundle seal requires them to carry the same
# identity. The earlier self-signed "Scribe Dev Signer" cert hung here because
# its private key lived in a locked custom keychain; the login-keychain Apple
# Development identity signs the same dylibs in seconds.
find "${TARGET}/Contents/Frameworks" "${TARGET}/Contents/MacOS" \
    -name '*.dylib' -type f 2>/dev/null | while read -r dylib; do
    codesign --force --sign "${IDENTITY}" --timestamp=none "${dylib}"
done
codesign --force \
    --sign "${IDENTITY}" \
    --timestamp=none \
    --entitlements "${DEV_ENTITLEMENTS}" \
    "${TARGET}"

echo "==> Verifying signature"
codesign --verify --verbose=2 "${TARGET}"

echo "==> Verifying entitlements include audio-input and calendars"
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - "${TARGET}" 2>/dev/null)"
if ! grep -q "com.apple.security.device.audio-input" <<<"${SIGNED_ENTITLEMENTS}"; then
    echo "WARNING: audio-input entitlement missing from signed app." >&2
    exit 1
fi
if ! grep -q "com.apple.security.personal-information.calendars" <<<"${SIGNED_ENTITLEMENTS}"; then
    echo "WARNING: calendars entitlement missing from signed app." >&2
    exit 1
fi

echo
echo "Done. Local Debug app installed and signed with '${IDENTITY}'."
if [[ "${IDENTITY}" == "-" ]]; then
    echo "Ad-hoc fallback was used: TCC grants and the ElevenLabs Keychain ACL"
    echo "will not match this build. Install an Apple Development identity and re-run."
fi
