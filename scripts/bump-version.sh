#!/usr/bin/env bash
# Phase υ: single-source-of-truth version bump.
#
# Updates every version surface in lockstep:
#   - Sources/TranscriberCore/BuildInfo.swift  (BuildInfo.version)
#   - TranscriberApp/project.yml               (MARKETING_VERSION)
#   - TranscriberApp/project.yml               (CURRENT_PROJECT_VERSION, monotonic int)
#   - CHANGELOG.md                             (new header)
#
# Usage:
#   scripts/bump-version.sh <new-version>
#       e.g. scripts/bump-version.sh 1.0.0-rc1
#
# After running, regenerate the Xcode project:
#   cd TranscriberApp && xcodegen
# Then commit + tag.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <new-version>" >&2
    echo "  e.g. $0 1.0.0-rc1" >&2
    exit 64
fi
NEW_VERSION="$1"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Codex rc1-final P1.6: refuse to bump from a dirty worktree so a
# half-finished bump can't be tagged + released against a phantom
# state.
if [[ -n "$(git -C "${PROJECT_DIR}" status --porcelain)" ]]; then
    echo "Worktree has uncommitted changes. Commit or stash before bumping." >&2
    exit 65
fi

# Codex rc2-audit RELEASE-1: validate SemVer 2.0 BNF before injecting
# the value into Swift / YAML / file paths. Rejects shell metacharacters,
# quotes, and any string that doesn't match the canonical SemVer regex.
# Pattern: 1*DIGIT.1*DIGIT.1*DIGIT[-PRERELEASE][+BUILD]
# PRERELEASE = ALPHANUM[.ALPHANUM]*
# BUILD      = ALPHANUM[.ALPHANUM]*
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?(\+[0-9A-Za-z][0-9A-Za-z.-]*)?$'
if [[ ! "${NEW_VERSION}" =~ ${SEMVER_RE} ]]; then
    echo "Version '${NEW_VERSION}' is not valid SemVer 2.0." >&2
    echo "  Required: MAJOR.MINOR.PATCH[-prerelease][+build]" >&2
    echo "  Examples: 1.0.0, 1.0.0-rc1, 1.0.0+build42, 1.2.3-rc.1+build.42" >&2
    exit 64
fi

BUILD_INFO="${PROJECT_DIR}/Sources/TranscriberCore/BuildInfo.swift"
PROJECT_YML="${PROJECT_DIR}/TranscriberApp/project.yml"
CHANGELOG="${PROJECT_DIR}/CHANGELOG.md"

# Find current values for safety.
CURRENT_VERSION="$(grep -E 'public static let version' "${BUILD_INFO}" | sed -nE 's/.*"([^"]+)".*/\1/p')"
CURRENT_BUILD="$(grep -E 'CURRENT_PROJECT_VERSION:' "${PROJECT_YML}" | sed -nE 's/.*"([^"]+)".*/\1/p')"
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "==> Bumping ${CURRENT_VERSION} -> ${NEW_VERSION} (build ${CURRENT_BUILD} -> ${NEW_BUILD})"

# 1. BuildInfo.swift.
sed -i.bak -E "s/(public static let version = )\"[^\"]+\"/\1\"${NEW_VERSION}\"/" "${BUILD_INFO}"
rm "${BUILD_INFO}.bak"

# 2. project.yml MARKETING_VERSION.
sed -i.bak -E "s/(MARKETING_VERSION: )\"[^\"]+\"/\1\"${NEW_VERSION}\"/" "${PROJECT_YML}"
# 3. project.yml CURRENT_PROJECT_VERSION (monotonic int).
sed -i.bak -E "s/(CURRENT_PROJECT_VERSION: )\"[^\"]+\"/\1\"${NEW_BUILD}\"/" "${PROJECT_YML}"
rm "${PROJECT_YML}.bak"

# 4. CHANGELOG header.
TODAY="$(date -u +%Y-%m-%d)"
if [[ -f "${CHANGELOG}" ]]; then
    if ! grep -q "^## ${NEW_VERSION} - " "${CHANGELOG}"; then
        # Prepend a new section directly after the title.
        TMP="$(mktemp)"
        awk -v ver="${NEW_VERSION}" -v today="${TODAY}" '
            BEGIN { inserted = 0 }
            /^# / && !inserted {
                print
                print ""
                print "## " ver " - " today
                print ""
                print "- (fill in changes)"
                print ""
                inserted = 1
                next
            }
            { print }
        ' "${CHANGELOG}" > "${TMP}"
        mv "${TMP}" "${CHANGELOG}"
    fi
else
    cat > "${CHANGELOG}" <<EOF
# Changelog

## ${NEW_VERSION} - ${TODAY}

- (fill in changes)

EOF
fi

cat <<EOF

==> Bumped to ${NEW_VERSION}
   BuildInfo.version          = ${NEW_VERSION}
   MARKETING_VERSION          = ${NEW_VERSION}
   CURRENT_PROJECT_VERSION    = ${NEW_BUILD}
   CHANGELOG.md updated.

Next steps:
  cd TranscriberApp && xcodegen
  git add -A
  git commit -m "release: bump to ${NEW_VERSION}"
  git tag -s v${NEW_VERSION} -m 'Release ${NEW_VERSION}'
EOF
