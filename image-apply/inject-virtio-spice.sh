#!/usr/bin/env bash
# Phase 3A (WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md): live-installs and confirms vioscsi/netkvm/
# QXL+SPICE on an already-built, already-WinRM-reachable disk - written OS-agnostic (takes
# server2019/server2022/server2025/windows11 like every other image-apply/*.sh script). Confirmed
# via 2 independent clean runs per OS (6 total, as of Server 2022/2025/Windows 11 - Server 2019 not
# yet exercised, see WINDOWS_SERVER_2019_IMPLEMENTATION_PLAN.md Phase E): Windows 11 exercises all
# three capabilities (storage, NIC, SPICE); Server 2022/2025/2019 exercise two of three (storage,
# SPICE) by design, not gap - NIC swap is deliberately scoped out for them (see below):
#
#   - Storage swap (vioscsi): runs for every OS, per explicit direction (2026-08-23) to exercise
#     `vioscsi`/virtio-scsi on Server 2022/2025 too - matching both Windows 11's own choice in this
#     plan and the user's own real, working `win2022-dc` libvirt VM (`virsh dumpxml` confirms it
#     uses `virtio-scsi`, not `virtio-blk-pci`). Server 2022/2025 enter this script already on
#     `virtio-blk-pci` (via the separate, already-proven offline-hivex mechanism,
#     make-bootable.sh/apply-unattend.sh, untouched by this script) - vioscsi has never been staged
#     there before, so Stage 1 stages+live-verifies it fresh, same as Windows 11's own e1000/ide-hd
#     starting point, just swapping FROM a different (already-virtio) starting device.
#   - NIC (netkvm): Windows 11 ONLY exercises the live-install-then-swap path (still on Setup.exe's
#     own `e1000`). Server 2022/2025/2019 already have `netkvm`/`virtio-net-pci` working from their
#     own first boot (same offline-hivex mechanism as storage, `net_device = "virtio-net"` in
#     packer/boot-and-provision.pkr.hcl) - there is nothing to swap, so this script only confirms
#     it's already Up rather than staging/swapping anything, and never relocates its placement.
#   - SPICE (QXL + spice-vdagent): runs identically for every OS - this is a real, universal gap
#     (neither Windows 11 nor Server 2022/2025 has it before this script runs; confirmed even
#     `win2022-dc`'s own hand-built libvirt config has no SPICE graphics element at all, QXL video
#     but VNC-only).
#
# Fourth hard-won lesson, added 2026-08-23 after a real virsh-registered Server 2022 boot: Start
# Menu (and other XAML/Fluent-UI shell components) crashed immediately with STATUS_STACK_BUFFER_
# OVERRUN in Windows.UI.Xaml.dll - root-caused via live WinRM event-log inspection to
# spice-guest-tools' own bundled QXL driver (classic "qxl", DriverVer 09/22/2015, no real WDDM/
# Direct3D support - matches a long-open Red Hat RFE, bugzilla.redhat.com/895356, asking for exactly
# this to be fixed). Explorer/plain Win32 apps worked fine (they don't need XAML composition); only
# Fluent-UI surfaces broke. Fix: virtio-win's own "qxldod" package (Red Hat's real, WHQL-signed WDDM
# driver, already sitting in the same virtio-win ISO this script already mounts for vioscsi/netkvm)
# targets the identical PCI hardware ID as spice-guest-tools' classic driver
# (PCI\VEN_1B36&DEV_0100&SUBSYS_11001AF4) and declares a better (lower) FeatureScore (F9 vs FC) -
# Windows' own documented driver-ranking rule means simply staging both and letting the real device
# bind deterministically prefers qxldod, no forced uninstall of the classic one needed.
# spice-guest-tools still runs unchanged (spice-vdagent/vdservice has no better source) - only the
# competing, better display driver is added alongside it. Confirmed directly against a real running
# reference VM (not just theory): the user's own long-used windows11vm-t14 already runs this exact
# qxldod build (Driver Date 11/20/2020, Version 10.0.0.21000) with a working Start Menu.
#
# Three hard-won lessons this script exists to encode, not re-derive (WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md
# Findings 3A-1, 3A-2, 3A-3):
#   1. A driver must be live-PnP-installed against an actually-present device (Get-PnpDevice
#      Status: OK), not just staged into the driver store via `pnputil /add-driver` - staging
#      alone does not register the boot-critical DriverDatabase entry a storage/NIC swap needs.
#   2. Once a device's PCI placement works, never relocate it - only ever add an explicit
#      pcie-root-port for a genuinely new device being introduced. Every already-primary device
#      (storage always; NIC on Server 2022/2025) stays on its existing placement untouched
#      throughout this script - only Windows 11's NIC swap introduces a new device and gets an
#      explicit pcie-root-port, the fix that resolved a real, confirmed firmware-level hang.
#   3. A Stage 1 "verify" device isn't a trustworthy stand-in for Stage 2's real primary device
#      unless their PCI topology is byte-identical - a bare (driveless) virtio-scsi-pci verify
#      controller negotiated a DIFFERENT PCI hardware ID (modern, DEV_1048) than the same
#      controller once it had a real backing drive (legacy/transitional, DEV_1004), and Stage 2
#      needed the latter. Rather than assume which specific factor causes the ID to differ (drive
#      presence and explicit-vs-implicit bus placement were both plausible, neither confirmed),
#      every verify device in this script now matches its Stage 2 counterpart's PCI placement
#      exactly (same root port addr/chassis/port, and a real backing drive for storage) - whatever
#      QEMU negotiates, it is then guaranteed identical in both stages regardless of the mechanism.
#
# Two-stage design: Stage 1 boots the disk on its current, unchanged primary devices, attaches
# driver sources and live "verify" hardware that isn't yet primary (storage, every OS; NIC,
# Windows 11 only), stages+verifies each driver, and installs SPICE guest tools. Stage 2 boots
# with the real, final device model and confirms everything actually works together. Ends with a
# graceful shutdown - the disk is left powered off, ready for real use, matching every other
# script in this project's own convention.
#
# Usage: inject-virtio-spice.sh <server2019|server2022|server2025|windows11> <target-qcow2-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OS="${1:?Usage: inject-virtio-spice.sh <server2019|server2022|server2025|windows11> <target-qcow2-path>}"
TARGET_QCOW2="${2:?Usage: inject-virtio-spice.sh <server2019|server2022|server2025|windows11> <target-qcow2-path>}"
validate_os "$OS"
[[ -f "$TARGET_QCOW2" ]] || { echo "ERROR: $TARGET_QCOW2 not found - build it first" >&2; exit 1; }

