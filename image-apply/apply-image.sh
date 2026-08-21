#!/usr/bin/env bash
# Build step 4: apply the Windows image (wimlib) to the primary partition. No boot
# required - wimlib-imagex apply writes files directly onto the offline-mounted NTFS
# partition, the same "DISM /Apply-Image-equivalent" this project exists to use instead
# of a booted interactive installer.
#
# WIM image index per OS is independently verified in PHASE2_ENGINEERING_LOG.md
# (Finding 0 for Server 2025, Session 12 Finding 42 for Server 2022, Session 13
# Finding 43 for Windows 11) - see image-apply/lib/common.sh's os_wim_index().
#
# Usage: apply-image.sh <server2022|server2025|windows11> <target-qcow2-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OS="${1:?Usage: apply-image.sh <server2022|server2025|windows11> <target-qcow2-path>}"
TARGET_QCOW2="${2:?Usage: apply-image.sh <server2022|server2025|windows11> <target-qcow2-path>}"
validate_os "$OS"

[[ -f "$TARGET_QCOW2" ]] || { echo "ERROR: $TARGET_QCOW2 not found - run partition-disk.sh first" >&2; exit 1; }

WIN_ISO="$(os_win_iso "$OS")"
[[ -f "$WIN_ISO" ]] || { echo "ERROR: $WIN_ISO not found in ISO_CACHE_DIR (${ISO_CACHE_DIR})" >&2; exit 1; }
WIM_INDEX="$(os_wim_index "$OS")"

MNT_ROOT="/tmp/win-build-mnt"
WIM_CACHE_DIR="${REPO_ROOT}/image-apply/output/wim-cache/${OS}"
INSTALL_WIM="${WIM_CACHE_DIR}/install.wim"

if [[ -f "$INSTALL_WIM" ]]; then
  log "Reusing already-extracted ${INSTALL_WIM}"
else
  log "Extracting install.wim from ${WIN_ISO} (this can take a few minutes, ~7GB)"
  mkdir -p "$WIM_CACHE_DIR"
  7z e -y -o"$WIM_CACHE_DIR" "$WIN_ISO" sources/install.wim
fi

log "Attaching ${TARGET_QCOW2}"
sudo modprobe nbd max_part=8
NBD_DEV=""
for cand in /dev/nbd{0,1,2,3,4,5,6,7}; do
  if ! sudo qemu-nbd -c "$cand" "$TARGET_QCOW2" 2>/dev/null; then
    continue
  fi
  NBD_DEV="$cand"
  break
done
[[ -n "$NBD_DEV" ]] || { echo "ERROR: could not attach $TARGET_QCOW2 to any /dev/nbd* device" >&2; exit 1; }
log "Attached as ${NBD_DEV}"
sudo partprobe "$NBD_DEV"
sleep 1

WIN_MNT="${MNT_ROOT}/win"

# Registered immediately after a successful attach, before anything else that could
# fail - an error in a later command must still detach the nbd device.
cleanup() {
  sudo umount "$WIN_MNT" 2>/dev/null || true
  sudo qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$WIN_MNT"
sudo mount -t ntfs-3g -o uid="$(id -u)",gid="$(id -g)" "${NBD_DEV}p3" "$WIN_MNT"

log "Applying ${OS}'s install.wim index ${WIM_INDEX} to ${WIN_MNT} (this takes ~14-15 minutes, per Finding 12/30)"
wimlib-imagex apply "$INSTALL_WIM" "$WIM_INDEX" "$WIN_MNT"

log "Image application complete: ${TARGET_QCOW2}"
