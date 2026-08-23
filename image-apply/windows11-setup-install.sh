#!/usr/bin/env bash
# Windows 11 ONLY - the Setup.exe-driven install path that replaces the fully-offline
# apply/bootable/specialize sequence for Windows 11 specifically (partition-disk.sh /
# apply-image.sh / make-bootable.sh / apply-unattend.sh stay unchanged and untouched -
# they remain Server 2022/2025's own proven path; this script never calls them and
# they never call this). Server 2022/2025 stay fully banned from Microsoft-Windows-
# Setup, no exception (CLAUDE.md) - this script hard-gates on windows11 and refuses
# to run against anything else.
#
# One unattended qemu-system-x86_64 session takes a blank disk all the way through:
# Setup.exe partitioning + image install (windowsPE pass) -> first reboot -> specialize/
# oobeSystem passes -> second reboot into a real desktop -> WinRM confirmed live. No
# eject, no bootindex= override of any kind - deliberately. Earlier versions of this
# script pinned bootindex= on the install CD-ROM and target disk, then had to guess a
# timing window to eject the CD-ROM before Setup's own reboot re-selected it. That
# design was found unreliable (a genuine "Windows 11 installation has failed" error
# from an eject that landed too early, and a structural gap where the pixel-sample
# "safety net" couldn't actually distinguish 10% complete from 90%) and was replaced
# after confirming, twice independently, that OVMF's own NVRAM boot order handles
# disk-vs-CD-ROM selection correctly on its own once Windows registers a real "Windows
# Boot Manager" entry - no static override needed at all. See
# PHASE3_ENGINEERING_LOG.md's Phase 3.4 "design reconsideration" entry for the full
# evidentiary trail (direct TianoCore boot-log confirmation of Boot0009 "Windows Boot
# Manager" on both reboots, both attempts). The retired eject-based mechanism and its
# own calibration convenience script (calibrate-eject-timing.sh) are kept in the repo
# as historical record, not deleted.
#
# Usage: windows11-setup-install.sh <target-qcow2-path> [computer-name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

TARGET_QCOW2="${1:?Usage: windows11-setup-install.sh <target-qcow2-path> [computer-name]}"
COMPUTER_NAME="${2:-WIN11PROD}"

# --- Hard gate: this script only ever builds Windows 11. There is deliberately no OS
# argument to mistype - Server 2022/2025 must never reach Setup.exe (CLAUDE.md, no
# exception). The one thing that could go wrong is someone pointing TARGET_QCOW2 at a
# path that looks like it belongs to another OS's build - guard the obvious case.
case "$(basename "$TARGET_QCOW2")" in
  *server2022*|*server2025*|*win2022*|*win2025*)
    echo "ERROR: refusing to run windows11-setup-install.sh against a target path that looks like a Server 2022/2025 disk ($TARGET_QCOW2). This script is Windows 11 only." >&2
    exit 1
    ;;
esac

