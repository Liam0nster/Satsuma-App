#!/bin/bash
# Builds build/Satsuma.app from the Swift package (run this on a Mac with Xcode or the Command Line Tools).
#
# Optional environment variables:
#   SIGN_ID   code-signing identity (default "-" = ad-hoc). With ad-hoc signing macOS forgets the Input Monitoring /
#             Accessibility grants after every rebuild; a stable identity keeps them. List yours with:
#               security find-identity -v -p codesigning
#             or create a free self-signed one in Keychain Access > Certificate Assistant > Create a Certificate
#             (type "Code Signing"), then:  SIGN_ID="My Cert Name" ./Scripts/build_app.sh
#   FFMPEG / FFPROBE / GS   paths of binaries to bundle into the app, e.g.
#               FFMPEG=$(which ffmpeg) FFPROBE=$(which ffprobe) ./Scripts/build_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ID="${SIGN_ID:--}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="build/Satsuma.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/Satsuma" "$APP/Contents/MacOS/Satsuma"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: prefer building from the iconset with Apple's iconutil; fall back to the prebuilt .icns.
if command -v iconutil >/dev/null 2>&1 && iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  :
else
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Copies one tool into the bundle and signs it (the hardened runtime requires every executable to be signed).
bundle_tool() {
  local path="$1"
  if [ ! -x "$path" ]; then
    echo "Skipping $path (not an executable file)"
    return
  fi
  # otool -L lists the shared libraries a binary needs; anything outside /usr/lib and /System won't exist on a Mac
  # that lacks Homebrew, so a Homebrew-built ffmpeg copied on its own usually will not run elsewhere.
  local extra
  extra="$(otool -L "$path" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/)' || true)"
  if [ -n "$extra" ]; then
    echo "WARNING: $path depends on non-system libraries:"
    echo "$extra" | sed 's/^/    /'
    echo "         It will only work on Macs that have those libraries. Use a statically linked build to be self-contained."
  fi
  cp "$path" "$APP/Contents/Resources/bin/"
  codesign --force --options runtime --sign "$SIGN_ID" "$APP/Contents/Resources/bin/$(basename "$path")"
  echo "Bundled $(basename "$path")"
}

[ -n "${FFMPEG:-}" ]  && bundle_tool "$FFMPEG"
[ -n "${FFPROBE:-}" ] && bundle_tool "$FFPROBE"
[ -n "${GS:-}" ]      && bundle_tool "$GS"

# Hardened runtime blocks DYLD_* library injection and unsigned code. No --deep: nested tools were signed above.
codesign --force --options runtime --entitlements Resources/Satsuma.entitlements --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Built $APP (signed with: $SIGN_ID)"
