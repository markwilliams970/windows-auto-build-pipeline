# Windows Server 2019: Design + Implementation Plan (Phase B)

## Status

**Design only — no pipeline code has been touched by this document.** This is Phase B of the
five-phase, gated Server 2019 addition (A: research — done, see `WINDOWS_SERVER_2019_RESEARCH_
PLAN.md` — B: this document, C: design review, D: implementation, E: E2E testing, 2+ builds
including role provisioning). Phase A closed with every research question resolved: the ISO is
cached (`../iso_cache/2019-17763.3650.221105-1748...iso`), its WIM edition index is directly
verified (index 2 = `ServerStandardEval`, Server Desktop Experience), the virtio `2k19` driver
subfolder is hash-confirmed identical to `2k22`'s, and the DCOM boot-storm mitigation is already
unconditional in the shared pipeline. Nothing here should re-litigate those findings — this document
is about *where the code needs to change*, not whether Server 2019 is safe to add.

This plan is grounded in a direct, file-by-file audit of the real pipeline (every script actually
read, every `grep` shown below actually run against the real repo — not inferred from the research
doc's own recommendations, which were written before this audit and turned out to be more
pessimistic about scope than the real code is).

---

## Design

### The headline finding: this pipeline is almost entirely table-driven, and Server 2019 fits the existing table shape exactly

Every `image-apply/*.sh` script (`partition-disk.sh`, `apply-image.sh`, `make-bootable.sh`) resolves
every OS-specific value (ISO path, WIM index, driver subfolder, disk size) through five functions in
`image-apply/lib/common.sh` — confirmed by direct read of all three scripts: none of them contain a
`case "$OS"` of their own beyond passing `$OS` straight into these functions and `validate_os`. This
means the *scripts themselves* need zero changes; only the lookup tables do.

Two scripts are the exception, each for a real, specific reason — covered below.

### Change 1: `image-apply/lib/common.sh` — five table additions + `validate_os`

This is the actual center of gravity for this whole change. Six one-line additions, one per
function, using the values Phase A already confirmed:

```bash
os_win_iso() {
  case "$1" in
    server2019) echo "${ISO_CACHE_DIR}/2019-17763.3650.221105-1748.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso" ;;
    server2022) echo "${ISO_CACHE_DIR}/2022-SERVER_EVAL_x64FRE_en-us.iso" ;;
    ...

os_wim_index() {
  case "$1" in
    server2019) echo 2 ;;  # "Windows Server 2019 SERVERSTANDARD", ServerStandardEval - CONFIRMED via wimlib-imagex info, 2026-09-02 (WINDOWS_SERVER_2019_RESEARCH_PLAN.md Finding 3)
    server2022) echo 2 ;;
    ...

os_driver_subfolder() {
  case "$1" in
    server2019) echo "2k19" ;;
    server2022) echo "2k22" ;;
    ...

os_disk_size_gb() {
  case "$1" in
    server2019|server2022|server2025) echo 40 ;;
    windows11) echo 64 ;;
    ...

os_computer_name() {
  case "$1" in
    server2019) echo "WIN2019PROD" ;;
    server2022) echo "WIN2022PROD" ;;
    ...

validate_os() {
  case "$1" in
    server2019|server2022|server2025|windows11) return 0 ;;
    *) echo "Unknown OS '$1' - expected server2019, server2022, server2025, or windows11" >&2; return 1 ;;
  esac
}
```

The header comment block at the top of `common.sh` (the one that says values are "transcribed
directly from `PHASE2_ENGINEERING_LOG.md`'s own independently-verified findings ... not assumed to
generalize") should gain a matching line for Server 2019, citing `WINDOWS_SERVER_2019_RESEARCH_
PLAN.md` Finding 3 instead of a `PHASE2_ENGINEERING_LOG.md` session — this project didn't run a live
bring-up session to get this value the way it did for the other three OSes, it ran a direct
`wimlib-imagex info` check during Phase A research. Worth being precise about that provenance
difference in the comment, not just copying the citation style without the citation being accurate.

### Change 2: `image-apply/apply-unattend.sh` — one case-statement line + a new template file

`apply-unattend.sh` has exactly one real `case "$OS"` of its own (every other script only calls
`common.sh` functions): it maps `$OS` to a checked-in unattend template file. This needs:

```bash
case "$OS" in
  server2019) TEMPLATE="${REPO_ROOT}/image-apply/unattend-server2019.xml" ;;
  server2022) TEMPLATE="${REPO_ROOT}/image-apply/unattend-server2022.xml" ;;
  ...
