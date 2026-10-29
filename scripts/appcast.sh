#!/bin/bash
#
# appcast.sh — sign a release DMG with the Sparkle Ed25519 key and add an <item>
# to appcast.xml so the build can offer it as an in-app update.
#
# Run after make-dmg.sh, before pushing the appcast + cutting the gh release:
#   ./scripts/appcast.sh 1.0.0 dist/Cryoframe-1.0.0.dmg "Release notes one-liner"
# To fetch and check Sparkle's tools only, signing nothing:
#   ./scripts/appcast.sh --fetch-tools
#
# The private key lives in your login keychain (created once with Sparkle's
# generate_keys). The matching public key is embedded in the app (project.yml).
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != "--fetch-tools" ]; then
  VERSION="${1:?usage: appcast.sh <version> <dmg> [notes]}"
  DMG="${2:?usage: appcast.sh <version> <dmg> [notes]}"
  NOTES="${3:-Cryoframe $VERSION}"
fi

SPARKLE_VER="2.9.3"
# SHA-256 of Sparkle-$SPARKLE_VER.tar.xz, as GitHub lists it for the release asset.
# Change the two together.
SPARKLE_SHA256="74a07da821f92b79310009954c0e15f350173374a3abe39095b4fc5096916be6"
# sign_update reads the update-signing key from the login keychain, so it is kept,
# and run, only where no one else can write: never /tmp, where any local user can
# create the folder first and have their own program run with that key.
CACHE="${CRYOFRAME_RELEASE_CACHE:-$HOME/Library/Caches/Cryoframe-release}"
SPARKLE_DIR="$CACHE/sparkle-$SPARKLE_VER"
TOOLS="$SPARKLE_DIR/bin"

# true when the path is owned by you and neither group nor others can write to it
private_to_me() {
  local owner mode
  read -r owner mode < <(stat -f '%u %Lp' "$1")
  [ "$owner" = "$(id -u)" ] && [ $(( 8#$mode & 8#022 )) -eq 0 ]
}

FETCH_WORK=""
fetch_sparkle() {
  echo "== fetching Sparkle $SPARKLE_VER tools =="
  mkdir -p "$CACHE" && chmod 700 "$CACHE"
  private_to_me "$CACHE" || { echo "$CACHE isn't private to you; refusing to keep the signing tool there"; exit 1; }
  FETCH_WORK=$(mktemp -d "$CACHE/fetch.XXXXXX")
  trap 'rm -rf "$FETCH_WORK"' EXIT
  curl -fsSL -o "$FETCH_WORK/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VER/Sparkle-$SPARKLE_VER.tar.xz"
  local got
  got=$(shasum -a 256 "$FETCH_WORK/sparkle.tar.xz" | awk '{print $1}')
  if [ "$got" != "$SPARKLE_SHA256" ]; then
    echo "the Sparkle $SPARKLE_VER download has SHA-256 $got, not $SPARKLE_SHA256; refusing it"
    exit 1
  fi
  mkdir "$FETCH_WORK/tools"
  tar -xJf "$FETCH_WORK/sparkle.tar.xz" -C "$FETCH_WORK/tools"
  rm -rf "$SPARKLE_DIR"
  mv "$FETCH_WORK/tools" "$SPARKLE_DIR"
}

[ -x "$TOOLS/sign_update" ] || fetch_sparkle
for p in "$CACHE" "$SPARKLE_DIR" "$TOOLS" "$TOOLS/sign_update"; do
  private_to_me "$p" || { echo "$p isn't private to you (owner or permissions); refusing to run the signing tool from it"; exit 1; }
done
if [ "${1:-}" = "--fetch-tools" ]; then
  echo "== Sparkle $SPARKLE_VER tools checked, in $TOOLS =="
  exit 0
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
