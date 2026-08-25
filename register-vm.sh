#!/usr/bin/env bash
# Registers an already-built disk (build.sh) as a libvirt domain, so it shows up in
# `virsh list --all` / virt-manager instead of existing only as a loose qcow2 file. Adapted
# from ../windows-server-vm-automation/register-vm.sh's own proven pattern (same
# `virsh define` mechanics, same USB-tablet gotcha - see CLAUDE.md's "VM screen inspection"
# section) - not reused verbatim, because that script assumes one fixed disk/NVRAM location
# and one fixed device model; this project has two of each, by OS and by build stage:
#
#   - server2022/server2025: build.sh hands off to Packer, which leaves the final,
#     role-provisioned disk at packer/output/<os>/<os>.qcow2 - then (as of this script's own
#     introduction) build.sh runs inject-virtio-spice.sh against that same file in place, so
#     by the time a real build finishes it's already on virtio-scsi + QXL/SPICE, NIC
#     untouched (netkvm, via the separate, already-proven offline-hivex mechanism).
#   - windows11: no Packer handoff. build.sh's own windows11-setup-install.sh +
#     inject-virtio-spice.sh sequence leaves the final disk at
#     image-apply/output/builds/<name>.qcow2, already on virtio-scsi/virtio-net/QXL+SPICE
#     (NIC *is* swapped for Windows 11 - see inject-virtio-spice.sh's own header).
#
# Both cases land in the same place: virtio-scsi disk (scsi-hd on a virtio-scsi-pci
# controller), virtio-net NIC, qxl-vga + a real SPICE channel (not VNC) - the config
# inject-virtio-spice.sh already proved boots and works, so libvirt's own PCI address
# allocation for the scsi controller doesn't need to reproduce inject-virtio-spice.sh's own
# raw addr=0x6 QEMU flags exactly. Finding 3A-3 (WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md)
# found that a virtio-scsi-pci controller's negotiated PCI hardware ID depends on whether it
# has a drive attached (legacy/transitional DEV_1004) or not (modern DEV_1048), not on its
# exact bus address - and Windows' own driver binding is keyed to that hardware ID, already
# registered in DriverDatabase by inject-virtio-spice.sh. Since this script always attaches
# the real OS disk to the controller it defines (never bare), it should negotiate the same
# DEV_1004 ID Windows already has staged, regardless of PCI slot. This is a reasoned
# inference from Finding 3A-3, not independently re-verified by a live virsh boot as of this
# script's own introduction - a real first boot is the next thing to confirm, not assumed.
#
# NVRAM: every script in this project's own pipeline (windows11-setup-install.sh,
# inject-virtio-spice.sh's both stages, boot-and-provision.pkr.hcl) starts every single QEMU
# invocation from a *fresh* copy of /usr/share/OVMF/OVMF_VARS_4M.fd, never a previous run's
# mutated NVRAM file - and this has worked repeatedly across every confirmed clean build,
# because the real boot state lives on the disk's own ESP (bcdboot's work), not in NVRAM.
# This script follows the identical convention rather than hunting for a specific prior run's
# NVRAM file (which may not even still exist - Packer's own per-build efivars.fd and
# inject-virtio-spice.sh's own per-run OVMF_VARS.fd are both scratch/working files, already
# pruned once by this project's own disk-hygiene pass this same session): it makes its own
# fresh, persistent, per-domain NVRAM copy at registration time and never reuses anyone else's.
#
# Usage:
#   ./register-vm.sh <server2022|server2025|windows11> [qcow2_path] [vm_name]
# qcow2_path defaults to the OS's own well-known build output location (packer/output/<os>/
# <os>.qcow2 for server2022/server2025; the most recently modified
# image-apply/output/builds/windows11-*.qcow2 for windows11 - timestamped per build, no
# single fixed name). vm_name defaults to the disk's own baked-in ComputerName, lowercased
# (image-apply/lib/common.sh's os_computer_name - reusing an existing convention rather than
# inventing a new one).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO_ROOT}/image-apply/lib/common.sh"

fail() { echo "ERROR: $*" >&2; exit 1; }

OS="${1:?Usage: register-vm.sh <server2022|server2025|windows11> [qcow2_path] [vm_name]}"
validate_os "$OS"

command -v virsh >/dev/null 2>&1 || fail "virsh is not installed or not on PATH"
virsh -c qemu:///system list >/dev/null 2>&1 \
  || fail "cannot reach libvirt at qemu:///system - is libvirtd running, and is this user in the 'libvirt' group?"

if [[ "$OS" == "windows11" ]]; then
  DEFAULT_QCOW2="$(ls -t "${REPO_ROOT}/image-apply/output/builds/windows11-"*.qcow2 2>/dev/null | head -1 || true)"
