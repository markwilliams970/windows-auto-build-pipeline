#!/usr/bin/env bash
# EXPERIMENT ONLY - see server2025-noprompt-setup-experiment.sh's header for full context.
#
# Builds the combined answer-file + virtio-driver CD this experiment's virtio pass needs,
# matching ../../windows-server-vm-automation/build.sh's own proven recipe exactly: same
# xorriso extraction of vioscsi/viostor/NetKVM's "2k25" subfolder from the cached
# virtio-win ISO, same chmod -R u+rwX fix for xorriso's read-only extracted permission
# bits, same .pdb strip. autounattend.xml sits at the CD root alongside those three driver
# directories (not a separate CD) - this is the same single-CD "unattend"-labeled layout
# windows-server-vm-automation's own windows-server.pkr.hcl cd_files/cd_content uses, and
# is why the answer file's DriverPaths list both D:\ and E:\ for every driver (drive-letter
# order between this CD and the install CD isn't deterministic).
#
# Usage: build-unattend-drivers-iso-server2025-virtio.sh [output-iso-path]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

OUT_DIR="${REPO_ROOT}/image-apply/output/experiments/unattend-drivers-server2025-virtio"
OUT_ISO="${1:-${OUT_DIR}/unattend-drivers.iso}"
STAGING_DIR="${OUT_DIR}/staging"
XML_SRC="${SCRIPT_DIR}/autounattend-server2025-noprompt-virtio-experiment.xml"

VIRTIO_OS_DIR="$(os_driver_subfolder server2025)"  # "2k25"

verify_iso() {
  local iso="$1"
  [[ -f "$iso" ]] || return 1
  # Case-insensitive: mkisofs uppercases the primary ISO9660 volume id
  # regardless of what's passed to -V, while the Joliet descriptor (what
  # Windows actually reads via Get-Volume) keeps the requested case - matching
  # production's cd_label = "unattend" and the FirstLogonCommands fallback's
  # own 'unattend' string exactly, not introducing a second casing variant.
  isoinfo -d -i "$iso" 2>/dev/null | grep -qi "^Volume id: unattend$" || return 1
  isoinfo -R -i "$iso" -x "/vioscsi/${VIRTIO_OS_DIR}/amd64/vioscsi.sys" >/dev/null 2>&1 || return 1
  isoinfo -R -i "$iso" -x "/netkvm/${VIRTIO_OS_DIR}/amd64/netkvm.sys" >/dev/null 2>&1 || return 1
  isoinfo -R -i "$iso" -x "/autounattend.xml" 2>/dev/null | cmp -s - "$XML_SRC" || return 1
  return 0
}

if verify_iso "$OUT_ISO"; then
  log "Reusing already-built, verified ${OUT_ISO}"
  exit 0
fi

[[ -f "$XML_SRC" ]] || { echo "ERROR: answer file template not found at $XML_SRC" >&2; exit 1; }
[[ -f "$VIRTIO_WIN_ISO" ]] || { echo "ERROR: $VIRTIO_WIN_ISO not found" >&2; exit 1; }

log "Extracting virtio ${VIRTIO_OS_DIR} drivers (vioscsi/viostor/NetKVM) from ${VIRTIO_WIN_ISO}"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
xorriso -indev "$VIRTIO_WIN_ISO" -osirrox on \
  -extract "/vioscsi/${VIRTIO_OS_DIR}" "${STAGING_DIR}/vioscsi/${VIRTIO_OS_DIR}" \
  -extract "/viostor/${VIRTIO_OS_DIR}" "${STAGING_DIR}/viostor/${VIRTIO_OS_DIR}" \
  -extract "/NetKVM/${VIRTIO_OS_DIR}" "${STAGING_DIR}/NetKVM/${VIRTIO_OS_DIR}" \
  >/dev/null
# xorriso preserves the source ISO's own read-only permission bits - same fix as
# windows-server-vm-automation/build.sh applies for the identical reason.
chmod -R u+rwX "$STAGING_DIR"
find "$STAGING_DIR" -type f -name '*.pdb' -delete

cp "$XML_SRC" "${STAGING_DIR}/autounattend.xml"

log "Building combined answer-file + driver ISO -> ${OUT_ISO}"
mkdir -p "$OUT_DIR"
rm -f "$OUT_ISO"
mkisofs -quiet -o "$OUT_ISO" -J -r -V "unattend" "$STAGING_DIR"

verify_iso "$OUT_ISO" || { echo "ERROR: rebuilt ISO at $OUT_ISO failed verification" >&2; exit 1; }
log "build-unattend-drivers-iso-server2025-virtio.sh complete and verified: ${OUT_ISO}"
