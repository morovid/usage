#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Usage.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Usage" "$APP/Contents/MacOS/Usage"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
# Set SIGN_IDENTITY to a Developer ID identity for distributable builds.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
if [[ "${SIGN_IDENTITY:--}" == "-" ]]; then
  echo "Ad-hoc build: macOS may require fresh Keychain approval after rebuilding."
  echo "Use a stable Apple Development or Developer ID SIGN_IDENTITY to preserve trust across builds."
fi
echo "Built $APP"
