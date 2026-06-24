#!/bin/bash
#
# derisk-split-read.sh — M1 de-risk gate.
#
# proves the assumption M0 did NOT test: the real architecture splits the mount
# (root helper) from the read (user GUI with FDA). M0 had root do both.
#
# also exercises the snapshot CREATE backend. two backends:
#   BACKEND=tmutil      (default) tmutil localsnapshot + mount_apfs — works as
#                       root with NO entitlement. the shippable path.
#   BACKEND=fssnapshot  raw fs_snapshot_* via fs_snapshot_spike — requires the
#                       Apple-restricted com.apple.developer.vfs.snapshot
#                       entitlement; as plain root it returns EPERM (proven).
#
# run AS THE NORMAL USER (do NOT sudo). it sudo's the privileged steps itself
# and reads the library in the unprivileged user context.
#
#   ./derisk-split-read.sh                 # tmutil backend
#   BACKEND=fssnapshot ./derisk-split-read.sh
#
set -euo pipefail
cd "$(dirname "$0")"

BACKEND="${BACKEND:-tmutil}"
MNT_BASE="/private/var/run/app.cryoframe/mnt"

c_blue=$'\033[34m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
log(){ printf '%s[derisk]%s %s\n' "$c_blue" "$c_rst" "$*"; }
ok(){  printf '%s[  ok  ]%s %s\n' "$c_grn" "$c_rst" "$*"; }
err(){ printf '%s[ fail ]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
step(){ printf '\n%s== %s ==%s\n' "$c_blue" "$*" "$c_rst"; }

if [[ "$(id -u)" -eq 0 ]]; then
  err "do NOT run with sudo — running as root would invalidate the split-read test."
  exit 1
fi
USER_NAME="$(id -un)"
LIB_REL="Users/${USER_NAME}/Pictures/Photos Library.photoslibrary"
log "backend: $BACKEND   reader: $USER_NAME (uid $(id -u))"

SNAP=""; MNT=""; SNAP_DATE=""

create_and_mount() {
  local ts; ts="$(date +%s)"
  MNT="${MNT_BASE}/${ts}"
  if [[ "$BACKEND" == "fssnapshot" ]]; then
    clang -O2 -Wall -o fs_snapshot_spike fs_snapshot_spike.c
    local out; out="$(sudo ./fs_snapshot_spike create)"; echo "$out"
    SNAP="$(printf '%s\n' "$out" | sed -n 's/^SNAP=//p')"
    MNT="$(printf '%s\n'  "$out" | sed -n 's/^MOUNTPOINT=//p')"
  else
    # tmutil backend: identify OUR snapshot by set-diff, like M0.
    local before after dev
    before="$(tmutil listlocalsnapshots / 2>/dev/null | sort)"
    sudo tmutil localsnapshot / >/dev/null
    after="$(tmutil listlocalsnapshots / 2>/dev/null | sort)"
    SNAP="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '^com.apple.TimeMachine' | tail -1)"
    [[ -n "$SNAP" ]] || SNAP="$(printf '%s\n' "$after" | grep '^com.apple.TimeMachine' | tail -1)"
    SNAP_DATE="${SNAP#com.apple.TimeMachine.}"; SNAP_DATE="${SNAP_DATE%.local}"
    dev="$(diskutil info /System/Volumes/Data | awk -F': *' '/Device Node/{print $2}' | tr -d ' ')"
    sudo mkdir -p "$MNT" && sudo chmod 755 "$(dirname "$(dirname "$MNT")")" "$(dirname "$MNT")" "$MNT" 2>/dev/null || true
    sudo mount_apfs -o rdonly -s "$SNAP" "$dev" "$MNT"
  fi
  [[ -n "$SNAP" && -n "$MNT" ]] || { err "create/mount failed to yield SNAP/MNT"; exit 1; }
  ok "snapshot=$SNAP  mount=$MNT"
}

teardown() {
  step "teardown (root)"
  sudo umount "$MNT" 2>/dev/null && ok "unmounted $MNT" || err "unmount failed for $MNT"
  sudo rmdir "$MNT" 2>/dev/null || true
  if [[ "$BACKEND" == "fssnapshot" ]]; then
    sudo ./fs_snapshot_spike teardown "$MNT" "$SNAP" 2>/dev/null || true
  else
    sudo tmutil deletelocalsnapshots "$SNAP_DATE" >/dev/null 2>&1 && ok "deleted our snapshot $SNAP_DATE" \
      || err "could not delete $SNAP_DATE — remove manually"
  fi
}

step "1. create + mount ($BACKEND)"
create_and_mount
trap teardown EXIT

FROZEN_LIB="${MNT}/${LIB_REL}"

step "2. SPLIT-READ TEST — read root-mounted snapshot as unprivileged user"
log "reader uid: $(id -u) ($(id -un))   [expect: non-root]"
log "path: $FROZEN_LIB"
SPLIT_PASS=1
if ls -la "$FROZEN_LIB" >/dev/null 2>&1; then
  ok "traversed + listed the frozen library (mountpoint perms + traversal OK)"
else
  err "could NOT list $FROZEN_LIB — traversal/permission failure"; SPLIT_PASS=0
fi
PROBE="$FROZEN_LIB/database/Photos.sqlite"
if head -c 16 "$PROBE" >/dev/null 2>&1; then
  ok "read bytes from Photos.sqlite as non-root (TCC/FDA satisfied for user process)"
else
  err "could NOT read $PROBE as non-root — TCC blocked the user read"; SPLIT_PASS=0
fi

trap - EXIT
teardown

step "3. verify clean teardown"
if tmutil listlocalsnapshots / 2>/dev/null | grep -q "${SNAP_DATE:-$SNAP}"; then
  err "our snapshot still present after teardown"
else
  ok "our snapshot gone; other (TM) snapshots untouched"
fi

step "RESULT"
if [[ "$SPLIT_PASS" -eq 1 ]]; then
  ok "SPLIT READ PASSES — root mounts, unprivileged FDA user reads. boundary sound."
else
  err "SPLIT READ FAILED — rethink: FDA reader must run in user context, not behind root mount."
  exit 1
fi
