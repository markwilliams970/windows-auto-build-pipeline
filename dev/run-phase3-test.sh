#!/usr/bin/env bash
# Phase 3 fast-iteration harness wrapper: boot a fresh copy-on-write overlay
# of one of Phase 2's confirmed-good reference disks (see role-test.pkr.hcl's
# header comment), upload services.yaml + scripts/, run the role orchestrator,
# and shut down. NOT part of the documented production build/verify/destroy
# workflow.
#
# Usage:
#   ./dev/run-phase3-test.sh <server2022|server2025> [services_yaml_path]
#
# services_yaml_path defaults to services-domain-controller.yaml sitting next
# to this script if omitted - always pass one explicitly to be sure.
set -euo pipefail

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_OS="${1:?Usage: $0 <server2022|server2025> [services_yaml_path]}"
case "$TARGET_OS" in
  server2022|server2025) ;;
  *) echo "ERROR: target_os must be 'server2022' or 'server2025', got '$TARGET_OS'" >&2; exit 1 ;;
esac

SERVICES_YAML="${2:-${DEV_DIR}/services-domain-controller.yaml}"
[[ -f "${SERVICES_YAML}" ]] || { echo "ERROR: services.yaml not found at ${SERVICES_YAML}" >&2; exit 1; }

BASELINE_QCOW2="${DEV_DIR}/../image-apply/output/win2022-session12.qcow2"
[[ "$TARGET_OS" == "server2025" ]] && BASELINE_QCOW2="${DEV_DIR}/../image-apply/output/win2025-session11.qcow2"
[[ -f "${BASELINE_QCOW2}" ]] || { echo "ERROR: reference disk not found at ${BASELINE_QCOW2} - Phase 2 must be run first" >&2; exit 1; }

# Host-side mutual-exclusion pre-check: fail in well under a second instead
# of after a several-minute boot. scripts/run-services.ps1 enforces the same
# rule on the guest as defense-in-depth (services.yaml hand-edits, or the
# orchestrator invoked some other way) - this is the primary, fast gate.
roles="$(grep -oE '^\s*-\s*[A-Za-z0-9_-]+' "${SERVICES_YAML}" | sed -E 's/^\s*-\s*//')"
has_dc=false
has_app=false
while IFS= read -r role; do
  [[ "$role" == "ad-ds" ]] && has_dc=true
  { [[ "$role" == "iis" ]] || [[ "$role" == "sql-server" ]]; } && has_app=true
done <<< "$roles"
if $has_dc && $has_app; then
  echo "ERROR: ${SERVICES_YAML} selects mutually exclusive roles - ad-ds cannot be combined with iis/sql-server." >&2
  exit 1
fi

echo "==> Target OS: ${TARGET_OS} (baseline: $(basename "${BASELINE_QCOW2}"))"
echo "==> Using services.yaml: ${SERVICES_YAML} (roles: $(echo "$roles" | tr '\n' ' '))"

# Unique per invocation, matching build.sh's own BUILD_ID convention - fixes the same class of
# collision bug build.sh itself hit (CLAUDE.md's Phase 3A section): a fixed-per-OS
# output_directory meant a second run against the same OS could fail outright (Packer refuses to
# run if output_directory already exists) if a prior run's directory was ever left behind. This
# harness still has a real, distinct need older sequential builds don't: it's meant for rapid,
# repeated iteration, so accumulating a fresh directory per run forever isn't acceptable disk
# hygiene either - handled below by proactively clearing STALE prior runs for this same OS
# (anything already on disk, since RUN_ID guarantees today's own path can't collide with them),
# not by blindly wiping a fixed path that might still be an actively-running build's own output.
RUN_ID="${TARGET_OS}-$(date +%Y%m%d-%H%M%S)"
VM_OUTPUT_DIR="${DEV_DIR}/output/vm-${RUN_ID}"
EFIVARS_SCRATCH="${DEV_DIR}/output/efivars-${RUN_ID}.fd"

mkdir -p "${DEV_DIR}/output"

echo "==> Clearing stale prior runs for ${TARGET_OS} (today's own run, ${RUN_ID}, is already unique and untouched by this)"
find "${DEV_DIR}/output" -maxdepth 1 -name "vm-${TARGET_OS}-*" -not -name "vm-${RUN_ID}" -exec rm -rf {} +
find "${DEV_DIR}/output" -maxdepth 1 -name "efivars-${TARGET_OS}-*.fd" -not -name "efivars-${RUN_ID}.fd" -exec rm -f {} +

# Belt-and-suspenders (matches build.sh's own identical check) - practically unreachable under
# this project's serial-builds-only convention, but fails loud instead of silently colliding if
# it's ever wrong.
[[ -e "$VM_OUTPUT_DIR" ]] && { echo "ERROR: ${VM_OUTPUT_DIR} already exists - refusing to overwrite; wait a second and retry, or investigate why a run with this exact id already exists" >&2; exit 1; }

cp /usr/share/OVMF/OVMF_VARS_4M.fd "${EFIVARS_SCRATCH}"

packer init "${DEV_DIR}/role-test.pkr.hcl"

packer validate \
  -var "target_os=${TARGET_OS}" \
  -var "run_id=${RUN_ID}" \
  -var "services_yaml_path=${SERVICES_YAML}" \
  -var "efivars_scratch=${EFIVARS_SCRATCH}" \
  "${DEV_DIR}"

packer build \
  -var "target_os=${TARGET_OS}" \
  -var "run_id=${RUN_ID}" \
  -var "services_yaml_path=${SERVICES_YAML}" \
  -var "efivars_scratch=${EFIVARS_SCRATCH}" \
  "${DEV_DIR}"
