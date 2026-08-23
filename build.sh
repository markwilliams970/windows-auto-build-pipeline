#!/usr/bin/env bash
# Production build workflow (CLAUDE.md's "Build" lifecycle, steps 3-8): partition a
# fresh disk, apply the Windows image, make it bootable, specialize it, then hand off to
# Packer for the first real boot and role provisioning. Every real build applies the WIM
# fresh - never reuses a previously-applied disk (CLAUDE.md's "Ephemeral Infrastructure,
# Still" principle). Steps 1-2 (prerequisite validation, ISO acquisition/caching) are not
# implemented here - this assumes ../iso_cache/ is already populated, matching this
# project's current state; see CLAUDE.md's Build step 1-2 for what a future addition
# would need to cover.
#
# Usage: build.sh <server2022|server2025|windows11> [services_yaml_path] [computer_name]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO_ROOT}/image-apply/lib/common.sh"

OS="${1:?Usage: build.sh <server2022|server2025|windows11> [services_yaml_path] [computer_name]}"
SERVICES_YAML="${2:-}"
COMPUTER_NAME_ARG="${3:-}"
validate_os "$OS"

# Single unique identifier for this whole build, reused everywhere downstream (Packer's own
# output_directory/vm_name, the pre-Packer efivars copy, inject-virtio-spice.sh's own
# per-run work dir) so two builds of the same OS never collide on a shared path - this was a
# real, confirmed bug (Packer's qemu builder refuses to run if output_directory already
# exists; the old fixed "output/${OS}" path meant any second build of the same OS always hit
# it). Timestamp-seconds granularity matches this project's own established convention
# (image-apply/output/builds/*.qcow2 already named this way) - not a new scheme.
BUILD_ID="${OS}-$(date +%Y%m%d-%H%M%S)"

BUILD_DIR="${REPO_ROOT}/image-apply/output/builds"
mkdir -p "$BUILD_DIR"
TARGET_QCOW2="${BUILD_DIR}/${BUILD_ID}.qcow2"
# Belt-and-suspenders uniqueness check (the "robust checks" this project's own standards call
# for, not just assuming a fresh timestamp never collides) - practically unreachable under the
# project's serial-builds-only convention, but cheap and fails loud instead of silently
# overwriting a real disk if it's ever wrong.
[[ -e "$TARGET_QCOW2" ]] && { echo "ERROR: ${TARGET_QCOW2} already exists - refusing to overwrite; wait a second and retry, or investigate why a build with this exact id already ran" >&2; exit 1; }

log "=== Build: ${OS} -> ${TARGET_QCOW2} ==="

# Windows 11 takes a completely different path as of Phase 3.4 (PHASE3_ENGINEERING_LOG.md):
# a single Setup.exe-driven script covers partitioning, image install, bootability, and
# specialize/oobeSystem in one unattended qemu session, confirmed via real WinRM inline -
# there is no Packer handoff afterward (Windows 11 has zero Phase 3 roles to provision,
# per CLAUDE.md's standing scope note, and the script already confirms first boot itself).
# Server 2022/2025 are completely untouched by this branch - same partition-disk.sh /
# apply-image.sh / make-bootable.sh / apply-unattend.sh / Packer sequence as always, no
# exception (CLAUDE.md's absolute ban on Microsoft-Windows-Setup for those two OSes).
if [[ "$OS" == "windows11" ]]; then
  log "[1/2] windows11-setup-install.sh (Setup.exe-driven - see PHASE3_ENGINEERING_LOG.md Phase 3.4)"
  if [[ -n "$COMPUTER_NAME_ARG" ]]; then
    "${REPO_ROOT}/image-apply/windows11-setup-install.sh" "$TARGET_QCOW2" "$COMPUTER_NAME_ARG"
  else
    "${REPO_ROOT}/image-apply/windows11-setup-install.sh" "$TARGET_QCOW2"
  fi

  log "[2/2] inject-virtio-spice.sh (Phase 3A - see WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md)"
  "${REPO_ROOT}/image-apply/inject-virtio-spice.sh" "$OS" "$TARGET_QCOW2"

  log "Build complete: ${TARGET_QCOW2} (Windows 11 - virtio-scsi/virtio-net/qxl+SPICE, no Packer handoff, no roles to provision)"
  exit 0
