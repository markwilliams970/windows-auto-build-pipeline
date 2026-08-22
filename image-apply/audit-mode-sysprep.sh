#!/usr/bin/env bash
# Build step 5.5 (windows11 only): boot once into Audit Mode and run Sysprep
# (/generalize /oobe /shutdown) fully unattended, before the real customer-facing
# unattend.xml is ever dropped - matching Microsoft's own real OEM manufacturing flow
# (PHASE3_ENGINEERING_LOG.md Session 3/Finding 9) instead of skipping straight from
# offline image prep to what this project used to treat as the real first boot. Runs
# between make-bootable.sh and apply-unattend.sh in build.sh's orchestration.
#
# Confirmed working via PHASE3_ENGINEERING_LOG.md Session 4:
#   - Finding 10: the offline-drop delivery mechanism (%WINDIR%\Panther\unattend.xml)
#     triggers real Audit Mode entry - no OOBE screen, built-in Administrator auto-logon,
#     the real Sysprep GUI auto-launches, exactly matching Microsoft's documented
#     behavior.
#   - Finding 11: Microsoft-Windows-Deployment/RunSynchronous under the auditUser pass
#     automates Sysprep's own invocation with zero live keystroke driving - the VM ran
#     sysprep /generalize /oobe /shutdown unattended and powered itself off on its own,
#     confirmed via Windows' own Sysprep_succeeded.tag marker. That same test disk
#     carried the normal viostor/netkvm driver injection (not a stripped-down disk), so
#     Sysprep did not reject this project's non-standard offline injection approach
#     either.
#
# Uses image-apply/unattend-windows11-audit-sysprep.xml directly - no per-build
# substitution needed (unlike apply-unattend.sh's ComputerName), since this trigger
# file has no build-specific values at all.
#
# Windows 11 only - Server 2022/2025 stay on the proven, fully-offline architecture
# unchanged (CLAUDE.md's own scope note for Option B).
#
# Usage: audit-mode-sysprep.sh <windows11> <target-qcow2-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OS="${1:?Usage: audit-mode-sysprep.sh <windows11> <target-qcow2-path>}"
TARGET_QCOW2="${2:?Usage: audit-mode-sysprep.sh <windows11> <target-qcow2-path>}"
validate_os "$OS"
if [[ "$OS" != "windows11" ]]; then
  echo "ERROR: audit-mode-sysprep.sh is windows11-only (Finding 9/Option B scope) - got '$OS'. Server 2022/2025 must not call this script." >&2
  exit 1
fi

[[ -f "$TARGET_QCOW2" ]] || { echo "ERROR: $TARGET_QCOW2 not found - run make-bootable.sh first" >&2; exit 1; }

TRIGGER_TEMPLATE="${REPO_ROOT}/image-apply/unattend-windows11-audit-sysprep.xml"
[[ -f "$TRIGGER_TEMPLATE" ]] || { echo "ERROR: trigger unattend template not found at $TRIGGER_TEMPLATE" >&2; exit 1; }

MNT_ROOT="/tmp/win-build-mnt"
WIN_MNT="${MNT_ROOT}/win"
NBD_DEV=""

cleanup_mount() {
  sudo umount "$WIN_MNT" 2>/dev/null || true
  [[ -n "$NBD_DEV" ]] && sudo qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
}

attach_nbd() {
  sudo modprobe nbd max_part=8
  NBD_DEV=""
  for cand in /dev/nbd{0,1,2,3,4,5,6,7}; do
    if sudo qemu-nbd -c "$cand" "$TARGET_QCOW2" 2>/dev/null; then
      NBD_DEV="$cand"
      break
    fi
  done
  [[ -n "$NBD_DEV" ]] || { echo "ERROR: could not attach $TARGET_QCOW2 to any /dev/nbd* device" >&2; exit 1; }
  sudo partprobe "$NBD_DEV"
  sleep 1
}

