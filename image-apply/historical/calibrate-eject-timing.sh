#!/usr/bin/env bash
# RETIRED - kept as historical record only, no longer called by anything in this
# project. windows11-setup-install.sh dropped the entire eject-timing mechanism this
# script existed to calibrate, in favor of removing the static bootindex= override
# and letting OVMF's own NVRAM boot order handle disk-vs-CD selection - confirmed
# working twice independently (project_documentation/PHASE3_ENGINEERING_LOG.md, Phase 3.4's "design
# reconsideration" entry). There is nothing left for this script to calibrate: no
# eject happens anymore, so no eject timing needs measuring. Left in the repo rather
# than deleted per this project's own standard of keeping negative-branch/superseded
# work as a documented record (same treatment as audit-mode-sysprep.sh) - the content
# below is unmodified from when it was live.
#
# Windows 11 ONLY - convenience script to measure a real host's own Setup.exe install
# timing, so windows11-setup-install.sh's W11_EJECT_* env vars can be tuned correctly
# instead of guessing. Different hosts (storage/CPU throughput) run the install at
# different real-world speeds; the committed defaults are only calibrated for the host
# this project was developed on.
#
# What it does: boots a throwaway disk through Setup.exe's windowsPE pass only (no
# specialize/oobeSystem - reuses the already-proven minimal Phase 3.2 answer file,
# image-apply/autounattend-windows11-phase32.xml), and polls the same blue-background
# pixel windows11-setup-install.sh itself samples (tools/qmp-pixel.py) to find:
#   T0 - when Setup's blue "Installing Windows 11" screen first appears
#   T1 - when that screen stops being blue (Setup's own first reboot beginning)
# It deliberately does NOT eject the install media - this run is left to hit the
# CD-ROM-reboot-fallback on purpose (Phase 3.2 attempt 1's known behavior), since only
# the T0/T1 timing matters here, not a successful install. The VM is killed the moment
# T1 is observed - no need to let the botched reboot play out further.
#
# All throwaway artifacts (disk, OVMF vars, answer-file ISO, QMP socket, work dir) are
# deleted when this script exits, success or failure - nothing is left behind to
# accumulate, per this project's own disk-hygiene standard (CLAUDE.md).
#
# Usage: calibrate-eject-timing.sh [poll-interval-sec]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Moved to image-apply/historical/ (retired script, kept as historical record) - one
# level deeper than the other image-apply/*.sh scripts, so lib/common.sh is now a
# parent-relative path, not a sibling.
source "${SCRIPT_DIR}/../lib/common.sh"

POLL_INTERVAL_SEC="${1:-10}"
CEILING_SEC="${CALIBRATE_CEILING_SEC:-1200}"  # give up and report failure if never observed both T0 and T1

NOPROMPT_ISO="${REPO_ROOT}/image-apply/output/iso-noprompt/win11-noprompt.iso"
[[ -f "$NOPROMPT_ISO" ]] || { echo "ERROR: $NOPROMPT_ISO not found - run build-iso-noprompt.sh first" >&2; exit 1; }

TEMPLATE="${REPO_ROOT}/image-apply/autounattend-windows11-phase32.xml"
[[ -f "$TEMPLATE" ]] || { echo "ERROR: minimal answer-file template not found at $TEMPLATE" >&2; exit 1; }

PIXEL_X="${W11_EJECT_PIXEL_X:-640}"
PIXEL_Y="${W11_EJECT_PIXEL_Y:-400}"
INSTALLING_RGB="${W11_INSTALLING_RGB:-0 90 158}"

WORK_DIR="$(mktemp -d "${REPO_ROOT}/image-apply/output/calibrate-XXXXXX")"
TARGET_QCOW2="${WORK_DIR}/target.qcow2"
OVMF_VARS_RUN="${WORK_DIR}/OVMF_VARS.fd"
ANSWER_ISO="${WORK_DIR}/autounattend.iso"
QMP_SOCK="/tmp/w11calib-$$.sock"
QEMU_LOG="${WORK_DIR}/qemu.log"

QEMU_PID=""
cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill -9 "$QEMU_PID" 2>/dev/null || true
  fi
  rm -f "$QMP_SOCK"
  rm -rf "$WORK_DIR"
  log "Cleaned up all throwaway calibration artifacts (${WORK_DIR}, ${QMP_SOCK})"
}
trap cleanup EXIT

log "Building throwaway 64GB disk and minimal answer-file ISO"
qemu-img create -f qcow2 "$TARGET_QCOW2" 64G >/dev/null
# Setup.exe only auto-detects an answer file named exactly autounattend.xml at the
# media root - mkisofs must be pointed at a file with that exact name, not the
# template's own on-disk name, or Setup silently falls back to its interactive
# language-selection screen with no error at all (caught the hard way while testing
# this script - see project_documentation/PHASE3_ENGINEERING_LOG.md Phase 3.4).
cp "$TEMPLATE" "${WORK_DIR}/autounattend.xml"
mkisofs -quiet -o "$ANSWER_ISO" -J -r -V "AUTOUNATTEND" "${WORK_DIR}/autounattend.xml"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS_RUN"

