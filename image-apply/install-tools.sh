#!/usr/bin/env bash
# Phase 4 tool installer stage (project_documentation/PHASE4_TOOLS_INSTALLER_PLAN.md). Runs after inject-virtio-spice.sh
# in build.sh, against the final, already-role-provisioned, already-SPICE-injected artifact - by
# this point storage is virtio-scsi and NIC is virtio-net for every OS (Phase 3A ran unconditionally
# just before this), so this script needs no OS branching in its own QEMU device model at all,
# unlike inject-virtio-spice.sh.
#
# Five of the six tools (7zip/putty/winscp/chrome/notepadplusplus) are deliberately NOT pinned or
# cached in ../iso_cache/ - they churn far faster than the Windows ISOs that convention exists for,
# and pinning them would just relocate the staleness problem this project's own
# "Version-sensitivity and brittleness" standard already warns about. Instead this script resolves
# and downloads each one's CURRENT version fresh, from the Linux host, on every single invocation -
# see project_documentation/PHASE4_TOOLS_INSTALLER_PLAN.md's A.1/A.3 revision (2026-09-03) for the full reasoning,
# including why this stays host-side rather than delegating the download to the guest (guest-side
# download would reintroduce the exact "hidden dependency" - live internet access from inside the
# guest at exactly the right unattended moment - that got Chocolatey rejected in this project's own
# Phase 4 research).
#
# datadog-agent is the one deliberate exception: pinned to tools.yaml's datadog.agent_version,
# since the Agent's version can affect monitoring-integration test comparability build-to-build.
#
# Matches image-apply/inject-virtio-spice.sh's own established pattern: mounted delivery ISO (not
# WinRM file transfer), a short WinRM call that invokes a file already on that ISO (not an inlined
# script - sidesteps the WinRS command-line length ceiling entirely, see the winrm_ps comment
# below), graceful QMP shutdown, never a hard kill on a disk meant to be reused.
#
# Usage: install-tools.sh <server2019|server2022|server2025|windows11> <target-qcow2-path> [tools_yaml_path] [Install|Uninstall|Status]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OS="${1:?Usage: install-tools.sh <server2019|server2022|server2025|windows11> <target-qcow2-path> [tools_yaml_path] [Install|Uninstall|Status]}"
TARGET_QCOW2="${2:?Usage: install-tools.sh <server2019|server2022|server2025|windows11> <target-qcow2-path> [tools_yaml_path] [Install|Uninstall|Status]}"
TOOLS_YAML_PATH="${3:-${REPO_ROOT}/tools.yaml}"
MODE="${4:-Install}"
validate_os "$OS"
[[ -f "$TARGET_QCOW2" ]] || { echo "ERROR: $TARGET_QCOW2 not found - build it first" >&2; exit 1; }
[[ -f "$TOOLS_YAML_PATH" ]] || { echo "ERROR: $TOOLS_YAML_PATH not found" >&2; exit 1; }
case "$MODE" in Install|Uninstall|Status) ;; *) echo "ERROR: mode must be Install, Uninstall, or Status (got '$MODE')" >&2; exit 1 ;; esac

ADMIN_PASSWORD="${ADMIN_PASSWORD:-TestP@ssw0rd123}"
WINRM_PORT="${WINRM_PORT:-15985}"
WINRM_TIMEOUT_SEC="${WINRM_TIMEOUT_SEC:-600}"
WINRM_RETRY_SEC="${WINRM_RETRY_SEC:-15}"

# --- tools.yaml parsing (host side) - same section-tracking approach as scripts/install-tools.ps1's
# own Read-ToolsYaml, kept in sync deliberately rather than sharing a parser across bash/PowerShell.
parse_selected_tools() {
  awk '
    /^tools:[[:space:]]*$/ { insec=1; next }
    /^[^[:space:]#]/ && !/^tools:/ { insec=0 }
    insec && /^[[:space:]]*-[[:space:]]*[A-Za-z0-9_-]+/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
    }
  ' "$TOOLS_YAML_PATH"
}

