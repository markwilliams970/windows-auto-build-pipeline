#!/usr/bin/env bash
# EXPERIMENT ONLY - not production, not wired into build.sh or windows-pipeline.
#
# Tests whether Windows 11's Setup.exe fix (image-apply/windows11-setup-install.sh: a
# _noprompt-patched ISO removing the "press any key" UEFI keystroke race, plus a
# hand-built qemu-system-x86_64 invocation with no bootindex= override, bypassing
# Packer's QEMU builder entirely) also unblocks Windows Server 2025 media - which has
# never been tried. Only the Server-2025-side of this was previously tested, and only
# inside Packer's own builder (an explicit `-boot order=d,menu=off` qemuargs hint,
# confirmed present on the real command line but made no observable difference - see
# ../../windows-server-vm-automation/WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md Finding
# 15). That doc's own Finding 15 update explicitly flags the noprompt technique as "a
# cheap, low-risk thing to try before anything more invasive" and notes nobody has
# tried it for this exact bug - this script is that attempt.
#
# CLAUDE.md's ban on Microsoft-Windows-Setup for Server 2022/2025 is "absolute, no
# exception" for the PRODUCTION pipeline. This script deliberately violates that, as an
# explicitly authorized, isolated research spike - it lives only under
# image-apply/experiments/, is not referenced anywhere in build.sh/windows-pipeline, and
# does not modify or weaken the hard gates in image-apply/build-iso-noprompt.sh or
# image-apply/windows11-setup-install.sh. If this experiment succeeds, the intended
# beneficiary is the SIBLING project's own Packer+autounattend Server 2025 support
# (Finding 15) - not adoption into this project's own production pipeline, which
# already has a working, proven Server 2025 path via full offline-apply.
#
# Deliberately minimal, matching Windows 11's own Phase 3.3 scoping: plain ide-hd/
# ide-cd/e1000 (Windows' inbox drivers, zero injection), no virtio, no roles. This
# isolates the one variable actually in question - does Setup.exe get past the boot
# hang at all - rather than also re-proving driver injection, which Server 2022/2025
# already have a completely different, already-proven mechanism for (offline hivex,
# this project's own production path).
#
# A negative result (still hangs/times out) is a real, useful, recordable finding, not
# a failure of the experiment - see Finding 15's own speculation that the deeper cause
# might be OVMF's EFI-shell-first boot-device ordering, which noprompt alone would not
# fix. Record whatever happens in a findings doc afterward either way.
#
# Usage: server2025-noprompt-setup-experiment.sh <target-qcow2-path> [computer-name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

TARGET_QCOW2="${1:?Usage: server2025-noprompt-setup-experiment.sh <target-qcow2-path> [computer-name]}"
COMPUTER_NAME="${2:-WIN2025EXP}"

