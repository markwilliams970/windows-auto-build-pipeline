#!/usr/bin/env bash
# Build step 5: make the offline-applied disk bootable, then offline-inject the boot-
# critical and network VirtIO drivers. Two sub-steps, run in this exact order because
# it's the order Session 8 actually proved working (driver injection AFTER bcdboot, not
# before - WinPE's own startnet.cmd unconditionally copies its own baked-in viostor.sys
# onto the target as part of the bcdboot pass, so this script's own OS-correct copy has
# to happen afterward or it would just get overwritten):
#
#   1. Boot the proven WinPE medium (image-apply/output/winpe-boot-index1-work.qcow2)
#      together with the target disk. WinPE's startnet.cmd (unchanged since Session 8,
#      confirmed OS-version-agnostic across all three target OSes per Session 12/13)
#      runs drvload/diskpart/bcdboot unattended and shuts itself down when done - real,
#      Microsoft-tool-built BCD, not an approximation.
#   2. Offline hivexregedit --merge of tools/gen-viostor-ddb-reg.py's viostor AND netkvm
#      DriverDatabase presets into the target's own SYSTEM hive (Finding 29's corrected
#      hive-root parent key), then copy the OS-correct viostor.sys/netkvm.sys (kernel
#      drivers are not binary-compatible across major NT versions even when hardware IDs
#      match - Session 12) and stage NetKVM's full driver package at
#      C:\Drivers\NetKVM\<subfolder>\amd64\ for the live pnputil step FirstLogonCommands
#      runs later (apply-unattend.sh's unattend.xml).
#
# Usage: make-bootable.sh <server2019|server2022|server2025|windows11> <target-qcow2-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OS="${1:?Usage: make-bootable.sh <server2019|server2022|server2025|windows11> <target-qcow2-path>}"
TARGET_QCOW2="${2:?Usage: make-bootable.sh <server2019|server2022|server2025|windows11> <target-qcow2-path>}"
validate_os "$OS"

[[ -f "$TARGET_QCOW2" ]] || { echo "ERROR: $TARGET_QCOW2 not found - run apply-image.sh first" >&2; exit 1; }

WINPE_QCOW2="${REPO_ROOT}/image-apply/output/winpe-boot-index1-work.qcow2"
[[ -f "$WINPE_QCOW2" ]] || { echo "ERROR: WinPE bootability medium not found at $WINPE_QCOW2 - see image-apply/build-winpe-medium.sh" >&2; exit 1; }

DRIVER_SUBFOLDER="$(os_driver_subfolder "$OS")"
[[ -f "$VIRTIO_WIN_ISO" ]] || { echo "ERROR: $VIRTIO_WIN_ISO not found in ISO_CACHE_DIR" >&2; exit 1; }

OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_SCRATCH="${REPO_ROOT}/image-apply/output/efivars-${OS}-bootable.fd"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS_SCRATCH"

QMP_SOCK="/tmp/mkboot-${OS}.sock"
rm -f "$QMP_SOCK"

log "Booting WinPE + target together to run bcdboot (WinPE on ide.0, target on virtio-blk-pci, per Finding 17)"
# USB tablet device (CLAUDE.md's "Known gotcha" under QEMU/KVM/libvirt): a guest's default
# pointer is a relative PS/2 mouse, which any QMP absolute-position click (tools/qmp-click.py)
# cannot drive at all - the sibling project hit the identical problem for its own VNC/SPICE
# console and fixed it with libvirt's <input type='tablet' bus='usb'/>. Added here up front,
# on every qemu-system-x86_64 invocation this project constructs, per that same convention -
# cheap now, avoids rediscovering the gap mid-debugging session later.
# bootindex is explicit and load-bearing, not defensive - discovered the hard way when
# this script was re-run against a target that already had a valid BCD from a prior
# run: OVMF's own boot-option discovery preferred the target's now-real Windows Boot
# Manager over WinPE, landing on a real interactive OOBE screen instead of running
# startnet.cmd, which just sat there until this step's own timeout fired. Pinning the
# boot order explicitly makes this step idempotent regardless of the target's own
# current boot state.
timeout 300 qemu-system-x86_64 \
  -machine q35,accel=kvm \
  -cpu host \
  -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS_SCRATCH" \
  -drive file="$WINPE_QCOW2",if=none,id=winpe,format=qcow2 \
  -device ide-hd,drive=winpe,bus=ide.0,bootindex=1 \
  -drive file="$TARGET_QCOW2",if=none,id=target,format=qcow2 \
  -device virtio-blk-pci,drive=target,bootindex=2 \
  -device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0 \
  -qmp "unix:${QMP_SOCK},server,nowait" \
  -display none \
  || { rc=$?; if [[ $rc -eq 124 ]]; then echo "ERROR: WinPE+bcdboot boot timed out after 300s" >&2; exit 1; fi; }