else
  # Packer's own output_directory/vm_name are build_id-named (build.sh's own BUILD_ID,
  # "<os>-<timestamp>"), not fixed per OS - a fixed "packer/output/<os>/<os>.qcow2" path
  # collided across repeated builds of the same OS (a real, confirmed bug this project hit
  # and fixed). Pick the most recently modified match, same "newest by mtime" convention as
  # the windows11 case above.
  DEFAULT_QCOW2="$(ls -t "${REPO_ROOT}/packer/output/${OS}-"*/"${OS}-"*.qcow2 2>/dev/null | head -1 || true)"
fi
QCOW2_PATH="${2:-$DEFAULT_QCOW2}"
[[ -n "$QCOW2_PATH" && -f "$QCOW2_PATH" ]] || fail "no disk found at '${QCOW2_PATH:-<none>}' - run build.sh first, or pass the right qcow2_path explicitly"

# Precondition: this script's device model (virtio-scsi-pci disk, qxl-vga/SPICE) only
# matches a disk that has already been through inject-virtio-spice.sh - every real build.sh
# run guarantees this before register-vm.sh would ever be invoked, but a disk built by
# hand-running image-apply/*.sh stages directly (e.g. while iterating on apply-image.sh/
# make-bootable.sh changes) never reaches that step. Pointing this script at such a disk
# silently produces the INACCESSIBLE_BOOT_DEVICE/indefinite-hang failure class documented in
# PHASE3_ENGINEERING_LOG.md's 2026-08-24/2026-08-25 sessions - fail loud instead of guessing.
# Checked via inject-virtio-spice.sh's own completion marker
# (C:\virtio-spice-injected.marker, written only after its Stage 2 verification fully
# succeeds), read offline via the same qemu-nbd/ntfs-3g mount pattern every image-apply/*.sh
# script already uses - reusing its exact /tmp/win-build-mnt/ prefix so no sudoers change is
# needed. Locates the Windows partition by filesystem type (lsblk FSTYPE=ntfs) rather than
# assuming a fixed partition number: server2022/server2025's own partition-disk.sh layout
# puts it at p3, but windows11's Setup.exe-driven partitioning has never been independently
# confirmed to match, so this doesn't assume it does.
echo "==> Checking ${QCOW2_PATH} for inject-virtio-spice.sh's completion marker" >&2
CHECK_MNT="/tmp/win-build-mnt/register-check"
sudo modprobe nbd max_part=8
CHECK_NBD=""
for cand in /dev/nbd{0,1,2,3,4,5,6,7}; do
  if ! sudo qemu-nbd -c "$cand" "$QCOW2_PATH" 2>/dev/null; then
    continue
  fi
  CHECK_NBD="$cand"
  break
done
[[ -n "$CHECK_NBD" ]] || fail "could not attach $QCOW2_PATH to any /dev/nbd* device to check for inject-virtio-spice.sh's completion marker"
sudo partprobe "$CHECK_NBD"
sleep 1

NTFS_PART="$(lsblk -no PATH,FSTYPE "$CHECK_NBD" | awk '$2 == "ntfs" { print $1; exit }')"
if [[ -z "$NTFS_PART" ]]; then
  sudo qemu-nbd -d "$CHECK_NBD" >/dev/null 2>&1 || true
  fail "no NTFS partition found on $QCOW2_PATH (via $CHECK_NBD) - is this a valid, fully-applied Windows disk?"
fi

mkdir -p "$CHECK_MNT"
cleanup_check() {
  sudo umount "$CHECK_MNT" 2>/dev/null || true
  sudo qemu-nbd -d "$CHECK_NBD" >/dev/null 2>&1 || true
}
trap cleanup_check EXIT
sudo mount -t ntfs-3g -o ro "$NTFS_PART" "$CHECK_MNT"
MARKER_FOUND=0
[[ -f "${CHECK_MNT}/virtio-spice-injected.marker" ]] && MARKER_FOUND=1
sudo umount "$CHECK_MNT"
sudo qemu-nbd -d "$CHECK_NBD" >/dev/null 2>&1 || true
trap - EXIT

[[ "$MARKER_FOUND" == "1" ]] \
  || fail "${QCOW2_PATH} has not been through inject-virtio-spice.sh (no C:\\virtio-spice-injected.marker found on its Windows volume) - this script's virtio-scsi-pci/QXL/SPICE device model requires it. Run image-apply/inject-virtio-spice.sh against this disk first, or use tools/boot-adhoc-target.sh to boot it directly for testing instead."

