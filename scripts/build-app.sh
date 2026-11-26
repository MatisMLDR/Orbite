#!/bin/zsh
# Build Orbite.app, install it in /Applications and relaunch it.
# Usage: scripts/build-app.sh [Debug|Release]   (INSTALL_DIR=... to install elsewhere)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
# xcode-select may point at the Command Line Tools, which have no xcodebuild.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodegen generate --quiet
LOG=build/xcodebuild.log
mkdir -p build
if ! xcodebuild -project Orbite.xcodeproj -scheme Orbite -configuration "$CONFIG" \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u
  echo "BUILD FAILED (log: $LOG)"
  exit 1
fi
grep -E "warning: .*Orbite/" "$LOG" | sort -u || true

APP="build/Build/Products/$CONFIG/Orbite.app"
codesign --verify --deep --strict "$APP"

pkill -x Orbite 2>/dev/null || true
# `open` fails (-600) while the previous instance is still quitting.
for _ in {1..50}; do pgrep -x Orbite >/dev/null || break; sleep 0.1; done

# Same signature at a stable path: the location grant and the helper approval carry over.
INSTALLED="${INSTALL_DIR:-/Applications}/Orbite.app"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
codesign --verify --deep --strict "$INSTALLED"
[[ "${NO_LAUNCH:-0}" == 1 ]] || open "$INSTALLED"
echo "→ $INSTALLED"
