#!/usr/bin/env bash
# Checks a qcow2 disk for inject-virtio-spice.sh's own completion marker
# (C:\virtio-spice-injected.marker, written only after its Stage 2 verification fully
# succeeds), read offline via the same qemu-nbd/ntfs-3g mount pattern every image-apply/*.sh
# script already uses. Extracted from register-vm.sh's own precondition check (Phase 5,
# 2026-09) so both the legacy script and windows-pipeline's `register-vm` command share one
# implementation instead of duplicating the nbd-attach/mount/detach dance - register-vm.sh's
# own comment on why this check exists at all (a disk that skipped inject-virtio-spice.sh
# produces the INACCESSIBLE_BOOT_DEVICE/indefinite-hang failure class documented in
# project_documentation/PHASE3_ENGINEERING_LOG.md's 2026-08-24/2026-08-25 sessions) carries over unchanged.
#
# This is a real disk-content check, not a trust-the-caller's-metadata shortcut - even
# windows-pipeline's own state record (which tracks whether create ran inject-virtio-spice.sh)
# is deliberately not trusted here instead of this, per CLAUDE.md's "verify before trusting"
# standard: metadata can go stale or be hand-edited, the marker on the actual disk can't.
#
# Usage: check-virtio-spice-marker.sh <qcow2_path>
# Exit 0 if the marker is present, 1 otherwise (with a message on stderr either way).
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

QCOW2_PATH="${1:?Usage: check-virtio-spice-marker.sh <qcow2_path>}"
[[ -f "$QCOW2_PATH" ]] || fail "no such file: $QCOW2_PATH"

echo "==> Checking ${QCOW2_PATH} for inject-virtio-spice.sh's completion marker" >&2
CHECK_MNT="/tmp/win-build-mnt/register-check"
sudo modprobe nbd max_part=8
CHECK_NBD=""
for cand in /dev/nbd{0,1,2,3,4,5,6,7}; do
  if ! sudo qemu-nbd -c "$cand" "$QCOW2_PATH" 2>/dev/null; then
    continue
  fi
  CHECK_NBD="$cand"
  break
done
[[ -n "$CHECK_NBD" ]] || fail "could not attach $QCOW2_PATH to any /dev/nbd* device to check for inject-virtio-spice.sh's completion marker"
sudo partprobe "$CHECK_NBD"
sleep 1

NTFS_PART="$(lsblk -no PATH,FSTYPE "$CHECK_NBD" | awk '$2 == "ntfs" { print $1; exit }')"
if [[ -z "$NTFS_PART" ]]; then
  sudo qemu-nbd -d "$CHECK_NBD" >/dev/null 2>&1 || true
  fail "no NTFS partition found on $QCOW2_PATH (via $CHECK_NBD) - is this a valid, fully-applied Windows disk?"
fi

mkdir -p "$CHECK_MNT"
cleanup_check() {
  sudo umount "$CHECK_MNT" 2>/dev/null || true
  sudo qemu-nbd -d "$CHECK_NBD" >/dev/null 2>&1 || true
}
trap cleanup_check EXIT
sudo mount -t ntfs-3g -o ro "$NTFS_PART" "$CHECK_MNT"
MARKER_FOUND=0
[[ -f "${CHECK_MNT}/virtio-spice-injected.marker" ]] && MARKER_FOUND=1
sudo umount "$CHECK_MNT"
sudo qemu-nbd -d "$CHECK_NBD" >/dev/null 2>&1 || true
trap - EXIT

[[ "$MARKER_FOUND" == "1" ]] \
  || fail "${QCOW2_PATH} has not been through inject-virtio-spice.sh (no C:\\virtio-spice-injected.marker found on its Windows volume) - this disk's virtio-scsi-pci/QXL/SPICE device model requires it. Run image-apply/inject-virtio-spice.sh against this disk first, or use tools/boot-adhoc-target.sh to boot it directly for testing instead."

echo "==> Marker found - ${QCOW2_PATH} is safe to register" >&2
