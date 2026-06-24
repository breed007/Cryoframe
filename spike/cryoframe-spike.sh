#!/bin/bash
#
# cryoframe-spike.sh — M0 snapshot spike (CLI scaffold, NOT the shipping mechanism)
#
# proves: consistent APFS snapshot -> archive -> reopenable Photos library.
#
# fast-path scaffold per the build plan:
#   - tmutil localsnapshot   (M1 promotes this to fs_snapshot_create in the root helper)
#   - mount_apfs -s          (read-only mount of the frozen Data volume)
#   - ditto / zip / dmg      (archive from the frozen tree)
#   - umount + deletelocalsnapshots   (teardown — only OUR snapshot)
#
# privilege model under test:
#   - root      : localsnapshot, mount_apfs, umount, deletelocalsnapshots
#   - FDA reader: the archive step reads Photos-library content => the process
#                 running this script MUST have Full Disk Access. root does NOT
#                 bypass TCC for Photos content.
#
# run it like:
#   sudo /path/to/cryoframe-spike.sh
# from a Terminal that has been granted Full Disk Access
# (System Settings > Privacy & Security > Full Disk Access > add your terminal).
#
# overrides (env vars):
#   LIBRARY   path to the .photoslibrary           (default: ~/Pictures/Photos Library.photoslibrary)
#   DEST      output directory for the archive      (default: ~/Cryoframe-Spike-Out)
#   MODE      copy | zip | dmg                       (default: copy)
#   KEEP      1 = keep snapshot mounted for poking   (default: 0)
#
set -euo pipefail

# ---- constants ---------------------------------------------------------------
SNAP_PREFIX="com.apple.TimeMachine"            # tmutil's namespace (scaffold only)
MOUNT_BASE="/private/tmp/cryoframe_snap"        # deterministic, reconcilable mountpoint
STATE_DIR="/private/tmp/cryoframe_state"        # records snapshots WE create, for safe reconcile
RUN_TS="$(date +%Y%m%d-%H%M%S)"
MOUNTPOINT="${MOUNT_BASE}.${RUN_TS}"
STATEFILE="${STATE_DIR}/run.${RUN_TS}"

# ---- resolve the invoking (non-root) user ------------------------------------
# under sudo, $HOME is root's; we want the human's library by default.
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(eval echo "~${REAL_USER}")"

LIBRARY="${LIBRARY:-${REAL_HOME}/Pictures/Photos Library.photoslibrary}"
DEST="${DEST:-${REAL_HOME}/Cryoframe-Spike-Out}"
MODE="${MODE:-copy}"
KEEP="${KEEP:-0}"

