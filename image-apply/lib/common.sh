#!/usr/bin/env bash
# Shared config/helpers for image-apply/*.sh. Source this, don't execute it.
#
# OS-specific values below (WIM image index, virtio-win driver subfolder, disk size,
# ComputerName prefix) are transcribed directly from PHASE2_ENGINEERING_LOG.md's own
# independently-verified findings for each OS - not assumed to generalize from one
# to the next, per this project's own "verify before trusting" standard:
#   - Server 2022 index 2 / Server 2025 index 2: Session 12 Finding 42, Finding 0
#   - Windows 11 index 1 (only image in the WIM): Session 13 Finding 43
#   - Server 2019 index 2: WINDOWS_SERVER_2019_RESEARCH_PLAN.md Finding 3 (verified via
#     `wimlib-imagex info` during Phase A research, not a live bring-up session - the one
#     value here with a different provenance than the other three, called out explicitly
#     per this project's own standard of not overstating a citation's origin)
#   - Driver subfolders (2k19/2k22/2k25/w11): confirmed via `7z l` against virtio-win-0.1.285.iso
#     (2k19 additionally hash-verified byte-identical to 2k22's INF/driver files - Finding 4/5)
#   - Windows 11's 64GB disk size: Session 13 Finding 43 (matches Windows 11's documented
#     minimum storage requirement - the offline-apply path doesn't evaluate the check that
#     would otherwise flag a smaller disk, but there's no reason to invite the question)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ISO_CACHE_DIR="${ISO_CACHE_DIR:-${REPO_ROOT}/../iso_cache}"

# Overridable via env for future ISO version bumps - see ../iso_cache/'s own
# currency-check convention (CLAUDE.md's "Relationship to ../windows-server-vm-automation/").
VIRTIO_WIN_ISO="${VIRTIO_WIN_ISO:-${ISO_CACHE_DIR}/virtio-win-0.1.285.iso}"

os_win_iso() {
  case "$1" in
    server2019) echo "${ISO_CACHE_DIR}/2019-17763.3650.221105-1748.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso" ;;
    server2022) echo "${ISO_CACHE_DIR}/2022-SERVER_EVAL_x64FRE_en-us.iso" ;;
    server2025) echo "${ISO_CACHE_DIR}/2025-26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso" ;;
    windows11)  echo "${ISO_CACHE_DIR}/win11ent-CLIENTENTERPRISEEVAL_x64FRE_en-us.iso" ;;
    *) echo "os_win_iso: unknown OS '$1'" >&2; return 1 ;;
  esac
}

os_wim_index() {
  case "$1" in
    server2019) echo 2 ;;  # "Windows Server 2019 SERVERSTANDARD", ServerStandardEval
    server2022) echo 2 ;;  # "Windows Server 2022 SERVERSTANDARD", ServerStandardEval
    server2025) echo 2 ;;  # "Windows Server 2025 SERVERSTANDARD", ServerStandardEval
    windows11)  echo 1 ;;  # "Windows 11 Enterprise Evaluation" - only image in the WIM
    *) echo "os_wim_index: unknown OS '$1'" >&2; return 1 ;;
  esac
}

os_driver_subfolder() {
  case "$1" in
    server2019) echo "2k19" ;;
    server2022) echo "2k22" ;;
    server2025) echo "2k25" ;;
    windows11)  echo "w11" ;;
    *) echo "os_driver_subfolder: unknown OS '$1'" >&2; return 1 ;;
  esac
}

os_disk_size_gb() {
  case "$1" in
    server2019|server2022|server2025) echo 40 ;;
    windows11) echo 64 ;;
    *) echo "os_disk_size_gb: unknown OS '$1'" >&2; return 1 ;;
  esac
}

os_computer_name() {
  case "$1" in
    server2019) echo "WIN2019PROD" ;;
    server2022) echo "WIN2022PROD" ;;
    server2025) echo "WIN2025PROD" ;;
    windows11)  echo "WIN11PROD" ;;
    *) echo "os_computer_name: unknown OS '$1'" >&2; return 1 ;;
  esac
}

validate_os() {
  case "$1" in
    server2019|server2022|server2025|windows11) return 0 ;;
    *) echo "Unknown OS '$1' - expected server2019, server2022, server2025, or windows11" >&2; return 1 ;;
  esac
}

log() { echo "==> $*"; }