log "Booting (windowsPE pass only - no eject, this run is expected to eventually hit the CD-ROM reboot fallback and that's fine)"
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$OVMF_VARS_RUN" \
  -drive file="$NOPROMPT_ISO",media=cdrom,if=none,id=installcd \
  -device ide-cd,drive=installcd,bus=ide.0,bootindex=1 \
  -drive file="$ANSWER_ISO",media=cdrom,if=none,id=answercd \
  -device ide-cd,drive=answercd,bus=ide.1 \
  -drive file="$TARGET_QCOW2",if=none,id=target,format=qcow2 \
  -device ide-hd,drive=target,bus=ide.2,bootindex=2 \
  -qmp "unix:${QMP_SOCK},server,nowait" \
  -display none \
  > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!
log "qemu pid ${QEMU_PID}"

for i in $(seq 1 20); do
  [[ -S "$QMP_SOCK" ]] && break
  sleep 0.5
done
[[ -S "$QMP_SOCK" ]] || { echo "ERROR: QMP socket never appeared - see $QEMU_LOG" >&2; exit 1; }

BOOT_START="$(date +%s)"
T0=""
T1=""
ELAPSED=0
log "Polling pixel (${PIXEL_X},${PIXEL_Y}) every ${POLL_INTERVAL_SEC}s, looking for Setup's blue Installing screen (expected ~${INSTALLING_RGB})"
while [[ "$ELAPSED" -le "$CEILING_SEC" ]]; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "ERROR: qemu exited unexpectedly at ${ELAPSED}s - see $QEMU_LOG" >&2
    exit 1
  fi
  PIXEL="$(python3 "${REPO_ROOT}/tools/qmp-pixel.py" --socket "$QMP_SOCK" --x "$PIXEL_X" --y "$PIXEL_Y" 2>/dev/null || echo "")"
  IS_BLUE=0
  [[ "$PIXEL" == "$INSTALLING_RGB" ]] && IS_BLUE=1

  if [[ -z "$T0" && "$IS_BLUE" -eq 1 ]]; then
    T0="$ELAPSED"
    log "T0 (blue Installing screen first seen): ${T0}s elapsed"
  elif [[ -n "$T0" && -z "$T1" && "$IS_BLUE" -eq 0 ]]; then
    T1="$ELAPSED"
    log "T1 (screen no longer blue - Setup's own reboot beginning): ${T1}s elapsed"
    break
  fi

  sleep "$POLL_INTERVAL_SEC"
  ELAPSED=$(( $(date +%s) - BOOT_START ))
done

if [[ -z "$T0" || -z "$T1" ]]; then
  echo "ERROR: did not observe both T0 and T1 within ${CEILING_SEC}s (T0=${T0:-unset} T1=${T1:-unset}). Check ${QEMU_LOG} and this host's real install speed - the ceiling (CALIBRATE_CEILING_SEC) may need raising." >&2
  exit 1
fi

# Recommendation: target ~85% of the way through the observed blue-screen window for
# the base timeout, leaving the poll window run from there up to 30s before the
# observed T1 as a safety margin. The risk here is asymmetric, learned the hard way
# during Phase 3.4's own first automated validation run: a base timeout chosen too
# early (that run used a fixed 300s, and a naive 70%-of-duration formula tried here
# against this exact run's own T0/T1 would have recommended an only-slightly-later
# 316s) caused a real "Windows 11 installation has failed" error, because Setup
# hadn't yet finished reading everything it needed from the install media. Ejecting
# too early reliably breaks the install; ejecting anywhere from the real proven-safe
# point up to just before the actual reboot is fine - so this recommendation
# deliberately biases late (85%, not 70%) rather than aiming for the middle.
DURATION=$(( T1 - T0 ))
RECOMMENDED_BASE=$(( T0 + (DURATION * 85 / 100) ))
RECOMMENDED_CEILING=$(( T1 - 20 ))
if [[ "$RECOMMENDED_CEILING" -le "$RECOMMENDED_BASE" ]]; then
  RECOMMENDED_CEILING=$(( RECOMMENDED_BASE + POLL_INTERVAL_SEC * 2 ))
fi

cat <<EOF

=== Calibration result ===
T0 (blue Installing screen first seen): ${T0}s
T1 (screen changed - Setup's own reboot begins): ${T1}s
Observed blue-screen duration: ${DURATION}s

Recommended env vars for windows11-setup-install.sh on this host:
  export W11_EJECT_BASE_TIMEOUT_SEC=${RECOMMENDED_BASE}
  export W11_EJECT_POLL_CEILING_SEC=${RECOMMENDED_CEILING}

These deliberately bias toward the LATER end of the observed blue-screen window (85% of
its duration) rather than the middle - ejecting too early reliably breaks the install,
ejecting late (up to just before the real reboot) does not, so the asymmetry favors
waiting longer. Not a guarantee, since the true safe-to-eject percentage isn't directly
observable without OCR (see
windows11-setup-install.sh's own header comment on this limitation). Run a real build
with these values and confirm it lands cleanly before trusting them for production use.
EOF