```

...plus a new `image-apply/unattend-server2019.xml`. Read `unattend-server2022.xml` directly (its
own header comment already says it's "the Windows Server 2022 variant of `unattend-server2025.xml`
— same proven structure ... only the driver path (2k22 instead of 2k25) and ComputerName differ").
Server 2019's version is the same pattern one more time: **copy `unattend-server2022.xml` verbatim,
then change exactly two things**:
1. The `pnputil /add-driver` `FirstLogonCommands` line's driver path:
   `C:\Drivers\NetKVM\2k22\amd64\netkvm.inf` -> `C:\Drivers\NetKVM\2k19\amd64\netkvm.inf`.
2. The header comment's own provenance note (currently says "Server 2022 variant of
   unattend-server2025.xml" — Server 2019's version should say it's the Server 2022 variant, citing
   this document instead of a `PHASE2_ENGINEERING_LOG.md` session, same provenance-accuracy point as
   Change 1).

The template's own placeholder `<ComputerName>WIN2022-S12</ComputerName>` doesn't need to be
"correct" — `apply-unattend.sh` overwrites it via `sed` at apply time regardless (confirmed by direct
read: `sed "s|<ComputerName>[^<]*</ComputerName>|<ComputerName>${COMPUTER_NAME}</ComputerName>|"`) —
but per this project's own standard of not leaving stale-looking artifacts, it should still be
changed to something Server-2019-appropriate (e.g. `WIN2019-DESIGN`) rather than left reading
`WIN2022-S12`, which would be actively misleading to a future reader.

Every other setting in the file (OOBE skip flags, `AdministratorPassword`/`AutoLogon` with the
project's standard lab password, the network-category-to-Private wait, WinRM-over-HTTP enablement)
is already OS-agnostic Windows Setup behavior — Phase A Finding 8 found no Server-2019-specific
regression here, and there is no reason to change any of it.

### Change 3: `packer/boot-and-provision.pkr.hcl` — one validation-list line

The **only** OS-specific logic inside the Packer template itself (confirmed by grepping every use of
`target_os` in the file — there are exactly two, both in one `variable` block) is an input-validation
guard:

```hcl
variable "target_os" {
  ...
  validation {
    condition     = contains(["server2019", "server2022", "server2025", "windows11"], var.target_os)
    error_message = "The target_os variable must be \"server2019\", \"server2022\", \"server2025\", or \"windows11\"."
  }
}
```

Nothing else in the `.pkr.hcl` branches on `target_os` — `build_id`, `vm_name`, `output_directory`,
`disk_size_mb`, and `services_yaml_path` are all passed through generically from `build.sh`'s own
variables, none of them OS-conditional inside the template itself. **Without this change, `packer
validate`/`packer build server2019` fails immediately and loudly** — a cheap, easy-to-catch mistake
if forgotten (Packer's own validation error, not a silent misbehavior), but real and worth listing
explicitly so it isn't missed during Phase D.

### Change 4 (cosmetic, not functional): usage-string/comment updates

Every script's own `Usage: ... <server2022|server2025|windows11> ...` string (`build.sh`,
`partition-disk.sh`, `apply-image.sh`, `make-bootable.sh`, `apply-unattend.sh`,
`inject-virtio-spice.sh`, `register-vm.sh`) is a literal string in a comment/error message, not a
parsed enum — `validate_os` is the actual gate. These don't need to change for the pipeline to work,
but leaving them stale (a user running `build.sh` with no args would see an error message that
doesn't mention `server2019` as a valid option) is a real, if minor, usability gap. Included in scope
for Phase D as a batch of small, low-risk edits — not because it's required for correctness.

### What needs **zero** changes — confirmed by direct read, not assumed

- **`image-apply/partition-disk.sh`, `image-apply/apply-image.sh`, `image-apply/make-bootable.sh`**:
  every OS-specific value they need comes from `common.sh`'s functions (Change 1 above); none of
  them contain their own `case "$OS"`.
- **`tools/gen-viostor-ddb-reg.py`**: takes `--driver viostor` / `--driver netkvm`, not an OS
  argument — its hardware-ID presets are shared across every Server SKU (confirmed: `2k19`'s INF
  files are byte-identical to `2k22`'s per Phase A Finding 4/5). No `server2019` case needed because
  there's no OS-keyed case to add one to.
- **`image-apply/inject-virtio-spice.sh`**: confirmed via direct read — its only OS-conditional logic
  is `DO_NIC_SWAP` (Windows-11-only; Server SKUs never swap NIC, using the existing offline-hivex
  NetKVM mechanism instead) and `QXLDOD_SUBFOLDER` (already hardcoded to `"2k19"` for **every**
  non-Windows-11 OS today — meaning Server 2022 and Server 2025 already run their qxldod/SPICE
  display driver injection through the `2k19` subfolder of `spice-guest-tools`, per the script's own
  comment: `qxldod.inf`'s `[Manufacturer]` section targets the generic `NTamd64.6.2` class with no
  per-version decoration, and the `2k16`/`2k19`/`w10` subfolders are byte-identical — `2k19` was
  picked as "the newest available build, safe to use unmodified for every target OS here." Server
  2019 becomes the **first OS in this project where the driver-subfolder name and the actual guest OS
  name coincide** — a nice, purely coincidental confirmation that this existing shared-subfolder
  choice was already correct, not a new risk.
- **`register-vm.sh`**: device model (virtio-scsi disk, virtio-net NIC, qxl-vga+SPICE) is fully
  OS-agnostic; its only OS-conditional logic is `DEFAULT_QCOW2` resolution (`windows11` looks in
  `image-apply/output/builds/`, every other OS looks in `packer/output/<os>-*/`) — Server 2019 falls
  into the existing `else` branch identically to Server 2022/2025, no new branch needed.
- **`services.yaml`, `scripts/run-services.ps1`, `dev/services-domain-controller.yaml`,
  `dev/services-app-server.yaml`**: confirmed via direct grep — zero OS-version references anywhere
  in the role-provisioning layer. The two-profile guard (`ad-ds` alone vs. `iis`/`sql-server`
  together) has no OS-specific carve-out to add one to, matching Phase A Recommendation #7's
  expectation exactly.
- **`build.sh`**: the Windows-11-specific branch (`if [[ "$OS" == "windows11" ]]`) is the only
  OS-conditional logic; Server 2019 falls through to the same `else` path Server 2022/2025 already
  use (partition → apply → bootable → unattend → Packer handoff → `inject-virtio-spice.sh`), with no
  new branch needed.

### Documentation (not code) — deliberately deferred to the end of Phase E, not done now

`CLAUDE.md` describes Server 2022/2025/Windows 11 throughout as the three (soon four) target OSes,
with substantial narrative about each one's proven history. Per this project's own established
pattern — every prior OS's `CLAUDE.md` narrative was written *after* real, evidence-backed success,
never speculatively ahead of it — this plan deliberately does **not** propose editing `CLAUDE.md`'s
prose during Phase D. `WINDOWS_SERVER_2019_RESEARCH_PLAN.md` and this document (Phase B) are the
correct place for pre-implementation design/tracking; `CLAUDE.md` gets a real update only once Phase
E's two builds succeed, mirroring exactly how Server 2022's Session 12 and Windows 11's Phase 3.4/3.5
earned their own `CLAUDE.md` narrative sections only after the fact.

---

## Assumptions

- **Host QEMU version and the cached `virtio-win-0.1.285.iso` remain unchanged** between this plan
  and Phase D/E execution — same standing assumption Phase A already flagged (Finding 5); if either
  changes, the PCI-hardware-ID inference should be re-checked before trusting a build result.
- **The Server 2019 ISO's own `install.wim` structure (image count, ordering) doesn't change between
  Phase A's verification and Phase D's actual `apply-image.sh` run** — trivially true since it's the
  same cached file, not re-downloaded, but worth stating since this project's own "Version-sensitivity"
  standard treats an ISO refresh as a real risk trigger elsewhere.
- **`unattend-server2022.xml` is still the most current, correct Server-SKU template to copy from** —
  it's the one Phase A's audit read directly (2026-09-02); if it's been modified since, the copy
  should be re-derived from whatever `apply-unattend.sh` actually references at the time Phase D
  executes, not from what this plan quotes.
- **Server 2019's AD DS/IIS/SQL Server role provisioning needs no script changes** — reasonable
  (same Windows Server role infrastructure Server 2022/2025 already prove out, and `run-services.ps1`
  has no OS-version branching to begin with), but not independently exercised by a real Server 2019
  role-provisioning run until Phase E.

## Risks

- **Lowest risk since Phase A closed**: every concrete change above is small, mechanical, and
  table-driven — the kind of change this project's own history already describes as "zero changes to
  any of the reusable tooling, only OS-specific input values" for Server 2022's own bring-up. There
  is no open architectural question left; Phase D is closer to data entry than engineering.
- **Real, if narrow, residual risk**: `unattend-server2019.xml` is a hand-copied file, and a
  copy-paste slip (forgetting to change `2k22` -> `2k19` in the `pnputil` line, or leaving a stray
  Server-2022-specific comment) is the kind of mistake that wouldn't be caught by `packer validate`
  or any other automated check — it would only surface as a real driver-installation failure during
  Phase E's first build. Mitigation: a direct `diff` against `unattend-server2022.xml` after creating
  the new file, checked by hand before the first real build, not just visual review while writing it.
- **The one thing Phase A explicitly could not close**: QEMU-side PCI hardware ID negotiation
  (`DEV_1004`/`DEV_1048`) has no OS-side variable that could make it differ for Server 2019 (Finding
  5's own reasoning — negotiation happens in QEMU/firmware, before the guest OS loads), but it has
  not been independently boot-tested for Server 2019 specifically. This is exactly what Phase E's
  first real build resolves — not a design gap, a "the test hasn't run yet" gap.
- **Packer validation-list miss**: forgetting Change 3 (the `contains([...])` list) is the one change
  in this plan that would produce an immediate, loud, unambiguous failure (`packer validate` refusing
  to proceed) rather than a subtle bug — low risk of shipping unnoticed, but easy to trip over if
  Phase D is done as a quick edit to `common.sh` alone without also touching the `.pkr.hcl`.

---

## Phase D: implementation sequence (once Phase C signs off)

Small enough that this doesn't need Phase 2's own heavy internal sub-milestone gating — but broken
into an explicit order so each step is independently checkable before the next, per this project's
own "work in phases, don't produce a large monolithic implementation" standard:

**D1. `image-apply/lib/common.sh`** — the six table additions (Change 1). Checkable immediately:
`bash -n image-apply/lib/common.sh` (syntax) plus a direct call of each function
(`source image-apply/lib/common.sh && os_win_iso server2019` etc.) to confirm each returns the
expected value with no typos, before anything downstream depends on it.

**D2. `image-apply/unattend-server2019.xml` + `image-apply/apply-unattend.sh`'s case line** (Change
2). Checkable via `diff unattend-server2022.xml unattend-server2019.xml` — should show exactly the
driver-path line and the header-comment/ComputerName-placeholder lines changed, nothing else. Also
run the file through an XML well-formedness check (`xmllint --noout` or equivalent) since it's
hand-edited.

**D3. `packer/boot-and-provision.pkr.hcl`** (Change 3). Checkable via `packer validate -var
target_os=server2019 -var build_id=test -var source_qcow2=/dev/null -var disk_size_mb=40960
packer/` (or equivalent minimal var set) — confirms the validation list accepts `server2019` without
needing a real build.

**D4. Usage-string/comment updates** (Change 4) across the seven scripts listed above — batch,
low-risk, no functional check needed beyond `bash -n` on each touched file.

**D5. Pre-flight sanity, no real build yet**: run `validate_os server2019` (should succeed) and
`validate_os server2019 2>&1 | grep server2019` against the updated error message (should now
mention `server2019` as a valid option) — confirms D1-D4 are wired together correctly before
committing to a real, ~15-50 minute end-to-end build attempt.

Each of D1-D5 is independently reviewable in a single small diff — this plan does not propose
landing all five as one large commit, matching this project's own standing instruction against
monolithic implementations.

---

## Phase E: E2E testing plan

Per the user's own explicit requirement: **at least 2 builds including services provisioning.**
Mirrors exactly how Server 2022 and Server 2025 were each first validated in Phase 3 Session 2 (one
profile per OS, not both profiles against both OSes) — not the heavier 6-build-per-OS bar Phase 3A
used for cross-cutting driver work, since that bar was about proving a shared mechanism generalizes
across *already-proven* OSes, not about first-time OS bring-up.

**Build 1: `server2019` + `ad-ds` profile** (domain controller), mirroring Server 2022's own first
validation:
```
./build.sh server2019 dev/services-domain-controller.yaml
```
Success bar: partition → apply → bootable → specialize → Packer handoff → WinRM reachable → NTDS/DNS
up, domain live after reboot (matching Server 2022's own Session 2 bar) → `inject-virtio-spice.sh`
clean (vioscsi live-verified, SPICE tools installed) → `register-vm.sh server2019` + `virsh start` →
live desktop confirmed via `virsh screenshot`, hostname/NIC/disk verified over real WinRM (not just a
screenshot) — the same evidentiary bar every other OS in this project has already met.

**Build 2: `server2019` + `iis`/`sql-server` profile** (app server), mirroring Server 2025's own
first validation:
```
./build.sh server2019 dev/services-app-server.yaml
```
Success bar: same pipeline stages, `W3SVC` running/HTTP 200 for IIS, SA login + live `SELECT 1` for
SQL Server (matching Server 2025's own Session 2 bar exactly), then the same
`inject-virtio-spice.sh`/`register-vm.sh`/`virsh start`/WinRM verification sequence as Build 1.

**Both builds get their own `PHASE3_ENGINEERING_LOG.md` session entries** (real findings as they
occur — this plan is not a promise that Server 2019 will bring up with zero surprises, only that
Phase A/B's research and design work found no reason to expect any). If either build surfaces a real,
non-cosmetic bug (the kind Phase 3 Session 2 found for Server 2022/2025 — sudoers scoping, nbd
attach-timing races, etc.), that becomes its own documented finding, not a silent workaround.

**Only after both builds succeed**: the deferred `CLAUDE.md` documentation pass (adding Server 2019
as a fourth production-ready target OS throughout, updating the Repository Structure sketch,
Development Approach narrative, etc.) — matching this project's own established pattern of writing
that narrative after proof, not ahead of it.

---

## Open questions for Phase C (design review)

1. **Computer name**: this plan proposes `WIN2019PROD` (matching the `WIN<year>PROD` convention
   `os_computer_name` already uses for the other two Server SKUs). Confirm this is wanted, not e.g.
   something that avoids implying "production" for what's still lab/eval infrastructure — though
   the other two OSes already use this exact pattern, so consistency argues for keeping it.
2. **Datacenter edition**: this plan (like Phase A's own recommendations) assumes Standard edition
   only, matching Server 2022/2025's existing convention — Datacenter is not proposed. Confirm no
   interest in also wiring a `server2019-dc` variant or similar; not scoped here if so.
3. **`dev/` fast-iteration harness**: this plan deliberately does not extend `dev/role-test.pkr.hcl`/
   `dev/run-phase3-test.sh` to cover Server 2019 — that harness is for rapid *provisioning-script*
   iteration against an already-proven reference disk, and per `PHASE3_ENGINEERING_LOG.md`'s own
   2026-08-26 entry, its Server 2022/2025 reference disks no longer exist on disk anyway (a separate,
   pre-existing gap). Confirm this is correctly out of scope for the Server 2019 addition specifically,
   not something Phase D should also fix while it's in the area.
4. **Sequencing of the two Phase E builds**: this plan proposes `ad-ds` first (mirroring the order
   Server 2022 was actually validated in), then `iis`/`sql-server`. No strong reason to prefer the
   other order — flagging only because Phase E, once started, commits real build time (Server 2025's
   own `iis`/`sql-server` build took ~51 minutes) and it's worth confirming the order doesn't matter
   before starting rather than after.
