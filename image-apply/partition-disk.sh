#!/usr/bin/env bash
# Build step 3: partition a fresh disk image directly, no boot required.
#
# GPT layout matches Microsoft's own documented manufacturing layout for UEFI Windows
# installs (100MiB ESP / 16MiB MSR / rest Windows), the same layout used throughout
# PHASE2_ENGINEERING_LOG.md's hand-run sessions. mkntfs needs the Windows partition's
# real start sector to write a boot-correct BPB (Finding 2 - qemu-nbd-attached partition
# sub-devices don't expose geometry mkntfs can auto-detect); this script queries it from
# sgdisk's own output after creating the partition rather than hardcoding the value the
# log observed (239616) - Session 8's own closing notes recommend this: recomputing is
# cheap, and a mismatch would itself be a signal something changed.
#
# Usage: partition-disk.sh <server2019|server2022|server2025|windows11> <output-qcow2-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OS="${1:?Usage: partition-disk.sh <server2019|server2022|server2025|windows11> <output-qcow2-path>}"
OUT_QCOW2="${2:?Usage: partition-disk.sh <server2019|server2022|server2025|windows11> <output-qcow2-path>}"
validate_os "$OS"

SIZE_GB="$(os_disk_size_gb "$OS")"
MNT_ROOT="/tmp/win-build-mnt"

if [[ -e "$OUT_QCOW2" ]]; then
  echo "ERROR: $OUT_QCOW2 already exists - refusing to overwrite a possibly-real disk. Remove it first if this is intentional." >&2
  exit 1
fi

log "Creating ${SIZE_GB}GB qcow2 at ${OUT_QCOW2}"
mkdir -p "$(dirname "$OUT_QCOW2")"
qemu-img create -f qcow2 "$OUT_QCOW2" "${SIZE_GB}G"

log "Loading nbd kernel module"
sudo modprobe nbd max_part=8

NBD_DEV=""
for cand in /dev/nbd{0,1,2,3,4,5,6,7}; do
  if ! sudo qemu-nbd -c "$cand" "$OUT_QCOW2" 2>/dev/null; then
    continue
  fi
  NBD_DEV="$cand"
  break
done
if [[ -z "$NBD_DEV" ]]; then
  echo "ERROR: could not attach $OUT_QCOW2 to any /dev/nbd* device" >&2
  exit 1
fi
log "Attached as ${NBD_DEV}"

# The kernel doesn't always have the device's real size negotiated with qemu-nbd's
# server side by the moment qemu-nbd -c returns - sgdisk hit this directly once as
# "Disk is too small to hold GPT data (0 sectors)!" against a freshly-attached device
# that `lsblk` also still showed as 0B. Poll until the kernel reports the real size.
for i in $(seq 1 20); do
  SIZE_BYTES="$(lsblk -b -n -d -o SIZE "$NBD_DEV" 2>/dev/null || echo 0)"
  [[ "${SIZE_BYTES:-0}" -gt 0 ]] && break
  sleep 0.5
done
if [[ "${SIZE_BYTES:-0}" -eq 0 ]]; then
  echo "ERROR: ${NBD_DEV} still reports zero size after waiting - attach didn't settle" >&2
  exit 1
fi

cleanup() {
  sudo umount "${MNT_ROOT}/esp" 2>/dev/null || true
  sudo umount "${MNT_ROOT}/win" 2>/dev/null || true
  sudo qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Partitioning ${NBD_DEV}: 100MiB ESP (ef00) / 16MiB MSR (0c01) / rest Windows (0700)"
sudo sgdisk --zap-all "$NBD_DEV"
sudo sgdisk -n 1:0:+100M -t 1:ef00 -c 1:"EFI System" "$NBD_DEV"
sudo sgdisk -n 2:0:+16M  -t 2:0c01 -c 2:"MSR"         "$NBD_DEV"
sudo sgdisk -n 3:0:0     -t 3:0700 -c 3:"Windows"     "$NBD_DEV"
sudo partprobe "$NBD_DEV"
sleep 1

log "Formatting ESP as FAT32"
sudo mkfs.vfat -F32 "${NBD_DEV}p1"

WIN_START_SECTOR="$(sudo sfdisk -o Device,Start -l "$NBD_DEV" | awk -v dev="${NBD_DEV}p3" '$1 == dev {print $2}')"
if [[ -z "$WIN_START_SECTOR" ]]; then
  echo "ERROR: could not determine ${NBD_DEV}p3's start sector via sfdisk" >&2
  exit 1
fi
log "Windows partition start sector: ${WIN_START_SECTOR} (queried, not hardcoded - Finding 2/Session 8)"

log "Formatting Windows partition as NTFS"
sudo mkntfs -Q -F -L Windows -p "$WIN_START_SECTOR" -H 255 -S 63 "${NBD_DEV}p3"

log "Partitioning complete: ${OUT_QCOW2}"
