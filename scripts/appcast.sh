#!/bin/bash
#
# appcast.sh — sign a release DMG with the Sparkle Ed25519 key and add an <item>
# to appcast.xml so the build can offer it as an in-app update.
#
# Run after make-dmg.sh, before pushing the appcast + cutting the gh release:
#   ./scripts/appcast.sh 1.0.0 dist/Cryoframe-1.0.0.dmg "Release notes one-liner"
#
# The private key lives in your login keychain (created once with Sparkle's
# generate_keys). The matching public key is embedded in the app (project.yml).
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: appcast.sh <version> <dmg> [notes]}"
DMG="${2:?usage: appcast.sh <version> <dmg> [notes]}"
NOTES="${3:-Cryoframe $VERSION}"
SPARKLE_VER="2.9.3"
TOOLS="/tmp/sparkle-tools-$SPARKLE_VER/bin"

if [ ! -x "$TOOLS/sign_update" ]; then
  echo "== fetching Sparkle $SPARKLE_VER tools =="
  mkdir -p "$TOOLS/.."
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VER/Sparkle-$SPARKLE_VER.tar.xz" \
    | tar -xJ -C "$TOOLS/.."
fi

[ -f "$DMG" ] || { echo "no DMG at $DMG"; exit 1; }

# Read the build number out of the app INSIDE the DMG. Sparkle compares the feed's
# <sparkle:version> against the installed app's CFBundleVersion (the build number,
# stamped YYYYMMDD.HHMM), NOT the marketing string — so the item must carry the
# build number, or Sparkle thinks the installed build is newer and never updates.
# Reading it from the DMG makes drift impossible.
echo "== reading version from the DMG =="
MNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
APP_IN_DMG=$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_IN_DMG/Contents/Info.plist")
SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_IN_DMG/Contents/Info.plist")
hdiutil detach "$MNT" >/dev/null; rmdir "$MNT" 2>/dev/null || true
[ -n "$BUILD" ] || { echo "couldn't read CFBundleVersion from the DMG"; exit 1; }
if [ "$SHORT" != "$VERSION" ]; then
  echo "warning: DMG marketing version ($SHORT) != argument ($VERSION) — using $SHORT for the label"
fi
echo "  marketing $SHORT · build $BUILD"

# sign_update prints e.g.  sparkle:edSignature="…" length="12345"
SIG_LINE=$("$TOOLS/sign_update" "$DMG")
URL="https://github.com/breed007/Cryoframe/releases/download/v$SHORT/$(basename "$DMG")"
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
ITEM=$(cat <<XML
    <item>
      <title>$SHORT</title>
      <description><![CDATA[$NOTES]]></description>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIG_LINE />
    </item>
XML
)

# insert the new item right after <channel>'s metadata (before the first existing
# <item>, or before </channel>) so newest is first.
python3 - "$ITEM" <<'PY'
import sys, re
item = sys.argv[1]
path = "appcast.xml"
xml = open(path).read()
marker = "</language>"
if marker in xml:
    xml = xml.replace(marker, marker + "\n" + item, 1)
else:
    xml = xml.replace("</channel>", item + "\n  </channel>", 1)
open(path, "w").write(xml)
print("appcast.xml updated for", item.split("<title>")[1].split("</title>")[0].strip())
PY

echo "== signed and appended. Commit appcast.xml, push, then create the gh release with the DMG. =="
