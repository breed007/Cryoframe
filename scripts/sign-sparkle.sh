#!/bin/bash
#
# sign-sparkle.sh — re-sign Sparkle's nested helpers with our Developer ID, the
# hardened runtime, and a secure timestamp, then reseal the framework and the app.
# Xcode does not sign the deeply-nested Updater.app / Autoupdate / XPC services
# inside Sparkle.framework, so notarization rejects them ("not signed with a valid
# Developer ID … no secure timestamp"). This fixes that.
#
#   usage: ./scripts/sign-sparkle.sh <app-path>
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: sign-sparkle.sh <app>}"
ID="Developer ID Application: Brian Reed (YA83Q8FTH3)"
ENT="Sources/Cryoframe/Cryoframe.entitlements"
FW="$APP/Contents/Frameworks/Sparkle.framework"
V="$FW/Versions/B"
FLAGS=(--force --options runtime --timestamp)

[ -d "$FW" ] || { echo "  no Sparkle.framework — nothing to re-sign"; exit 0; }

echo "== re-signing Sparkle helpers =="
for x in "$V/XPCServices/"*.xpc; do
  [ -e "$x" ] && codesign "${FLAGS[@]}" --preserve-metadata=entitlements --sign "$ID" "$x"
done
[ -e "$V/Autoupdate" ]   && codesign "${FLAGS[@]}" --sign "$ID" "$V/Autoupdate"
[ -d "$V/Updater.app" ]  && codesign "${FLAGS[@]}" --sign "$ID" "$V/Updater.app"
codesign "${FLAGS[@]}" --sign "$ID" "$FW"
# reseal the app (NOT --deep, so the helper keeps its own signature) so it records
# the re-signed framework; preserve the app's entitlements.
codesign "${FLAGS[@]}" --entitlements "$ENT" --sign "$ID" "$APP"
echo "  done"
