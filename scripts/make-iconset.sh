#!/bin/bash
#
# make-iconset.sh — regenerate the AppIcon asset catalog from make-icon.swift.
# Each size is re-rendered (not downscaled), so small icons stay crisp.
#
set -euo pipefail
cd "$(dirname "$0")/.."
SET="Sources/Cryoframe/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"

gen() { swift scripts/make-icon.swift "$1" "$SET/$2" >/dev/null; }
gen 16   icon_16.png
gen 32   icon_16@2x.png
gen 32   icon_32.png
gen 64   icon_32@2x.png
gen 128  icon_128.png
gen 256  icon_128@2x.png
gen 256  icon_256.png
gen 512  icon_256@2x.png
gen 512  icon_512.png
gen 1024 icon_512@2x.png
echo "iconset regenerated in $SET"
