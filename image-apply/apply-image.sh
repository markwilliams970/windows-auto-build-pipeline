#!/usr/bin/env bash
# Build step 4: apply the Windows image (wimlib) to the primary partition. No boot
# required - wimlib-imagex apply writes files directly onto the offline NTFS partition
# device, the same "DISM /Apply-Image-equivalent" this project exists to use instead
# of a booted interactive installer.
#
# WIM image index per OS is independently verified in PHASE2_ENGINEERING_LOG.md
# (Finding 0 for Server 2025, Session 12 Finding 42 for Server 2022, Session 13
# Finding 43 for Windows 11) - see image-apply/lib/common.sh's os_wim_index().
#
# Applies directly to the raw nbd partition device (not an ntfs-3g-mounted directory)
# with --strict-acls, via the sudo rule in tools/sudoers-windows-auto-build-pipeline.
# PHASE3_ENGINEERING_LOG.md's "ROOT CAUSE CONFIRMED" entry (2026-08-24) traced the Start
# Menu/DCOM-activation crash directly to the previous approach: mounting via ntfs-3g
# with uid=/gid= (specifically so this step could run as the normal user) silently
# disables ntfs-3g's own Windows ACL/security-descriptor support - confirmed directly by
# re-running wimlib-imagex apply against that exact mount with --strict-acls, which
# failed immediately with "Extraction backend does not support security descriptors!"
# Applying straight to the block device instead invokes wimlib's own built-in
# direct-NTFS-volume writer, a genuinely different code path (confirmed empirically -
# distinct log output, "Applying image ... to NTFS volume /dev/nbdXp3" rather than the
# FUSE-mount run's FILE_ATTRIBUTE_* warnings) that can actually restore real security
# descriptors. --strict-acls is deliberately not optional here: if this ever silently
# stopped working, the build should hard-fail rather than quietly reintroduce this bug.
#
# Usage: apply-image.sh <server2019|server2022|server2025|windows11> <target-qcow2-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OS="${1:?Usage: apply-image.sh <server2019|server2022|server2025|windows11> <target-qcow2-path>}"
TARGET_QCOW2="${2:?Usage: apply-image.sh <server2019|server2022|server2025|windows11> <target-qcow2-path>}"
validate_os "$OS"

[[ -f "$TARGET_QCOW2" ]] || { echo "ERROR: $TARGET_QCOW2 not found - run partition-disk.sh first" >&2; exit 1; }

WIN_ISO="$(os_win_iso "$OS")"
[[ -f "$WIN_ISO" ]] || { echo "ERROR: $WIN_ISO not found in ISO_CACHE_DIR (${ISO_CACHE_DIR})" >&2; exit 1; }
WIM_INDEX="$(os_wim_index "$OS")"

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

# Registered immediately after a successful attach, before anything else that could
# fail - an error in a later command must still detach the nbd device. Nothing is
# mounted in this script anymore (see header), so cleanup is just the nbd detach.
cleanup() {
  sudo qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Applying ${OS}'s install.wim index ${WIM_INDEX} directly to ${NBD_DEV}p3 (this takes ~14-15 minutes, per Finding 12/30 - may differ slightly under wimlib's native NTFS writer, not yet measured)"
sudo wimlib-imagex apply "$INSTALL_WIM" "$WIM_INDEX" "${NBD_DEV}p3" --strict-acls

log "Image application complete: ${TARGET_QCOW2}"
