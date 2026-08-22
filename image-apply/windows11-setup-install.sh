#!/usr/bin/env bash
# Windows 11 ONLY - the Setup.exe-driven install path that replaces the fully-offline
# apply/bootable/specialize sequence for Windows 11 specifically (partition-disk.sh /
# apply-image.sh / make-bootable.sh / apply-unattend.sh stay unchanged and untouched -
# they remain Server 2022/2025's own proven path; this script never calls them and
# they never call this). Server 2022/2025 stay fully banned from Microsoft-Windows-
# Setup, no exception (CLAUDE.md) - this script hard-gates on windows11 and refuses
# to run against anything else.
#
# One unattended qemu-system-x86_64 session takes a blank disk through: Setup.exe
# partitioning + image install (windowsPE pass) -> a QMP-scripted eject of both CD-ROMs
# at the calibrated safe point -> first reboot landing cleanly on the disk's own Boot
# Manager entry -> specialize/oobeSystem passes -> a second reboot into a real desktop
# -> WinRM confirmed live. Transcribed directly from PHASE3_ENGINEERING_LOG.md's Phase
# 3.3 attempts 1-3 (three independent clean runs, zero BSODs) - not reconstructed from
# memory. See WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md Phase 3 for the full design.
#
# The eject-trigger timing is NOT hardcoded - see the W11_EJECT_* env vars below.
# Defaults are calibrated from this project's own three Phase 3.3 runs on this host;
# a different host (different storage/CPU throughput) may need different values - use
# image-apply/calibrate-eject-timing.sh to measure real numbers for a new host rather
# than guessing.
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

# --- Configuration, all overridable - see the header comment above. Defaults are
# PHASE3_ENGINEERING_LOG.md Phase 3.3's own observed timing on this host: the
# "Installing Windows 11 / N% complete" blue screen was consistently confirmed present
# from ~5:00 through ~7:30 elapsed, with the proven-safe eject point (75-77% complete)
# observed at roughly 5:48-6:18 elapsed and reboot never beginning before ~7:48 across
# 3 manual runs. IMPORTANT, learned the hard way (Phase 3.4's own first automated
# validation run): a 300s base timeout - chosen as "safely before 75%" without
# realizing "safely before the proven-safe point" is the wrong direction of safety -
# caused a real "Windows 11 installation has failed" error, because Setup hadn't yet
# finished reading everything it needed from the install media at that point. The
# risk is asymmetric: ejecting too EARLY reliably breaks the install; ejecting
# anywhere from the proven-safe point up to just before the real reboot is fine. The
# default below is deliberately biased toward the LATER end of the observed-safe
# range, not the middle, for exactly this reason. Different hosts still need their own
# calibration (calibrate-eject-timing.sh) rather than trusting this default blindly.
W11_EJECT_BASE_TIMEOUT_SEC="${W11_EJECT_BASE_TIMEOUT_SEC:-360}"   # wait this long before polling starts
W11_EJECT_POLL_INTERVAL_SEC="${W11_EJECT_POLL_INTERVAL_SEC:-15}"  # how often to sample during the poll window
W11_EJECT_POLL_CEILING_SEC="${W11_EJECT_POLL_CEILING_SEC:-480}"   # hard cap - eject regardless once reached
W11_EJECT_PIXEL_X="${W11_EJECT_PIXEL_X:-640}"                     # sample point: mid-screen, clear of any text/UI
W11_EJECT_PIXEL_Y="${W11_EJECT_PIXEL_Y:-400}"
# Windows Setup's own blue background color (confirmed via tools/qmp-pixel.py against
# three independent real screenshots - PHASE3_ENGINEERING_LOG.md Phase 3.4).
W11_INSTALLING_RGB="${W11_INSTALLING_RGB:-0 90 158}"

W11_WINRM_PORT="${W11_WINRM_PORT:-15985}"
W11_WINRM_TIMEOUT_SEC="${W11_WINRM_TIMEOUT_SEC:-1200}"  # total time to wait for real desktop + WinRM after eject
W11_WINRM_RETRY_SEC="${W11_WINRM_RETRY_SEC:-15}"         # gap between WinRM auth retries (Phase 3.3's own observed transient-401 pattern)
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

