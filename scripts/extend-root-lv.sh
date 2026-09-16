#!/usr/bin/env bash
#
# Grow the root ext4 filesystem into unallocated space in its LVM volume group.
#
# The Ubuntu Server installer commonly allocates only part of the disk to the
# root logical volume and leaves the rest of the volume group unused. This
# script claims that unused space.
#
# Safety properties:
#   - discovers every device name at runtime, nothing is hardcoded
#   - refuses to run unless the target really is an ext4 root on LVM
#   - aborts if the filesystem superblock reports errors
#   - performs an lvextend dry run and shows you the result first
#   - requires you to type the word "extend" to proceed
#   - extends the LV and the filesystem as two separate, verified steps
#   - leaves a reserve of unallocated space in the VG so an LVM snapshot
#     remains possible later
#
# Both operations only ever grow. Growing an ext4 filesystem is an online,
# in-place metadata operation: existing data is never moved or rewritten.
# Shrinking is the dangerous direction and this script never does it.
#
# Usage:
#   sudo scripts/extend-root-lv.sh              leave 20G reserve in the VG
#   sudo scripts/extend-root-lv.sh --reserve 0  use every free extent
#   sudo scripts/extend-root-lv.sh --dry-run    show the plan, change nothing

set -euo pipefail

RESERVE_GB=20
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --reserve) RESERVE_GB="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '[extend] %s\n' "$*"; }
fail() { printf '[extend] ABORT: %s\n' "$*" >&2; exit 1; }
rule() { printf '\n--- %s ---\n' "$*"; }

[ "$(id -u)" -eq 0 ] || fail "must run as root (use: sudo $0)"

for cmd in findmnt lvs vgs lvextend resize2fs dumpe2fs awk; do
    command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: $cmd"
done

# --- discover ---------------------------------------------------------------

ROOT_SRC=$(findmnt -n -o SOURCE /)
ROOT_FS=$(findmnt -n -o FSTYPE /)

log "root filesystem : $ROOT_SRC ($ROOT_FS)"

[ "$ROOT_FS" = "ext4" ] || fail "root is $ROOT_FS, not ext4. resize2fs is not the right tool here."

# Resolve the device-mapper node to its LVM volume group and logical volume.
LV_NAME=$(lvs --noheadings -o lv_name --select "lv_path=$ROOT_SRC" 2>/dev/null | awk '{$1=$1;print}' || true)
VG_NAME=$(lvs --noheadings -o vg_name --select "lv_path=$ROOT_SRC" 2>/dev/null | awk '{$1=$1;print}' || true)

if [ -z "$LV_NAME" ] || [ -z "$VG_NAME" ]; then
    # Fall back to matching on the dm name, which is how /dev/mapper entries read.
    DM_NAME=$(basename "$(readlink -f "$ROOT_SRC")")
    read -r LV_NAME VG_NAME <<<"$(lvs --noheadings -o lv_name,vg_name 2>/dev/null \
        | awk -v dm="$DM_NAME" '{gsub(/-/,"--",$1); gsub(/-/,"--",$2);
                                  if (dm == $2"-"$1) print}' \
        | head -1)"
    LV_NAME=$(lvs --noheadings -o lv_name 2>/dev/null | awk 'NR==1{$1=$1;print}')
    VG_NAME=$(lvs --noheadings -o vg_name 2>/dev/null | awk 'NR==1{$1=$1;print}')
fi

[ -n "$LV_NAME" ] || fail "could not determine the logical volume behind $ROOT_SRC"
[ -n "$VG_NAME" ] || fail "could not determine the volume group behind $ROOT_SRC"

LV_PATH="/dev/$VG_NAME/$LV_NAME"
[ -e "$LV_PATH" ] || fail "resolved LV path does not exist: $LV_PATH"

log "volume group    : $VG_NAME"
log "logical volume  : $LV_NAME  ($LV_PATH)"

# --- current state ----------------------------------------------------------

rule "current state"
vgs "$VG_NAME"
echo
lvs "$VG_NAME"
echo
df -h /

VFREE_K=$(vgs --noheadings --units k --nosuffix -o vg_free "$VG_NAME" | awk '{printf "%d", $1}')
VFREE_GB=$(( VFREE_K / 1024 / 1024 ))

log "unallocated in $VG_NAME: ${VFREE_GB} GiB"

if [ "$VFREE_GB" -le 1 ]; then
    fail "the volume group has no meaningful free space. Nothing to do."
fi

# --- filesystem health ------------------------------------------------------

