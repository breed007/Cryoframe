#!/bin/bash
#
# build-and-install.sh — signed Release build of Cryoframe + install to /Applications.
#
# SMAppService registers a root LaunchDaemon, which expects the app in a stable,
# signed location. /Applications is that location. Notarization is M8 — not needed
# for local registration.
#
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== regenerating project =="
xcodegen generate >/dev/null

echo "== signed Release build (Developer ID) =="
rm -rf build
xcodebuild build -scheme Cryoframe -configuration Release -derivedDataPath build \
  -destination 'platform=macOS' -quiet

APP="build/Build/Products/Release/Cryoframe.app"
./scripts/sign-sparkle.sh "$APP"
echo "== verifying signature + embedded helper =="
codesign --verify --deep --strict "$APP"
codesign -v -R='identifier "app.cryoframe.helper" and anchor apple generic and certificate leaf[subject.OU] = "YA83Q8FTH3"' \
  "$APP/Contents/MacOS/CryoframeHelper"
echo "  signature + helper requirement OK"

DEST="/Applications/Cryoframe.app"
echo "== installing to $DEST =="
# re-installing? click Unregister in the running app first so the old daemon
# registration is cleared before the binary is replaced.
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo
echo "installed: $DEST"
echo "next: open it, click Register, approve in System Settings ▸ General ▸ Login Items,"
echo "      grant Full Disk Access to Cryoframe, then Run snapshot test. See docs/M1-install.md"
