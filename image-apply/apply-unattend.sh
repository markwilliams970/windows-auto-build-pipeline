#!/usr/bin/env bash
# Build step 6: offline specialize/unattend pass. Drops the proven unattend.xml at
# %WINDIR%\Panther\unattend.xml, where Windows Setup's own configuration-pass engine
# picks it up automatically on first real boot for the specialize/oobeSystem passes -
# no DISM /Apply-Unattend, no Setup.exe involved (confirmed against Microsoft's own
# documented answer-file search order and empirically - Session 9 Finding 34).
#
# Templates (image-apply/unattend-<os>.xml) already carry the proven FirstLogonCommands
# sequence (live pnputil /add-driver for netkvm, network-category-to-Private wait,
# WinRM-over-HTTP enablement) unchanged - this script only substitutes ComputerName,
# since the checked-in templates still carry their original session-specific hostnames
# (WIN2025-S11 etc.) which were fine for one-off verification but not a real build
# convention.
#
# Usage: apply-unattend.sh <server2019|server2022|server2025|windows11> <target-qcow2-path> [computer-name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OS="${1:?Usage: apply-unattend.sh <server2019|server2022|server2025|windows11> <target-qcow2-path> [computer-name]}"
TARGET_QCOW2="${2:?Usage: apply-unattend.sh <server2019|server2022|server2025|windows11> <target-qcow2-path> [computer-name]}"
COMPUTER_NAME="${3:-$(os_computer_name "$OS")}"
validate_os "$OS"

[[ -f "$TARGET_QCOW2" ]] || { echo "ERROR: $TARGET_QCOW2 not found - run make-bootable.sh first" >&2; exit 1; }

TEMPLATE=""
case "$OS" in
  server2019) TEMPLATE="${REPO_ROOT}/image-apply/unattend-server2019.xml" ;;
  server2022) TEMPLATE="${REPO_ROOT}/image-apply/unattend-server2022.xml" ;;
  server2025) TEMPLATE="${REPO_ROOT}/image-apply/unattend-server2025.xml" ;;
  windows11)  TEMPLATE="${REPO_ROOT}/image-apply/unattend-windows11.xml" ;;
esac
[[ -f "$TEMPLATE" ]] || { echo "ERROR: unattend template not found at $TEMPLATE" >&2; exit 1; }

# NetBIOS ComputerName is capped at 15 characters - fail loudly rather than silently
# truncate and produce a mismatched-looking hostname later.
if [[ ${#COMPUTER_NAME} -gt 15 ]]; then
  echo "ERROR: computer name '$COMPUTER_NAME' exceeds NetBIOS's 15-character limit" >&2
  exit 1
fi

MNT_ROOT="/tmp/win-build-mnt"
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
sudo partprobe "$NBD_DEV"
sleep 1

WIN_MNT="${MNT_ROOT}/win"
mkdir -p "$WIN_MNT"
cleanup() {
  sudo umount "$WIN_MNT" 2>/dev/null || true
  sudo qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sudo mount -t ntfs-3g -o uid="$(id -u)",gid="$(id -g)" "${NBD_DEV}p3" "$WIN_MNT"

log "Writing unattend.xml (ComputerName=${COMPUTER_NAME}) to %WINDIR%\\Panther\\"
mkdir -p "${WIN_MNT}/Windows/Panther"
sed "s|<ComputerName>[^<]*</ComputerName>|<ComputerName>${COMPUTER_NAME}</ComputerName>|" \
  "$TEMPLATE" > "${WIN_MNT}/Windows/Panther/unattend.xml"

log "apply-unattend.sh complete: ${TARGET_QCOW2} (ComputerName=${COMPUTER_NAME})"
