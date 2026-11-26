#!/bin/zsh
# Screenshots for the README, from the Debug build's demo mode (made-up traffic, see Orbite/Demo/DemoMode.swift).
# Each scene is a fresh launch: nothing is clicked or typed. The terminal needs the Screen Recording permission.
# Usage: scripts/screenshots.sh [scene-name ...]   → build/screenshots/<name>.png
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT=build/screenshots
mkdir -p "$OUT" build

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  xcodegen generate --quiet
  xcodebuild -project Orbite.xcodeproj -scheme Orbite -configuration Debug -derivedDataPath build \
    -destination 'platform=macOS,arch=arm64' build > build/screenshots-build.log 2>&1 || { echo "BUILD FAILED"; exit 1; }
fi
APP="$PWD/build/Build/Products/Debug/Orbite.app"
swiftc -O -o build/window-id scripts/window-id.swift 2>/dev/null

# name | ORBITE_DEMO_SCENE | launch arguments
SCENES=(
  "globe|globe|-mapLook globe -globeDayNight YES"
  "app|app:Safari|-mapLook globe -globeDayNight YES"
  "tracker|host:doubleclick.net|-mapLook globe -globeDayNight YES"
  "place|site:Mumbai|-mapLook globe -globeDayNight YES"
  "recap|recap|-mapLook globe -globeDayNight YES"
  "diagnosis|diagnosis|-mapLook globe -globeDayNight YES"
  "search|search|-mapLook globe -globeDayNight YES"
)

for entry in "${SCENES[@]}"; do
  IFS='|' read -r name scene args <<< "$entry"
  if (( $# > 0 )) && [[ " $* " != *" $name "* ]]; then continue; fi
  open -n "$APP" --env ORBITE_DEMO=1 --env ORBITE_DEMO_SCENE="$scene" --env ORBITE_DEMO_WINDOW=1440x900 \
    --env ORBITE_DEMO_APPEARANCE=dark --args -AppleLanguages '(en)' -AppleLocale en_US ${=args}
  sleep 2
  pid=$(pgrep -n -f "$APP/Contents/MacOS/Orbite")
  sleep "${WAIT:-9}"   # map tiles, the globe texture and a few seconds of live comets
  if id=$(build/window-id "$pid"); then
    screencapture -o -x -l"$id" "$OUT/$name.png"
    width=$(sips -g pixelWidth "$OUT/$name.png" | awk '/pixelWidth/ {print $2}')
    # A small image is a Stage Manager thumbnail: the window was not in front.
    if (( width < 2000 )); then echo "!! $name: window not in front ($width px)"; else echo "→ $OUT/$name.png"; fi
  else
    echo "no window for $name"
  fi
  kill "$pid" 2>/dev/null || true
  for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
done