DRIVER_SUBFOLDER="$(os_driver_subfolder "$OS")"

# QXL's proper WDDM driver (qxldod, Red Hat's "QXL Display Only Driver") ships in virtio-win under
# its own OS-folder set that stops at 2k19/w10 - no 2k22/2k25/w11 folder names exist even though
# vioscsi/NetKVM have them. Confirmed (2026-08-23) this isn't a real gap: qxldod.inf's own
# [Manufacturer] section targets NTamd64.6.2 (Windows 8/Server 2012 and later, generic - no
# per-version decoration above that), and the 2k16/2k19/w10 folders are byte-identical
# (sha256-verified) - so 2k19/w10 is simply the newest available build, safe to use unmodified for
# every target OS here. See the header comment below for why this driver is needed at all.
QXLDOD_SUBFOLDER="w10"
[[ "$OS" != "windows11" ]] && QXLDOD_SUBFOLDER="2k19"

ADMIN_PASSWORD="${ADMIN_PASSWORD:-TestP@ssw0rd123}"
WINRM_PORT="${WINRM_PORT:-15985}"
WINRM_TIMEOUT_SEC="${WINRM_TIMEOUT_SEC:-600}"
WINRM_RETRY_SEC="${WINRM_RETRY_SEC:-15}"
SPICE_PORT="${SPICE_PORT:-5902}"
VNC_DISPLAY="${VNC_DISPLAY:-1}"

SPICE_TOOLS_EXE="${ISO_CACHE_DIR}/spice-guest-tools-latest.exe"
[[ -f "$SPICE_TOOLS_EXE" ]] || { echo "ERROR: $SPICE_TOOLS_EXE not found - download it from https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe and cache it under ${ISO_CACHE_DIR}/ first (see WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md)" >&2; exit 1; }
[[ -f "$VIRTIO_WIN_ISO" ]] || { echo "ERROR: $VIRTIO_WIN_ISO not found" >&2; exit 1; }

RUN_ID="$(basename "$TARGET_QCOW2" .qcow2)"
WORK_DIR="${REPO_ROOT}/image-apply/output/virtio-spice-work/${RUN_ID}"
mkdir -p "$WORK_DIR"

# Small delivery ISO for spice-guest-tools, matching this project's existing pattern of
# delivering files to a guest via a mounted ISO rather than WinRM file transfer.
SPICE_TOOLS_ISO="${WORK_DIR}/spice-tools.iso"
if [[ ! -f "$SPICE_TOOLS_ISO" ]]; then
  SPICE_SRC_DIR="${WORK_DIR}/spice-tools-src"
  mkdir -p "$SPICE_SRC_DIR"
  cp "$SPICE_TOOLS_EXE" "$SPICE_SRC_DIR/"
  mkisofs -quiet -o "$SPICE_TOOLS_ISO" -J -r -V "SPICETOOLS" "$SPICE_SRC_DIR"
fi

OVMF_VARS_RUN="${WORK_DIR}/OVMF_VARS.fd"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS_RUN"

# --- WinRM/QMP helpers, matching this project's own established patterns (windows11-setup-install.sh) --