log "WinPE session ended - verifying bcdboot succeeded and applying driver injection"

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

# WinPE's own startnet.cmd (unchanged since Session 8/Finding 31) writes its bcdboot log
# under this "session8-"-prefixed name regardless of which real build uses this medium -
# cosmetic wart from the medium's original build session, not worth the risk of editing a
# proven-working artifact just to rename a log file.
BCDBOOT_LOG="${WIN_MNT}/session8-bcdboot-log.txt"
if [[ ! -f "$BCDBOOT_LOG" ]] || ! grep -qi "Boot files successfully created" "$BCDBOOT_LOG"; then
  echo "ERROR: bcdboot did not report success (missing or bad ${BCDBOOT_LOG})" >&2
  cat "$BCDBOOT_LOG" 2>/dev/null >&2 || true
  exit 1
fi
log "bcdboot confirmed: $(cat "$BCDBOOT_LOG")"

log "Extracting driver files for ${OS} (subfolder ${DRIVER_SUBFOLDER}) from virtio-win ISO"
DRIVER_CACHE_DIR="${REPO_ROOT}/image-apply/output/virtio-drivers/${DRIVER_SUBFOLDER}"
# Checked via netkvmp.exe specifically, not just the directory's existence - an earlier
# version of this script only extracted netkvm.inf/.sys/.cat, which pnputil's live
# /add-driver step (apply-unattend.sh's FirstLogonCommands) then failed against with
# "The system cannot find the file specified": netkvm.inf's own [SourceDisksFiles]
# section requires netkvmp.exe (its NDIS performance-filter helper) to be staged
# alongside the .inf, confirmed by reading the .inf directly rather than assuming
# .inf/.sys/.cat is the complete package (viostor's DriverDatabase-only use never needed
# this, which is how the gap went unnoticed until a real live-boot test hit it).
if [[ ! -f "${DRIVER_CACHE_DIR}/netkvm/netkvmp.exe" ]]; then
  mkdir -p "$DRIVER_CACHE_DIR"
  7z e -y -o"${DRIVER_CACHE_DIR}/viostor" "$VIRTIO_WIN_ISO" "viostor/${DRIVER_SUBFOLDER}/amd64/viostor.inf" "viostor/${DRIVER_SUBFOLDER}/amd64/viostor.sys" "viostor/${DRIVER_SUBFOLDER}/amd64/viostor.cat"
  7z e -y -o"${DRIVER_CACHE_DIR}/netkvm" "$VIRTIO_WIN_ISO" "NetKVM/${DRIVER_SUBFOLDER}/amd64/netkvm.inf" "NetKVM/${DRIVER_SUBFOLDER}/amd64/netkvm.sys" "NetKVM/${DRIVER_SUBFOLDER}/amd64/netkvm.cat" "NetKVM/${DRIVER_SUBFOLDER}/amd64/netkvmp.exe" "NetKVM/${DRIVER_SUBFOLDER}/amd64/netkvmco.exe"
fi