# ---- logging -----------------------------------------------------------------
c_blue=$'\033[34m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
log()  { printf '%s[cryoframe]%s %s\n' "$c_blue" "$c_rst" "$*"; }
ok()   { printf '%s[  ok  ]%s %s\n' "$c_grn" "$c_rst" "$*"; }
err()  { printf '%s[ fail ]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
step() { printf '\n%s== %s ==%s\n' "$c_blue" "$*" "$c_rst"; }

# ---- teardown trap -----------------------------------------------------------
# fires on ANY exit. unmounts and (unless KEEP) deletes only the snapshot we made.
OUR_SNAP=""
cleanup() {
  local rc=$?
  if [[ "$KEEP" == "1" && $rc -eq 0 ]]; then
    log "KEEP=1 — leaving snapshot mounted at: $MOUNTPOINT"
    log "snapshot: $OUR_SNAP"
    log "tear down later with:  sudo umount '$MOUNTPOINT' && sudo tmutil deletelocalsnapshots ${OUR_SNAP#${SNAP_PREFIX}.}"
    return
  fi
  step "teardown"
  if mount | grep -q " on ${MOUNTPOINT} "; then
    umount "$MOUNTPOINT" 2>/dev/null && ok "unmounted $MOUNTPOINT" || err "could not unmount $MOUNTPOINT"
  fi
  [[ -d "$MOUNTPOINT" ]] && rmdir "$MOUNTPOINT" 2>/dev/null || true
  if [[ -n "$OUR_SNAP" ]]; then
    local snapdate="${OUR_SNAP#${SNAP_PREFIX}.}"; snapdate="${snapdate%.local}"
    if tmutil deletelocalsnapshots "$snapdate" >/dev/null 2>&1; then
      ok "deleted our snapshot: $OUR_SNAP"
    else
      err "could not delete snapshot $OUR_SNAP — delete manually: sudo tmutil deletelocalsnapshots $snapdate"
    fi
  fi
  [[ -f "$STATEFILE" ]] && rm -f "$STATEFILE"
  [[ $rc -ne 0 ]] && err "exited with status $rc"
}
trap cleanup EXIT

# ---- preflight ---------------------------------------------------------------
step "preflight"

[[ "$(uname -m)" == "arm64" ]] || { err "not arm64 (got $(uname -m)) — Cryoframe is Apple Silicon only"; exit 1; }
ok "arch: arm64"
ok "macOS: $(sw_vers -productVersion)"

if [[ "$(id -u)" -ne 0 ]]; then
  err "must run as root (snapshot/mount syscalls). re-run:  sudo $0"
  exit 1
fi
ok "running as root"

[[ -e "$LIBRARY" ]] || { err "library not found: $LIBRARY"; exit 1; }
log "library: $LIBRARY"
log "dest:    $DEST"
log "mode:    $MODE"

# FDA probe — read a real byte from inside the library. root does NOT bypass
# this; if the terminal lacks Full Disk Access, this fails and so would the
# archive step. fail fast with a clear message rather than sealing an empty copy.
PROBE="$LIBRARY/database/Photos.sqlite"
if [[ -r "$PROBE" ]] && head -c 16 "$PROBE" >/dev/null 2>&1; then
  ok "FDA probe: can read library internals"
else
  err "FDA probe FAILED — cannot read $PROBE"
  err "grant Full Disk Access to your terminal (System Settings > Privacy & Security"
  err "> Full Disk Access), fully quit & reopen the terminal, then re-run."
  exit 1
fi

# ---- reconcile (orphan sweep from a prior crashed run) -----------------------
step "reconcile — sweep orphans from prior runs"
mkdir -p "$STATE_DIR"
# 1) stale mounts under our base
while IFS= read -r mp; do
  [[ -z "$mp" ]] && continue
  log "orphan mount: $mp — unmounting"
  umount "$mp" 2>/dev/null && ok "unmounted $mp" || err "stuck mount $mp"
  rmdir "$mp" 2>/dev/null || true
done < <(mount | awk -v b="$MOUNT_BASE" '$3 ~ b {print $3}')
# 2) snapshots recorded by prior runs' statefiles (never touch TM snapshots we didn't make)
shopt -s nullglob
for sf in "$STATE_DIR"/run.*; do
  [[ "$sf" == "$STATEFILE" ]] && continue
  local_snap="$(cat "$sf" 2>/dev/null || true)"
  if [[ -n "$local_snap" ]] && tmutil listlocalsnapshots / 2>/dev/null | grep -qx "$local_snap"; then
    sd="${local_snap#${SNAP_PREFIX}.}"; sd="${sd%.local}"
    log "orphan snapshot from $sf: $local_snap — deleting"
    tmutil deletelocalsnapshots "$sd" >/dev/null 2>&1 && ok "deleted $local_snap" || err "could not delete $local_snap"
  fi
  rm -f "$sf"
done
shopt -u nullglob
ok "reconcile done"

# ---- 1. create snapshot ------------------------------------------------------
step "create snapshot"
# capture the snapshot set before, so we can identify exactly the one WE create
# (and never confuse it with Time Machine's own snapshots).
before="$(tmutil listlocalsnapshots / 2>/dev/null || true)"
create_out="$(tmutil localsnapshot / 2>&1)"; log "$create_out"
after="$(tmutil listlocalsnapshots / 2>/dev/null || true)"
OUR_SNAP="$(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) | grep "^${SNAP_PREFIX}\." | tail -1)"
if [[ -z "$OUR_SNAP" ]]; then
  # tmutil may coalesce if a same-minute snapshot already exists; fall back to newest.
  OUR_SNAP="$(printf '%s\n' "$after" | grep "^${SNAP_PREFIX}\." | tail -1)"
  log "no new snapshot delta (coalesced?) — adopting newest: $OUR_SNAP"
fi
[[ -n "$OUR_SNAP" ]] || { err "could not determine snapshot name"; exit 1; }
printf '%s' "$OUR_SNAP" > "$STATEFILE"
ok "snapshot: $OUR_SNAP  (recorded in $STATEFILE)"

# ---- 2. mount snapshot read-only ---------------------------------------------
step "mount snapshot (read-only)"
DATA_DEV="$(diskutil info /System/Volumes/Data | awk -F': *' '/Device Node/{print $2}' | tr -d ' ')"
[[ -n "$DATA_DEV" ]] || { err "could not find Data volume device"; exit 1; }
log "Data device: $DATA_DEV"
mkdir -p "$MOUNTPOINT"
mount_apfs -o rdonly -s "$OUR_SNAP" "$DATA_DEV" "$MOUNTPOINT"
mount | grep -q " on ${MOUNTPOINT} " || { err "mount did not appear"; exit 1; }
ok "mounted $OUR_SNAP -> $MOUNTPOINT (ro)"

# library path INSIDE the snapshot: the Data volume root holds /Users, so strip
# the live /System/Volumes/Data-or-/ prefix and re-root under the mountpoint.
LIB_REL="${LIBRARY#/System/Volumes/Data}"   # no-op if already a plain ~ path
LIB_REL="${LIB_REL#/}"
FROZEN_LIB="${MOUNTPOINT}/${LIB_REL}"
[[ -e "$FROZEN_LIB" ]] || { err "frozen library not found at $FROZEN_LIB"; exit 1; }
ok "frozen library: $FROZEN_LIB"

# ---- size / space guard (now readable via FDA on the frozen tree) ------------
step "size + free-space check"
LIB_BYTES="$(du -sk "$FROZEN_LIB" 2>/dev/null | awk '{print $1*1024}')"
log "library size: $(du -sh "$FROZEN_LIB" 2>/dev/null | awk '{print $1}')"
mkdir -p "$DEST"
AVAIL_BYTES="$(df -k "$DEST" | awk 'NR==2{print $4*1024}')"
if [[ -n "$LIB_BYTES" && "$AVAIL_BYTES" -lt "$LIB_BYTES" ]]; then
  err "not enough free space at $DEST (need ~$((LIB_BYTES/1024/1024)) MiB, have $((AVAIL_BYTES/1024/1024)) MiB)"
  exit 1
fi
ok "free space sufficient"

# ---- 3. archive from the frozen tree -----------------------------------------
step "archive ($MODE)"
LIB_NAME="$(basename "$LIBRARY")"
ARTIFACT=""
case "$MODE" in
  copy)
    ARTIFACT="${DEST}/${LIB_NAME}"
    rm -rf "$ARTIFACT"
    # ditto preserves ACLs, resource forks, xattrs — a cp -R would not.
    ditto "$FROZEN_LIB" "$ARTIFACT"
    ;;
  zip)
    ARTIFACT="${DEST}/${LIB_NAME%.photoslibrary}.zip"
    rm -f "$ARTIFACT"
    ditto -c -k --sequesterRsrc --keepParent "$FROZEN_LIB" "$ARTIFACT"
    ;;
  dmg)
    ARTIFACT="${DEST}/${LIB_NAME%.photoslibrary}.dmg"
    rm -f "$ARTIFACT"
    hdiutil create -srcfolder "$FROZEN_LIB" -format UDZO -ov "$ARTIFACT" >/dev/null
    ;;
  *) err "unknown MODE: $MODE (use copy|zip|dmg)"; exit 1 ;;