# pywinrm's run_ps() (called by both functions below) base64-encodes the script as UTF-16LE and
# sends it as a single WinRS command line: `powershell -encodedcommand <base64>`. WinRS has a
# real, hard ceiling on that command line's length - confirmed the hard way (2026-08-25): a
# ~3050-char PS script (well under PowerShell's own 32KB script-size sanity, and under
# CreateProcess's separate 32767-char limit) failed outright with "The command line is too
# long" at an encoded length of ~8170 chars. The exact documented WinRS ceiling isn't confirmed
# (plausibly the classic 8191-char cmd.exe command-line limit, given how close the failure was
# to it, but not verified against a primary source) - so this guard uses 7800 as a conservative,
# deterministic budget with real margin below the observed failure point, checked BEFORE ever
# contacting the guest (a qemu boot cycle is 10+ minutes; this check is instant), rather than
# letting an oversized payload fail late and cryptically after a full boot. If this guard ever
# fires: don't raise the budget - shrink the payload. The actual fix both times this has come up
# is removing PS-side comments (which cost real wire bytes for zero functional value - move the
# explanation to a bash comment above the winrm_ps call instead, which costs nothing over the
# wire) or splitting one call into two smaller ones.
assert_winrm_ps_budget() {
  local ps_script="$1"
  local char_count=${#ps_script}
  local b64_len=$(( ((char_count * 2) + 2) / 3 * 4 ))
  local total_len=$(( b64_len + 28 ))  # 28 = strlen("powershell -encodedcommand ")
  local safe_limit=7800
  if (( total_len > safe_limit )); then
    echo "ERROR: winrm_ps payload too large (${char_count} PS chars -> ~${total_len} encoded WinRS command chars, safe budget ${safe_limit}) - shrink the payload (move PS-side comments to bash comments above the call, or split into two calls) rather than raising this limit; see this function's own header comment for the full story." >&2
    exit 1
  fi
}

winrm_ps() {
  assert_winrm_ps_budget "$1"
  python3 - "$WINRM_PORT" "$ADMIN_PASSWORD" "$1" <<'PYEOF'
import sys, winrm
port, password, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
s = winrm.Session(f'http://127.0.0.1:{port}/wsman', auth=('Administrator', password),
                   transport='basic', server_cert_validation='ignore',
                   operation_timeout_sec=300, read_timeout_sec=330)
r = s.run_ps(cmd)
sys.stdout.buffer.write(r.std_out)
sys.stderr.buffer.write(r.std_err)
sys.exit(r.status_code)
PYEOF
}

winrm_ps_out() {
  # Same as winrm_ps but only echoes stdout to the caller (for capturing a value), still fails loud.
  assert_winrm_ps_budget "$1"
  python3 - "$WINRM_PORT" "$ADMIN_PASSWORD" "$1" <<'PYEOF'
import sys, winrm
port, password, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
s = winrm.Session(f'http://127.0.0.1:{port}/wsman', auth=('Administrator', password),
                   transport='basic', server_cert_validation='ignore',
                   operation_timeout_sec=300, read_timeout_sec=330)
r = s.run_ps(cmd)
if r.status_code != 0:
    sys.stderr.buffer.write(r.std_err)
    sys.exit(r.status_code)
sys.stdout.buffer.write(r.std_out)
PYEOF
}

wait_for_winrm() {
  # $1: qemu pid to watch - fail fast if it has already exited, rather than waiting out the
  # full timeout blindly (matches windows11-setup-install.sh's own established pattern; this
  # script's own first end-to-end run hit exactly this gap - a qemu that died in the first
  # second still burned the full 600s timeout before this fix).
  local qemu_pid="$1"
  local qemu_log="$2"
  log "Waiting for WinRM on 127.0.0.1:${WINRM_PORT} (up to ${WINRM_TIMEOUT_SEC}s) - transient first-probe failures are expected and retried (PHASE3_ENGINEERING_LOG.md Phase 3.3)"
  local deadline=$(( $(date +%s) + WINRM_TIMEOUT_SEC ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      echo "ERROR: qemu (pid ${qemu_pid}) exited unexpectedly while waiting for WinRM - see ${qemu_log}" >&2
      return 1
    fi
    if winrm_ps 'hostname' >/dev/null 2>&1; then
      log "WinRM confirmed"
      return 0
    fi
    sleep "$WINRM_RETRY_SEC"
  done
  echo "ERROR: WinRM never confirmed within ${WINRM_TIMEOUT_SEC}s" >&2
  return 1
}

qmp_graceful_shutdown() {
  local sock="$1" pid="$2"
  # `|| true` below: if the QMP connection itself fails (socket gone, protocol error), don't let
  # that abort this function via set -e - fall through to the same wait-loop/timeout instead, so
  # a failed ACPI request is handled identically to a successful-but-ignored one (both correctly
  # end in this function's own return 1, not an uncontrolled early exit that could skip a
  # caller's own hard-kill fallback and leave the process orphaned with no cleanup at all).
  python3 - "$sock" <<'PYEOF' || true
import json, socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect(sys.argv[1])
f = sock.makefile("rwb", buffering=0)
f.readline()
sock.sendall((json.dumps({"execute": "qmp_capabilities"}) + "\n").encode())
f.readline()
sock.sendall((json.dumps({"execute": "system_powerdown"}) + "\n").encode())
f.readline()
PYEOF
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || { log "qemu (pid ${pid}) exited cleanly"; return 0; }
    sleep 5
  done
  echo "ERROR: qemu (pid ${pid}) did not exit within 200s of a graceful shutdown request - this project's standing rule is never to hard-kill a disk that will be reused (a hard quit fakes corruption symptoms); investigate manually before retrying" >&2
  return 1
}

# --- OS-conditional device-model facts, per this script's own scope decisions above -------------
# Windows 11 enters this script still on Setup.exe's own `ide-hd`/`e1000` (windows11-setup-install.sh
# never touches virtio at all). Server 2022/2025 enter this script already on `virtio-blk-pci`/
# `virtio-net-pci` via the separate, already-proven offline-hivex mechanism - confirmed directly
# against packer/boot-and-provision.pkr.hcl (`disk_interface = "virtio"`, `net_device = "virtio-net"`).
# Storage swaps to vioscsi for every OS now; NIC only swaps for Windows 11 (Server's netkvm is
# already correct and is never relocated, per Finding 3A-2).
DO_STORAGE_SWAP="true"
DO_NIC_SWAP="false"
if [[ "$OS" == "windows11" ]]; then
  DO_NIC_SWAP="true"
fi

# ===============================================================================================
# Stage 1: boot on current primary devices (unchanged), attach driver sources (+ live "verify"
# hardware for whatever this OS still needs swapped), stage+verify each driver, install SPICE
# guest tools.
# ===============================================================================================
log "[Stage 1/2] Live-install verify boot for ${OS} (storage swap: always; NIC swap: ${DO_NIC_SWAP})"

# Short, fixed path directly under /tmp/ - Unix socket paths have a hard 108-byte kernel limit
# (CLAUDE.md's own documented gotcha); WORK_DIR is nested too deep to use directly.
QMP_SOCK1="/tmp/injspice-stage1-${RUN_ID}.sock"
rm -f "$QMP_SOCK1"

STAGE1_ARGS=(
  -machine q35,accel=kvm -cpu host -smp 4 -m 4096
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
  -drive if=pflash,format=raw,file="$OVMF_VARS_RUN"
  -drive "file=${TARGET_QCOW2},if=none,id=target,format=qcow2"
)

# Primary boot devices - unchanged from how this disk already boots today. Windows 11 is still on
# Setup.exe's own ide-hd/e1000; Server 2022/2025 is already on virtio-blk-pci/virtio-net-pci (via
# the separate, already-proven offline-hivex mechanism, untouched by this script).
if [[ "$OS" == "windows11" ]]; then
  STAGE1_ARGS+=(
    -device ide-hd,drive=target,bus=ide.0
    -drive "file=${VIRTIO_WIN_ISO},media=cdrom,if=none,id=virtiocd"
    -device ide-cd,drive=virtiocd,bus=ide.1
    -drive "file=${SPICE_TOOLS_ISO},media=cdrom,if=none,id=spicecd"
    -device ide-cd,drive=spicecd,bus=ide.2
    -netdev "user,id=net0,hostfwd=tcp::${WINRM_PORT}-:5985"
    -device e1000,netdev=net0
  )
else
  STAGE1_ARGS+=(
    -device virtio-blk-pci,drive=target
    -drive "file=${VIRTIO_WIN_ISO},media=cdrom,if=none,id=virtiocd"
    -device ide-cd,drive=virtiocd,bus=ide.0
    -drive "file=${SPICE_TOOLS_ISO},media=cdrom,if=none,id=spicecd"
    -device ide-cd,drive=spicecd,bus=ide.1
    -netdev "user,id=net0,hostfwd=tcp::${WINRM_PORT}-:5985"
    -device virtio-net-pci,netdev=net0
  )
fi

# Storage verify controller - every OS now (vioscsi is new to all of them). Live-verify controllers
# attached alongside the still-primary boot device, not yet primary themselves (Finding 3A-1:
# staging a driver isn't enough, it must bind to a present device). Gets its own explicit
# pcie-root-port AND a real, tiny throwaway backing drive - not left bare. A completely clean disk
# run caught a real gap: a bare virtio-scsi-pci controller (no drive) enumerates under a DIFFERENT
# PCI hardware ID (VEN_1AF4&DEV_1048, "modern"/1.0) than the same controller WITH a drive attached
# (VEN_1AF4&DEV_1004, "legacy/transitional") - confirmed directly by comparing pnputil's own
# device-ID output between a bare-verify run and Stage 2's real, drive-attached scsi0, which
# crashed with INACCESSIBLE_BOOT_DEVICE because DEV_1004 was never registered by a bare-controller
# verify step (Finding 3A-3). Giving the verify controller a real drive on the same explicit root
# port Stage 2 will use makes it topologically identical, closing the gap regardless of mechanism.
VERIFY_DISK="${WORK_DIR}/scsiverify-throwaway.qcow2"
qemu-img create -f qcow2 "$VERIFY_DISK" 1G >/dev/null
STAGE1_ARGS+=(
  -device pcie-root-port,id=rp_scsiverify,bus=pcie.0,addr=0x6,chassis=1,port=1
  -device virtio-scsi-pci,id=scsiverify,bus=rp_scsiverify
  -drive "file=${VERIFY_DISK},if=none,id=verifydrive,format=qcow2"
  -device scsi-hd,drive=verifydrive,bus=scsiverify.0
)

if [[ "$DO_NIC_SWAP" == "true" ]]; then
  # Windows 11 only - Server 2022/2025's netkvm is already correct, nothing to verify-then-swap.
  # Own explicit pcie-root-port, same reasoning as storage above: this combination (two new virtio
  # devices attached simultaneously alongside ide-hd/e1000) hung at the firmware level the first
  # time this script ran end-to-end (byte-identical tools/qmp-screenshot.py captures, near-zero
  # CPU - a real wedge, Finding 3A-2), even though neither piece had ever failed alone. Throwaway,
  # never referenced again after this boot.
  STAGE1_ARGS+=(
    -device pcie-root-port,id=rp_nicverify,bus=pcie.0,addr=0x7,chassis=2,port=2
    -netdev user,id=netverify
    -device virtio-net-pci,netdev=netverify,id=nicverify,bus=rp_nicverify
  )
fi

STAGE1_ARGS+=(
  -device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0
  -qmp "unix:${QMP_SOCK1},server,nowait"
  -display none
)

qemu-system-x86_64 "${STAGE1_ARGS[@]}" > "${WORK_DIR}/stage1-qemu.log" 2>&1 &
QEMU_PID1=$!
log "Stage 1 qemu pid ${QEMU_PID1}, log ${WORK_DIR}/stage1-qemu.log"

cleanup_stage1() {
  # Capture the exit status that triggered this trap BEFORE running anything else - without this,
  # the trap's own last command (kill -9 ... || true, which always succeeds) becomes the WHOLE
  # SCRIPT's exit status once the EXIT trap finishes, silently turning a real failure (e.g. a
  # winrm_ps timeout) into a reported success for anything driving this script. Found and fixed
  # in install-tools.sh's own copy of this pattern first (PHASE4_TOOLS_INSTALLER_PLAN.md's Phase E
  # testing, 2026-09-03), then confirmed this script carries the identical latent bug - dormant
  # here only because every completed real run on record has had its graceful shutdown succeed,
  # so this trap's hard-kill fallback has never actually been the thing that ended a run.
  local exit_code=$?
  if kill -0 "$QEMU_PID1" 2>/dev/null; then
    # An error here (e.g. a winrm_ps failure) means this trap is the FIRST shutdown attempt for
    # this qemu process - unlike the intentional success-path call to qmp_graceful_shutdown
    # further down, which this trap never reaches on an error exit. Try graceful first, exactly
    # like the success path does - confirmed the hard way (2026-08-25) that skipping straight to
    # a hard kill here, while Windows was live and healthy mid-verification, produced a disk with
    # an unexplained OOBE regression on its next boot (this project's own standing rule: a hard
    # quit fakes corruption symptoms on a disk that will be reused).
    echo "Cleanup: Stage 1 qemu (pid ${QEMU_PID1}) still running after an error - attempting graceful shutdown before considering a hard kill" >&2
    if ! qmp_graceful_shutdown "$QMP_SOCK1" "$QEMU_PID1"; then
      echo "Cleanup: graceful shutdown did not complete - forcing qemu (pid ${QEMU_PID1}) down as a last resort; treat this disk's state as suspect, don't reuse it without checking" >&2
      kill -9 "$QEMU_PID1" 2>/dev/null || true
    fi
  fi
  exit "$exit_code"
}
trap cleanup_stage1 EXIT

wait_for_winrm "$QEMU_PID1" "${WORK_DIR}/stage1-qemu.log"

log "Staging + live-verifying vioscsi (subfolder ${DRIVER_SUBFOLDER})$( [[ "$DO_NIC_SWAP" == "true" ]] && echo " and netkvm" )"
NIC_VERIFY_PS=""
if [[ "$DO_NIC_SWAP" == "true" ]]; then
  NIC_VERIFY_PS="
pnputil /add-driver \"\${virtioLetter}:\\NetKVM\\${DRIVER_SUBFOLDER}\\amd64\\netkvm.inf\" /install
if (\$LASTEXITCODE -ne 0) { throw \"pnputil /add-driver netkvm failed with exit \$LASTEXITCODE\" }
\$netOk = @(Get-PnpDevice -Class Net | Where-Object { \$_.FriendlyName -like 'Red Hat VirtIO*' -and \$_.Status -eq 'OK' })
if (\$netOk.Count -eq 0) { throw 'netkvm did not reach a live Status:OK PnP install on any matching device - see Finding 3A-1' }
Write-Output 'netkvm live-verified: Status OK'
"
else
  # Server 2022/2025: netkvm already works from this disk's own first boot - just confirm, don't
  # stage/swap anything (Finding 3A-2: never relocate an already-working device).
  NIC_VERIFY_PS="
\$netUp = @(Get-NetAdapter | Where-Object { \$_.InterfaceDescription -like 'Red Hat VirtIO*' -and \$_.Status -eq 'Up' })
if (\$netUp.Count -eq 0) { throw \"expected an already-Up Red Hat VirtIO NIC on \$env:COMPUTERNAME - none found\" }
Write-Output \"NIC already virtio and Up (\$(\$netUp[0].Name)) - no swap needed\"
"
fi

# Below: matches vioscsi/netkvm PnP status on ANY device, not a scalar comparison - a disk
# that's been through this script's Stage 1 more than once (e.g. a retried run) accumulates
# stale/ghost PnP entries for devices no longer present in the current boot's exact PCI
# topology (Status: Unknown), so Get-PnpDevice can legitimately return more than one match.
# Comparing an array to a scalar with -ne does element-wise comparison in PowerShell, not what's
# intended - a real bug caught on this script's own second real run, not a hypothetical.
winrm_ps "
\$ErrorActionPreference = 'Stop'
\$virtioLetter = (Get-Volume | Where-Object { \$_.FileSystemLabel -like 'virtio-win*' }).DriveLetter
\$spiceLetter  = (Get-Volume | Where-Object { \$_.FileSystemLabel -eq 'SPICETOOLS' }).DriveLetter
if (-not \$virtioLetter) { throw 'virtio-win ISO not found mounted (no volume with label virtio-win*)' }
if (-not \$spiceLetter)  { throw 'SPICE tools ISO not found mounted (no volume with label SPICETOOLS)' }

pnputil /add-driver \"\${virtioLetter}:\\vioscsi\\${DRIVER_SUBFOLDER}\\amd64\\vioscsi.inf\" /install
if (\$LASTEXITCODE -ne 0) { throw \"pnputil /add-driver vioscsi failed with exit \$LASTEXITCODE\" }

Start-Sleep -Seconds 5
\$scsiOk = @(Get-PnpDevice -Class SCSIAdapter | Where-Object { \$_.FriendlyName -like 'Red Hat VirtIO*' -and \$_.Status -eq 'OK' })
if (\$scsiOk.Count -eq 0) { throw 'vioscsi did not reach a live Status:OK PnP install on any matching device - see Finding 3A-1, this means the device was not actually present/bound, only staged' }
Write-Output 'vioscsi live-verified: Status OK'
${NIC_VERIFY_PS}
& \"\${spiceLetter}:\\spice-guest-tools-latest.exe\" /S
if (\$LASTEXITCODE -ne 0) { throw \"spice-guest-tools-latest.exe /S failed with exit \$LASTEXITCODE\" }
Write-Output 'spice-guest-tools installed'

# qxldod: staged only here, same as spice-guest-tools' own classic qxl driver just above - no QXL
# device exists yet in Stage 1 to live-bind against (Stage 2 adds qxl-vga for the first time).
# Windows' own driver ranking (qxldod's FeatureScore F9 beats classic qxl's FC - lower wins) picks
# it deterministically once the real device appears in Stage 2; verified explicitly there, not
# assumed here.
pnputil /add-driver \"\${virtioLetter}:\\qxldod\\${QXLDOD_SUBFOLDER}\\amd64\\qxldod.inf\" /install
if (\$LASTEXITCODE -ne 0) { throw \"pnputil /add-driver qxldod failed with exit \$LASTEXITCODE\" }
Write-Output 'qxldod staged'
"

log "Stage 1 complete - graceful shutdown"
qmp_graceful_shutdown "$QMP_SOCK1" "$QEMU_PID1"
trap - EXIT

# Disk hygiene (CLAUDE.md) - the verify drive is genuinely throwaway, never referenced again.
[[ -n "${VERIFY_DISK:-}" ]] && rm -f "$VERIFY_DISK"

# ===============================================================================================
# Stage 2: real device-model boot. Any already-primary device (storage always; NIC on Server
# 2022/2025) stays on its existing placement untouched (Finding 3A-2). Only Windows 11's NIC
# swap introduces a genuinely new device and gets an explicit pcie-root-port - the actual fix for
# the confirmed firmware-level hang. qxl-vga stays on its implicit default placement everywhere.
# ===============================================================================================
log "[Stage 2/2] Final boot for ${OS}: qxl-vga + SPICE added, storage swapped to virtio-scsi$( [[ "$DO_NIC_SWAP" == "true" ]] && echo ", NIC swapped to virtio-net" )"

QMP_SOCK2="/tmp/injspice-stage2-${RUN_ID}.sock"
rm -f "$QMP_SOCK2"

STAGE2_ARGS=(
  -machine q35,accel=kvm -cpu host -smp 4 -m 4096
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
  -drive if=pflash,format=raw,file="$OVMF_VARS_RUN"
  -drive "file=${TARGET_QCOW2},if=none,id=target,format=qcow2"
)

# Storage: the root port here uses the IDENTICAL addr/chassis/port as Stage 1's scsiverify (0x6/1/1)
# - deliberately, not coincidentally, for every OS. A completely clean disk run caught a real gap:
# a bare-verify virtio-scsi-pci controller (no drive, Stage 1's original design) negotiated a
# DIFFERENT PCI hardware ID (VEN_1AF4&DEV_1048, "modern") than the same controller WITH a drive
# attached (VEN_1AF4&DEV_1004, "legacy/transitional") - and Stage 2 crashed with
# INACCESSIBLE_BOOT_DEVICE because DEV_1004 was never registered. Rather than assume *why* the ID
# differs (drive presence? explicit vs implicit bus placement? both remain plausible, unconfirmed),
# the deterministic fix is to make Stage 1's verify topology byte-identical to Stage 2's real
# topology - whatever QEMU negotiates, it is then guaranteed to be the same value in both stages,
# regardless of the mechanism (Finding 3A-3).
STAGE2_ARGS+=(
  -device pcie-root-port,id=rp_scsi,bus=pcie.0,addr=0x6,chassis=1,port=1
  -device virtio-scsi-pci,id=scsi0,bus=rp_scsi
  -device scsi-hd,drive=target,bus=scsi0.0
)

if [[ "$DO_NIC_SWAP" == "true" ]]; then
  # Windows 11 only. Same addr/chassis/port (0x7/2/2) as Stage 1's nicverify, same reasoning.
  STAGE2_ARGS+=(
    -device pcie-root-port,id=rp_nic,bus=pcie.0,addr=0x7,chassis=2,port=2
    -netdev "user,id=net0,hostfwd=tcp::${WINRM_PORT}-:5985"
    -device virtio-net-pci,netdev=net0,id=nic0,bus=rp_nic
  )
else
  # Server 2022/2025: already virtio-net-pci from its own first boot - implicit placement,
  # completely untouched, no new root port (nothing new is being introduced here, Finding 3A-2).
  STAGE2_ARGS+=(
    -netdev "user,id=net0,hostfwd=tcp::${WINRM_PORT}-:5985"
    -device virtio-net-pci,netdev=net0
  )
fi

STAGE2_ARGS+=(
  -device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0
  -device virtio-serial-pci,id=virtio-serial0
  -chardev spicevmc,id=charchannel0,name=vdagent
  -device virtserialport,bus=virtio-serial0.0,nr=1,chardev=charchannel0,id=channel0,name=com.redhat.spice.0
  -device qxl-vga,vgamem_mb=32
  -spice "port=${SPICE_PORT},addr=127.0.0.1,disable-ticketing=on,image-compression=off"
  -vnc "127.0.0.1:${VNC_DISPLAY}"
  -qmp "unix:${QMP_SOCK2},server,nowait"
)

qemu-system-x86_64 "${STAGE2_ARGS[@]}" > "${WORK_DIR}/stage2-qemu.log" 2>&1 &
QEMU_PID2=$!
log "Stage 2 qemu pid ${QEMU_PID2}, log ${WORK_DIR}/stage2-qemu.log, SPICE on 127.0.0.1:${SPICE_PORT}, VNC on 127.0.0.1:$((5900 + VNC_DISPLAY))"

cleanup_stage2() {
  # Same exit-code-preservation fix as cleanup_stage1 above, and for the identical reason - see
  # that function's own comment for the full story (found in install-tools.sh's own copy of this
  # pattern during its Phase E testing, 2026-09-03, then confirmed present here too).
  local exit_code=$?
  if kill -0 "$QEMU_PID2" 2>/dev/null; then
    # Same reasoning as cleanup_stage1 above - try graceful first, only hard-kill as a last
    # resort. This is the exact trap that hard-killed a live, healthy, WinRM-reachable Windows
    # session on 2026-08-25 (the winrm_ps command-length bug fired mid-verification), producing
    # a disk with an unexplained OOBE regression on its next boot - a graceful attempt here would
    # very likely have succeeded, since WinRM was confirmed live moments before.
    echo "Cleanup: Stage 2 qemu (pid ${QEMU_PID2}) still running after an error - attempting graceful shutdown before considering a hard kill" >&2
    if ! qmp_graceful_shutdown "$QMP_SOCK2" "$QEMU_PID2"; then
      echo "Cleanup: graceful shutdown did not complete - forcing qemu (pid ${QEMU_PID2}) down as a last resort; treat this disk's state as suspect, don't reuse it without checking" >&2
      kill -9 "$QEMU_PID2" 2>/dev/null || true
    fi
  fi
  exit "$exit_code"
}
trap cleanup_stage2 EXIT

wait_for_winrm "$QEMU_PID2" "${WORK_DIR}/stage2-qemu.log"

log "Verifying NIC and display; storage too if it was swapped"
# The final line below writes C:\virtio-spice-injected.marker, only reached once every check
# in this block already succeeded - register-vm.sh checks for it offline before it will ever
# define a domain for this disk. Documented HERE, not as an inline PS comment inside the
# winrm_ps payload below: this whole block is transmitted as `powershell -encodedcommand
# <base64>` over WinRS, which has a real, hard command-line ceiling (~8191 chars) - confirmed
# the hard way (2026-08-25) when adding a 3-line PS comment for this exact marker pushed an
# already-comment-heavy version of this block over that ceiling ("The command line is too
# long", the qemu process force-killed by this script's own cleanup trap). Keep new
# documentation here in bash, not inside the PS string - it costs nothing over the wire.
winrm_ps "
\$ErrorActionPreference = 'Stop'

if (\$${DO_STORAGE_SWAP}) {
  \$diskStatus = (Get-Disk -Number 0).OperationalStatus
  if (\$diskStatus -ne 'Online') { throw \"boot disk not Online after storage swap (got: \$diskStatus)\" }
}

# Match on ANY device at the wanted status, not a scalar comparison - see the same fix/comment
# in Stage 1 above (Get-PnpDevice/Get-NetAdapter can return more than one match on a disk that's
# been through this script more than once, from stale/ghost PnP history for a prior topology).
\$netUp = @(Get-NetAdapter | Where-Object { \$_.InterfaceDescription -like 'Red Hat VirtIO*' -and \$_.Status -eq 'Up' })
if (\$netUp.Count -eq 0) { throw 'virtio NIC not Up on any matching adapter' }

\$qxlOk = @(Get-PnpDevice -Class Display | Where-Object { \$_.FriendlyName -like 'Red Hat QXL*' -and \$_.Status -eq 'OK' })
if (\$qxlOk.Count -eq 0) { throw 'QXL display device not Status:OK on any matching device' }

# Status:OK alone doesn't say WHICH of the two staged, competing drivers actually bound (Finding,
# 2026-08-23: spice-guest-tools' own classic qxl driver also reaches Status:OK, but crashes any
# XAML/Fluent-UI shell surface - Start Menu, Search - with STATUS_STACK_BUFFER_OVERRUN in
# Windows.UI.Xaml.dll, since it has no real WDDM/Direct3D support). Assert the bound driver is
# specifically qxldod (Red Hat's WHQL-signed WDDM build, DriverVersion 10.0.0.21000) - confirmed
# against a real, long-used reference VM already running this exact build with a working Start Menu.
\$qxlDrv = Get-CimInstance Win32_PnPSignedDriver | Where-Object { \$_.DeviceName -like 'Red Hat QXL*' } | Select-Object -First 1
if (-not \$qxlDrv -or \$qxlDrv.DriverVersion -ne '10.0.0.21000') { throw \"QXL bound to unexpected driver version '\$(\$qxlDrv.DriverVersion)' - expected qxldod 10.0.0.21000; classic qxl driver may have won ranking instead (see Finding 3A-4)\" }
Write-Output \"qxldod confirmed bound: DriverVersion \$(\$qxlDrv.DriverVersion), DriverDate \$(\$qxlDrv.DriverDate)\"

# Known first-boot start-order race (WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md): vdservice can be
# Stopped on its very first boot despite StartType Automatic, because it starts before the
# QXL/virtio-serial channel is fully up. Nudge it rather than leaving it to chance - a real,
# already-diagnosed benign race, not a new defect to investigate each time.
\$vd = Get-Service vdservice -ErrorAction SilentlyContinue
if (\$vd -and \$vd.Status -ne 'Running') {
  Start-Service vdservice
  Start-Sleep -Seconds 3
  \$vd = Get-Service vdservice
}
if (-not \$vd -or \$vd.Status -ne 'Running') { throw \"SPICE VDAgent service not Running after nudge (got: \$(\$vd.Status))\" }

Write-Output \"NIC Up (\$(\$netUp[0].Name)), QXL OK, vdservice Running - all confirmed\"

Set-Content -Path C:\virtio-spice-injected.marker -Value (Get-Date -Format o)
"

log "Stage 2 complete - graceful shutdown, disk left ready for real use"
qmp_graceful_shutdown "$QMP_SOCK2" "$QEMU_PID2"
trap - EXIT

log "inject-virtio-spice.sh complete for ${OS}: ${TARGET_QCOW2} now has SPICE (qxldod + vdagent), boots on virtio-scsi$( [[ "$DO_NIC_SWAP" == "true" ]] && echo "/virtio-net (swapped)" || echo " (NIC already virtio, untouched)" )"