log "Booting: install CD (bootindex=1) + answer-file CD + target disk (bootindex=2), e1000 NIC on hostfwd :${W11_WINRM_PORT}"
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$OVMF_VARS_RUN" \
  -drive file="$NOPROMPT_ISO",media=cdrom,if=none,id=installcd \
  -device ide-cd,drive=installcd,bus=ide.0,bootindex=1 \
  -drive file="${WORK_DIR}/autounattend.iso",media=cdrom,if=none,id=answercd \
  -device ide-cd,drive=answercd,bus=ide.1 \
  -drive file="$TARGET_QCOW2",if=none,id=target,format=qcow2 \
  -device ide-hd,drive=target,bus=ide.2,bootindex=2 \
  -netdev "user,id=net0,hostfwd=tcp::${W11_WINRM_PORT}-:5985" \
  -device e1000,netdev=net0 \
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

# --- Eject trigger: base timeout (the real, calibrated signal), then a bounded poll
# window that samples the known Windows-Setup-blue pixel to (a) confirm we're not
# ejecting into an already-black/rebooted screen and (b) still eject at the ceiling as
# a best-effort fallback rather than never ejecting at all. This can't distinguish 40%
# from 75% from 90% complete - only "still on the blue Installing screen" from "not" -
# so the base timeout, calibrated per-host via calibrate-eject-timing.sh, is what
# actually targets the proven-safe ~75-77% neighborhood; the poll window is a
# confirmation/safety net around it, not an independent progress reader.
log "Waiting ${W11_EJECT_BASE_TIMEOUT_SEC}s (base timeout) before polling for the safe eject window"
sleep "$W11_EJECT_BASE_TIMEOUT_SEC"

ELAPSED="$W11_EJECT_BASE_TIMEOUT_SEC"
CONFIRMED_BLUE=0
while [[ "$ELAPSED" -le "$W11_EJECT_POLL_CEILING_SEC" ]]; do
  PIXEL="$(python3 "${REPO_ROOT}/tools/qmp-pixel.py" --socket "$QMP_SOCK" --x "$W11_EJECT_PIXEL_X" --y "$W11_EJECT_PIXEL_Y" 2>/dev/null || echo "")"
  if [[ "$PIXEL" == "$W11_INSTALLING_RGB" ]]; then
    log "Confirmed still on Setup's blue Installing screen at ${ELAPSED}s elapsed (pixel=${PIXEL}) - ejecting now"
    CONFIRMED_BLUE=1
    break
  fi
  log "Pixel at ${ELAPSED}s elapsed: '${PIXEL}' (not the expected Installing-screen blue yet/anymore) - continuing to poll"
  sleep "$W11_EJECT_POLL_INTERVAL_SEC"
  ELAPSED=$(( ELAPSED + W11_EJECT_POLL_INTERVAL_SEC ))
done

if [[ "$CONFIRMED_BLUE" -eq 0 ]]; then
  echo "WARNING: never confirmed the blue Installing screen within the poll window (base=${W11_EJECT_BASE_TIMEOUT_SEC}s, ceiling=${W11_EJECT_POLL_CEILING_SEC}s) - ejecting anyway as best-effort. This host's timing may not match the calibrated defaults; consider running calibrate-eject-timing.sh and re-tuning W11_EJECT_* env vars. Inspect ${WORK_DIR} if this build fails." >&2
fi

python3 "${REPO_ROOT}/tools/qmp-eject.py" --socket "$QMP_SOCK" --device installcd --device answercd
log "Ejected install + answer-file media"

# --- Wait for real WinRM connectivity, with a retry loop - Phase 3.3 attempts 2 and 3
# both hit a transient first-probe auth/connection failure (WinRM's own listener still
# settling from FirstLogonCommands' own Restart-Service WinRM step) that cleared on
# retry within seconds. A single-shot check would have misreported those as failures.
python3 -c "import winrm" 2>/dev/null || { echo "ERROR: python3's 'winrm' module (pywinrm) not found - install it with 'pip3 install pywinrm' (or 'pip3 install --user pywinrm'). This is a real project dependency, not optional." >&2; exit 1; }

log "Waiting for real WinRM connectivity on 127.0.0.1:${W11_WINRM_PORT} (up to ${W11_WINRM_TIMEOUT_SEC}s)"
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
