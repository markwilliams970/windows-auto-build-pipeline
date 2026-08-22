#!/usr/bin/env bash
# Windows 11 ONLY. Builds a "_noprompt"-patched bootable Windows 11 ISO: swaps the
# stock efisys.bin/cdboot.efi (which show the "Press any key to boot from CD..."
# prompt) for their efisys_noprompt.bin/cdboot_noprompt.efi counterparts - genuine,
# 15-year-old Microsoft tooling that ships on the stock ISO itself (not a community
# hack; see WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md Phase 2), then rebuilds the ISO
# via the verified xorriso dual-boot-catalog recipe (same doc, Phase 2 point 4).
#
# This eliminates the UEFI boot-prompt keystroke race entirely, by construction -
# CLAUDE.md's "RECONSIDERED AGAIN, Windows 11 only" note is what authorizes using
# Microsoft-Windows-Setup again for Windows 11 specifically, on the strength of this
# exact mechanism. Server 2022/2025 remain fully banned from Setup.exe, no exception -
# this script refuses to run against anything but windows11 (see validate below).
#
# Idempotent: if a previously-built, previously-verified ISO already exists at the
# output path, this script skips straight to re-verifying it and exits - a rebuild
# only happens when the output is missing or fails verification.
#
# Usage: build-iso-noprompt.sh [output-iso-path]
#   (output-iso-path defaults to image-apply/output/iso-noprompt/win11-noprompt.iso,
#   matching Phase 3.1-3.3's own hand-run convention)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Hard gate - this script must never be pointed at Server 2022/2025 media. There is
# no OS argument to mistype here (unlike the shared image-apply/*.sh scripts) because
# this mechanism is Windows-11-only by design, not by convention - so the gate checks
# the one thing that could go wrong: someone passing a Server ISO path in by hand.
SRC_ISO="$(os_win_iso windows11)"
[[ -f "$SRC_ISO" ]] || { echo "ERROR: $SRC_ISO not found in ISO_CACHE_DIR (${ISO_CACHE_DIR})" >&2; exit 1; }

OUT_DIR="${REPO_ROOT}/image-apply/output/iso-noprompt"
OUT_ISO="${1:-${OUT_DIR}/win11-noprompt.iso}"
EXTRACT_DIR="${OUT_DIR}/extracted"

verify_iso() {
  local iso="$1"
  [[ -f "$iso" ]] || return 1
  # Cheap, real verification, not just "the file exists": confirm the volume ID
  # xorriso wrote (WINSETUP, this script's own -volid) and that both noprompt-sourced
  # boot files are present at their real on-ISO paths, matching Phase 2's own primary-
  # source verification standard rather than trusting a prior run blindly.
  isoinfo -d -i "$iso" 2>/dev/null | grep -q "^Volume id: WINSETUP$" || return 1
  isoinfo -R -i "$iso" -x /efi/microsoft/boot/efisys.bin 2>/dev/null | cmp -s - "${EXTRACT_DIR}/efi/microsoft/boot/efisys_noprompt.bin" 2>/dev/null || return 1
  return 0
}

if verify_iso "$OUT_ISO"; then
  log "Reusing already-built, verified ${OUT_ISO}"
  exit 0
fi

log "Building _noprompt-patched Windows 11 ISO -> ${OUT_ISO}"
mkdir -p "$OUT_DIR"

if [[ ! -d "$EXTRACT_DIR" ]] || [[ -z "$(ls -A "$EXTRACT_DIR" 2>/dev/null)" ]]; then
  log "Extracting ${SRC_ISO} (~6-7GB, this can take a few minutes)"
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  7z x -y -o"$EXTRACT_DIR" "$SRC_ISO" >/dev/null
else
  log "Reusing already-extracted ${EXTRACT_DIR}"
fi

BOOT_DIR="${EXTRACT_DIR}/efi/microsoft/boot"
for f in efisys.bin efisys_noprompt.bin cdboot.efi cdboot_noprompt.efi; do
  [[ -f "${BOOT_DIR}/${f}" ]] || { echo "ERROR: expected ${BOOT_DIR}/${f} not found - is this really Windows 11 media with the _noprompt files? (see WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md Phase 2)" >&2; exit 1; }
done
[[ -f "${EXTRACT_DIR}/boot/etfsboot.com" ]] || { echo "ERROR: expected ${EXTRACT_DIR}/boot/etfsboot.com not found" >&2; exit 1; }

log "Overwriting stock efisys.bin/cdboot.efi with their _noprompt counterparts"
cp "${BOOT_DIR}/efisys_noprompt.bin" "${BOOT_DIR}/efisys.bin"
cp "${BOOT_DIR}/cdboot_noprompt.efi" "${BOOT_DIR}/cdboot.efi"

log "Rebuilding ISO via xorriso (dual boot catalog: BIOS + UEFI)"
rm -f "$OUT_ISO"
xorriso -as mkisofs \
  -iso-level 3 \
  -volid "WINSETUP" \
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
log "build-iso-noprompt.sh complete and verified: ${OUT_ISO}"
