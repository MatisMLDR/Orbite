#!/bin/zsh
# Builds Orbite for release: a universal app signed with Developer ID, notarized and stapled, in a disk image
# that is itself signed, notarized and stapled. Output: build/release/Orbite.dmg.
#
# Needs a Developer ID Application certificate, XcodeGen, uv (for dmgbuild) and notarytool credentials stored
# in the keychain: xcrun notarytool store-credentials <profile>.
# Usage: scripts/release.sh   (NOTARY_PROFILE=notary and SIGN_IDENTITY="Developer ID Application" by default;
#        NOTARIZE=0 builds and checks everything but skips Apple's notary service)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROFILE="${NOTARY_PROFILE:-notary}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
OUT=build/release
APP="$OUT/Orbite.app"
DMG="$OUT/Orbite.dmg"

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo "→ $*"; }

rm -rf "$OUT"
mkdir -p "$OUT"

step "Archiving Orbite $VERSION (universal, Release)"
xcodegen generate --quiet
if ! xcodebuild archive -project Orbite.xcodeproj -scheme Orbite -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$OUT/Orbite.xcarchive" > "$OUT/archive.log" 2>&1; then
  grep -E "error:" "$OUT/archive.log" | sort -u
  fail "archive failed (log: $OUT/archive.log)"
fi
ditto "$OUT/Orbite.xcarchive/Products/Applications/Orbite.app" "$APP"

step "Checking signatures"
codesign --verify --deep --strict "$APP" || fail "the app's signature does not verify"
for code in "$APP" "$APP/Contents/MacOS/OrbiteHelper" "$APP/Contents/PlugIns/OrbiteWidget.appex"; do
  info=$(codesign -dv --verbose=4 "$code" 2>&1)
  grep -q "^Authority=Developer ID Application" <<< "$info" || fail "$code is not signed with a Developer ID"
  grep -q "flags=0x10000(runtime)" <<< "$info" || fail "$code lacks the hardened runtime"
  grep -q "^Timestamp=" <<< "$info" || fail "$code has no secure timestamp"
  if codesign -d --entitlements - --xml "$code" 2>/dev/null | grep -q "get-task-allow"; then
    fail "$code carries get-task-allow"
  fi
done
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/Orbite")"

# Submits a file to Apple's notary service and waits; prints the log when it is refused.
notarize() {
  if [[ "${NOTARIZE:-1}" == 0 ]]; then echo "  skipped (NOTARIZE=0)"; return; fi
  local result="$OUT/notary-$(basename "$1").json"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$result"
  local notary_status=$(plutil -extract status raw -o - "$result")
  if [[ "$notary_status" != "Accepted" ]]; then
    xcrun notarytool log "$(plutil -extract id raw -o - "$result")" --keychain-profile "$PROFILE" || true
    fail "notarization of $(basename "$1"): $notary_status"
  fi
  echo "  accepted"
}

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/Orbite.zip"
notarize "$OUT/Orbite.zip"
[[ "${NOTARIZE:-1}" == 0 ]] || xcrun stapler staple -q "$APP"

step "Building the disk image"
uvx --quiet dmgbuild -s scripts/dmg/settings.py -D app="$APP" "Orbite $VERSION" "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the disk image"
notarize "$DMG"
if [[ "${NOTARIZE:-1}" == 0 ]]; then echo "✓ $DMG (not notarized)"; exit 0; fi
xcrun stapler staple -q "$DMG"

step "Verifying"
xcrun stapler validate -q "$DMG" || fail "no ticket stapled to the disk image"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
mount=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$DMG" > /dev/null
spctl -a -vv "$mount/Orbite.app" 2>&1 | sed 's/^/  /'
hdiutil detach -quiet "$mount"
echo "  sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "✓ $DMG"
