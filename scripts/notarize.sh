#!/bin/bash
#
# notarize.sh — signed Release build, notarize, and staple.
#
# one-time credential setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials cryoframe-notary \
#       --apple-id you@example.com --team-id YA83Q8FTH3 --password <app-specific-password>
#
# then:  ./scripts/notarize.sh
# override the profile name with NOTARY_PROFILE=...
#
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-cryoframe-notary}"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notary credentials stored under profile '$PROFILE'."
  echo "Set them up once (app-specific password from appleid.apple.com):"
  echo "  xcrun notarytool store-credentials $PROFILE \\"
  echo "      --apple-id <your-apple-id> --team-id YA83Q8FTH3 --password <app-specific-password>"
  exit 1
fi

echo "== signed Release build =="
xcodegen generate >/dev/null
rm -rf build
xcodebuild build -scheme Cryoframe -configuration Release -derivedDataPath build \
  -destination 'platform=macOS' -quiet

APP="build/Build/Products/Release/Cryoframe.app"
./scripts/sign-sparkle.sh "$APP"
codesign --verify --deep --strict "$APP"
echo "  signed OK"

ZIP="build/Cryoframe.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== submitting to Apple notary (waits for result) =="
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "== stapling =="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo
echo "notarized + stapled: $APP"
echo "ship the .app (or wrap it in a DMG) — Gatekeeper will accept it on any Mac."
