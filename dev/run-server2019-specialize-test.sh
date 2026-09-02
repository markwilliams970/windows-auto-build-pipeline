#!/usr/bin/env bash
# Fast-iteration harness for debugging Server 2019's Enable-PSRemoting hang
# (PHASE3_ENGINEERING_LOG.md, 2026-09-02 Phase E1 session) - NOT the same tool as
# dev/role-test.pkr.hcl, which assumes WinRM already works and iterates on role
# scripts. This one iterates on the specialize step itself (image-apply/
# unattend-server2019.xml's FirstLogonCommands) against a disk that has never
# booted, so each cycle only pays real Windows boot time (a few minutes), not the
# ~20 minute partition+apply-image cost - matching this project's own "reuse the
# pattern, not necessarily the exact files" convention (CLAUDE.md).
#
# Prerequisite: image-apply/output/server2019-baseline-bootable.qcow2 - a frozen,
# NEVER-BOOTED, bootable-but-unspecialized Server 2019 disk, produced once via:
#   ./image-apply/partition-disk.sh server2019 image-apply/output/server2019-baseline-bootable.qcow2
#   ./image-apply/apply-image.sh server2019 image-apply/output/server2019-baseline-bootable.qcow2
#   ./image-apply/make-bootable.sh server2019 image-apply/output/server2019-baseline-bootable.qcow2
# This script never writes to that file - every run creates a fresh qemu-img
# backing-file overlay (matching the sibling project's own dev/ COW-overlay
# pattern) so the baseline stays pristine across any number of iterations.
#
# Each run: fresh overlay -> apply-unattend.sh (picks up whatever's currently in
# image-apply/unattend-server2019.xml, so edit that file between runs to test a
# new FirstLogonCommands approach) -> boot with QMP enabled (same virtio-blk-pci
# topology as tools/boot-adhoc-target.sh, since this disk hasn't been through
# inject-virtio-spice.sh) -> poll for WinRM Basic-auth reachability -> report.
#
# Usage: dev/run-server2019-specialize-test.sh [label] [timeout-seconds]
#   label            short tag for this run's overlay/socket naming (default: a timestamp)
#   timeout-seconds  how long to wait for WinRM before giving up (default: 600)
#
# Leaves the VM running either way (success or timeout) for live follow-up
# inspection via tools/qmp-screenshot.py / qmp-sendkey.py / qmp-type.py against
# the printed socket path - shut it down yourself (QMP system_powerdown) when done.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="${REPO_ROOT}/image-apply/output/server2019-baseline-bootable.qcow2"
[[ -f "$BASELINE" ]] || { echo "ERROR: baseline not found at $BASELINE - build it first (see this script's own header comment)" >&2; exit 1; }

LABEL="${1:-$(date +%Y%m%d-%H%M%S)}"
TIMEOUT_SEC="${2:-600}"

OUT_DIR="${REPO_ROOT}/dev/output/server2019-specialize-test"
mkdir -p "$OUT_DIR"
OVERLAY="${OUT_DIR}/overlay-${LABEL}.qcow2"
EFIVARS="${OUT_DIR}/efivars-${LABEL}.fd"
QMP_SOCK="/tmp/s19spec-${LABEL}.sock"
WINRM_PORT="${WINRM_PORT:-15985}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-TestP@ssw0rd123}"

[[ -e "$OVERLAY" || -e "$EFIVARS" ]] && { echo "ERROR: ${OVERLAY} or ${EFIVARS} already exists - pick a different label" >&2; exit 1; }

echo "==> Creating COW overlay ${OVERLAY} (backed by ${BASELINE}, baseline untouched)"
qemu-img create -f qcow2 -F qcow2 -b "$BASELINE" "$OVERLAY" >/dev/null

echo "==> Running apply-unattend.sh against the overlay (picks up the current image-apply/unattend-server2019.xml)"
"${REPO_ROOT}/image-apply/apply-unattend.sh" server2019 "$OVERLAY"

echo "==> Booting overlay (virtio-blk-pci, matching tools/boot-adhoc-target.sh's topology for a pre-inject-virtio-spice disk)"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$EFIVARS"
qemu-system-x86_64 \
  -machine type=q35,accel=kvm \
  -cpu host \
  -m 4096 -smp 4 \
  -netdev user,id=user.0,hostfwd=tcp::"${WINRM_PORT}"-:5985 \
  -device virtio-net-pci,netdev=user.0 \
  -drive file="$OVERLAY",if=none,id=target,format=qcow2 \
  -device virtio-blk-pci,drive=target,bootindex=1 \
  -drive file="/usr/share/OVMF/OVMF_CODE_4M.fd",if=pflash,unit=0,format=raw,readonly=on \
  -drive file="$EFIVARS",if=pflash,unit=1,format=raw \
  -device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0 \
  -qmp unix:"${QMP_SOCK}",server,nowait \
  -display none \
  -daemonize \
  -pidfile "${OUT_DIR}/qemu-${LABEL}.pid"

echo "qmp socket: ${QMP_SOCK}"
echo "winrm hostfwd: 127.0.0.1:${WINRM_PORT} -> guest:5985"
echo "  tools/qmp-screenshot.py --socket ${QMP_SOCK} --out shot.png"

echo "==> Polling for WinRM Basic-auth reachability (up to ${TIMEOUT_SEC}s) - transient early failures are expected"
DEADLINE=$(( $(date +%s) + TIMEOUT_SEC ))
RESULT="TIMEOUT"
while [[ "$(date +%s)" -lt "$DEADLINE" ]]; do
  if python3 - "$WINRM_PORT" "$ADMIN_PASSWORD" <<'PYEOF' 2>/dev/null
import sys, winrm
port, password = sys.argv[1], sys.argv[2]
s = winrm.Session(f'http://127.0.0.1:{port}/wsman', auth=('Administrator', password),
                   transport='basic', server_cert_validation='ignore',
                   operation_timeout_sec=10, read_timeout_sec=15)
r = s.run_cmd('hostname')
sys.exit(0 if r.status_code == 0 else 1)
PYEOF
  then
    RESULT="SUCCESS"
    break
  fi
  sleep 10
done

ELAPSED=$(( TIMEOUT_SEC - (DEADLINE - $(date +%s)) ))
if [[ "$RESULT" == "SUCCESS" ]]; then
  echo "==> RESULT: SUCCESS - WinRM Basic-auth reachable after ~${ELAPSED}s"
else
  echo "==> RESULT: TIMEOUT - WinRM not reachable with Basic auth after ${TIMEOUT_SEC}s"
  echo "    (curl -i http://127.0.0.1:${WINRM_PORT}/wsman shows WWW-Authenticate types actually offered, if any)"
fi
echo "==> VM left running for follow-up inspection - PID file: ${OUT_DIR}/qemu-${LABEL}.pid, QMP socket: ${QMP_SOCK}"