log "Offline-dropping the Audit Mode + Sysprep trigger unattend.xml to %WINDIR%\\Panther\\"
trap cleanup_mount EXIT
attach_nbd
mkdir -p "$WIN_MNT"
sudo mount -t ntfs-3g -o uid="$(id -u)",gid="$(id -g)" "${NBD_DEV}p3" "$WIN_MNT"
mkdir -p "${WIN_MNT}/Windows/Panther"
cp "$TRIGGER_TEMPLATE" "${WIN_MNT}/Windows/Panther/unattend.xml"
sudo umount "$WIN_MNT"
sudo qemu-nbd -d "$NBD_DEV"
trap - EXIT
NBD_DEV=""
log "Trigger unattend.xml dropped; disk detached cleanly"

log "Booting solo into Audit Mode to run Sysprep unattended (this can take several minutes)"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_SCRATCH="${REPO_ROOT}/image-apply/output/efivars-${OS}-bootable.fd"
[[ -f "$OVMF_VARS_SCRATCH" ]] || { echo "ERROR: $OVMF_VARS_SCRATCH not found - run make-bootable.sh first (it produces this disk's own boot-entry-carrying NVRAM state)" >&2; exit 1; }

QMP_SOCK="/tmp/audit-sysprep-${OS}.sock"
rm -f "$QMP_SOCK"

# No trap here deliberately - qemu runs in the foreground and this project's
# established convention (make-bootable.sh's WinPE boot) is a plain `timeout`
# wrapper, since the guest shuts itself down on its own (Finding 11) rather than
# needing to be killed. A genuine hang is caught by the timeout below.
timeout 900 qemu-system-x86_64 \
  -machine q35,accel=kvm \
  -cpu host \
  -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS_SCRATCH" \
  -drive file="$TARGET_QCOW2",if=none,id=target,format=qcow2 \
  -device virtio-blk-pci,drive=target,bootindex=1 \
  -qmp "unix:${QMP_SOCK},server,nowait" \
  -display none \
  || { rc=$?; if [[ $rc -eq 124 ]]; then echo "ERROR: Audit Mode + Sysprep boot timed out after 900s - the VM never shut itself down (Sysprep may be stuck, or RunSynchronous never fired)" >&2; exit 1; fi; }

log "QEMU exited on its own (Sysprep's /shutdown, per Finding 11) - verifying Sysprep actually succeeded"

# A VM exiting isn't proof Sysprep succeeded (a crash would also end the process), so
# check Windows' own success marker directly rather than inferring success from the
# exit alone - this project's "verify before trusting" standard.
trap cleanup_mount EXIT
attach_nbd
mkdir -p "$WIN_MNT"

MOUNT_LOG="$(mktemp)"
sudo mount -t ntfs-3g -o uid="$(id -u)",gid="$(id -g)" "${NBD_DEV}p3" "$WIN_MNT" 2>"$MOUNT_LOG" || true
if grep -qi "read-only" "$MOUNT_LOG"; then
  echo "ERROR: disk mounted read-only - PHASE3_ENGINEERING_LOG.md Session 3's signature of an unclean shutdown. Sysprep's own /shutdown should leave a clean volume; this indicates a crash, not a normal completion." >&2
  cat "$MOUNT_LOG" >&2
  rm -f "$MOUNT_LOG"
  exit 1
fi
rm -f "$MOUNT_LOG"

SUCCESS_TAG="${WIN_MNT}/Windows/System32/Sysprep/Sysprep_succeeded.tag"
if [[ ! -f "$SUCCESS_TAG" ]]; then
  echo "ERROR: $SUCCESS_TAG not found - Sysprep did not report success. Check Windows/System32/Sysprep/Panther/setupact.log and setuperr.log on this disk for the real failure." >&2
  exit 1
fi
log "Confirmed: Sysprep_succeeded.tag present - Sysprep completed cleanly"

sudo umount "$WIN_MNT"
sudo qemu-nbd -d "$NBD_DEV"
trap - EXIT
NBD_DEV=""

log "audit-mode-sysprep.sh complete: ${TARGET_QCOW2} is genuinely Sysprep-prepared"