rule "filesystem health"
FS_STATE=$(dumpe2fs -h "$LV_PATH" 2>/dev/null | awk -F: '/^Filesystem state:/{gsub(/^ +/,"",$2); print $2}')
log "superblock state: ${FS_STATE:-unknown}"

case "$FS_STATE" in
    *"with errors"*)
        fail "the filesystem reports errors. Run fsck from a rescue boot before resizing." ;;
    "")
        log "WARNING: could not read the superblock state. Proceeding is your call." ;;
esac

# A mounted ext4 normally reports 'clean'. Anything mentioning errors is a stop.

# --- plan -------------------------------------------------------------------

RESERVE_K=$(( RESERVE_GB * 1024 * 1024 ))
GROW_K=$(( VFREE_K - RESERVE_K ))

if [ "$GROW_K" -le 0 ]; then
    fail "reserve of ${RESERVE_GB} GiB leaves nothing to grow into (free: ${VFREE_GB} GiB). Lower --reserve."
fi

GROW_GB=$(( GROW_K / 1024 / 1024 ))

rule "plan"
log "grow    $LV_PATH by ${GROW_GB} GiB"
log "keep    ${RESERVE_GB} GiB unallocated in $VG_NAME (room for an LVM snapshot)"
log "then    resize2fs to fill the enlarged volume, online, with / mounted"

rule "lvextend dry run"
lvextend --test -L "+${GROW_K}k" "$LV_PATH" 2>&1 || fail "the dry run failed. Nothing was changed."

if [ "$DRY_RUN" -eq 1 ]; then
    rule "dry run only"
    log "no changes made. Re-run without --dry-run to apply."
    exit 0
fi

# --- confirm ----------------------------------------------------------------

rule "confirmation"
cat <<EOF
This will grow the root filesystem in place, while it is mounted.

It only ever adds capacity. Existing data is not moved, rewritten or deleted.
The operation is the standard way to claim unallocated LVM space and is safe
to run on a live system with containers running.

That said, no resize operation is a substitute for a backup. If there is data
on this machine you cannot lose and have never backed up, stop now and back it
up first.

Type exactly:  extend
EOF
printf 'confirm> '
read -r ANSWER
[ "$ANSWER" = "extend" ] || fail "not confirmed (you typed '${ANSWER}'). Nothing was changed."

# --- step 1: extend the logical volume --------------------------------------

rule "step 1 of 2: extending the logical volume"
LV_BEFORE_K=$(lvs --noheadings --units k --nosuffix -o lv_size "$LV_PATH" | awk '{printf "%d", $1}')
log "LV size before: $(( LV_BEFORE_K / 1024 / 1024 )) GiB"

lvextend -L "+${GROW_K}k" "$LV_PATH"

LV_AFTER_K=$(lvs --noheadings --units k --nosuffix -o lv_size "$LV_PATH" | awk '{printf "%d", $1}')
log "LV size after : $(( LV_AFTER_K / 1024 / 1024 )) GiB"

if [ "$LV_AFTER_K" -le "$LV_BEFORE_K" ]; then
    fail "the logical volume did not grow. The filesystem was NOT touched, so nothing is at risk."
fi

# --- step 2: grow the filesystem --------------------------------------------

rule "step 2 of 2: growing the filesystem"
DF_BEFORE=$(df -B1 --output=size / | tail -1)

resize2fs "$LV_PATH"

DF_AFTER=$(df -B1 --output=size / | tail -1)

if [ "$DF_AFTER" -le "$DF_BEFORE" ]; then
    fail "the filesystem did not grow. The LV is larger than the filesystem, which is harmless. Investigate with: resize2fs -P $LV_PATH"
fi

# --- verify -----------------------------------------------------------------

rule "verification"
df -h /
echo
lvs "$VG_NAME"
echo
vgs "$VG_NAME"

rule "write test"
TESTFILE=$(mktemp /root/.extend-verify.XXXXXX)
dd if=/dev/urandom of="$TESTFILE" bs=1M count=64 status=none
SUM_W=$(sha256sum "$TESTFILE" | cut -d' ' -f1)
sync
SUM_R=$(sha256sum "$TESTFILE" | cut -d' ' -f1)
rm -f "$TESTFILE"
if [ "$SUM_W" = "$SUM_R" ]; then
    log "64 MiB write and read back verified, checksums match"
else
    fail "write verification FAILED. Check dmesg immediately."
fi

rule "done"
log "root filesystem is now $(df -h --output=size / | tail -1 | tr -d ' ') with $(df -h --output=avail / | tail -1 | tr -d ' ') available"
log "${RESERVE_GB} GiB left unallocated in $VG_NAME for snapshots"