fi

log "[1/4] partition-disk.sh"
"${REPO_ROOT}/image-apply/partition-disk.sh" "$OS" "$TARGET_QCOW2"

log "[2/4] apply-image.sh"
"${REPO_ROOT}/image-apply/apply-image.sh" "$OS" "$TARGET_QCOW2"

log "[3/4] make-bootable.sh"
"${REPO_ROOT}/image-apply/make-bootable.sh" "$OS" "$TARGET_QCOW2"

log "[4/4] apply-unattend.sh"
if [[ -n "$COMPUTER_NAME_ARG" ]]; then
  "${REPO_ROOT}/image-apply/apply-unattend.sh" "$OS" "$TARGET_QCOW2" "$COMPUTER_NAME_ARG"
else
  "${REPO_ROOT}/image-apply/apply-unattend.sh" "$OS" "$TARGET_QCOW2"
fi

log "image-apply pipeline complete: ${TARGET_QCOW2}"

DISK_SIZE_MB=$(( $(os_disk_size_gb "$OS") * 1024 ))

log "Handing off to Packer for first real boot + role provisioning"
PACKER_DIR="${REPO_ROOT}/packer"
mkdir -p "${PACKER_DIR}/output"
PACKER_EFIVARS="${PACKER_DIR}/output/${BUILD_ID}-efivars.fd"
PACKER_OUTPUT_DIR="${PACKER_DIR}/output/${BUILD_ID}"
[[ -e "$PACKER_EFIVARS" || -e "$PACKER_OUTPUT_DIR" ]] && { echo "ERROR: ${PACKER_EFIVARS} or ${PACKER_OUTPUT_DIR} already exists - refusing to overwrite; investigate before retrying" >&2; exit 1; }
# Packer's qemu builder expects efi_firmware_vars to already exist (it doesn't create
# one from scratch) - a fresh copy per build, matching dev/run-phase3-test.sh's same
# pattern.
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$PACKER_EFIVARS"
packer init "${PACKER_DIR}/boot-and-provision.pkr.hcl"

PACKER_ARGS=(
  -var "target_os=${OS}"
  -var "build_id=${BUILD_ID}"
  -var "source_qcow2=${TARGET_QCOW2}"
  -var "disk_size_mb=${DISK_SIZE_MB}"
)
if [[ -n "$SERVICES_YAML" ]]; then
  PACKER_ARGS+=(-var "services_yaml_path=${SERVICES_YAML}")
fi

packer validate "${PACKER_ARGS[@]}" "$PACKER_DIR"
packer build "${PACKER_ARGS[@]}" "$PACKER_DIR"

# Phase 3A (WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md): runs against Packer's own final,
# already-role-provisioned artifact (not the pre-Packer TARGET_QCOW2 above) - vioscsi +
# QXL/SPICE for every OS; NIC stays on the existing, already-proven offline-hivex netkvm
# mechanism this disk already booted on during the Packer run just above (untouched, per
# Finding 3A-2 - "never relocate an already-working device"). Windows 11's own build path
# (the branch above, exited already) wires this in the equivalent spot in its own sequence.
# PROVISIONED_QCOW2's own BUILD_ID-based path also fixes a second collision this same bug
# would otherwise have caused: inject-virtio-spice.sh derives ITS OWN per-run work directory
# from this file's basename (RUN_ID) - a fixed "${OS}.qcow2" name would have collided there
# too, one level down, even after the Packer output_directory fix above.
PROVISIONED_QCOW2="${PACKER_OUTPUT_DIR}/${BUILD_ID}.qcow2"
log "[Phase 3A] inject-virtio-spice.sh (vioscsi + QXL/SPICE - see WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md)"
"${REPO_ROOT}/image-apply/inject-virtio-spice.sh" "$OS" "$PROVISIONED_QCOW2"

log "Build complete: ${PROVISIONED_QCOW2} (virtio-scsi/virtio-net/qxl+SPICE, roles provisioned - image-apply's own pre-Packer copy at ${TARGET_QCOW2} is now stale, superseded by this one)"