if [[ ${#COMPUTER_NAME} -gt 15 ]]; then
  echo "ERROR: computer name '$COMPUTER_NAME' exceeds NetBIOS's 15-character limit" >&2
  exit 1
fi

if [[ -e "$TARGET_QCOW2" ]]; then
  echo "ERROR: $TARGET_QCOW2 already exists - refusing to overwrite. Remove it first if intentional." >&2
  exit 1
fi

S25_WINRM_PORT="${S25_WINRM_PORT:-15986}"
S25_WINRM_TIMEOUT_SEC="${S25_WINRM_TIMEOUT_SEC:-2400}"  # Server Standard w/ Desktop Experience is a larger image than Win11; leave real margin
S25_WINRM_RETRY_SEC="${S25_WINRM_RETRY_SEC:-15}"
S25_ADMIN_PASSWORD="${S25_ADMIN_PASSWORD:-TestP@ssw0rd123}"

NOPROMPT_ISO="${REPO_ROOT}/image-apply/output/experiments/iso-noprompt-server2025/server2025-noprompt.iso"
[[ -f "$NOPROMPT_ISO" ]] || { echo "ERROR: $NOPROMPT_ISO not found - run build-iso-noprompt-server2025.sh first" >&2; exit 1; }

TEMPLATE="${SCRIPT_DIR}/autounattend-server2025-noprompt-experiment.xml"
[[ -f "$TEMPLATE" ]] || { echo "ERROR: answer file template not found at $TEMPLATE" >&2; exit 1; }

RUN_ID="$(basename "$TARGET_QCOW2" .qcow2)"
WORK_DIR="${REPO_ROOT}/image-apply/output/experiments/run-${RUN_ID}"
mkdir -p "$WORK_DIR"

log "Generating answer-file ISO (ComputerName=${COMPUTER_NAME})"
sed "s|<ComputerName>[^<]*</ComputerName>|<ComputerName>${COMPUTER_NAME}</ComputerName>|" \
  "$TEMPLATE" > "${WORK_DIR}/autounattend.xml"
mkisofs -quiet -o "${WORK_DIR}/autounattend.iso" -J -r -V "AUTOUNATTEND" "${WORK_DIR}/autounattend.xml"

log "Creating 40GB target disk at ${TARGET_QCOW2}"
mkdir -p "$(dirname "$TARGET_QCOW2")"
qemu-img create -f qcow2 "$TARGET_QCOW2" 40G >/dev/null

OVMF_VARS_RUN="${WORK_DIR}/OVMF_VARS.fd"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS_RUN"

QMP_SOCK="/tmp/s25exp-${RUN_ID}.sock"
rm -f "$QMP_SOCK"

QEMU_LOG="${WORK_DIR}/qemu.log"
cleanup() {
  # $? captured first - see CLAUDE.md's "bash trap ... EXIT" standard (Phase 4 finding:
  # a trap's own last command's exit status silently becomes the whole script's exit
  # status otherwise). Every intentional exit path below already disarms this trap.
  local exit_code=$?
  if [[ -n "${QEMU_PID:-}" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    log "Cleanup: qemu (pid ${QEMU_PID}) still running - forcing it down"
    kill -9 "$QEMU_PID" 2>/dev/null || true
  fi
  rm -f "$QMP_SOCK"
  exit "$exit_code"
}
trap cleanup EXIT

log "Booting: install CD (noprompt) + answer-file CD + target disk, no bootindex= override, e1000 NIC on hostfwd :${S25_WINRM_PORT}"
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
  -netdev "user,id=net0,hostfwd=tcp::${S25_WINRM_PORT}-:5985" \
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

python3 -c "import winrm" 2>/dev/null || { echo "ERROR: python3's 'winrm' module (pywinrm) not found - install it with 'pip3 install pywinrm'" >&2; exit 1; }

log "Waiting for real WinRM connectivity on 127.0.0.1:${S25_WINRM_PORT} (up to ${S25_WINRM_TIMEOUT_SEC}s)"
DEADLINE=$(( $(date +%s) + S25_WINRM_TIMEOUT_SEC ))
CONFIRMED_HOSTNAME=""
while [[ "$(date +%s)" -lt "$DEADLINE" ]]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "ERROR: qemu (pid ${QEMU_PID}) exited unexpectedly while waiting for WinRM - see ${QEMU_LOG}" >&2
    exit 1
  fi
  CONFIRMED_HOSTNAME="$(python3 - "$S25_WINRM_PORT" "$COMPUTER_NAME" "$S25_ADMIN_PASSWORD" <<'PYEOF' 2>/dev/null || true
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
  sleep "$S25_WINRM_RETRY_SEC"
done

if [[ -z "$CONFIRMED_HOSTNAME" ]]; then
  echo "ERROR: WinRM never confirmed within ${S25_WINRM_TIMEOUT_SEC}s - see ${QEMU_LOG} and inspect via tools/qmp-screenshot.py against ${QMP_SOCK}. QEMU left running for debugging (pid ${QEMU_PID}); shut it down manually via QMP system_powerdown once done." >&2
  trap - EXIT
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

log "server2025-noprompt-setup-experiment.sh complete: ${TARGET_QCOW2} (ComputerName=${CONFIRMED_HOSTNAME})"
