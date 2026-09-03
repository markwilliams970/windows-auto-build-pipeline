#!/usr/bin/env bash
# Ad hoc boot of a single target disk that has NOT yet been through
# inject-virtio-spice.sh - i.e. any disk produced by running image-apply/*.sh stages
# directly (partition-disk.sh/apply-image.sh/make-bootable.sh/apply-unattend.sh) rather
# than a full build.sh run. Such a disk only ever had viostor (virtio-blk) registered by
# make-bootable.sh's offline hivex DriverDatabase merge - it has no vioscsi driver at all.
#
# Device model matches make-bootable.sh's own target-disk attachment and
# packer/boot-and-provision.pkr.hcl's disk_interface = "virtio" exactly: virtio-blk-pci,
# not virtio-scsi-pci. See project_documentation/PHASE3_ENGINEERING_LOG.md's 2026-08-24/2026-08-25 sessions for
# why this distinction matters - booting a pre-injection disk via register-vm.sh (which
# always assumes virtio-scsi-pci + vioscsi, per its own header) produces an inconsistent
# INACCESSIBLE_BOOT_DEVICE/indefinite-hang failure that looks like a pipeline defect but
# isn't one.
#
# Do NOT use this script for a disk that HAS been through inject-virtio-spice.sh (i.e. any
# real build.sh output, or a Windows 11 build) - use register-vm.sh for those; this script's
# virtio-blk-pci topology is specifically wrong for a disk whose viostor DriverDatabase
# entry has been superseded by vioscsi.
#
# Usage: boot-adhoc-target.sh <qcow2-path> [hostfwd-port] [short-name]
#   hostfwd-port  host TCP port forwarded to the guest's WinRM listener (5985). Default 15985.
#   short-name    used to derive the QMP socket/efivars paths under /tmp - keep it short,
#                 unix socket paths have a hard 108-byte kernel limit (CLAUDE.md). Default "adhoc".
#
# Runs qemu-system-x86_64 in the foreground via exec - background it yourself (&, nohup)
# for a long-lived test session. Prints the QMP socket path and hostfwd port to stderr
# before exec'ing so they're available to whatever screenshots/sends keys/checks WinRM next.
set -euo pipefail

DISK="${1:?usage: boot-adhoc-target.sh <qcow2-path> [hostfwd-port] [short-name]}"
PORT="${2:-15985}"
NAME="${3:-adhoc}"

if [[ ! -f "$DISK" ]]; then
  echo "ERROR: disk not found: $DISK" >&2
  exit 1
fi
DISK="$(cd "$(dirname "$DISK")" && pwd)/$(basename "$DISK")"

QMP_SOCK="/tmp/${NAME}.sock"
EFIVARS="/tmp/${NAME}-efivars.fd"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.fd"

rm -f "$QMP_SOCK" "$EFIVARS"
cp "$OVMF_VARS_TEMPLATE" "$EFIVARS"

echo "disk:        $DISK" >&2
echo "qmp socket:  $QMP_SOCK" >&2
echo "winrm hostfwd: 127.0.0.1:${PORT} -> guest:5985" >&2
echo "  tools/qmp-screenshot.py --socket $QMP_SOCK --out shot.png" >&2
echo "  tools/qmp-sendkey.py --socket $QMP_SOCK meta_l" >&2

exec qemu-system-x86_64 \
  -machine type=q35,accel=kvm \
  -cpu host \
  -m 4096 -smp 4 \
  -netdev user,id=user.0,hostfwd=tcp::"${PORT}"-:5985 \
  -device virtio-net-pci,netdev=user.0 \
  -drive file="$DISK",if=none,id=target,format=qcow2 \
  -device virtio-blk-pci,drive=target,bootindex=1 \
  -drive file="$OVMF_CODE",if=pflash,unit=0,format=raw,readonly=on \
  -drive file="$EFIVARS",if=pflash,unit=1,format=raw \
  -device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0 \
  -qmp unix:"${QMP_SOCK}",server,nowait \
  -display none
