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

BUILD_DIR="${REPO_ROOT}/image-apply/output/builds"
mkdir -p "$BUILD_DIR"
TARGET_QCOW2="${BUILD_DIR}/${OS}-$(date +%Y%m%d-%H%M%S).qcow2"

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
  log "[1/1] windows11-setup-install.sh (Setup.exe-driven - see PHASE3_ENGINEERING_LOG.md Phase 3.4)"
  if [[ -n "$COMPUTER_NAME_ARG" ]]; then
    "${REPO_ROOT}/image-apply/windows11-setup-install.sh" "$TARGET_QCOW2" "$COMPUTER_NAME_ARG"
  else
    "${REPO_ROOT}/image-apply/windows11-setup-install.sh" "$TARGET_QCOW2"
  fi
  log "Build complete: ${TARGET_QCOW2} (Windows 11 - no Packer handoff, no roles to provision)"
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
# Packer's qemu builder expects efi_firmware_vars to already exist (it doesn't create
# one from scratch) - a fresh copy per build, matching dev/run-phase3-test.sh's same
# pattern.
cp /usr/share/OVMF/OVMF_VARS_4M.fd "${PACKER_DIR}/output/${OS}-efivars.fd"
packer init "${PACKER_DIR}/boot-and-provision.pkr.hcl"

PACKER_ARGS=(
  -var "target_os=${OS}"
  -var "source_qcow2=${TARGET_QCOW2}"
  -var "disk_size_mb=${DISK_SIZE_MB}"
)
if [[ -n "$SERVICES_YAML" ]]; then
  PACKER_ARGS+=(-var "services_yaml_path=${SERVICES_YAML}")
fi

packer validate "${PACKER_ARGS[@]}" "$PACKER_DIR"
packer build "${PACKER_ARGS[@]}" "$PACKER_DIR"

log "Build complete: ${TARGET_QCOW2}, provisioned output under packer/output/${OS}/"