esac
chown -R "$REAL_USER" "$DEST" 2>/dev/null || true
ok "archived -> $ARTIFACT"

# ---- 4. verify: checksum -----------------------------------------------------
step "verify — checksum"
if [[ -d "$ARTIFACT" ]]; then
  SUM="$(cd "$ARTIFACT/.." && find "$LIB_NAME" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
  log "tree checksum (sha256 of file sums): $SUM"
else
  SUM="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
  log "file checksum (sha256): $SUM"
fi
printf '%s  %s\n' "$SUM" "$ARTIFACT" > "${ARTIFACT}.sha256" 2>/dev/null || \
  printf '%s  %s\n' "$SUM" "$ARTIFACT" > "${DEST}/$(basename "$ARTIFACT").sha256"
ok "checksum written"

# ---- done — hand off to manual reopen verification ---------------------------
step "M0 GATE — manual reopen check"
cat <<EOF
archive produced: $ARTIFACT

strong verification (do this by hand for the gate):
  1. if zip/dmg: expand/mount it to get the .photoslibrary back.
  2. hold Option and launch Photos:  open -a Photos --args  (then Option-click)
     or:  open -b com.apple.Photos   while holding Option to get the chooser.
  3. choose: $ARTIFACT  (or the expanded copy)
  4. PASS if the library opens with NO "repair"/"recover" prompt and content is intact.

teardown (snapshot unmount + delete) runs automatically on exit below.
EOF
ok "spike pipeline complete — see manual check above"
# trap cleanup() fires here on normal exit.
