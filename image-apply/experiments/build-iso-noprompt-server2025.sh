#!/usr/bin/env bash
# EXPERIMENT ONLY - see server2025-noprompt-setup-experiment.sh's header for the full
# context. This is a Server-2025-targeted sibling of the production
# image-apply/build-iso-noprompt.sh (which is Windows-11-only, hard-gated, and
# untouched by this file). Same technique, same verified xorriso recipe
# (project_documentation/WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md Phase 2), different source ISO.
#
# Deliberately kept as its own small script rather than parameterizing the production
# one - this keeps CLAUDE.md's existing "Windows 11 only, no exception" gate on
# build-iso-noprompt.sh completely intact and unambiguous, per the explicit scoping
# agreed for this experiment.
#
# Usage: build-iso-noprompt-server2025.sh [output-iso-path]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

SRC_ISO="$(os_win_iso server2025)"
[[ -f "$SRC_ISO" ]] || { echo "ERROR: $SRC_ISO not found in ISO_CACHE_DIR (${ISO_CACHE_DIR})" >&2; exit 1; }

OUT_DIR="${REPO_ROOT}/image-apply/output/experiments/iso-noprompt-server2025"
OUT_ISO="${1:-${OUT_DIR}/server2025-noprompt.iso}"
EXTRACT_DIR="${OUT_DIR}/extracted"

verify_iso() {
  local iso="$1"
  [[ -f "$iso" ]] || return 1
  isoinfo -d -i "$iso" 2>/dev/null | grep -q "^Volume id: WINSETUP2025$" || return 1
  isoinfo -R -i "$iso" -x /efi/microsoft/boot/efisys.bin 2>/dev/null | cmp -s - "${EXTRACT_DIR}/efi/microsoft/boot/efisys_noprompt.bin" 2>/dev/null || return 1
  return 0
}

if verify_iso "$OUT_ISO"; then
  log "Reusing already-built, verified ${OUT_ISO}"
  exit 0
fi

log "Building _noprompt-patched Windows Server 2025 ISO -> ${OUT_ISO}"
mkdir -p "$OUT_DIR"

if [[ ! -d "$EXTRACT_DIR" ]] || [[ -z "$(ls -A "$EXTRACT_DIR" 2>/dev/null)" ]]; then
  log "Extracting ${SRC_ISO} (~8GB, this can take a few minutes)"
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  7z x -y -o"$EXTRACT_DIR" "$SRC_ISO" >/dev/null
else
  log "Reusing already-extracted ${EXTRACT_DIR}"
fi

BOOT_DIR="${EXTRACT_DIR}/efi/microsoft/boot"
for f in efisys.bin efisys_noprompt.bin cdboot.efi cdboot_noprompt.efi; do
  [[ -f "${BOOT_DIR}/${f}" ]] || { echo "ERROR: expected ${BOOT_DIR}/${f} not found - is this really Server 2025 media with the _noprompt files?" >&2; exit 1; }
done
[[ -f "${EXTRACT_DIR}/boot/etfsboot.com" ]] || { echo "ERROR: expected ${EXTRACT_DIR}/boot/etfsboot.com not found" >&2; exit 1; }

log "Overwriting stock efisys.bin/cdboot.efi with their _noprompt counterparts"
cp "${BOOT_DIR}/efisys_noprompt.bin" "${BOOT_DIR}/efisys.bin"
cp "${BOOT_DIR}/cdboot_noprompt.efi" "${BOOT_DIR}/cdboot.efi"

log "Rebuilding ISO via xorriso (dual boot catalog: BIOS + UEFI)"
rm -f "$OUT_ISO"
xorriso -as mkisofs \
  -iso-level 3 \
  -volid "WINSETUP2025" \
  -eltorito-boot boot/etfsboot.com \
    -eltorito-catalog boot/boot.cat \
    -no-emul-boot \
    -boot-load-size 8 \
    -boot-info-table \
  -eltorito-alt-boot \
    -e efi/microsoft/boot/efisys.bin \
    -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o "$OUT_ISO" \
  "$EXTRACT_DIR" \
  >/dev/null

verify_iso "$OUT_ISO" || { echo "ERROR: rebuilt ISO at $OUT_ISO failed verification" >&2; exit 1; }
log "build-iso-noprompt-server2025.sh complete and verified: ${OUT_ISO}"