parse_datadog_agent_version() {
  awk '
    /^datadog:[[:space:]]*$/ { insec=1; next }
    /^[^[:space:]#]/ && !/^datadog:/ { insec=0 }
    insec && /^[[:space:]]*agent_version:/ {
      line=$0
      sub(/^[[:space:]]*agent_version:[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/"/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$TOOLS_YAML_PATH"
}

mapfile -t SELECTED_TOOLS < <(parse_selected_tools)
if [[ ${#SELECTED_TOOLS[@]} -eq 0 ]]; then
  log "No tools selected in ${TOOLS_YAML_PATH} - nothing to do"
  exit 0
fi

DD_AGENT_VERSION="$(parse_datadog_agent_version)"

NEEDS_DATADOG=false
for t in "${SELECTED_TOOLS[@]}"; do [[ "$t" == "datadog-agent" ]] && NEEDS_DATADOG=true; done

# Fail loud, before ever starting QEMU - Phase C decision #3 (project_documentation/PHASE4_TOOLS_INSTALLER_PLAN.md).
if [[ "$NEEDS_DATADOG" == "true" && "$MODE" == "Install" && -z "${DD_API_KEY:-}" ]]; then
  echo "ERROR: tools.yaml lists datadog-agent but \$DD_API_KEY is unset - refusing to boot the VM and install the Agent unconfigured. Set DD_API_KEY or remove datadog-agent from ${TOOLS_YAML_PATH}." >&2
  exit 1
fi

RUN_ID="$(basename "$TARGET_QCOW2" .qcow2)"
WORK_DIR="${REPO_ROOT}/image-apply/output/tools-install-work/${RUN_ID}"
STAGING_DIR="${WORK_DIR}/staging"
# Unlike inject-virtio-spice.sh's spice-tools.iso (built once, reused across invocations for the
# same RUN_ID, since spice-guest-tools-latest.exe is a static cached file), this stage's staging
# dir - and the ISO built from it - is wiped and rebuilt fresh on EVERY invocation: reusing a
# previously-built one would silently defeat the entire point of "always fetch current" (A.3).
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
MANIFEST="${STAGING_DIR}/manifest.txt"
: > "$MANIFEST"

# --- per-tool "find the current installer" resolvers, each setting DL_URL (+ DL_VERSION where
# knowable) - every one of these was verified against a real, live HTTP request during
# project_documentation/PHASE4_TOOLS_INSTALLER_PLAN.md's research pass, not guessed. See that doc's A.3 table for the
# full citation trail (SourceForge redirects, a GitHub API call, an HTML scrape, Google's own
# permanent URL, and Datadog's documented versioned-MSI convention).

resolve_7zip() {
  local redirect ver
  redirect=$(curl -sIL --max-time 30 -o /dev/null -w '%{url_effective}' "https://sourceforge.net/projects/sevenzip/files/latest/download")
  ver=$(echo "$redirect" | grep -oE '7z[0-9]+' | head -1 | sed 's/7z//')
  [[ -n "$ver" ]] || { echo "ERROR: could not resolve the current 7-Zip version from SourceForge's latest-download redirect (got: $redirect)" >&2; return 1; }
  DL_URL="https://www.7-zip.org/a/7z${ver}-x64.msi"
  DL_VERSION="$ver"
}

resolve_putty() {
  local html href
  html=$(curl -sL --max-time 30 "https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html")
  href=$(echo "$html" | grep -oE 'href="[^"]*w64/putty-64bit-[0-9.]+-installer\.msi"' | head -1 | sed -E 's/^href="//; s/"$//')
  [[ -n "$href" ]] || { echo "ERROR: could not find a PuTTY w64 MSI link on chiark's latest.html page" >&2; return 1; }
  DL_URL="$href"
  DL_VERSION="$(echo "$href" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
}

resolve_winscp() {
  local redirect
  redirect=$(curl -sIL --max-time 30 -o /dev/null -w '%{url_effective}' "https://sourceforge.net/projects/winscp/files/latest/download")
  [[ -n "$redirect" ]] || { echo "ERROR: could not resolve the current WinSCP download URL from SourceForge" >&2; return 1; }
  DL_URL="$redirect"
  DL_VERSION="$(echo "$redirect" | grep -oE 'WinSCP-[0-9.]+-Setup' | grep -oE '[0-9.]+' | head -1)"
}

resolve_notepadplusplus() {
  local json url
  json=$(curl -sL --max-time 30 "https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest")
  url=$(echo "$json" | grep -oE '"browser_download_url": *"[^"]*Installer\.x64\.msi"' | grep -v '\.sig"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
  [[ -n "$url" ]] || { echo "ERROR: could not find a Notepad++ x64 MSI asset in the latest GitHub release" >&2; return 1; }
  DL_URL="$url"
  DL_VERSION="$(echo "$url" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -1)"
}

resolve_chrome() {
  # Google's own permanent, always-latest-stable URL - no version parsing possible or needed.
  DL_URL="https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi"
  DL_VERSION="latest-stable"
}

resolve_datadog_agent() {
  [[ -n "$DD_AGENT_VERSION" ]] || { echo "ERROR: datadog.agent_version not set in ${TOOLS_YAML_PATH}" >&2; return 1; }
  # URL pattern confirmed against Datadog's own Chef cookbook source (chef-datadog's
  # _install-windows.rb/attributes/default.rb), then live-verified against real published
  # versions - see project_documentation/PHASE4_TOOLS_INSTALLER_PLAN.md A.3.
  DL_URL="https://windows-agent.datadoghq.com/ddagent-cli-${DD_AGENT_VERSION}.msi"
  DL_VERSION="$DD_AGENT_VERSION"
}

fetch_tool() {
  local name="$1" staged_name="$2"
  case "$name" in
    7zip) resolve_7zip ;;
    putty) resolve_putty ;;
    winscp) resolve_winscp ;;
    notepadplusplus) resolve_notepadplusplus ;;
    chrome) resolve_chrome ;;
    datadog-agent) resolve_datadog_agent ;;
    *) echo "ERROR: no resolver for tool '$name'" >&2; return 1 ;;
  esac
  log "Fetching ${name} (version ${DL_VERSION}) from ${DL_URL}"
  curl -sL --max-time 300 -o "${STAGING_DIR}/${staged_name}" "$DL_URL"
  [[ -s "${STAGING_DIR}/${staged_name}" ]] || { echo "ERROR: download of ${name} produced an empty or missing file" >&2; return 1; }
  echo "${name} ${DL_VERSION} ${DL_URL}" >> "$MANIFEST"
}

if [[ "$MODE" == "Install" ]]; then
  for t in "${SELECTED_TOOLS[@]}"; do
    case "$t" in
      7zip)             fetch_tool "7zip" "7zip.msi" ;;
      putty)            fetch_tool "putty" "putty.msi" ;;
      winscp)           fetch_tool "winscp" "winscp.exe" ;;
      notepadplusplus)  fetch_tool "notepadplusplus" "notepadplusplus.msi" ;;
      chrome)           fetch_tool "chrome" "chrome.msi" ;;
      datadog-agent)    fetch_tool "datadog-agent" "datadog-agent.msi" ;;
      *) echo "WARNING: no known installer for tool '$t' listed in ${TOOLS_YAML_PATH} - skipping" >&2 ;;
    esac
  done
