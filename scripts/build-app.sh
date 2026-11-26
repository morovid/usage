#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
if (( $# > 1 )); then
  echo "Usage: zsh scripts/build-app.sh [version]" >&2
  exit 1
fi
VERSION="${1:-}"
if [[ -n "$VERSION" && ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Version must have the format 1.2.3." >&2
  exit 1
fi
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Usage.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Usage" "$APP/Contents/MacOS/Usage"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
fi
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# A stable identity keeps the code requirement identical across builds, so Keychain approvals persist.
# Override with SIGN_IDENTITY=- for an ad-hoc build.
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Morovid s.r.o. (R973J5PQW7)}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
  echo "Ad-hoc build: macOS will require fresh Keychain approval after rebuilding."
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  codesign -dr - "$APP" 2>&1 | grep designated
fi
# Rebuilding in place can leave Finder/Launch Services showing an old generic
# icon. Refresh this bundle only; do not reset global caches or restart the Dock.
touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP" || echo "Could not refresh app registration; reopen the app to refresh its icon." >&2
fi
echo "Built $APP"
