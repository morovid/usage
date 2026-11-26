#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

if (( $# != 1 )) || [[ ! "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Usage: zsh scripts/release.sh 1.2.3" >&2
  exit 1
fi
VERSION="$1"
PROFILE="${NOTARY_PROFILE:-usage-notary}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Morovid s.r.o. (R973J5PQW7)}"
if [[ "$IDENTITY" == "-" ]]; then
  echo "Releases require a Developer ID Application signing identity." >&2
  exit 1
fi
DMG="$ROOT/dist/Usage-$VERSION.dmg"
if [[ -e "$DMG" || -e "$DMG.sha256" ]]; then
  echo "Release output already exists: $DMG. Move it aside before rebuilding." >&2
  exit 1
fi

# Check credentials before building. Configure this profile once; no secrets in scripts.
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null
SIGN_IDENTITY="$IDENTITY" zsh "$ROOT/scripts/build-app.sh" "$VERSION"
APP="$ROOT/dist/Usage.app"
WORK="$(mktemp -d "$ROOT/dist/.release.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

notarize() {
  local artifact="$1" result="$2"
  xcrun notarytool submit "$artifact" --keychain-profile "$PROFILE" --wait --output-format json > "$result"
  local outcome
  outcome="$(plutil -extract status raw -o - "$result")"
  if [[ "$outcome" != "Accepted" ]]; then
    echo "Notarization was not accepted. Submission details: $result" >&2
    cat "$result" >&2
    return 1
  fi
}

# Staple the app itself so it remains verifiable after copying out of the image.
ditto -c -k --keepParent "$APP" "$WORK/Usage.zip"
notarize "$WORK/Usage.zip" "$ROOT/dist/notary-app-$VERSION.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

mkdir "$WORK/image"
ditto "$APP" "$WORK/image/Usage.app"
ln -s /Applications "$WORK/image/Applications"
hdiutil create -volname "Usage $VERSION" -srcfolder "$WORK/image" \
  -format UDZO "$WORK/Usage-$VERSION.dmg"
codesign --force --timestamp --sign "$IDENTITY" "$WORK/Usage-$VERSION.dmg"
notarize "$WORK/Usage-$VERSION.dmg" "$ROOT/dist/notary-dmg-$VERSION.json"
xcrun stapler staple "$WORK/Usage-$VERSION.dmg"
xcrun stapler validate "$WORK/Usage-$VERSION.dmg"
codesign --verify --verbose=2 "$WORK/Usage-$VERSION.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$WORK/Usage-$VERSION.dmg"
mv "$WORK/Usage-$VERSION.dmg" "$DMG"
(cd "$ROOT/dist" && shasum -a 256 "Usage-$VERSION.dmg" > "Usage-$VERSION.dmg.sha256")
echo "Release ready: $DMG"