else
  log "Mode=${MODE}: skipping host-side installer downloads (not needed for uninstall/status)"
fi

cp "$TOOLS_YAML_PATH" "${STAGING_DIR}/tools.yaml"
cp "${REPO_ROOT}/scripts/install-tools.ps1" "${STAGING_DIR}/install-tools.ps1"

TOOLS_ISO="${WORK_DIR}/tools-delivery.iso"
mkisofs -quiet -o "$TOOLS_ISO" -J -r -V "TOOLSCD" "$STAGING_DIR"

OVMF_VARS_RUN="${WORK_DIR}/OVMF_VARS.fd"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OVMF_VARS_RUN"

# --- WinRM/QMP helpers, copied from image-apply/inject-virtio-spice.sh's own established pattern
# (see that script's header comments for the full rationale on each) rather than factored into
# lib/common.sh - matches this project's existing convention of each QEMU-driving script carrying
# its own copies (windows11-setup-install.sh does the same).

assert_winrm_ps_budget() {
  local ps_script="$1"
  local char_count=${#ps_script}
  local b64_len=$(( ((char_count * 2) + 2) / 3 * 4 ))
  local total_len=$(( b64_len + 28 ))
  local safe_limit=7800
  if (( total_len > safe_limit )); then
    echo "ERROR: winrm_ps payload too large (${char_count} PS chars -> ~${total_len} encoded WinRS command chars, safe budget ${safe_limit}) - shrink the payload rather than raising this limit; see inject-virtio-spice.sh's own assert_winrm_ps_budget comment for the full story." >&2
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

wait_for_winrm() {
  local qemu_pid="$1"
  local qemu_log="$2"
  log "Waiting for WinRM on 127.0.0.1:${WINRM_PORT} (up to ${WINRM_TIMEOUT_SEC}s)"
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

# --- boot: storage=virtio-scsi, NIC=virtio-net, no OS branching - inject-virtio-spice.sh already
# put every OS on this exact device model unconditionally just before this stage runs. No display
# device is attached (pure WinRM/msiexec silent installs don't need one), which also sidesteps
# inject-virtio-spice.sh's own first-boot vdservice/QXL race entirely - nothing here depends on it.
QMP_SOCK="/tmp/installtools-${RUN_ID}.sock"
rm -f "$QMP_SOCK"

QEMU_ARGS=(
  -machine q35,accel=kvm -cpu host -smp 4 -m 4096
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
  -drive if=pflash,format=raw,file="$OVMF_VARS_RUN"
  -drive "file=${TARGET_QCOW2},if=none,id=target,format=qcow2"
  # Explicit pcie-root-port placement (same addr/chassis/port as inject-virtio-spice.sh's own
  # Stage 2, which is what actually made this disk boot on virtio-scsi in the first place) -
  # NOT an implicit/default bus placement. Finding 3A-3 (project_documentation/WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md)
  # found that PCI topology, not just drive presence, affects which hardware ID a virtio-scsi-pci
  # controller negotiates - an implicit placement here negotiated a different ID than what's
  # registered in the guest's DriverDatabase, producing an INACCESSIBLE_BOOT_DEVICE-style failure
  # that triggered WinRE's automatic repair instead of a normal boot (confirmed via a QMP
  # screendump: the boot landed on WinRE/Setup's shared "Choose your keyboard layout" screen, not
  # a real desktop). Matching Stage 2's exact topology is the deterministic fix, not a guess.
  -device pcie-root-port,id=rp_scsi,bus=pcie.0,addr=0x6,chassis=1,port=1
  -device virtio-scsi-pci,id=scsi0,bus=rp_scsi
  -device scsi-hd,drive=target,bus=scsi0.0
  -drive "file=${TOOLS_ISO},media=cdrom,if=none,id=toolscd"
  -device ide-cd,drive=toolscd,bus=ide.0
  -netdev "user,id=net0,hostfwd=tcp::${WINRM_PORT}-:5985"
  -device virtio-net-pci,netdev=net0
  -device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0
  -qmp "unix:${QMP_SOCK},server,nowait"
  -display none
)

qemu-system-x86_64 "${QEMU_ARGS[@]}" > "${WORK_DIR}/qemu.log" 2>&1 &
QEMU_PID=$!
log "install-tools qemu pid ${QEMU_PID}, log ${WORK_DIR}/qemu.log"

cleanup() {
  # Capture the exit status that triggered this trap BEFORE running anything else - a bug found
  # the hard way during this stage's own first real test run: the old version of this function
  # ended with `kill -9 ... || true`, whose own exit status (0) became the WHOLE SCRIPT's exit
  # status once the EXIT trap finished, silently turning a real WinRM-timeout failure into a
  # reported success (build.sh, and anything driving it, saw exit code 0). Preserving and
  # re-asserting the original code is what actually makes failures visible to the caller.
  local exit_code=$?
  if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "Cleanup: qemu (pid ${QEMU_PID}) still running after an error - attempting graceful shutdown before considering a hard kill" >&2
    if ! qmp_graceful_shutdown "$QMP_SOCK" "$QEMU_PID"; then
      echo "Cleanup: graceful shutdown did not complete - forcing qemu (pid ${QEMU_PID}) down as a last resort; treat this disk's state as suspect, don't reuse it without checking" >&2
      kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
  fi
  exit "$exit_code"
}
trap cleanup EXIT

wait_for_winrm "$QEMU_PID" "${WORK_DIR}/qemu.log"

log "Running install-tools.ps1 (Mode=${MODE}) from the mounted delivery ISO"
winrm_ps "
\$ErrorActionPreference = 'Stop'
\$toolsLetter = (Get-Volume | Where-Object { \$_.FileSystemLabel -eq 'TOOLSCD' }).DriveLetter
if (-not \$toolsLetter) { throw 'tools delivery ISO not found mounted (no volume labeled TOOLSCD)' }
& \"\${toolsLetter}:\install-tools.ps1\" -Mode '${MODE}' -ApiKey '${DD_API_KEY:-}'
"

log "install-tools.sh complete for ${OS} (Mode=${MODE}) - graceful shutdown"
qmp_graceful_shutdown "$QMP_SOCK" "$QEMU_PID"
trap - EXIT

log "install-tools.sh finished: ${TARGET_QCOW2}"