if [[ ${#COMPUTER_NAME} -gt 15 ]]; then
  echo "ERROR: computer name '$COMPUTER_NAME' exceeds NetBIOS's 15-character limit" >&2
  exit 1
fi

if [[ -e "$TARGET_QCOW2" ]]; then
  echo "ERROR: $TARGET_QCOW2 already exists - refusing to overwrite. Remove it first if intentional." >&2
  exit 1
fi

# --- Configuration, overridable. W11_WINRM_TIMEOUT_SEC now covers the entire install
# (there's no separate eject-wait phase before it starts) - Phase 3.4's two NVRAM-
# boot-order confirmation runs took 14-16 minutes end to end on this host, sometimes
# slower than this session's earlier eject-based runs; 1800s leaves real margin rather
# than cutting it close.
W11_WINRM_PORT="${W11_WINRM_PORT:-15985}"
W11_WINRM_TIMEOUT_SEC="${W11_WINRM_TIMEOUT_SEC:-1800}"  # total time to wait for real desktop + WinRM after boot
W11_WINRM_RETRY_SEC="${W11_WINRM_RETRY_SEC:-15}"         # gap between WinRM auth retries (observed transient-401 pattern)
W11_ADMIN_PASSWORD="${W11_ADMIN_PASSWORD:-TestP@ssw0rd123}"

NOPROMPT_ISO="${REPO_ROOT}/image-apply/output/iso-noprompt/win11-noprompt.iso"
[[ -f "$NOPROMPT_ISO" ]] || { echo "ERROR: $NOPROMPT_ISO not found - run build-iso-noprompt.sh first" >&2; exit 1; }

TEMPLATE="${REPO_ROOT}/image-apply/autounattend-windows11-phase33.xml"
[[ -f "$TEMPLATE" ]] || { echo "ERROR: answer file template not found at $TEMPLATE" >&2; exit 1; }

RUN_ID="$(basename "$TARGET_QCOW2" .qcow2)"
WORK_DIR="${REPO_ROOT}/image-apply/output/iso-noprompt/run-${RUN_ID}"
mkdir -p "$WORK_DIR"

log "Generating answer-file ISO (ComputerName=${COMPUTER_NAME})"
sed "s|<ComputerName>[^<]*</ComputerName>|<ComputerName>${COMPUTER_NAME}</ComputerName>|" \
  "$TEMPLATE" > "${WORK_DIR}/autounattend.xml"
mkisofs -quiet -o "${WORK_DIR}/autounattend.iso" -J -r -V "AUTOUNATTEND" "${WORK_DIR}/autounattend.xml"

log "Creating 64GB target disk at ${TARGET_QCOW2}"
mkdir -p "$(dirname "$TARGET_QCOW2")"
qemu-img create -f qcow2 "$TARGET_QCOW2" 64G >/dev/null

OVMF_VARS_RUN="${WORK_DIR}/OVMF_VARS.fd"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS_RUN"

QMP_SOCK="/tmp/w11setup-${RUN_ID}.sock"
rm -f "$QMP_SOCK"

QEMU_LOG="${WORK_DIR}/qemu.log"
cleanup() {
  if [[ -n "${QEMU_PID:-}" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    log "Cleanup: qemu (pid ${QEMU_PID}) still running - forcing it down"
    kill -9 "$QEMU_PID" 2>/dev/null || true
  fi
  rm -f "$QMP_SOCK"
}
trap cleanup EXIT

# No bootindex= on any device, deliberately - see the header comment. OVMF picks the
# CD-ROM on the very first boot (the only bootable device on a blank disk) and then
# picks the disk's own newly-registered "Windows Boot Manager" NVRAM entry on every
# reboot after that, on its own.
# USB tablet device (CLAUDE.md's "Known gotcha" under QEMU/KVM/libvirt): a guest's default
# pointer is a relative PS/2 mouse, which any QMP absolute-position click (tools/qmp-click.py)
# cannot drive at all - the sibling project hit the identical problem for its own VNC/SPICE
# console and fixed it with libvirt's <input type='tablet' bus='usb'/>. Added here up front,
# on every qemu-system-x86_64 invocation this project constructs, per that same convention -
# cheap now, avoids rediscovering the gap mid-debugging session later. This script itself
# never clicks anything (fully unattended via answer files/WinRM), but the device costs
# nothing to include and means a future debugging session doesn't have to rediscover this.
log "Booting: install CD + answer-file CD + target disk (no bootindex= override), e1000 NIC on hostfwd :${W11_WINRM_PORT}"
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$OVMF_VARS_RUN" \
  -drive file="$NOPROMPT_ISO",media=cdrom,if=none,id=installcd \
  -device ide-cd,drive=installcd,bus=ide.0 \
  -drive file="${WORK_DIR}/autounattend.iso",media=cdrom,if=none,id=answercd \
  -device ide-cd,drive=answercd,bus=ide.1 \
  -drive file="$TARGET_QCOW2",if=none,id=target,format=qcow2 \
  -device ide-hd,drive=target,bus=ide.2 \
  -netdev "user,id=net0,hostfwd=tcp::${W11_WINRM_PORT}-:5985" \
  -device e1000,netdev=net0 \
  -device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0 \
  -qmp "unix:${QMP_SOCK},server,nowait" \
  -display none \
  > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!
log "qemu pid ${QEMU_PID}, QMP socket ${QMP_SOCK}, log ${QEMU_LOG}"

for i in $(seq 1 20); do
  [[ -S "$QMP_SOCK" ]] && break
  sleep 0.5
done
[[ -S "$QMP_SOCK" ]] || { echo "ERROR: QMP socket never appeared - qemu failed to start, see $QEMU_LOG" >&2; exit 1; }

# --- Wait for real WinRM connectivity, with a retry loop - this project's own Phase
# 3.3 sessions repeatedly hit a transient first-probe auth/connection failure (WinRM's
# own listener still settling from FirstLogonCommands' own Restart-Service WinRM step)
# that cleared on retry within seconds. A single-shot check would have misreported
# those as failures.
python3 -c "import winrm" 2>/dev/null || { echo "ERROR: python3's 'winrm' module (pywinrm) not found - install it with 'pip3 install pywinrm' (or 'pip3 install --user pywinrm'). This is a real project dependency, not optional." >&2; exit 1; }

log "Waiting for real WinRM connectivity on 127.0.0.1:${W11_WINRM_PORT} (up to ${W11_WINRM_TIMEOUT_SEC}s) - no eject step, Setup runs fully unattended start to finish"
DEADLINE=$(( $(date +%s) + W11_WINRM_TIMEOUT_SEC ))
CONFIRMED_HOSTNAME=""
while [[ "$(date +%s)" -lt "$DEADLINE" ]]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "ERROR: qemu (pid ${QEMU_PID}) exited unexpectedly while waiting for WinRM - see ${QEMU_LOG}" >&2
    exit 1
  fi
  CONFIRMED_HOSTNAME="$(python3 - "$W11_WINRM_PORT" "$COMPUTER_NAME" "$W11_ADMIN_PASSWORD" <<'PYEOF' 2>/dev/null || true
import sys
import winrm
port, expected_name, password = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    s = winrm.Session(f'http://127.0.0.1:{port}/wsman', auth=('Administrator', password),
                       transport='basic', server_cert_validation='ignore')
    r = s.run_cmd('hostname')
    print(r.std_out.decode().strip())
except Exception:
    pass
PYEOF
)"
  if [[ -n "$CONFIRMED_HOSTNAME" ]]; then
    break
  fi
  sleep "$W11_WINRM_RETRY_SEC"
done

if [[ -z "$CONFIRMED_HOSTNAME" ]]; then
  echo "ERROR: WinRM never confirmed within ${W11_WINRM_TIMEOUT_SEC}s - see ${QEMU_LOG} and inspect the disk. QEMU left running for debugging (pid ${QEMU_PID}); shut it down manually via QMP system_powerdown once done." >&2
  trap - EXIT  # leave the VM up for inspection rather than force-killing it
  exit 1
fi

if [[ "$CONFIRMED_HOSTNAME" != "$COMPUTER_NAME" ]]; then
  echo "WARNING: WinRM hostname '${CONFIRMED_HOSTNAME}' does not match requested ComputerName '${COMPUTER_NAME}'" >&2
fi
log "WinRM confirmed: hostname=${CONFIRMED_HOSTNAME}"

log "Shutting down gracefully via QMP system_powerdown"
python3 - "$QMP_SOCK" <<'PYEOF'
import json, socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
f = sock.makefile("rwb", buffering=0)
f.readline()
sock.sendall((json.dumps({"execute": "qmp_capabilities"}) + "\n").encode())
f.readline()
sock.sendall((json.dumps({"execute": "system_powerdown"}) + "\n").encode())
f.readline()
PYEOF

for i in $(seq 1 40); do
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 5
done
if kill -0 "$QEMU_PID" 2>/dev/null; then
  echo "WARNING: qemu (pid ${QEMU_PID}) did not exit within 200s of system_powerdown - forcing it down" >&2
else
  log "qemu exited cleanly"
fi

log "windows11-setup-install.sh complete: ${TARGET_QCOW2} (ComputerName=${CONFIRMED_HOSTNAME})"