# Unmounted before the driver-file overwrite, deliberately - see PHASE3_ENGINEERING_LOG.md's
# "Update 5" finding (2026-08-24). Writing viostor.sys/netkvm.sys through this ntfs-3g uid=/gid=
# mount (as a plain `cp`, the original approach) silently resets the file's real NTFS security
# descriptor to the mount's own generic default, re-breaking the exact bug apply-image.sh's own
# switch to a native NTFS-volume writer (--strict-acls) fixed for the rest of the disk - confirmed
# directly via ntfsinfo's per-file Security ID (the boot-critical viostor.sys ended up with a
# different, generic ID than every other untouched driver file shares). ntfscp operates directly
# on the block device, like wimlib's own native apply mode, and was confirmed to leave a file's
# pre-existing security descriptor untouched when overwriting its content - but it needs exclusive
# access to the device, so the FUSE mount used for the bcdboot-log check above and the registry
# edits below must not be active at the same time.
log "Copying OS-correct viostor.sys/netkvm.sys into System32/drivers via ntfscp (overwrites WinPE's own generic viostor.sys copy), not through the ntfs-3g mount"
sudo umount "$WIN_MNT"
sudo ntfscp "${NBD_DEV}p3" "${DRIVER_CACHE_DIR}/viostor/viostor.sys" /Windows/System32/drivers/viostor.sys
sudo ntfscp "${NBD_DEV}p3" "${DRIVER_CACHE_DIR}/netkvm/netkvm.sys" /Windows/System32/drivers/netkvm.sys
sudo mount -t ntfs-3g -o uid="$(id -u)",gid="$(id -g)" "${NBD_DEV}p3" "$WIN_MNT"

log "Generating and merging DriverDatabase registrations (viostor, netkvm) into the SYSTEM hive"
SYSTEM_HIVE="${WIN_MNT}/Windows/System32/config/SYSTEM"
TMP_REG_DIR="$(mktemp -d)"
python3 "${REPO_ROOT}/tools/gen-viostor-ddb-reg.py" --driver viostor -o "${TMP_REG_DIR}/viostor.reg"
python3 "${REPO_ROOT}/tools/gen-viostor-ddb-reg.py" --driver netkvm -o "${TMP_REG_DIR}/netkvm.reg"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$SYSTEM_HIVE" "${TMP_REG_DIR}/viostor.reg"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$SYSTEM_HIVE" "${TMP_REG_DIR}/netkvm.reg"

# ServicesPipeTimeout fix (2026-08-23 finding, real and reproduced - not theoretical): every real
# build's first interactive boot follows several already-automated boot/shutdown cycles on a
# freshly-applied disk (Packer's own provision+restart, then inject-virtio-spice.sh's two more) -
# exactly the "boot storm" conditions (heavy disk I/O, cold caches) that trigger a documented
# Windows Server 2022 race: RPC Endpoint Mapper doesn't finish initializing within the default
# service-dependency timeout (30s), so DCOM can't register local servers, so SystemEventsBroker and
# Background Tasks Infrastructure fail to start, so anything depending on them - StartMenuExperience-
# Host (Start Menu), SearchHost, and IIS - fails or crashes (confirmed directly: identical
# STATUS_STACK_BUFFER_OVERRUN/Windows.UI.Xaml.dll crash at the same fault offset across two separate
# fresh builds, plus repeated DistributedCOM Event 10010 "did not register with DCOM within the
# required timeout" for StartMenuExperienceHost specifically - not a QXL driver issue, ruled out by
# a real independent comparison VM running an older driver with a working Start Menu). Real-world
# confirmation this is a known, named Windows Server 2022 architectural issue, not specific to this
# project: https://learn.microsoft.com/en-us/answers/questions/5836440/ (same symptom triad -
# Start Menu, Search, IIS - same root cause chain, same registry-based fix). Applied offline, before
# the very first boot, because the race is in early service startup - by the time FirstLogonCommands
# runs the window has usually already closed. 120000 (120s, double the community-cited 60s) to leave
# real margin under this project's own heavier-than-typical boot conditions (four automated cycles
# per real build, not one).
cat > "${TMP_REG_DIR}/services-pipe-timeout.reg" <<'REGEOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control]
"ServicesPipeTimeout"=dword:0001d4c0
REGEOF
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$SYSTEM_HIVE" "${TMP_REG_DIR}/services-pipe-timeout.reg"

rm -rf "$TMP_REG_DIR"

log "Staging NetKVM's full driver package at C:\\Drivers\\NetKVM\\${DRIVER_SUBFOLDER}\\amd64\\ for the live pnputil FirstLogonCommands step"
DEST="${WIN_MNT}/Drivers/NetKVM/${DRIVER_SUBFOLDER}/amd64"
mkdir -p "$DEST"
cp "${DRIVER_CACHE_DIR}/netkvm/"* "$DEST/"

log "make-bootable.sh complete: ${TARGET_QCOW2}"
