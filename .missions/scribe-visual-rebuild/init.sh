#!/usr/bin/env bash
set -euo pipefail

REPO=/Users/szymonsypniewicz/Documents/code/scribe
cd "$REPO"

echo "[init] verifying Xcode + Swift toolchain"
xcodebuild -version >/dev/null
swift --version >/dev/null

echo "[init] resolving Swift packages"
swift package resolve --package-path "$REPO" >/dev/null

echo "[init] design references present?"
test -d "$REPO/.missions/scribe-visual-rebuild/design-reference" || {
  echo "ERROR: design-reference/ missing under mission dir" >&2
  exit 1
}

echo "[init] fonts bundled?"
test -f "$REPO/TranscriberApp/Scribe/Fonts/InterVariable.ttf" || {
  echo "ERROR: InterVariable.ttf missing under TranscriberApp/Scribe/Fonts/" >&2
  exit 1
}

echo "[init] ok"
