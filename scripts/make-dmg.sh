#!/bin/bash
#
# make-dmg.sh — wrap the notarized app in a distribution DMG, then notarize and
# staple the DMG itself so the download passes Gatekeeper with no warnings.
#
# run ./scripts/notarize.sh first (it builds + signs + notarizes + staples the app).
#
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-cryoframe-notary}"

APP="build/Build/Products/Release/Cryoframe.app"
[ -d "$APP" ] || { echo "No notarized app at $APP — run ./scripts/notarize.sh first."; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="dist/Cryoframe-$VERSION.dmg"
mkdir -p dist
rm -f "$DMG"

echo "== staging =="
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"          # drag-to-install target

echo "== building dmg =="
hdiutil create -volname "Cryoframe $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

echo "== notarizing dmg =="
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "release dmg: $DMG"
shasum -a 256 "$DMG"