VM_NAME="${3:-$(os_computer_name "$OS" | tr '[:upper:]' '[:lower:]')}"

CPUS="${CPUS:-4}"
MEMORY_MB="${MEMORY_MB:-16384}"
EFI_FIRMWARE_CODE="${EFI_FIRMWARE_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
NETWORK="${NETWORK:-default}"

[[ -f "$EFI_FIRMWARE_CODE" ]] || fail "OVMF code file not found at ${EFI_FIRMWARE_CODE} - override via EFI_FIRMWARE_CODE=..."
virsh -c qemu:///system net-info "$NETWORK" >/dev/null 2>&1 \
  || fail "libvirt network '${NETWORK}' does not exist - override via NETWORK=..., or create it (virsh net-define/net-start)"

# Repeated builds reuse the same computer name/vm_name by default (image-apply/lib/common.sh's
# os_computer_name is fixed per OS), so re-registering after a rebuild is the common case, not
# an edge case. Only touch a domain that's actually shut off - refuse to silently undefine
# something that might be in active use.
NVRAM_DIR="${REPO_ROOT}/image-apply/output/registered-vms"
mkdir -p "$NVRAM_DIR"
NVRAM_PATH="${NVRAM_DIR}/${VM_NAME}-efivars.fd"

if virsh -c qemu:///system dominfo "$VM_NAME" >/dev/null 2>&1; then
  STATE="$(virsh -c qemu:///system domstate "$VM_NAME")"
  [[ "$STATE" == "shut off" ]] \
    || fail "libvirt domain '${VM_NAME}' already exists and is '${STATE}' - shut it down (or destroy it) before re-registering"
  echo "==> Domain '${VM_NAME}' already registered and shut off - undefining before re-registering with the fresh build" >&2
  # --nvram: this script owns NVRAM_PATH exclusively (never reused across registrations, per
  # the "always fresh" convention above) - remove the old copy along with the domain rather
  # than leaving it orphaned, then write a brand new one below.
  virsh -c qemu:///system undefine --nvram "$VM_NAME"
fi

cp /usr/share/OVMF/OVMF_VARS_4M.fd "$NVRAM_PATH"

DOMAIN_XML="$(mktemp --suffix=.xml)"
trap 'rm -f "$DOMAIN_XML"' EXIT

# Device model matches what inject-virtio-spice.sh already proved boots (WINDOWS11_VIRTIO_
# SPICE_DRIVERS_PLAN.md): virtio-scsi disk, virtio-net NIC, qxl-vga + a real SPICE channel
# (not VNC-only, unlike the sibling project's own register-vm.sh) including the vdagent
# virtserialport that channel needs for clipboard/resolution sync to actually work. SPICE
# listener is loopback-only with no ticketing/auth, matching this project's own explicit
# choice during Phase 3A testing for a single-operator lab host - not exposed beyond
# 127.0.0.1. cpu mode host-passthrough matches -cpu host used throughout this project's own
# QEMU invocations (windows11-setup-install.sh, inject-virtio-spice.sh, Packer's cpu_model).
cat > "$DOMAIN_XML" <<EOF
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>${MEMORY_MB}</memory>
  <currentMemory unit='MiB'>${MEMORY_MB}</currentMemory>
  <vcpu placement='static'>${CPUS}</vcpu>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>${EFI_FIRMWARE_CODE}</loader>
    <nvram>${NVRAM_PATH}</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='localtime'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${QCOW2_PATH}'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <controller type='scsi' index='0' model='virtio-scsi'/>
    <interface type='network'>
      <source network='${NETWORK}'/>
      <model type='virtio'/>
    </interface>
    <graphics type='spice' autoport='yes' listen='127.0.0.1' tlsPort='-1'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <video>
      <model type='qxl' vgamem='32768'/>
    </video>
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
    </channel>
    <!-- Without this, libvirt defaults to a relative PS/2 mouse, which desyncs from
         SPICE's own absolute cursor position and makes the console unusable (clicks land
         somewhere other than the visible cursor) - see CLAUDE.md's "VM screen inspection"
         section for the full explanation, carried over unchanged from the sibling
         project's own register-vm.sh. -->
    <input type='tablet' bus='usb'/>
  </devices>
</domain>
EOF

echo "==> Defining libvirt domain '${VM_NAME}' from ${QCOW2_PATH}" >&2
virsh -c qemu:///system define "$DOMAIN_XML"

echo "==> Registered '${VM_NAME}' - visible in virt-manager now, shut off." >&2
echo "==> Start it with: virsh -c qemu:///system start ${VM_NAME}" >&2
echo "==> Console (SPICE, loopback-only): virt-viewer --connect qemu:///system ${VM_NAME}" >&2
