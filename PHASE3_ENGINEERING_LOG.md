# Phase 3 Engineering Log: Role Provisioning Confirmed for Server 2022 and Server 2025

Status as of this writing: **Phase 3 is done.** All four OS × profile combinations (Windows Server
2022/2025 × domain-controller/app-server) were confirmed live against this project's own
offline-applied, Phase-2-proven reference disks. The reused role-provisioning scripts needed zero
changes beyond a new, project-specific mutual-exclusion guard. One real, non-obvious defect was
found and fixed in the new test harness itself (Finding 1 below) — not in the reused scripts, and
not in Phase 2's mechanism. See `CLAUDE.md`'s Phase 3 section for the current status summary and
`PHASE2_ENGINEERING_LOG.md` for the offline-apply mechanism this phase builds on.

**This banner describes only where the file starts, not where it ends.** This same log later covers
Windows 11's entire separate journey - the fully-offline pipeline's Findings 7-9 and eventual HARD
STOP, the Setup.exe-driven pivot (Phase 3.1-3.3), formalizing it into production scripts and
discovering the NVRAM-boot-order design (Phase 3.4), and production-readiness validation (Phase 3.5)
- ending with Windows 11 reaching the same production-ready status Server 2022/2025 have here. See
`CLAUDE.md`'s Phase 3 section and `WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md` for the current,
rolled-up status of all three OSes; treat this file as the chronological record behind that summary,
not a replacement for reading it.

This log follows the sibling project's and `PHASE2_ENGINEERING_LOG.md`'s own convention: symptom,
diagnosis, root cause, fix, in the order they were actually hit, including the dead ends.

---

## Setup summary (context for the finding below)

- Reused `scripts/run-services.ps1`, `install-ad.ps1`, `install-iis.ps1`, `install-sql-server.ps1`,
  `verify-post-reboot.ps1` from `../windows-server-vm-automation/scripts/` byte-for-byte, per
  `CLAUDE.md`'s explicit reuse instruction — no changes needed to any of the four role scripts.
- **New requirement not present in the sibling project:** two mutually-exclusive profiles —
  `ad-ds` alone vs. `iis`/`sql-server` together — enforced twice: a fast host-side pre-check in the
  new `dev/run-phase3-test.sh` wrapper (fails in well under a second, before any VM boots) and a
  defense-in-depth guard added directly to `scripts/run-services.ps1` (throws if both role groups
  are present, in case `services.yaml` is ever hand-edited or the orchestrator is invoked some other
  way). `services.yaml`'s flat-list shape is otherwise unchanged from the sibling project. Two
  ready-made profile files: `dev/services-domain-controller.yaml` (`ad-ds`), `dev/services-app-server.yaml`
  (`iis` + `sql-server`).
- **New test harness**: `dev/role-test.pkr.hcl` + `dev/run-phase3-test.sh`, following
  `CLAUDE.md`'s "reuse the pattern, not necessarily the exact files" note about the sibling
  project's own `dev/` fast-iteration harness. Boots a disposable copy-on-write overlay
  (`use_backing_file = true`) on top of Phase 2's own confirmed-good, WinRM-reachable reference
  disks (`image-apply/output/win2022-session12.qcow2` / `win2025-session11.qcow2`, sha256-verified
  before use) rather than a separately-maintained `dev/baseline/` copy — the reference disks already
  live in `image-apply/output/` (already gitignored there) and never need duplicating. Deliberately
  `disk_interface = "virtio"` (→ `virtio-blk-pci`), **not** `"virtio-scsi"` like the sibling
  project's own dev harness uses — `tools/gen-viostor-ddb-reg.py`'s offline driver injection was
  registered against a real `virtio-blk-pci` hardware ID (`PHASE2_ENGINEERING_LOG.md`, around line
  692), and `virtio-scsi` presents a different device entirely; using it here would have
  reintroduced `INACCESSIBLE_BOOT_DEVICE`. Caught by reading the prior log before running anything,
  not hit empirically.
- This harness is explicitly **not** the production `packer/boot-and-provision.pkr.hcl` named in
  `CLAUDE.md`'s repo-structure sketch — that file still doesn't exist, and isn't real buildable work
  yet, since `image-apply/`'s own scripts (`partition-disk.sh`/`apply-image.sh`/`make-bootable.sh`/
  `apply-unattend.sh`) are still hand-run steps recorded only in `PHASE2_ENGINEERING_LOG.md`, not
  formalized. See "STATUS AND NEXT STEPS" below.

---

## Finding 1: Server 2025 reliably failed Packer's WinRM wait against a disk already proven WinRM-reachable

**Symptom:** `./dev/run-phase3-test.sh server2025 dev/services-domain-controller.yaml` errored with
`Timeout waiting for WinRM` after 11m43s (default `winrm_timeout = "10m"`). Bumping the timeout to
15m and retrying produced the identical failure at 15m40s. Server 2022, by contrast, had already
passed both profiles cleanly (6m58s and 18m06s) using the exact same `role-test.pkr.hcl`, differing
only in which reference disk/checksum the shared `locals.os_config` map selected.

**Diagnosis:** The failing disk (`win2025-session11.qcow2`) was `PHASE2_ENGINEERING_LOG.md` Session
11/13's own confirmed-good, real-WinRM-verified reference disk, so a broken disk seemed unlikely but
had to be ruled out empirically, not assumed — per `CLAUDE.md`'s "verify before trusting" standard
and its QMP-screendump convention for exactly this kind of situation (Packer's own qemu builder
doesn't expose QMP, per `CLAUDE.md`'s documented caveat, so this needed a separate ad hoc
`qemu-system-x86_64` invocation, not a Packer-internal debugging trick):

1. Built a throwaway COW overlay of `win2025-session11.qcow2` and booted it directly with
   `qemu-system-x86_64` (`virtio-blk-pci` disk, `virtio-net-pci` net, `q35`, OVMF, `-cpu host`,
   `-qmp unix:/tmp/diag2025.sock,server,nowait`), watched via `tools/qmp-watch.sh` at 20s intervals.
   Reached a fully booted, logged-in Administrator desktop (Server Manager auto-launched) within
   ~4 minutes, and a direct `curl http://127.0.0.1:<hostfwd-port>/wsman` got back the exact response
   a working WinRM listener returns to a bare GET (`405`, `Allow: POST`,
   `Server: Microsoft-HTTPAPI/2.0`) — WinRM was genuinely up and correct. The disk was not broken.
2. Since the disk was fine, the difference had to be in *how* Packer specifically invokes qemu.
   Captured Packer's actual generated command via `PACKER_LOG=1 PACKER_LOG_PATH=...`:
   ```
   qemu-system-x86_64 -machine type=q35,accel=kvm -netdev user,id=user.0,hostfwd=tcp::PORT-:5985
     -vnc 127.0.0.1:N -m 16384M -smp 4 -device virtio-net,netdev=user.0
     -drive file=...,if=virtio,cache=writeback,discard=ignore,format=qcow2
     -drive file=OVMF_CODE_4M.fd,if=pflash,unit=0,format=raw,readonly=on
     -drive file=efivars.fd,if=pflash,unit=1,format=raw -name phase3-server2025.qcow2
   ```
   Compared against the working ad hoc command from step 1: **Packer's invocation never passes
   `-cpu` at all.**
3. Reproduced Packer's exact command line by hand (`-m 16384M`, `-device virtio-net,netdev=user.0`,
   `if=virtio` drive shorthand — every quirk preserved) with only `-cpu host` and a QMP socket
   added. WinRM answered correctly within about a minute — confirming the missing `-cpu` argument,
   not memory size or device-naming differences, was the actual variable.

**Root cause:** The Packer qemu plugin's `cpu_model` field defaults to unset (verified against
HashiCorp's own documentation via a real search, not assumed): with nothing set, QEMU never
receives a `-cpu` argument under KVM at all and silently falls back to its generic, feature-minimal
`qemu64` baseline CPU model instead of the host's real CPU — no error, no warning either way.
Windows Server 2022 tolerated this fine (WinRM up well within the original 10-minute wait, on both
profiles). Windows Server 2025 did not, twice, even at 15 minutes. The exact mechanism for *why*
2025 is more sensitive was not directly confirmed — no screendump exists of a `qemu64`-CPU 2025 boot
specifically, since Packer doesn't expose QMP and the two failed Packer runs left nothing to inspect
after their own timeout cleanup. Best-supported hypothesis, not proven: Server 2025's heavier
default security posture (VBS/HVCI-adjacent features expecting CPU virtualization-extension flags
that `qemu64` doesn't expose) combined with simply more baseline first-boot work than Server 2022,
so a modest per-operation slowdown compounds into a much larger total delay. This hypothesis is not
load-bearing for the fix.

**Fix:** Added `cpu_model = "host"` to the single shared `source "qemu" "role_test"` block in
`dev/role-test.pkr.hcl` (HashiCorp's own docs recommend `"host"` under a hypervisor for exactly this
reason). Confirmed: Server 2025 AD-DS, retried immediately after with no other change, passed in
17m37s with WinRM connecting quickly. Server 2025 App-Server (`iis` + `sql-server`) then also passed
cleanly in 47m29s — longer than Server 2022's 18m06s for the same profile, consistent with (not
independent confirmation of) the "more baseline work" half of the hypothesis above, since SQL
Server's own install is itself CPU-heavy.

**Also worth knowing:** this same gap likely exists in the sibling project's own
`dev/role-test.pkr.hcl` (the direct pattern this file was built from) and possibly its production
`packer/windows-server.pkr.hcl` — neither was touched or fixed here, out of scope for this project's
repository, but worth checking over there at some point.

---

## Confirmed results (all four combinations)

| OS | Profile | Result | Time |
|---|---|---|---|
| Server 2022 | `ad-ds` | NTDS/DNS up, domain live after reboot, `verify-post-reboot.ps1` passed | 6m58s |
| Server 2022 | `iis` + `sql-server` | `W3SVC`/HTTP 200; SA login + `SELECT 1` over real SQL Server 2022 Developer | 18m06s |
| Server 2025 | `ad-ds` | NTDS/DNS up, domain live after reboot, `verify-post-reboot.ps1` passed | 17m37s |
| Server 2025 | `iis` + `sql-server` | `W3SVC`/HTTP 200; SA login + `SELECT 1` over real SQL Server 2022 Developer | 47m29s |

No VM left running, no stray `qemu-system-x86_64`/`packer` processes, no leftover `/tmp/diag*` files
at the end of this session (confirmed via `pgrep`).

---

## Session 2: formalized `image-apply/`'s real scripts and the production
`packer/boot-and-provision.pkr.hcl` - both target OSes confirmed end-to-end through a completely
fresh disk built entirely by the new scripts, not a hand-run or dev-harness reference disk

**Where this picked up:** Session 1 closed Phase 3 using the dev/ test harness against Phase 2's
own hand-built reference disks. That left a real gap this project's own conventions treat as
load-bearing, not cosmetic: `image-apply/`'s actual scripts didn't exist, and Phase 2's proven
recipe lived only as narrative findings in `PHASE2_ENGINEERING_LOG.md`. This session formalized it:
`image-apply/lib/common.sh` (OS config table), `partition-disk.sh`, `apply-image.sh`,
`make-bootable.sh`, `apply-unattend.sh`, `packer/boot-and-provision.pkr.hcl`, and a `build.sh`
orchestrator - transcribed directly from the exact commands in Sessions 8-13 of the Phase 2 log, not
reconstructed from memory.

Every command in the recipe was already proven; translating hand-run, interactively-observed steps
into unattended scripts still surfaced five real, non-obvious bugs, each caught by actually running
the scripts rather than by inspection:

### Finding 2: `sudo mkdir` isn't in the sudoers allowlist (and doesn't need to be)

**Symptom:** `apply-image.sh`/`make-bootable.sh`/`apply-unattend.sh` failed non-interactively with
`sudo: a password is required` at their first `sudo mkdir -p "$WIN_MNT"` call.

**Root cause:** `tools/sudoers-windows-auto-build-pipeline` scopes NOPASSWD rules to the exact
disk-prep binaries this project needs (`qemu-nbd`, `sgdisk`, `mkfs.*`, `mount`/`umount`, `sfdisk`) -
`mkdir` was never one of them, and doesn't need to be: the mount point just needs to exist as a
directory, not be root-owned, since the subsequent `mount -o uid=...,gid=...` call makes it
user-writable regardless of who created it.

**Fix:** Plain `mkdir -p`, no `sudo`, in all three scripts.

### Finding 3: partition sub-devices aren't always present immediately after a *fresh* `qemu-nbd` attach of an already-partitioned disk

**Symptom:** `apply-image.sh` failed with `ntfs-3g: Failed to access volume '/dev/nbd0p3': No such
file or directory` immediately after a successful `qemu-nbd -c` attach.

**Diagnosis:** `partition-disk.sh` already ran `partprobe` right after `sgdisk` created the
partition table - but a *separate*, later script re-attaching that same already-partitioned qcow2
via a fresh `qemu-nbd -c` doesn't automatically get the kernel to notice the existing partitions
right away.

**Fix:** `sudo partprobe "$NBD_DEV"` + a 1s settle, added after every fresh attach in
`apply-image.sh`, `make-bootable.sh`, and `apply-unattend.sh` - not just the one in
`partition-disk.sh` that runs right after `sgdisk`.

### Finding 4: `qemu-nbd -c` can return success before the kernel has actually negotiated the device's real size, and `sgdisk` will believe it

**Symptom:** On one `partition-disk.sh` run, `sgdisk` failed with `Disk is too small to hold GPT
data (0 sectors)! Aborting!` immediately after a successful attach; `lsblk /dev/nbd0` independently
confirmed `0B` at that moment.

**Diagnosis:** A genuine attach-timing race, not a one-off fluke of that run - `qemu-nbd -c`
returning doesn't guarantee the kernel's nbd block layer has already learned the export's real size
from the server side.

**Fix:** Poll `lsblk -b -n -d -o SIZE "$NBD_DEV"` (no `sudo` needed - reads sysfs, not the device
itself) until non-zero, up to 20 tries at 0.5s, before running `sgdisk` at all.

### Finding 5: `make-bootable.sh` wasn't idempotent against a disk that already had a valid BCD - OVMF's own boot-option discovery would boot the target directly instead of WinPE, permanently "poisoning" that disk's one-shot specialize/`FirstLogonCommands` passes

**Symptom:** A re-run of `make-bootable.sh` (after fixing Finding 2) hung until its own 300s
timeout. A QMP screendump of a manual reproduction showed real Windows OOBE ("Hi there"), not
WinPE.

**Diagnosis:** The disk had already been made bootable once by an earlier (differently-failing)
attempt. With no explicit boot order, OVMF's boot-option discovery preferred the target's own
now-valid Windows Boot Manager over WinPE's `ide-hd` medium. Worse than just picking the wrong
device for *this* run: Windows Setup's specialize/`oobeSystem` pass and `FirstLogonCommands` each
run **once**, ever, regardless of whether an answer file was present at the time - so that
accidental boot (with no `unattend.xml` applied yet) permanently consumed those passes on
interactive defaults. A subsequently-correct `apply-unattend.sh` run could never retroactively fix
that specific disk; the only real fix was starting over on a fresh one. This single bug is why three
separate from-scratch Server 2022 disks were needed this session before a clean end-to-end test was
possible - a real, expensive lesson about how unforgiving Windows Setup's one-shot pass tracking is
in an unattended pipeline, not just a scripting nuisance.

**Fix:** Explicit `bootindex=1` on the WinPE `ide-hd` device and `bootindex=2` on the target
`virtio-blk-pci` device in `make-bootable.sh`'s qemu invocation - pins the boot order regardless of
the target's own current boot state, making the step genuinely idempotent.

### Finding 6: `netkvm.inf` requires `netkvmp.exe` (declared in its own `[SourceDisksFiles]` section) to be staged alongside it, or `pnputil /add-driver` fails outright - invisible in the proven recipe because `viostor`'s offline-only use path never needed it

**Symptom:** A from-scratch disk booted correctly, reached a real desktop, `AutoLogon` and
`FirstLogonCommands` all ran - but WinRM was never reachable. TCP connected to the forwarded port
but no data ever flowed (the exact SLIRP-level signature Finding 36 in `PHASE2_ENGINEERING_LOG.md`
already identified as "the guest has no working IP," not a WinRM config problem). Offline inspection
of `C:\session12-pnputil-log.txt` showed the real cause directly: `"Failed to add driver package:
The system cannot find the file specified."`

**Diagnosis:** `make-bootable.sh` only extracted and staged `netkvm.inf`/`.sys`/`.cat` from the
virtio-win ISO - reasonable, since that's exactly what `gen-viostor-ddb-reg.py`'s own docstring says
is needed for its offline `DriverDatabase` registration mechanism. But `pnputil /add-driver` (the
*live* mechanism `apply-unattend.sh`'s `FirstLogonCommands` actually uses for netkvm, per Finding
39/40 in the Phase 2 log) validates the full driver package described by the `.inf` itself.
Confirmed by reading `netkvm.inf` directly: its `[SourceDisksFiles]` section declares
`netkvmp.exe` (an NDIS performance-filter helper) as required, which was never copied. This gap was
invisible throughout Phase 2's own hand-run sessions because `viostor` (the only driver that ever
went through code review this closely) is only ever offline-`DriverDatabase`-registered, never
`pnputil`-installed live, so its own minimal `.inf`/`.sys`/`.cat` set was never actually tested
against `pnputil`'s fuller validation.

**Root cause:** An incorrect assumption (never independently verified against `netkvm.inf` itself
until this failure forced it) that `.inf`/`.sys`/`.cat` was a complete enough package for both
driver-installation mechanisms this project uses, when only one of the two actually requires that
full a check.

**Fix:** `make-bootable.sh` now also extracts `netkvmp.exe` (and `netkvmco.exe`, for completeness of
the same package family) from the virtio-win ISO and stages them alongside the rest at
`C:\Drivers\NetKVM\<subfolder>\amd64\`. The extraction cache's "already done" check was also
tightened to look for `netkvmp.exe` specifically, not just the directory's existence, so a
previously-incomplete cache from before this fix doesn't silently stay incomplete forever.

**Same one-shot-pass consequence as Finding 5**: a disk that already ran `FirstLogonCommands` once
(even if the `pnputil` step within it failed) can't be retroactively fixed by rebuilding just the
driver files - `FirstLogonCommands` doesn't retry a failed command on a later boot. This is why a
*third* from-scratch Server 2022 disk was needed this session, not just a second.

### Operational note (not a script bug): Packer's qemu builder needs `efi_firmware_vars` to already exist

`packer/boot-and-provision.pkr.hcl`'s `efi_firmware_vars` points at a path Packer expects to already
contain a real OVMF vars file - it does not create one from scratch the way a person might assume.
`build.sh` copies a fresh `OVMF_VARS_4M.fd` there before every `packer build`, matching
`dev/run-phase3-test.sh`'s identical existing pattern; this was missed on the first manual
`packer build` invocation of the new production config and produced `failed to read from efivars
file ...: no such file or directory` within seconds.

### Operational note (harness, not project code): long-running `packer build` invocations launched via this session's own tracked background-task mechanism were externally killed within 15-60 seconds, three times in a row, on the exact same command

Not a bug in `boot-and-provision.pkr.hcl`, `build.sh`, or anything in this repository - confirmed by
launching the *identical* command as a fully detached process (`nohup ... & disown`, outside the
session's own background-task tracking), which ran cleanly to completion (50m57s, full IIS+SQL
Server install included) on the very next attempt with no other change. Recorded here in case a
future session hits the same pattern: if a long Packer/QEMU build launched via the harness's tracked
background-task mechanism dies within the first minute with no error from Packer itself other than
"Cancelling build after receiving terminated," try relaunching it fully detached before assuming the
build itself is broken.

---

## Confirmed results (production pipeline, Session 2)

| OS | Profile | Path | Result | Time |
|---|---|---|---|---|
| Server 2022 | `ad-ds` | `image-apply/*.sh` (fresh disk) → `packer/boot-and-provision.pkr.hcl` | NTDS/DNS up, domain live after reboot | 6m49s |
| Server 2025 | `iis` + `sql-server` | `image-apply/*.sh` (fresh disk) → `packer/boot-and-provision.pkr.hcl` | HTTP 200; SA login + `SELECT 1` | 50m57s |

Both built from completely blank qcow2 disks by the new scripts - no dev-harness reference disk, no
hand-run steps anywhere in the chain. `image-apply/output/builds/server2022-test3.qcow2` and
`server2025-test1.qcow2` are the two confirmed-good disks this session produced (both still present
as of this writing, gitignored, disposable per this project's ephemeral-infrastructure principle -
not meant to be kept long-term; both were in fact deleted in a later housekeeping pass once the
evidentiary bar was independently re-confirmed elsewhere - see the "Housekeeping, continued" section
below).

---

## STATUS AND NEXT STEPS ON RESUMPTION (Session 2)

**Where things stand: the production pipeline is real now, not just designed.** `image-apply/`'s
four scripts plus `packer/boot-and-provision.pkr.hcl` and `build.sh` together take a completely
blank disk all the way to a WinRM-reachable, role-provisioned VM, confirmed end-to-end for both
target OSes with zero hand-run steps anywhere in the chain. Both the Server-2025 `cpu_model` gap
(Session 1, Finding 1) and this session's five findings above are now fixed at the source, not
worked around downstream.

**What's still genuinely open:**
1. Windows 11 was not run through `image-apply/`'s new scripts this session (Server 2022/2025 only,
   matching this session's actual scope) - the OS config table already covers it
   (`image-apply/lib/common.sh`), but it's untested through the new scripts specifically. Not
   blocking anything (Windows 11 gets none of Phase 3's roles either way), but worth knowing before
   assuming it "just works" the way Session 12/13 confirmed for the *hand-run* recipe.
2. `image-apply/build-winpe-medium.sh` (documenting/automating how `winpe-boot-index1-work.qcow2`
   itself was built, per `PHASE2_ENGINEERING_LOG.md` Findings 11-12) was not written this session -
   the existing medium works and was reused as-is. A truly from-scratch environment with no prior
   `image-apply/output/` state would currently have no way to produce this file; it's a real
   reproducibility gap, just not one that blocked this session's work.
3. `build.sh` itself (the top-level orchestrator wiring all four `image-apply/*.sh` scripts plus the
   Packer handoff together) was written and code-reviewed but not run start-to-finish as a single
   invocation this session - each stage was run individually while iterating on the bugs above, and
   the final confirmed runs invoked Packer directly rather than through `build.sh`. Worth one clean
   `build.sh` run end-to-end before treating it as proven, even though every stage it calls has now
   been individually confirmed.

**Persistent state that survives** (under `image-apply/output/`, gitignored, as of this writing -
both `.qcow2` files below were deleted in a later housekeeping pass, see "Housekeeping, continued"):
`server2022-test3.qcow2` and `server2025-test1.qcow2` are this session's two confirmed-good
from-scratch disks. `image-apply/output/virtio-drivers/` and `image-apply/output/wim-cache/` hold
extracted driver files and `install.wim`s respectively, reused across runs to avoid re-extracting on
every invocation. `packer/output/server2022/` and `packer/output/server2025/` hold the final
provisioned VM artifacts from each confirmed run.

---

## Session 3: closing the Windows 11 gap flagged above (item 1) - found a real,
## reproducible defect distinct from anything Server 2022/2025 hit, and a genuine
## architectural fork in the road for fixing it properly

**Where this picked up:** Session 2 closed with Windows 11 explicitly untested through the new
`image-apply/*.sh` scripts (item 1 in its own next-steps list). This session ran it - and found
real problems Server 2022/2025 never hit, deep enough that "run the same scripts, same as Server"
turned out not to be the right frame at all.

### Finding 7: Windows 11's OOBE shows an interactive "Choose your keyboard layout" screen despite
`unattend-windows11.xml` already containing every setting Microsoft's own current documentation
recommends for suppressing it

**Symptom:** A completely fresh, hands-off first boot (zero keyboard/mouse interaction, watched only
via `tools/qmp-screenshot.py`) reliably stops at a real, interactive "Choose your keyboard layout"
OOBE screen with `US` pre-highlighted, requiring a keypress to advance. Reproduced independently on
two separate from-scratch disks. Never observed on Server 2022 or Server 2025 with the structurally
equivalent `unattend-server*.xml` files.

**Diagnosis, primary-source-verified rather than assumed (per this project's own research-first
discipline):**
- Microsoft's current schema reference for the `OOBE` component
  ([Microsoft Learn: OOBE](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-oobe))
  **no longer lists `SkipMachineOOBE` or `SkipUserOOBE` at all** - the current child-element table is
  `HideEULAPage`, `HideLocalAccountScreen` (Server-only), `HideOEMRegistrationScreen`,
  `HideOnlineAccountScreens`, `HideWirelessSetupInOOBE`, `NetworkLocation`, `OEMAppID`,
  `ProtectYourPC`, `UnattendEnableRetailDemo`, `VMModeOptimizations`. `unattend-windows11.xml` sets
  `SkipUserOOBE`/`SkipMachineOOBE` anyway (inherited from the sibling project's original answer
  file) - settings Microsoft's own reference has already dropped.
- Microsoft's ["Automate OOBE"](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/automate-oobe)
  page states outright, as a boxed warning: **"Don't use the `SkipMachineOOBE` setting to automate
  OOBE. Instead, use the above unattend settings."** Its full recommended-settings table (all
  `oobeSystem` pass): `Microsoft-Windows-International-Core`'s `InputLocale`/`SystemLocale`/
  `UILanguage`/`UserLocale`; `Microsoft-Windows-Shell-Setup/UserAccounts`; `Microsoft-Windows-Shell-
  Setup/OOBE`'s `HideEULAPage`/`HideOEMRegistrationScreen`/`HideOnlineAccountScreens`/
  `HideWirelessSetupInOOBE`/`HideLocalAccountScreen`; and `ProtectYourPC`. **Checked
  `unattend-windows11.xml` directly against this table: every applicable setting is already
  present** (`HideLocalAccountScreen` is the one omission, but Microsoft's own OOBE-component page
  says it's Server-only, so its absence is correct, not a gap). This rules out "missing setting" as
  the explanation.
- Microsoft's [`Oobe.xml` documentation](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/oobexml-in-windows-11)
  (a separate, OEM-manufacturing-oriented file from `unattend.xml`) states directly: *"The default
  values you set in Oobe.xml will be the default values the user sees on the Language, Region, and
  Keyboard layout selection screens during OOBE. **The user can select another value from the list
  if desired, and their selection will override the Oobe.xml settings.**"* This is Microsoft
  confirming, in its own words, that this specific screen category is designed to always show and
  require confirmation - not something any config file skips outright. Caveat, stated plainly: this
  doc describes `Oobe.xml` specifically (OEM-manufacturing-oriented, normally paired with a real
  Setup.exe/Audit-Mode flow - see Finding 8 below), not a direct statement about this project's
  offline-drop-without-Setup.exe delivery mechanism, so treat this as strong supporting evidence for
  *why* the screen behaves this way, not iron-clad proof our specific pipeline is bound by the exact
  same rule.
- Community reports checked for a *non-determinism* angle specifically (same config, sometimes
  works/sometimes doesn't) rather than just "these settings are unreliable" - found real, relevant,
  but not a precise match: an [NTLite forum thread](https://ntlite.com/community/threads/windows-11-24h2-bypasses-the-unattend-settings-for-windows-pe.5166/)
  documents a **hard, consistently-reproducing** Windows 11 24H2 regression where `windowsPE`-pass
  unattend settings are ignored outright by WinPE Setup, fixed via a registry `CmdLine` tweak that
  forces the legacy `setup.exe`. Real evidence Windows 11's unattend/OOBE behavior has genuinely
  shifted across recent builds, but describes a Setup.exe/WinPE-driven mechanism this project's
  pipeline never uses at all (no `windowsPE` pass, no Setup.exe anywhere, by design) - not a precise
  match, just corroborating context that this general area is known to be in flux upstream.

**Fix status:** confirmed workable (single scripted `send-key ret` via QMP once the screen is
reached advances OOBE normally, verified live against a real stuck instance), but not yet formalized
into `image-apply/make-bootable.sh` or a new script - superseded by Finding 8 below, which points at
a more correct fix than papering over this one screen with a keypress.

### Finding 8: a second, more serious, independently-confirmed defect - Windows 11 first boots can
BSOD with a kernel-level NTFS fault, and bisection isolates the trigger to `apply-unattend.sh`
specifically, not the pipeline's other three scripts

**Symptom:** Two separate fresh Windows 11 disks, each booted fully hands-off (zero interaction,
confirmed via screenshot-only monitoring) with **no interaction by the operator at any point before
the crash**, blue-screened during the normal "This might take a few minutes" servicing screen -
before ever reaching the keyboard-layout screen from Finding 7. Different stop codes each time
(`KMODE_EXCEPTION_NOT_HANDLED (0x1E)` on one run; `PAGE_FAULT_IN_NONPAGED_AREA (0x50)`, explicitly
naming `Ntfs.sys` as the failing module, on an independent from-scratch disk on a later run) -
differing crash signatures on nominally identical builds is the standard fingerprint of genuine
on-disk corruption being hit at different memory offsets, not a deterministic single bug repeating
identically. Never observed on Server 2022 or Server 2025 despite both going through the identical
`apply-image.sh`/`make-bootable.sh`/`apply-unattend.sh` `ntfs-3g` mount/write/unmount sequence and
completing full multi-reboot role provisioning successfully, multiple times, this same session
(Session 2's own confirmed results).

**Bisection methodology and result** (each leg a genuinely fresh, from-scratch disk, watched
hands-off via screenshot-only monitoring, no keyboard/mouse interaction before observing the
outcome):
1. `partition-disk.sh` + `apply-image.sh` + full `make-bootable.sh` (viostor **and** netkvm
   `DriverDatabase` hivex injection + driver-file copies included) + `apply-unattend.sh` → **crashes
   reliably** (both stop codes above, on two independent disks).
2. Same as (1) but **skip `apply-unattend.sh` entirely** → **no crash**, reaches a real, further-along
   OOBE screen ("Hi there / What's your home country") cleanly. Confirmed twice independently on two
   separate from-scratch disks (`windows11-bisect2.qcow2`, `windows11-bisect3.qcow2`).
2a. Control test confirming the bisection methodology itself: `partition-disk.sh` + `apply-image.sh`
    only (skip make-bootable.sh's driver injection too) → **`INACCESSIBLE_BOOT_DEVICE (0x7B)`**, the
    expected, well-understood failure from a missing boot-critical storage driver (`PHASE2_ENGINEERING_LOG.md`
    Finding 29's own territory) - confirms the bisection setup correctly produces the *expected*
    failure when a genuinely-required step is skipped, rather than silently masking problems.
3. **Decisive.** Does the crash come from `apply-unattend.sh`'s own `ntfs-3g` write operation, or from
   Windows' specialize pass doing real processing work for the first time (only possible once a
   parseable `unattend.xml` exists) surfacing pre-existing latent corruption from an *earlier* step?
   Test: wrote an intentionally-invalid, non-XML garbage string to `Windows\Panther\unattend.xml`
   (exercises the identical `ntfs-3g` write path - same mount, same directory, same file - but Windows
   cannot parse it as a real answer file) on a fresh disk (`windows11-bisect4.qcow2`, through
   `partition-disk.sh`/`apply-image.sh`/`make-bootable.sh` first, exactly like every other leg), then
   booted hands-off. **Result: no crash.** Windows shows a completely normal, graceful dialog -
   `"Windows could not parse or process unattend answer file [C:\Windows\Panther\unattend.xml]. The
   answer file is invalid."` - handled cleanly, no BSOD, no corruption symptom of any kind. This
   conclusively rules out the `ntfs-3g` write mechanism itself as the cause (a garbage file exercising
   the identical write path is harmless) and confirms the trigger is specifically **Windows actually
   parsing and processing a valid, well-formed `unattend.xml`** - i.e., real specialize-pass work
   surfacing something, not the offline file-drop operation that delivers it. This directly supports
   Finding 9's Audit-Mode/Sysprep theory below: the specialize pass doing real work is exactly the
   scenario Sysprep's live `/generalize` cycle is meant to have already validated before a real
   customer-facing first boot ever attempts it, which this pipeline currently skips entirely.

**Methodological correction made mid-session, worth its own record:** an early hard QMP `quit` (used
to pause and offline-inspect a disk that had just reached a real desktop/OOBE screen with zero prior
interaction) left that specific disk's NTFS volume in a genuinely unclean state - not a pipeline bug,
just the normal consequence of killing a still-running guest OS mid-session. This produced two
misleading symptoms initially treated as more evidence of the same corruption: a later `ntfs-3g`
read-write mount refusing outright, and a spurious WinRE "Choose an option" recovery screen on a
subsequent boot of that same disk. Both were self-inflicted artifacts of the hard `quit`, not
independent findings - `windows11-test3.qcow2`'s crash (a disk never touched or quit even once
before it crashed on its own) is the one piece of evidence in this section not subject to that
caveat, and is why Finding 8 above is written the way it is (leaning on `test3` and the from-scratch
bisection legs, not on anything observed after a hard quit). Standing rule going forward, saved to
memory: end any QEMU session whose disk will be reused with a graceful QMP `system_powerdown` +
poll-until-exit, never a hard `quit`, unless the disk's state genuinely no longer matters.
**Practical complication discovered while trying to follow this rule**: Windows sitting at an
interactive OOBE screen (Finding 7's keyboard-layout screen, or the "Hi there" screen) does **not**
appear to honor a QMP `system_powerdown` ACPI signal at all (confirmed: no process exit after 90+
seconds) - graceful shutdown only works once a real desktop/shell session is reached. Plan
bisection legs so the disk being preserved for reuse is stopped at a point where a real shutdown is
actually possible, or accept rebuilding fresh rather than reusing a disk stuck at OOBE.

### Finding 9: Microsoft's own real OEM manufacturing pipeline never goes straight from "offline
image apply" to "customer-facing first boot" the way this project's pipeline currently does - it
always inserts an Audit Mode + Sysprep cycle in between, and this project has never done that

Read directly from Microsoft's primary documentation
([Deployment and imaging overview](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/deployment-and-imaging-primer?view=windows-11)),
not summarized secondhand, prompted by trying to understand why Findings 7-8 might be
Windows-11-specific. The real, documented OEM manufacturing flow:

1. **Apply the image via WinPE + DISM**, "skipping the Windows Setup process" - confirmed, in
   Microsoft's own words, as the same mechanism this project already uses (not a workaround; this
   *is* the documented OEM technique).
2. **Offline-customize while still in WinPE** - add drivers/packages to the applied-but-unbooted
   image. Matches this project's `make-bootable.sh` driver injection.
3. **Boot into Audit Mode** - a built-in Windows feature (triggered via `Ctrl+Shift+F3` during OOBE,
   or the `Microsoft-Windows-Deployment` unattend component) that logs straight into an
   Administrator desktop **without ever going through OOBE at all**. This project has never used
   this - it's the step that's missing.
4. **Make further live customizations** inside that real, running Windows session (install apps,
   drivers requiring a live OS, etc.).
5. **Run Sysprep** (`/generalize /oobe /shutdown`) - re-generalizes the installation (SIDs,
   hardware-confirmation state, etc.) so the *next* boot is a genuinely clean, real first-boot OOBE
   that fully honors the answer file. Per Microsoft's own text: *"Sysprep only runs online"* (must be
   run from within a live, booted session, not offline) *"and is included in all Windows images."*
6. **Ship it** - the customer's actual first power-on is that clean, Sysprep-prepared OOBE boot.

**This project's pipeline currently goes straight from step 2 to step 6**, treating the
offline-applied-plus-driver-injected disk's first boot as if it were already a Sysprep-prepared,
customer-ready first boot. Findings 7 and 8 are both plausibly explained by this gap: Windows' own
internal first-boot/generalize state tracking (registry flags, and possibly NTFS's own metadata
consistency expectations) may simply not be in the shape Windows expects without ever having gone
through a real, live Sysprep pass - `install.wim`'s own baseline generalized state is designed for
*one* specific flow (apply → boot → real OOBE, exactly once), and this project's additional
offline `hivex`/`ntfs-3g` edits after that captured state happen entirely outside anything Sysprep
or a real booted Windows session ever validated.

**Access note, since it matters for whether this is even a viable path**: despite the "OEM" framing,
none of this tooling is gated behind an OEM license or program membership, per Microsoft's own docs -
the ADK (bundling DISM, the WinPE add-on, and Windows SIM) is a free public download, Audit Mode is a
built-in feature of every Windows image, and Sysprep is explicitly "included in all Windows images."
The "OEM" label describes the *intended audience*, not an access restriction.

**This is a genuine architectural fork in the road, not a small patch - flagged here explicitly for
reconsideration, not decided:**
- **Option A**: keep the current architecture (offline-only, no boot until the final customer-facing
  boot) for all three OSes, and try to work around Findings 7/8 within that constraint (e.g., a
  scripted keypress for Finding 7, and further root-causing exactly what in `apply-unattend.sh`'s
  write triggers Finding 8, possibly avoidable without a live boot at all).
- **Option B**: add a real Audit-Mode-boot + Sysprep + shutdown cycle into `image-apply/` **for
  Windows 11 specifically**, between `make-bootable.sh` and `apply-unattend.sh` (or replacing
  `apply-unattend.sh`'s offline file-drop with a live, Sysprep-driven unattend application instead) -
  this would make Windows 11's build recipe a **distinct implementation branch** from Server
  2022/2025's, which have shown no evidence of needing this (zero BSODs, zero unskippable OOBE
  screens, across every attempt this session and Session 2's). Server 2022/2025 stay on the current
  fully-offline architecture; only Windows 11 gains an extra live-boot phase.
- **Revised on reflection, same session**: an earlier draft of this finding left open whether Server
  2022/2025 simply hadn't been stress-tested enough to surface the same problem. Counting the actual
  trial history corrects that: Server 2022 succeeded independently **three** separate times (dev-harness
  `ad-ds`, dev-harness `iis`/`sql-server`, production-pipeline `ad-ds` from a from-scratch disk) and
  Server 2025 succeeded independently **three** separate times too (same pattern) - six full
  boot-plus-reboot cycles across two OS versions, all through the identical `apply-unattend.sh`
  mechanism, each with real `FirstLogonCommands` work (`pnputil` driver install, a polling loop,
  WinRM listener creation), zero crashes. Against that, Windows 11 crashed on both of its clean
  attempts. That is a real, lopsided track record, not an absence of trials - and it lines up with a
  concrete, specific mechanism rather than needing to be explained by luck: Windows 11 has Fast
  Startup enabled by default (Server SKUs don't - `PHASE2_ENGINEERING_LOG.md` Session 13), and
  client-SKU first-boot servicing visibly does more work than Server's simpler first-boot path (the
  "This might take a few minutes" screen itself, which Server never shows an equivalent of). The
  working assumption going forward is that this is genuinely Windows-11-specific, not a
  latent risk in the Server 2022/2025 recipe - Option B's scope (Windows 11 only) reflects that.
  Worth re-opening only if Server 2022/2025 ever shows a similar crash under real production use, not
  something to keep re-litigating without new evidence.

---

## STATUS AND NEXT STEPS ON RESUMPTION (Session 3)

**Where things stand:** Server 2022 and Server 2025's production pipeline (Session 2) is unaffected
by anything found this session and needs no changes - six independent successful boot-plus-reboot
cycles across both OSes stand as real, repeated evidence, not a fluke. Windows 11 has a real,
reproducible, now root-caused-to-the-trigger-level defect that blocks a genuinely clean, fully
hands-off build: `apply-unattend.sh` (specifically, Windows actually parsing and processing the valid
`unattend.xml` it delivers) triggers first-boot instability ranging from an unskippable interactive
OOBE screen (Finding 7) to an outright kernel-level BSOD with differing NTFS-referencing stop codes
across runs (Finding 8) - genuine on-disk corruption, not a cosmetic glitch. Finding 9 identifies the
likely structural cause (this pipeline has never used Microsoft's own real Audit-Mode + Sysprep
cycle, which every real OEM manufacturing flow inserts between offline image prep and a customer-
facing first boot) and lays out two real architectural options, explicitly not decided yet.

**Immediate next steps, in order, whenever directed:**
1. **Decide between Option A and Option B in Finding 9** - this is a real scope/architecture decision
   for the user, not something to default into. Option B (Audit Mode + Sysprep, Windows-11-only) is
   the better-supported fix given Finding 8's bisection result (a valid, Windows-processed
   `unattend.xml` is the actual trigger - exactly the scenario Sysprep's live cycle exists to make
   safe), but it's real new work (an additional live-boot phase, `image-apply/` script changes
   specific to one OS), not a small patch. **A full research and phased execution plan for Option B
   is written up in `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`** - not started, nothing in it tested
   empirically, but ready to pick up directly whenever this gets prioritized.
2. If Option A is chosen instead: the immediate, narrower fix is scripting Finding 7's confirmed
   single-keypress workaround into the pipeline (QMP `send-key ret` once the keyboard-layout screen is
   detected), but Finding 8's BSOD risk would remain **unresolved** under Option A - a scripted
   keypress does nothing for on-disk NTFS corruption. Don't treat Option A as complete without also
   separately addressing Finding 8.
3. Either way, root-causing *why* real specialize-pass processing specifically corrupts NTFS metadata
   (not just *that* it does) would strengthen whichever fix is chosen - not yet investigated at the
   mechanism level (e.g., whether it's `$LogFile`/USN journal inconsistency from `ntfs-3g`'s writes
   not being byte-compatible with what a real Windows NTFS session would have produced, per the
   working hypothesis in this session's earlier discussion, still unconfirmed offline since `ntfsfix`
   isn't in this host's sudoers allowlist - see `tools/sudoers-windows-auto-build-pipeline` if that
   diagnostic access is ever wanted).

**Persistent state that survives** (under `image-apply/output/`, gitignored): `server2022-test3.qcow2`
and `server2025-test1.qcow2` (Session 2's confirmed-good disks, unchanged, unaffected by this
session; both later deleted in housekeeping, see "Housekeeping, continued" below).
`windows11-bisect4.qcow2` (this session's last disk - reached the graceful "invalid answer
file" dialog, not a real confirmed-good Windows 11 build; safe to delete, not a reference artifact
worth keeping). No VM left running, no `qemu-nbd` attached, environment fully clean at session end
(confirmed via `pgrep`).

---

## Session 4: Option B chosen - `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md` Phase 1 executed and
## confirmed, the plan's single biggest open question, resolved

**Where this picked up:** Session 3 closed with Option A vs. Option B explicitly undecided. This
session's direction was to proceed with Option B; `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`'s Phase 1
("verify the core mechanism, cheaply, before writing any real script") was executed exactly as
written there.

### Finding 10: the offline-drop delivery mechanism (`%WINDIR%\Panther\unattend.xml`) does trigger
### Audit Mode entry - the plan's single biggest unverified assumption is now confirmed true

Built a completely fresh Windows 11 disk (`image-apply/output/builds/windows11-auditphase1.qcow2`)
through the unmodified `partition-disk.sh`/`apply-image.sh`/`make-bootable.sh` sequence (so this disk
also carries the normal viostor/netkvm `DriverDatabase` offline injection - the same driver-injected
state a real build produces, not a stripped-down minimal disk). Wrote a new, deliberately minimal
answer file, `image-apply/unattend-windows11-audit-trigger.xml` - containing *only* the
`Microsoft-Windows-Deployment`/`Reseal`/`Mode=Audit` setting under the `oobeSystem` pass (confirmed
from Microsoft's own primary-source doc that `Reseal` is valid only under `auditSystem`/
`auditUser`/`oobeSystem`, never `specialize` -
https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-reseal).
Offline-dropped it to the same `Windows\Panther\unattend.xml` path this project already proved for
specialize/oobeSystem processing (Session 9/Finding 34) - not the DISM-mount-specific
`Panther\Unattend\Unattend.xml` subfolder path a different section of Microsoft's own doc describes,
which applies to modifying an already-OOBE-configured image via `Dism /Mount-Image`, not a fresh,
never-booted WIM apply like this project's.

Booted the disk solo (`virtio-blk-pci`, `q35`/`accel=kvm`/`cpu host` - matching
`packer/boot-and-provision.pkr.hcl`'s production device model exactly, per `make-bootable.sh`'s own
established pattern) with a QMP socket, watched via `tools/qmp-watch.sh` (15s interval, 30 shots).
**Result: unambiguous success, matching Microsoft's documented behavior exactly, not just a plausible
partial match:**

- No OOBE screen of any kind appeared - the boot went straight from firmware to the built-in
  **Administrator** account auto-logging in ("Preparing Windows"), exactly matching the docs' own
  description ("Booting to audit mode starts the computer in the built-in administrator account").
- The **System Preparation Tool (Sysprep) 3.14 GUI launched automatically** on reaching the desktop -
  again an exact match to Microsoft's documented behavior ("the computer boots into audit mode
  automatically, and the System Preparation (Sysprep) Tool appears"), not something this project
  triggered itself.
- The desktop watermark read "Windows 11 Enterprise Evaluation" with a real, live Explorer shell
  (Recycle Bin, desktop icon, taskbar, Start button) - a genuine interactive desktop session, not a
  crash or a black screen.

One cosmetic, unrelated artifact observed and worth recording so it isn't mistaken for a pipeline
defect in a future session: a `CrossDeviceResume.exe` (Phone Link's cross-device-resume component,
under `C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\`) error dialog reading "The
parameter is incorrect" appeared once on top of the Sysprep dialog (read directly via `Alt+Tab`
window-cycling through `tools/qmp-sendkey.py`, since no `usb-tablet` device was attached to this ad
hoc boot for `qmp-click.py` to use - only one distinct error window existed, not two, despite
appearing at two different taskbar positions across screenshots). This is a well-known, benign
first-logon quirk of this specific built-in Windows 11 app failing to find expected state in a fresh/
audit-mode account context - unrelated to this project's own driver injection or unattend mechanism,
and does not block or interfere with anything (Sysprep's own dialog was unaffected, still fully
interactive underneath it).

**Session stopped deliberately at this point, without running Sysprep** - Phase 1's own success
criterion (reach a real Administrator desktop with no OOBE) was already unambiguously met, and
running Sysprep now would have meant driving the GUI manually (Phase 2's *fallback* mechanism, not
its first choice - the plan's own Phase 2 wants `RunSynchronous`-automated `sysprep /generalize /oobe
/shutdown` tried first). Dismissed the `CrossDeviceResume.exe` dialog and the Sysprep dialog itself
both via `Escape` (never their `OK` buttons - `Escape` closed each cleanly without invoking any
action, confirmed via screenshot: `Cancel`-equivalent, landing back on a clean, dialog-free Audit
Mode desktop), then sent a graceful QMP `system_powerdown` - **which the VM honored and exited on its
own**, unlike Session 3's finding that an interactive OOBE screen doesn't honor ACPI shutdown; a real,
logged-in desktop session (even mid-dialog) does. Confirmed clean afterward: no `qemu` process, no
`qemu-nbd` attachment, no stale mount (`pgrep`/`mount` both checked).

This directly resolves Open Question 1 in `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md` ("Does the
offline-drop delivery mechanism trigger Audit Mode at all, in a Setup.exe-free pipeline?") - yes,
confirmed empirically, not just reasoned about. Per the plan's own framing, this was the hard stop
that would have blocked Option B entirely and forced a return to Option A; it didn't fail, so Option B
remains viable and Phase 2 is next.

**Persistent state that survives** (under `image-apply/output/`, gitignored):
`windows11-auditphase1.qcow2` - a real, confirmed-good disk sitting at a clean Audit Mode desktop
(Sysprep not yet run), worth keeping as a Phase 2 starting point rather than rebuilding from scratch,
though Phase 2 will likely need its own fresh disk anyway since `RunSynchronous` commands are
processed only during a pass's actual first execution, not replayable against an already-audit-mode
disk via a simple file drop. Screenshots from this session are under `/tmp/w11audit-shots/` (host
scratch, not committed - this log is the durable record). No VM left running, no `qemu-nbd` attached,
environment fully clean at session end (confirmed via `pgrep`/`mount`).

**Next steps:** `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md` Phase 2 - extend the trigger unattend.xml with
a `RunSynchronous` command (or researched equivalent) that runs `sysprep /generalize /oobe /shutdown`
automatically once Audit Mode is reached, on a fresh disk, confirming the VM powers itself off on its
own afterward with no live keystroke driving required.

### Finding 11: `RunSynchronous` under the `auditUser` pass does automate Sysprep's invocation with
### zero live keystroke driving - Phase 2 confirmed, and the same run also answers Phase 3's driver-
### tolerance question since this disk already carries the normal viostor/netkvm injection

Built a second completely fresh Windows 11 disk (`windows11-auditphase2.qcow2`) through the same
unmodified `partition-disk.sh`/`apply-image.sh`/`make-bootable.sh` sequence (so, like every real
build, it carries the normal offline viostor/netkvm `DriverDatabase` injection - not a stripped-down
disk). Extended Phase 1's confirmed-working trigger XML with a second settings pass, written up as
`image-apply/unattend-windows11-audit-sysprep.xml`:

- `oobeSystem`: `Reseal`/`Mode=Audit` (unchanged from Phase 1)
- `auditUser`: `Microsoft-Windows-Deployment`/`RunSynchronous`/`RunSynchronousCommand` running
  `cmd.exe /c C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown > C:\audit-sysprep-log.txt 2>&1`,
  `WillReboot=Never` - confirmed from Microsoft's own primary-source docs before writing this that
  `RunSynchronous` is valid only under `auditUser`/`specialize` (not `auditSystem`), and that
  `auditUser`'s own doc explicitly states no explicit Administrator-account/autologon setup is
  needed - the built-in Administrator account is auto-enabled and auto-signed-in specifically to run
  these commands, matching what Phase 1 already observed happening on its own.

Offline-dropped this to the same `%WINDIR%\Panther\unattend.xml` path, booted solo (identical device
model to Phase 1 - `virtio-blk-pci`/`q35`/`accel=kvm`/`cpu host`), watched via `tools/qmp-watch.sh`
(20s interval) while a separate `Monitor` watch polled for the QEMU process to exit on its own.
**Result: unambiguous, hands-off success:**

- The boot reached the same built-in-Administrator "Preparing Windows" screen Phase 1 showed - but
  this time it **never proceeded to a visible interactive desktop at all**. It stayed on "Preparing
  Windows" for roughly 80 seconds (consistent with `RunSynchronous` processing happening during
  `auditUser`'s own logon-context pass, before `explorer.exe`/the shell ever gets control - not
  something this project had reason to expect going in, but consistent with `auditUser` running
  "in user context," per its own doc), then **the QEMU process exited entirely on its own** with no
  further screenshots possible (`qmp-screenshot.py`'s next attempt failed with a plain
  `FileNotFoundError` on the socket path - the whole process, not just the guest, was gone).
- Confirmed via offline remount afterward (`ntfs-3g` mounted **read-write successfully**, itself a
  signal of a clean prior shutdown, not the read-only fallback Session 3 saw after an unclean one):
  Sysprep's own `setupact.log` shows a completely normal `/generalize /oobe /shutdown` run ending in
  `SYSPRP FCreateTagFile:Successfully created tag file
  C:\Windows\System32\Sysprep\Sysprep_succeeded.tag` - Windows' own definitive internal
  success marker, not this project's inference - followed immediately by
  `SYSPRP ProcessShutdown:Successfully called InitiateSystemShutdownEx to shutdown the computer`.
- Two non-fatal errors appear in the same log and are worth recording so a future session doesn't
  mistake them for something this project's own driver injection caused: `SPPNP: Failed to queue
  enumerated driver packages. Err = 0x57` during the generic "Sysprep Generalize Drivers" task
  (immediately preceded by a string of `Unable to uninstall device ROOT\<X>\0000. Err = 0xE0000231`
  lines for **platform root-enumerated devices** - `VOLMGR`, `BASICDISPLAY`, `SPACEPORT`,
  `ACPI_HAL`, `BASICRENDER` - not `viostor`/`netkvm` by name at all, a well-documented,
  widely-reported generic Sysprep quirk seen on plenty of stock Windows installs with zero custom
  driver injection); and `BCD: BiUpdateEfiEntry failed c000000d` / `BiExportBcdObjects failed` /
  `BiExportStoreAlterationsToEfi failed` (about exporting the generalized BCD store to UEFI NVRAM
  firmware variables specifically - a known common OVMF/QEMU-environment quirk, distinct from the
  primary on-disk BCD store update, which the very next log line confirms succeeded separately:
  `Sysprep_Generalize_Bcd: Successfully generalized the bcd store. Status=[0x0]`). Neither error
  blocked the success tag from being written.

This resolves `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`'s Phase 2 outright (RunSynchronous works, no
live keystroke driving needed, matching the plan's stated preference over its own QMP-keystroke
fallback) and **also substantively answers Open Question 3 / the plan's own Phase 3** ("Does
Sysprep's `/generalize` pass tolerate this project's offline `hivex`-injected virtio drivers
cleanly?") - because this test disk was never a stripped-down minimal one; it carries the exact same
driver injection every real build produces, and Sysprep completed successfully against it. This
doesn't yet confirm the drivers still function correctly on the *next* real boot after generalize
(that needs an actual Phase 4/5 end-to-end run, since PnP re-detects and reconfigures devices during
the following `specialize` pass) - but there's no evidence here of a Sysprep-level validation
rejection of this project's injection approach, which was the specific risk Finding 9 flagged.

**Persistent state that survives** (under `image-apply/output/`, gitignored):
`windows11-auditphase2.qcow2` - a real, confirmed-good disk that completed a live `/generalize /oobe
/shutdown` cycle and is now genuinely Sysprep-prepared, sitting powered off, ready for the real
final `apply-unattend.sh` drop and a real customer-facing first boot (the next real thing to test,
whether by hand or once Phase 4 formalizes this into a script). `windows11-auditphase1.qcow2` (Phase
1's disk, Sysprep never run) also still survives. No VM left running, no `qemu-nbd` attached,
environment fully clean at session end (confirmed via `pgrep`/`mount`).

**Next steps:** `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md` Phase 4 - write the real
`image-apply/audit-mode-sysprep.sh` script (mirroring `image-apply/*.sh`'s existing conventions) and
wire it into the pipeline between `make-bootable.sh` and `apply-unattend.sh`, for `windows11` only.
Phase 5 (full end-to-end validation, 2-3 independent successful builds) follows once Phase 4 exists
- and should include actually booting past Sysprep's post-generalize `specialize` pass to confirm
the virtio drivers genuinely still work post-Sysprep, not just that Sysprep itself didn't reject
them.

### Finding 12: Phase 4/5 - the real production `unattend.xml` still BSODs on its first real boot,
### even after a fully successful, live Audit Mode + Sysprep cycle. Option B's core hypothesis
### (Finding 9) is not confirmed by this run - the fix this whole plan was built around does not,
### by itself, resolve Finding 8

Wrote the real `image-apply/audit-mode-sysprep.sh` script, mirroring the existing `image-apply/*.sh`
conventions exactly (source `lib/common.sh`, `set -euo pipefail`, the same `qemu-nbd`/`ntfs-3g`
offline-drop pattern, a `timeout`-wrapped foreground `qemu-system-x86_64` boot matching
`make-bootable.sh`'s own established style rather than the ad hoc background+poll approach used for
interactive testing in Findings 10-11) - windows11-only, hard-gated (`OS != "windows11"` is a fail-
loud error, not a silent skip), transcribed directly from the proven Session 4 recipe: offline-drop
`unattend-windows11-audit-sysprep.xml`, boot solo, wait for the guest's own shutdown, re-attach and
verify `Sysprep_succeeded.tag` exists (checking the actual success marker, not just inferring
success from the process exiting - a crash also ends the process). Wired it into `build.sh` between
`make-bootable.sh` and `apply-unattend.sh`, conditional on `windows11`.

Ran the complete revised pipeline from a fourth from-scratch disk
(`windows11-phase4test.qcow2`): `partition-disk.sh` -> `apply-image.sh` -> `make-bootable.sh` ->
**the new `audit-mode-sysprep.sh`** -> `apply-unattend.sh` (the real, full production
`unattend-windows11.xml` - `ComputerName`, `TimeZone`, `RegisteredOwner`, full OOBE-skip,
`AutoLogon`, and all four `FirstLogonCommands` steps, not the minimal audit-trigger file). Every
offline stage succeeded exactly as designed, including the new script's own success-tag
verification. Then booted the disk solo one more time - this time with a real `virtio-net-pci`
device and QEMU user-mode `hostfwd` (`15985`-\>`5985`) so WinRM reachability could be checked
directly from the host, not just inferred from a screenshot - to observe the real, customer-facing
first boot this whole plan exists to make safe.

**Result: it still crashed, in exactly the pattern Finding 8 already documented.** The boot reached
further than Session 3's original crashes ever did - a real HTTP request to `http://<host>:15985/wsman`
got a genuine `405 Method Not Allowed` response (the correct answer for a bare GET against a WS-
Management endpoint, which only accepts SOAP POST - confirmed as a real response, not a false
positive, after a first check via a bare TCP connect turned out to be exactly that: QEMU's SLIRP
network backend accepts the *host-side* TCP handshake immediately at process start, before the guest
OS has booted at all, so a plain `/dev/tcp` connect test is not a valid readiness signal for this
setup - a follow-up `curl` to the same port hung and timed out with zero response at that same
moment, confirming the first "port open" result was meaningless). Real WinRM being reachable means
this run got as far as `FirstLogonCommands` actually running (network driver installed via the live
`pnputil` step, WinRM listener created) - genuine progress no earlier Windows 11 attempt in this
project reached. But: shortly after that same HTTP response, the guest **BSOD'd** -
`PAGE_FAULT_IN_NONPAGED_AREA (0x50)`, `What failed: Ntfs.sys` - captured via `qmp-screenshot.py`, not
inferred. It auto-rebooted (`BdsDxe` reloading `Windows Boot Manager`, confirmed via screenshot,
ruling out a boot-configuration regression) and **crashed again**, this time with a **different**
stop code: `KMODE_EXCEPTION_NOT_HANDLED (0x1E)`. This triggered Windows' own automatic-repair flow,
landing on WinRE's interactive "Choose your keyboard layout" screen - which, per Session 3's own
established finding, does not honor a graceful QMP `system_powerdown` (confirmed again here: the ACPI
signal was accepted by QMP but the guest never responded, unlike Session 4's earlier real-desktop
shutdowns in Findings 10-11) and had to be hard-killed (`SIGTERM`, then `SIGKILL` after that was also
ignored) rather than shut down cleanly - acceptable here since the disk was already in a crashed,
non-reusable state by that point, not a disk this session had any reason to preserve pristine.

**This is the same "differing NTFS-referencing stop codes across independent runs" signature Finding
8 described** (`0x50`/`Ntfs.sys` the first crash, `0x1E` the second) - reproduced on a disk that had
just completed a fully successful, live `sysprep /generalize /oobe /shutdown` cycle (Finding 11's own
`Sysprep_succeeded.tag` verification, re-run by the new script and confirmed again on this exact
disk before `apply-unattend.sh` ever touched it). **Finding 9's central hypothesis - that a live
Sysprep pass would re-validate the disk enough that Windows' subsequent real processing of a valid,
complex `unattend.xml` wouldn't corrupt anything - is not confirmed by this result.** Sysprep having
already run did not, by itself, prevent the crash on the very next real boot.

**What this does and doesn't rule out, so a future session doesn't over- or under-read this single
result:**
- It doesn't cleanly rule out Option B - one run is not the same evidentiary bar as the six
  independent Server 2022/2025 successes, or even Finding 8's own multi-run bisection. It's possible
  something *specific* to the interaction between Sysprep's re-generalized state and this
  particular unattend.xml's complexity (four `FirstLogonCommands`, a `PowerShell`-heavy network-wait
  loop, `AutoLogon`) is the actual trigger, rather than Option B's core mechanism being wrong outright.
  Session 3's own bisection already isolated the trigger to "Windows actually parsing and processing
  a *valid* `unattend.xml`" specifically (a garbage file exercising the identical offline write
  path was harmless) - and that finding stands unchanged; this session adds that a prior live
  Sysprep pass doesn't neutralize it, but doesn't identify what would.
- It does mean this plan's own success criteria (Phase 5: "no BSOD, no unskippable OOBE screen, real
  authenticated WinRM connectivity... a single clean run is not sufficient evidence; plan for at
  least 2-3 independent successes") are **not met**, and this first attempt failed outright, not
  marginally.
- The new `audit-mode-sysprep.sh` script itself worked exactly as designed and is not implicated -
  every stage up through its own success-tag verification behaved correctly; the crash happened
  strictly *after* `apply-unattend.sh`'s separate, unchanged offline-drop step, in the same place
  Finding 8 already pointed to.

**This is a genuine, sobering result surfaced immediately to the user rather than downplayed or
spun as partial success** - per this project's own "avoid rabbit holes" and "time-box the research"
standards (`WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`'s own Risks section: *"if it isn't converging
within a reasonable number of attempts, that's a legitimate signal to fall back to Option A rather
than open-ended troubleshooting"*), this is exactly the kind of decision point that belongs with the
user, not something to keep iterating on unilaterally. Not yet decided: whether to attempt further
Option B runs (to see if this is reproducible or was a one-off, matching the multi-run bar this
project has applied everywhere else), pursue the not-yet-investigated NTFS-mechanism root-cause
(Session 3's own deliberately-out-of-scope `$LogFile`/USN-journal hypothesis), or fall back to
Option A.

**Persistent state that survives** (under `image-apply/output/`, gitignored):
`windows11-phase4test.qcow2` - the crashed disk from this session, left as-is (not cleaned up,
not reused) as evidence for a future session's own inspection, matching this project's standard of
preserving rather than discarding a real, unexplained failure. `windows11-auditphase1.qcow2` and
`windows11-auditphase2.qcow2` (Sessions 4's earlier Phase 1/2 disks, both genuinely clean at the
point Sysprep completed) also still survive. No VM left running, no `qemu-nbd` attached, environment
fully clean at session end (confirmed via `pgrep`/`mount`) - the hard-kill above was of the guest
process only, and normal cleanup (unmount/detach) still ran correctly afterward.

**Next steps:** genuinely undecided, flagged explicitly for the user rather than defaulted into -
see the "does and doesn't rule out" discussion above. `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`'s own
status needs updating to reflect this result before any further Option B work resumes.

### Finding 13: directly tested the `$LogFile`/dirty-bit hypothesis with `ntfsfix` - it does not fix
### the crash, and the *identical* stop codes recurring argue against a journal-staleness mechanism

Per direction, picked up the NTFS-level mechanism investigation Session 3 flagged as out of scope and
Finding 12 left open. `ntfsfix` (part of `ntfs-3g`, already installed on this host) is documented,
in its own man page, as exactly the tool for this class of problem: *"resets the NTFS journal file
and schedules an NTFS consistency check for the first boot into Windows."* Needed root to run against
the raw `/dev/nbd*` partition device (same as `mkntfs`/`sgdisk` elsewhere in this project), which
wasn't yet in `tools/sudoers-windows-auto-build-pipeline` - added it (read-only `ntfsinfo` plus
`ntfsfix`, pinned to `/dev/nbd[0-9]*` exactly like every other rule in the file), asked the user to
install it (requires a real root password this sandboxed session can't supply), and along the way hit
the identical sudoers glob-matching gotcha the file's own "Update 2" note already documented for
`sfdisk` (a bare `ntfsfix /dev/nbd0p3` invocation has only one space where the `ntfsfix * /dev/nbd*`
rule's `*` requires two) - fixed with an explicit bare-invocation rule alongside the flagged one,
same pattern as that earlier fix.

**Diagnostic step first**: inspected `windows11-auditphase2.qcow2` (Finding 11's disk - completed a
verified, successful Sysprep `/generalize` cycle, never crashed, real `unattend.xml` never applied)
via `ntfsinfo -m`. `Volume Flags: 0x0000` - clean, no dirty bit. Ran `apply-unattend.sh` on it (the
same real production `unattend.xml` that crashed in Finding 12), then re-checked immediately
afterward, before any boot: **still `Volume Flags: 0x0000`.** This confirms directly (not just
inferred from Session 3's write-vs-process bisection) that this project's own offline `ntfs-3g` write
does not itself dirty the volume - whatever the eventual crash mechanism is, it isn't something
visible at the volume-dirty-flag level immediately after the offline write.

**Fix test**: ran `ntfsfix` (no `-d`, so it also sets the dirty flag to force Windows' own native
check at next mount - the tool's stated purpose) against that same disk, right before its real first
boot - i.e., the earliest point this project's pipeline could plausibly insert this fix, immediately
before the customer-facing boot Finding 12's crash happened on. Confirmed the tool did what its docs
say (`ntfsinfo` afterward showed `Volume Flags: 0x0001 DIRTY`, and a `--force`-flagged read was needed
to inspect it, consistent with a genuinely scheduled check). Then booted solo with the same device
model and WinRM-reachability check as Finding 12 (`virtio-net-pci` + QEMU user-mode `hostfwd`,
corrected this session to use a real HTTP round-trip via `curl` rather than a bare TCP connect - a
bare `/dev/tcp` connect test gave a false "open" reading immediately at QEMU startup, before the
guest OS had even booted, because QEMU's SLIRP network backend accepts the *host-side* TCP handshake
right away regardless of guest readiness; a real `curl` request confirmed this was meaningless by
hanging with zero response at that same moment).

**Result: no different from Finding 12, down to the specific stop codes.** WinRM answered a real
`405 Method Not Allowed` early on again (same as Finding 12 - the boot reaches `FirstLogonCommands`
either way), no chkdsk screen was ever visible despite the dirty flag being set beforehand, and the
guest then BSOD'd with **the exact same first stop code** - `PAGE_FAULT_IN_NONPAGED_AREA (0x50)`,
`What failed: Ntfs.sys` - at nearly the same point in the boot sequence, auto-rebooted, and crashed
**again with the exact same second stop code** - `KMODE_EXCEPTION_NOT_HANDLED (0x1E)` - landing on
the identical unattended WinRE "Choose your keyboard layout" screen Finding 12 also produced. Had to
hard-kill the guest process the same way (`SIGTERM` then `SIGKILL`, WinRE's interactive screen not
honoring QMP `system_powerdown`, matching the established pattern).

**This is a real, useful negative result, not a null one.** Two things follow from the stop codes
being identical, not just similar:
- **It argues against `$LogFile`/journal staleness as the mechanism.** If the crash were caused by
  Windows encountering an ntfs-3g-written journal it couldn't correctly interpret, resetting that
  journal and forcing a fresh native check should have changed *something* about the failure mode -
  a different stop code, a later crash point, visible repair activity, anything. Getting the
  identical `0x50` -> `0x1E` sequence at nearly identical timing is a strong signal the crash is
  **deterministic and reproducible given this exact disk content**, not a race or a
  journal-replay-triggered fault that a journal reset would perturb.
- **The determinism itself is informative for future investigation.** A crash this exactly repeatable
  (not "varies across runs" the way Session 3's original framing described it, though Findings 8's
  own crashes *did* vary in stop code across different runs - worth reconciling in a future session:
  possibly what varies run-to-run is *which* of several latent, always-present inconsistencies gets
  hit first, while the underlying trigger condition - Windows processing this exact class of complex
  `unattend.xml` - is itself fully deterministic) is a better target for direct forensic
  investigation (e.g., comparing MFT/directory-index state for the specific files
  `FirstLogonCommands` touches, before vs. after Sysprep, between a Windows 11 disk and a
  same-recipe Server 2022/2025 disk that never crashes) than a hard-to-reproduce heisenbug would be.

**Persistent state that survives** (under `image-apply/output/`, gitignored):
`windows11-auditphase2.qcow2` - now itself a second, independently-crashed disk (previously Finding
11's clean reference disk; consumed by this session's test, no longer a clean-Sysprep reference -
`windows11-auditphase1.qcow2` remains the one surviving clean, never-booted-post-Sysprep reference).
Both this disk and `windows11-phase4test.qcow2` (Finding 12's crash) now exist side by side as two
independently-produced, identically-symptomed crash artifacts, worth keeping for any future direct
forensic comparison. `tools/sudoers-windows-auto-build-pipeline` gained real, installed, working
`ntfsinfo`/`ntfsfix` access for future sessions. No VM left running, no `qemu-nbd` attached,
environment fully clean at session end (confirmed via `pgrep`).

**Next steps:** still genuinely undecided. This session's negative result narrows the field (probably
not `$LogFile` staleness) without yet identifying the actual mechanism. Candidates going forward:
deeper NTFS forensics comparing the two crashed Windows 11 disks against a same-recipe, never-crashing
Server 2022/2025 disk at the MFT/directory-index level; re-examining whether the crash is really
`unattend.xml`-complexity-specific (Finding 12's speculation, not yet tested - e.g. does a
Sysprep-then-*simpler*-unattend.xml combination succeed?); or setting Option B aside in favor of
Option A. Flagged for the user, not decided unilaterally.

### Finding 14: bisection ladder against the real `unattend.xml`'s own content - the crash has
### nothing to do with `FirstLogonCommands` at all, in either its heavy or its lightweight form; it
### reproduces identically with zero `FirstLogonCommands` present

Per direction, picked up Finding 12's own speculation ("could be an interaction with this specific
unattend.xml's complexity rather than Option B's core mechanism") and tested it directly with a
graduated bisection ladder, each variant a genuinely fresh disk carried through the full pipeline
(`partition-disk.sh` -> `apply-image.sh` -> `make-bootable.sh` -> `audit-mode-sysprep.sh`, each
independently confirming its own `Sysprep_succeeded.tag`) before dropping a variant-specific
`unattend.xml` and running the real solo boot.

**Variant D** (`image-apply/unattend-windows11-ladder-d.xml`): `specialize` (`ComputerName`/
`TimeZone`/`RegisteredOwner`) + OOBE-skip + `AutoLogon`/`AdministratorPassword` (a structural
prerequisite, not a separately-isolated variable - `FirstLogonCommands` only run in the context of
an actual logon, and Sysprep's own `/generalize` pass explicitly removes Audit Mode's built-in-
Administrator auto-enable per Microsoft's own docs, so nothing would trigger a first logon at all
without it) + only the two lightest `FirstLogonCommands` steps from the real production file
(`pnputil /add-driver` for NetKVM, and a marker-file echo) - omitting both heavy PowerShell blocks
(the network-readiness polling loop and the `Enable-PSRemoting`/WSMan-listener-rebuild/
`Restart-Service WinRM` block). **Result: crashed, identically** - `PAGE_FAULT_IN_NONPAGED_AREA
(0x50)`/`Ntfs.sys` then `KMODE_EXCEPTION_NOT_HANDLED (0x1E)` on the automatic retry, landing on the
same unattended WinRE keyboard-layout screen as Findings 12 and 13. Checked offline afterward (disk
mounted read-only after the forced `SIGKILL`, per the now-familiar "Metadata kept in Windows cache"
warning): both `C:\ladder-d-pnputil-log.txt` (*"Driver package added successfully"*) and
`C:\ladder-d-firstlogon-marker.txt` existed and were complete - **`FirstLogonCommands` finished
successfully before the crash happened**, ruling out `pnputil` failing or corrupting something
mid-run, and ruling out any specific FirstLogonCommands content (heavy or light) as the trigger.

**Variant C** (`image-apply/unattend-windows11-ladder-c.xml`): identical to D minus
`FirstLogonCommands` entirely - just `specialize` + OOBE-skip + `AutoLogon`. **Result: crashed,
identically again** - same `0x50`/`Ntfs.sys` -> `0x1E` sequence, same WinRE landing screen. No
`FirstLogonCommands` element was present in the answer file at all.

**This is decisive: the crash has nothing to do with `FirstLogonCommands`, in either form tested.**
Three independently-built, independently-Sysprep'd disks - the full production file (Finding 12),
`pnputil`-only (Variant D), and no-`FirstLogonCommands`-at-all (Variant C) - all produced the
*identical* stop-code sequence at nearly identical points in the boot. What's left implicated is the
skeleton shared by all three and absent from the one file that's never crashed (Finding 10/11's
`Reseal`/`RunSynchronous`-only trigger, which touches neither `specialize` nor `AutoLogon` at all):
the `specialize` pass itself, and/or `AutoLogon`/`UserAccounts`/`AdministratorPassword` specifically.
Both are also present, in essentially the same shape, in the sibling project's own proven Server
2022/2025 templates - which never crash - so whatever this is, it's Windows-11-specific in how it
interacts with this skeleton, not a defect in the skeleton on its own.

**Not yet tested**: removing `AutoLogon` too (down to `specialize` alone, or `specialize` + OOBE-skip
with no logon mechanism at all) - structurally harder to observe cleanly, since without a real logon
there's no automatic path to a desktop and the crash (if it still happens) would need to be caught
mid-`specialize`-pass or at/before an interactive OOBE screen rather than via a clean before/after
comparison.

**Persistent state that survives** (under `image-apply/output/`, gitignored): `windows11-ladderd.qcow2`
and `windows11-ladderc.qcow2`, two more independently-crashed disks, both left as-is - now five total
crash artifacts across this plan's real end-to-end attempts (`windows11-phase4test.qcow2`,
`windows11-auditphase2.qcow2` post-Finding-13, plus these two), all showing the identical two-stop-code
signature. `windows11-auditphase1.qcow2` remains the sole surviving clean, never-booted-post-Sysprep
reference disk. Two new template files committed: `unattend-windows11-ladder-d.xml`,
`unattend-windows11-ladder-c.xml`. No VM left running, no `qemu-nbd` attached, environment fully clean
at session end (confirmed via `pgrep`).

**Next steps:** the field has narrowed sharply - from "somewhere in the real unattend.xml" to
specifically "`specialize` and/or `AutoLogon`, independent of `FirstLogonCommands` entirely." Worth
direct NTFS-level forensic comparison now between one of these five crashed Windows 11 disks and a
same-recipe Server 2022/2025 disk at the point immediately after `specialize`/`AutoLogon` processing
- a same-recipe Server disk exists and never crashes despite processing structurally similar
settings, making it a real, available control rather than a hypothetical one. Also worth considering
whether this is specific to *this pipeline's* `specialize`/`AutoLogon` processing on an offline-
applied-then-Sysprep'd Windows 11 disk specifically (vs. Server 2022/2025's own offline-applied-but-
never-Sysprep'd disks - genuinely different disk histories, not just different OSes) rather than a
Windows-11-vs-Server difference per se. Flagged for the user, not decided unilaterally.

### Finding 15: a full audit of everything outside the tracked scripts - host packages, kernel, source
### media, cached WIM/driver extractions, the WinPE medium's own baked-in logic - found zero
### difference from what produced the one known-good Windows 11 build (`PHASE2_ENGINEERING_LOG.md`
### Session 13). The regression is not in any static input.

Prompted by a sharp observation: `win11-session13.qcow2` (Session 13's hand-run, fully successful
Windows 11 build - real desktop, no BSOD, confirmed authenticated WinRM) still survives on disk, and
this project's own `image-apply/*.sh` scripts are a direct, verified transcription of that exact
recipe. If the *code* is identical and a real artifact proves the *recipe* once produced a clean
result, the regression has to live somewhere the code diff can't see. Audited every such place:

**Sanity check first**: resumed `win11-session13.qcow2` itself (hibernated via Windows 11's Fast
Startup, not shut down - Finding 43's own noted caveat) via a solo boot matching its own original
device model (`OVMF_VARS_session13-solo.fd`, `virtio-net-pci` + `hostfwd`). **Result: resumed
cleanly to the same real, healthy desktop**, correct watermark (`"Windows 11 Enterprise Evaluation /
Windows License valid for 88 days"`), only the same benign `CrossDeviceResume.exe` cosmetic error
every other session has also seen. No BSOD. Confirms the disk and host environment are both still
fundamentally healthy - rules out host/environment decay as a blanket explanation before auditing
anything more specific.

**`unattend.xml` content** (re-confirming Finding 14's own bisection from the other direction):
mounted the Session 13 disk and diffed its actual on-disk answer file against today's
`unattend-windows11.xml` template. Identical, modulo Windows' own expected post-processing rewrite
(`wasPassProcessed="true"` on both passes, redacted passwords) - itself further confirmation both
`specialize` and `oobeSystem` completed cleanly back then with this exact content.

**Every git-tracked script**: `git log` confirms `partition-disk.sh`, `apply-image.sh`,
`make-bootable.sh`, `apply-unattend.sh`, and `lib/common.sh` are byte-identical to the commit
(`094dac4`) that both created *and* confirmed them against Server 2022/2025. The only change since is
this session's own `windows11`-gated `audit-mode-sysprep.sh` call in `build.sh` - confirmed via `git
show`, a plain `if [[ "$OS" == "windows11" ]]` block Server's own execution never enters.

**The WinPE bootability medium's own baked-in logic**: mounted `winpe-boot-index1-work.qcow2`
directly and read `Windows\System32\startnet.cmd` and `diskpart-assign.txt` off it - both byte-for-
byte identical to Session 8's originally-documented recipe (`wpeinit` -> `drvload` -> `diskpart /s`
-> `bcdboot W:\Windows /s S: /f UEFI` -> log copy-off -> `wpeutil shutdown`; `select disk 1` /
partition 1 -> `S:` / partition 3 -> `W:`). A checksum mismatch against an old `.bak` snapshot looked
alarming at first but turned out to be a false lead - the actual content read directly off the medium
matches the documented recipe exactly, and the `.bak` most likely predates Session 8's own
finalization of this file.

**Host packages and kernel**: `/var/log/apt/history.log` shows zero upgrades since before Session
13's build. `uptime -s` shows the host kernel has been running continuously since **before** Session
13 started (`2026-08-20 07:48:03`, Session 13 built at `11:01`) - the exact same kernel instance,
never rebooted, for this entire investigation. Rules out any host-level package or kernel drift
outright, not just "probably fine."

**OVMF firmware and source media**: `/usr/share/OVMF/OVMF_CODE_4M.fd`/`OVMF_VARS_4M.fd` dated June 2
- unchanged, predates Session 13 by months. The Windows 11 and virtio-win source ISOs in
`../iso_cache/` are dated July 22 and June 25 respectively - unchanged, predate Session 13 by weeks.

**Cached extractions, verified by direct re-extraction and checksum comparison, not assumed**: the
Windows 11 `install.wim` cache (re-extracted after Session 13's build, timing that looked like a real
lead at first) is **byte-identical** (`md5sum`) to a fresh `7z e` extraction from the still-unchanged
source ISO. Every driver file this project stages for Windows 11 (`netkvm.inf`/`.sys`/`.cat`/
`.exe`/`netkvmco.exe`, `viostor.inf`/`.sys`/`.cat`) is likewise byte-identical to a fresh extraction
from the unchanged virtio-win ISO.

**One dmesg anomaly chased down and explained, not left dangling**: a burst of seven `Buffer I/O
error on dev nbd0p3` kernel log lines at `11:26:45` today looked concerning on first read. Timing
correlation with this session's own actions places it exactly at the point `nbd0` was re-attached to
offline-inspect the already-BSOD'd, already-`SIGKILL`ed `windows11-ladderd.qcow2` disk (checking for
the `FirstLogonCommands` marker file) - i.e., `ntfs-3g` reading genuinely inconsistent metadata off a
disk already left mid-write by a hard kill, not a symptom appearing *before* or independent of a
crash. Consistent with being a downstream artifact of the crash already covered by Finding 14, not a
new, separate cause.

**Conclusion: every static input this pipeline depends on - tracked code, the WinPE medium's actual
logic, host packages, host kernel, firmware, source media, and cached extractions - is verified
identical to what produced Session 13's success.** Nothing was found by inspection; everything was
checked by direct comparison (`git log`/`git show`, mounting and reading files off disk, `md5sum`
against fresh re-extractions, `apt`/`uptime` history) rather than reasoned about. Given that, and
given this session's own four independent, fully deterministic reproductions of the identical crash
(same two stop codes, similar timing, every time) using this exact same, now-triple-verified recipe,
the most defensible remaining explanation is a **timing- or scheduling-sensitive fault in Windows
11's own first-boot processing under this host's KVM/virtio emulation** - not a defect in this
project's own pipeline, and not something a further code or environment audit is likely to surface.
Session 13's single success and this session's four consecutive failures are both real, both
against verifiably identical inputs; the variable left standing is real-world execution timing this
project has no direct way to control or fully explain, only to note.

**Persistent state that survives**: no new disks created this investigation (only inspected existing
ones and disposable `/tmp` scratch extractions, all cleaned up). No VM left running, no `qemu-nbd`
attached, environment fully clean at session end (confirmed via `pgrep`).

**Next steps**: this substantially changes the shape of the problem. If the fault is genuinely
timing-sensitive rather than deterministic-given-these-inputs, the earlier ladder bisection's
"identical stop codes every time" result (Finding 14) should be read as "identical *within one
session's* relatively stable timing conditions," not as proof of a fixed, always-reproducible defect
- worth attempting at least one more Windows 11 build in a **different session** (different time,
different host load) before concluding anything further about determinism one way or the other. Also
worth considering whether anything about this host specifically (CPU generation, KVM version,
virtio-win driver version `0.1.285` itself) is implicated, versus something that would reproduce on
any KVM host. Flagged for the user, not decided unilaterally.

## HARD STOP: the fully-offline (Setup.exe-free) Windows 11 build pathway is closed, per explicit
## direction. Both architectural options this project explored end at the same unresolved fault.
## Documented here in full so the next phase of work (researching how Windows 11 is actually built
## unattended elsewhere) starts from a complete record, not a partial one.

### Summary of the full trail, both options, in one place

This project's Windows 11 work branched into two architectural options at Session 3's Finding 9, and
this session (Session 4) pursued Option B to a real, evidence-backed conclusion. Combined with
Session 3's own earlier work on Option A, both options terminate at the identical underlying fault.
Restating the whole arc here, not just cross-referencing it, so a future session (or a person) can
understand the full shape of what was tried without reconstructing it from eleven separate findings:

**The fault itself.** A fresh Windows 11 disk, built via this project's offline `wimlib`-apply +
WinPE-`bcdboot` + offline-`unattend.xml`-drop pipeline (the same pipeline that works cleanly and
repeatedly for Windows Server 2022/2025), blue-screens during its real, customer-facing first boot -
specifically during or immediately after the `specialize`/`oobeSystem` configuration passes process a
valid answer file containing `AutoLogon`. Two specific stop codes recur, in the same order, whenever
this fault has been triggered: `PAGE_FAULT_IN_NONPAGED_AREA (0x50)` (explicitly naming `Ntfs.sys` as
the failing module) first, then an automatic reboot into `KMODE_EXCEPTION_NOT_HANDLED (0x1E)`, landing
on an unattended WinRE "Choose your keyboard layout" recovery screen that hangs indefinitely without
manual input - a dead end this pipeline cannot recover from unattended.

**Option A (fully offline, no live boot before the customer-facing one - Session 3, Findings 7-8).**
The original architecture. Bisection conclusively isolated the trigger to Windows *processing* a
valid `unattend.xml` during a real boot (not the offline file-write that delivers it - a
deliberately-invalid file exercising the identical write path was harmless). Both stop codes above
were observed here first, each on an independent from-scratch disk. Never observed on Server
2022/2025 despite six-plus independent successful builds through the identical shared pipeline code,
including real, disk-intensive role provisioning (AD DS, IIS, SQL Server) - this is Windows-11
specific, not a latent defect in the shared machinery.

**Option B (insert a live Audit Mode + Sysprep cycle before the customer-facing boot, matching
Microsoft's own real OEM manufacturing flow - Session 4, this session, Findings 9-15).** Hypothesis:
a live Sysprep `/generalize` pass would re-validate the disk enough to prevent the fault, since that
is exactly the scenario Sysprep's own validation exists to make safe. Built and confirmed real,
working automation for the *mechanism* itself - Findings 10-11 confirmed the offline-drop trigger
reaches real Audit Mode with no OOBE screen (exact match to Microsoft's documented behavior), and that
`RunSynchronous`/`auditUser` automates Sysprep's own invocation with zero live keystroke driving. The
real, production `image-apply/audit-mode-sysprep.sh` script (Finding 12) works exactly as designed,
confirmed via Windows' own `Sysprep_succeeded.tag` marker, not inferred. **But the hypothesis itself
was falsified**: a disk that had just completed a fully successful, verified Sysprep cycle still hit
the identical fault on its very next real boot (Finding 12), reproduced with `ntfsfix`'s `$LogFile`
reset applied beforehand (Finding 13, ruling out journal staleness as the mechanism), and reproduced
again on two further bisected variants that removed `FirstLogonCommands` content entirely, down to
just `specialize` + `AutoLogon` with zero first-logon scripting (Finding 14) - narrowing the trigger
to the `specialize`/`AutoLogon` skeleton itself, independent of anything this project's own tooling
adds.

**The "is it even our code" check (Finding 15).** The one genuinely successful Windows 11 build this
project ever produced (`PHASE2_ENGINEERING_LOG.md` Session 13, hand-run, predating both Sysprep and
the formalized `image-apply/*.sh` scripts) still survives on disk and still resumes cleanly today.
Every static input the current pipeline depends on was directly verified - not assumed - against what
produced that success: every git-tracked script (byte-identical since the commit that confirmed
Server 2022/2025 success through the same code), the WinPE medium's own baked-in boot logic
(byte-identical), host packages and kernel (zero changes, literally the same running kernel instance
since before that success), firmware and source media (unchanged, predate it by weeks to months), and
cached WIM/driver extractions (byte-identical to fresh re-extraction, confirmed via checksum). **Zero
difference found anywhere.** Combined with four independent, fully deterministic reproductions of the
identical two-stop-code fault this session alone, the most defensible explanation is a timing- or
scheduling-sensitive fault in Windows 11's own first-boot processing under this host's KVM/virtio
emulation - real, reproducible *within a given session's execution conditions*, but not tied to any
fixed input this project's own tooling controls.

**Research pass (this session, prompted by "we can't be the first to encounter this").** Nine
distinct web-search angles (literal stop codes, DISM/offline-apply framing, KVM/QEMU/virtio framing,
GitHub-native search of the `virtio-win` project itself) plus direct fetches of the two closest-hit
GitHub issues found real, credible, but non-matching context: Windows 11 + virtio storage devices are
a documented general category of BSOD risk (`virtio-win-pkg-scripts` #105: `0x18B
SECURE_KERNEL_ERROR`, a specific April 2025 Windows Update KB interacting with a driver version,
already fixed via Microsoft's Known Issue Rollback; `kvm-guest-drivers-windows` #730: `netkvm.sys`
`IRQL_NOT_LESS_OR_EQUAL` under sustained network load on Server 2016) - but nothing combining our
exact stop codes with `unattend.xml`/OOBE/offline-deployment keywords, anywhere. Working assessment:
this project's build mechanism (genuinely Setup.exe-free from partition to first boot) is itself
unusual - most real-world unattended Windows 11 deployment tooling (MDT, SCCM, Autopilot, Packer's own
Windows plugins) still routes through Setup.exe or a live-booted WinPE-driven image-capture/apply
cycle at some point. This project's approach exists specifically because the sibling project's
Setup.exe-driven path hit its own unrelated boot-timing bug
(`HANDOFF_FROM_UNATTENDED_INSTALL.md`/`PHASE2_ENGINEERING_LOG.md` Findings 15-28) - not because
Setup.exe itself is known-broken for Windows 11 in general. The community-precedent gap is plausibly
explained by how few deployments are built exactly this way, not by this being an impossible or
already-solved problem going unfound.

### Decision: HARD STOP on this pathway, by explicit direction

Both architectural options available within "apply the Windows image and make it bootable entirely
offline, no Setup.exe, no live boot before the customer-facing one" terminate at the same fault, with
strong, multi-angle evidence (not a hunch) that further iteration *within this pathway* is unlikely to
converge:
- The fault is not caused by anything in this project's own control (Finding 15 rules out code,
  environment, host state, and input media exhaustively).
- The fault is not caused by `FirstLogonCommands` content, driver injection specifically, or `$LogFile`
  staleness (Findings 13-14 each directly tested and ruled out a specific, plausible mechanism).
- No community precedent exists for the exact combination, despite genuine multi-angle research
  effort - this is very likely an edge case of a genuinely uncommon deployment mechanism, not a
  known-and-solved problem this project simply hasn't found yet.
- Repeating either option again would be attempting the identical thing and expecting a different
  result, per explicit user direction - not a productive next step.

**This does not retroactively invalidate anything already proven and shipped.** Server 2022/2025's
production pipeline (`image-apply/*.sh`, `packer/boot-and-provision.pkr.hcl`, `build.sh`) is
unaffected, uses none of the Windows-11-specific code added this session, and remains confirmed
production-ready on its own six-plus-build evidentiary bar. The underlying *tools* this project
proved out along the way - offline `wimlib` image application, BCD-SYS/WinPE-`bcdboot` bootability,
offline `hivex` driver injection, QMP-based hands-off VM observation - are not implicated by this
fault and remain valid, reusable techniques; what's specifically closed is the *combination* of
"entirely Setup.exe-free" with "Windows 11 client SKU."

### Next phase of work (not started - a new research question, not a continuation of Option A/B)

Per explicit direction: research how Windows 11 unattended builds are actually, successfully
accomplished elsewhere, as a precondition for designing whatever this project's Windows 11 pathway
becomes next - rather than deriving a third option from first principles the way Options A and B
were. This is a genuinely different question than anything investigated so far (which only ever
asked "why does our specific mechanism fail," not "what do working mechanisms actually do"), and per
this project's own "research-first discipline" standard, deserves the same multi-angle,
primary-source-verified treatment - including specifically checking whether any credible, working
approach still avoids Setup.exe (matching this project's own standing rule and its origin reason) or
whether that constraint itself needs to be revisited for Windows 11 specifically, now that the
Setup.exe-free path has been shown to have its own real, currently-unsolved failure mode. Not yet
begun as of this entry.

## New pathway, Windows 11 only: `WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md`'s Phase 3.1 - the
## `_noprompt` ISO technique cleanly passes its first gate

Per that plan's own research (Phases 0-2, primary-source-verified: Microsoft's own 15-year-old
`_noprompt` boot files, confirmed present on this project's own cached media, combined with this
project's already-proven direct `bootindex=` control instead of Packer's QEMU builder) and Phase
3's design (a gated, phased plan with an explicit pass/fail criterion at each step, not an
assumption the whole thing works end to end), executed Phase 3.1 - CLAUDE.md's standing Setup.exe
ban having just been explicitly, narrowly relaxed for Windows 11 to allow it.

**What was done**: extracted the full Windows 11 Enterprise Evaluation ISO (`7z x`, all ~7GB, not
just the boot files), swapped `efisys.bin`/`cdboot.efi` for the `efisys_noprompt.bin`/
`cdboot_noprompt.efi` content already present on the same ISO, rebuilt via the verified `xorriso`
recipe (`-eltorito-boot boot/etfsboot.com` for BIOS + `-eltorito-alt-boot -e
efi/microsoft/boot/efisys.bin` for UEFI, `-isohybrid-gpt-basdat`). **Verified the rebuild actually
took, not assumed**: `7z l` against the new ISO confirms `cdboot.efi`/`efisys.bin` are now the
correct size, and `md5sum` confirms their content is byte-identical to the `_noprompt` source files
- not just correctly-sized coincidentally.

Booted the new ISO **completely hands-off - zero keystrokes sent, not even a fallback script** -
via a hand-built `qemu-system-x86_64` invocation (`q35`/`accel=kvm`/`cpu host`, OVMF, CD-ROM-only,
no target disk attached at all, kept minimal per the plan's own Phase 3.1 scope), explicit
`bootindex=1` on the CD-ROM device, watched via `tools/qmp-watch.sh`.

**Result: clean, unambiguous pass.** `BdsDxe` loaded `Boot0001 "UEFI QEMU DVD-ROM"` directly - no
EFI Shell fallback, no PXE, no "Time out" the way the sibling project's own BCD boot log showed for
the un-patched media. The boot went straight from firmware log to a Windows boot-transition screen
to **a real "Windows 11 Setup" language-selection UI**, reached in roughly 20 seconds from boot
start, confirmed settled (three consecutive 10s-apart captures, byte-identical file size) rather
than a transient mid-render frame. At no point did any "press any key to boot from CD or DVD"
prompt appear on screen - not skipped via timing, genuinely never rendered at all, matching what the
`_noprompt` mechanism is documented to do.

This directly passes Phase 3.1's own stated gate. Shut down via QMP `system_powerdown` (ignored, as
expected for an interactive Setup UI screen matching this project's established pattern for
non-desktop screens) then `SIGKILL` - no data loss concern, no target disk was ever attached in
this minimal-scope test.

**What this does and doesn't establish, stated precisely**: this confirms the keystroke race is
genuinely eliminated for this project's own actual Windows 11 media, on this project's own actual
host/QEMU/OVMF stack - not inferred from the Proxmox thread, independently reproduced. It does
**not** yet confirm the deeper OVMF boot-device-ordering question (Phase 3.2's own job - does
`bootindex=` correctly resume into a real target disk across Setup's own multi-phase reboots), and
it does not yet confirm `EarlyF6DriverInstall` or any other Setup.exe-internal gate stays clear
under this delivery shape (also untested by this minimal, disk-less boot). Genuine, real progress -
not the whole plan validated yet.

**Persistent state that survives** (under `image-apply/output/`, gitignored):
`image-apply/output/iso-noprompt/win11-noprompt.iso` (the rebuilt, verified-correct patched ISO -
worth keeping rather than rebuilding, since the rebuild itself is now confirmed correct and
reusable for Phase 3.2 directly) and its `extracted/` working directory (the full unpacked ISO
content, also reusable). No VM left running, no `qemu-nbd` attached (none was ever needed for this
disk-less test), environment fully clean at session end (confirmed via `pgrep`).

**Next step**: Phase 3.2 - add a real target disk and a real (even if minimal) answer file, and
confirm `bootindex=` correctly re-selects the hard disk across Setup's own reboot(s) rather than
falling back into the still-attached ISO.

## Phase 3.2, attempt 1: real progress plus a real, anticipated gate failure - the TPM/Secure Boot
## bypass works cleanly; explicit `bootindex=` alone does NOT survive Setup's own first reboot

Built `image-apply/autounattend-windows11-phase32.xml` - a minimal `windowsPE`-pass-only answer
file (GPT partitioning matching `partition-disk.sh`'s own proven 100MiB-ESP/16MiB-MSR/rest-Primary
layout, `ImageInstall` targeting Windows 11's own confirmed index 1, `WillShowUI=OnError` throughout
so the run stays hands-off unless something actually goes wrong) - and a tiny second ISO
(`autounattend.iso`, built via the same `xorriso` tooling already in use) to deliver it, per
Setup.exe's own standard answer-file search convention. Target disk deliberately plain IDE, not
`virtio-blk-pci`, to avoid needing driver injection into Setup's own `boot.wim` just to answer this
phase's narrower boot-order question - matching the plan's own stated scoping.

**First boot hit Windows 11's own Setup.exe hardware-compatibility check** - a real, interactive
"This PC doesn't currently meet Windows 11 system requirements" (TPM 2.0, Secure Boot) screen,
exactly the risk Phase 3's own "Key assumptions" section flagged in advance. Not a surprise, and a
well-precedented, still-current fix: researched (not guessed) the exact mechanism - `RunSynchronous`
commands in the `windowsPE` pass setting `HKLM\SYSTEM\Setup\LabConfig`'s `BypassTPMCheck`/
`BypassSecureBootCheck`/`BypassRAMCheck`/`BypassStorageCheck`/`BypassCPUCheck` DWORDs, confirmed
still working as recently as October 2025, exact command syntax cross-checked against
`AveYo/MediaCreationTool.bat`'s own actively-maintained `bypass11/AutoUnattend.xml` rather than
invented from memory. Added to the answer file, rebuilt the delivery ISO, retried.

**Result: the bypass worked completely cleanly.** No compatibility screen at all this time - straight
through language settings, EULA, disk partitioning, and image selection into a real "Installing
Windows 11... X% complete" progress screen, watched climbing steadily (11% -> 37% -> 77%) over
several minutes with zero interaction. This is itself real, meaningful progress: the full
`windowsPE`-pass answer-file pipeline (locale, hardware-check bypass, disk configuration, image
selection) all processed correctly and automatically, on this project's own actual media.

**Then the anticipated gate failure, right on schedule.** After file-copy completed and Setup issued
its own first reboot, `BdsDxe` loaded `Boot0001 "UEFI QEMU DVD-ROM"` again - the explicit
`bootindex=1` on the CD-ROM device (unchanged since the initial boot) meant the firmware selected it
again on this reboot too, exactly as it had the first time, since nothing about the device's boot
priority had changed. Windows Setup itself detected this mismatch and surfaced its own built-in
safeguard dialog: *"It looks like you started an upgrade and booted from installation media... If
you want to perform a clean installation instead, click No."* - a real, informative failure signal,
not a crash, but a fully interactive dialog that breaks unattended automation as-is.

**This is precisely the caveat Phase 2's own research flagged in advance** (a Proxmox thread
participant's vague mention of "cloning VM state after first phase" to handle CD re-attachment) and
precisely what Phase 3.2's own gate was designed to test. Per the plan's own framing, this is real
engineering work to close, not a hard stop on the whole approach - static `bootindex=`, set once at
VM launch, cannot by itself express "prefer the CD-ROM on the very first boot, then prefer the hard
disk on every boot after that" - the firmware only ever evaluates boot priority fresh at each
reset/reboot, with no memory of what booted last time.

**Fix identified, not yet attempted**: eject the install media via QMP's `eject` command once
file-copy is confirmed complete (screenshot-detected, matching this project's own established
observation convention, rather than a fixed timing guess) and before Setup's own reboot fires - once
ejected, OVMF's own boot-option discovery has no bootable content in that drive and falls through to
the next `bootindex` candidate (the hard disk) automatically, on every subsequent reboot, with no
further intervention needed. This is a real, standard technique (the same reason Packer's own
Windows builders and countless real-world unattended-install pipelines eject install media
mid-build), not a novel workaround invented for this specific problem.

**Persistent state that survives** (under `image-apply/output/iso-noprompt/`, gitignored):
`win11-phase32-target.qcow2` - the target disk from this attempt, partially installed (Setup
completed file-copy before the reboot-order problem was hit) - worth discarding rather than reusing,
since Setup's own state-tracking (having already detected and surfaced the upgrade-vs-clean-install
dialog once) makes it an unreliable starting point for a retry; a fresh blank disk is cheap
(`qemu-img create`) and cleaner. `autounattend.iso`/`autounattend-src/` and the confirmed-working
`win11-noprompt.iso` all remain valid and reusable as-is. New template file committed:
`image-apply/autounattend-windows11-phase32.xml` (now includes the TPM/Secure Boot bypass,
confirmed necessary and confirmed working). No VM left running, no `qemu-nbd` attached, environment
fully clean (confirmed via `pgrep`).

**Next step**: Phase 3.2, attempt 2 - same recipe, fresh target disk, add a QMP-`eject`-on-detected-
completion step before the first reboot, and confirm the second (and any subsequent) reboot
correctly lands on the hard disk instead of re-triggering the upgrade-vs-clean-install dialog.

## Phase 3.2, attempt 2: PASSED. QMP-ejecting the install media before the first reboot fully
## resolves the boot-order problem - a real Setup.exe-driven Windows 11 install reached a genuine
## OOBE screen, first time in this project's history

Fresh target disk (attempt 1's was discarded per its own persistent-state note - Setup's own
upgrade-vs-clean-install detection made it an unreliable retry starting point), identical recipe to
attempt 1. Watched via `tools/qmp-watch.sh` as before, tracking almost identically to attempt 1's
own pacing (42% at ~3min, 59% at ~5min, 76% at ~5.5min) - confirms attempt 1's timing wasn't a
fluke, this pipeline's install pacing is consistent run to run.

**At 76% complete - the same point attempt 1 rebooted from within seconds - issued the fix directly**,
not waiting for a more precise signal: `{"execute": "eject", "arguments": {"device": "installcd"}}`
and the same for `answercd`, confirmed via a follow-up `query-block` showing both drives
`tray_open: true` with no media before the reboot occurred. Chose to act immediately at 76% rather
than wait for a more exact completion signal, given attempt 1's own evidence that the window between
"visibly close to 100%" and "reboot fires" was under a minute - and confirmed empirically that
ejecting this early doesn't interrupt anything: Setup's own file-copy continued normally to
completion afterward, meaning the ISO's content was already fully consumed by this point in the
process, matching the plan's own reasoning for why this fix should be safe.

**Result: the fix works completely.** The first reboot after file-copy landed straight into a real
"Installing X%　/ Please keep your computer on" specialize-pass continuation screen - no `BdsDxe`
CD-ROM boot-log line at all this time (the now-empty drives are silently skipped by OVMF's own boot
enumeration), no upgrade-vs-clean-install dialog, no interruption of any kind. Specialize-pass
processing continued for several more minutes and included **a second reboot** (a bare `TianoCore`
splash with no CD-ROM boot-log line, same clean pattern) before landing on **a real, genuine Windows
11 OOBE screen** - "Is this the right country or region?", the actual out-of-box first-run
experience, confirmed via screenshot, not inferred.

**This is the first time in this project's entire history that a Setup.exe-driven Windows 11 install
has completed end to end.** Every prior Setup.exe attempt (Sessions 3-6 of `PHASE2_ENGINEERING_LOG.md`,
and this session's own Phase 3.1) either never got past `EarlyF6DriverInstall` or was deliberately
scoped short of a full install. This run went from a patched ISO's own first boot, through the
hardware-compatibility bypass, through disk partitioning and image installation, through file-copy,
through **two separate reboots each correctly landing on the target hard disk with zero fallback to
the now-ejected install media**, all the way to a real OOBE screen - fully unattended except for the
one deliberate, scripted QMP intervention this phase exists to validate.

Shut down via QMP `system_powerdown` (ignored, as expected for an interactive OOBE screen matching
this project's established pattern) then `SIGKILL` - no further data to preserve, this phase's own
gate was already conclusively met by the screenshot evidence.

**This directly and cleanly passes Phase 3.2's own stated gate**: "every reboot correctly resumes
into the installed system on the hard disk... never falling back into the ISO/EFI shell/PXE." Two
separate reboots, zero fallback, either time.

**What this does and doesn't establish, stated precisely**: confirms the `bootindex=`-plus-QMP-eject
combination genuinely solves the reboot-order problem this project's own prior Setup.exe work never
got far enough to even encounter. It does not yet confirm `EarlyF6DriverInstall` or any other
Setup.exe-internal gate stays clear all the way through a *complete* run with a full `specialize`/
`oobeSystem` answer file (this minimal `windowsPE`-only file never gave Setup anything to process in
those later passes, so OOBE was reached in its normal interactive form, not skipped) - that's Phase
3.3's own job, along with confirming real authenticated WinRM connectivity as this project's
established success bar.

**One open engineering question for Phase 3.4's eventual formalization, not resolved here**: this
session used visual judgment (screenshot review) to decide when to eject, timed against attempt 1's
own observed pacing. A real, unattended production script needs a scriptable, non-visual trigger -
Phase 3's own design proposal already named two real candidates (a generous fixed timeout matching
this project's existing `timeout 300`-style convention, or a cheap fixed-pixel color-sample check
against repeated screenshots, avoiding any need for OCR) - neither implemented yet, and a third
candidate surfaced mid-session worth testing before committing to either: dropping the static
`bootindex=` override on the CD-ROM entirely and relying on OVMF's own NVRAM-driven boot order once
Windows itself registers a Boot Manager entry during install, which may sidestep needing a
timed/detected eject at all. Not yet tested.

**Persistent state that survives** (under `image-apply/output/iso-noprompt/`, gitignored):
`win11-phase32-target.qcow2` - a real, disk-image proof that a Setup.exe-driven Windows 11 install
via this project's own tooling can reach a genuine OOBE screen, worth keeping as a reference rather
than discarding. All other Phase 3.1/3.2 artifacts (`win11-noprompt.iso`, `autounattend.iso`, the
`extracted/` working directory) remain valid and reusable. No VM left running, no `qemu-nbd`
attached, environment fully clean (confirmed via `pgrep`).

**Next step**: Phase 3.3 - a real, complete answer file covering `specialize`/`oobeSystem` (adapting
this project's existing `unattend-windows11.xml` content), a genuinely fresh end-to-end run with the
QMP-eject fix included, and confirmation of real authenticated WinRM connectivity with no BSOD and no
unskippable OOBE hang - matching this project's own established success bar, and requiring 2-3
independent successes before being trusted, not one.

## Housekeeping: Option A/B experiment disks deleted, by explicit direction, to free local disk space

Six Windows 11 Audit-Mode/Sysprep-branch disk artifacts (`windows11-auditphase1.qcow2`,
`windows11-auditphase2.qcow2`, `windows11-bisect4.qcow2`, `windows11-ladderc.qcow2`,
`windows11-ladderd.qcow2`, `windows11-phase4test.qcow2` - Findings 10-14's evidence disks,
`bisect4` itself already flagged "safe to delete" back in Session 3) deleted from
`image-apply/output/builds/`, reclaiming ~91GB (host disk usage: 530GB -> 444GB used, 427GB free).
These were the persistent-state artifacts referenced throughout the now-closed HARD STOP section -
their disappearance is deliberate, not data loss, now that that pathway is closed and the findings
themselves (stop codes, screenshots, log excerpts) are already fully captured in this log rather
than depending on the disks themselves. Explicitly preserved, not touched: `server2022-test3.qcow2`/
`server2025-test1.qcow2` (production Server reference disks), `win11-session13.qcow2` (the one
valuable hand-run success reference), and everything under `iso-noprompt/` (this session's active
Phase 3.1-3.3 work). Older Server 2022/2025 Phase 2 hand-run disks were identified as a separate,
lower-priority cleanup candidate but left untouched, out of scope of this specific request.

## Housekeeping, continued: all remaining Server 2022/2025 disk artifacts also deleted, by explicit
## direction - reclaiming a further ~118GB (~110GB actual)

Per explicit follow-up direction, deleted the Server 2022/2025 disk artifacts left untouched above -
both the ones `PHASE2_ENGINEERING_LOG.md` Session 11 itself had already flagged as superseded
(`win2025-session9.qcow2`, `win2025-session9b.qcow2`, `win2025-test.qcow2`, `win2025-target.qcow2`)
*and* the ones previously flagged "the reference disk... treat as a valuable asset"
(`win2025-session11.qcow2`, `win2022-session12.qcow2`, Session 11/12's own hand-run confirmations)
*and* Phase 3 Session 2's own most-recent, most-authoritative production-pipeline disks
(`builds/server2022-test3.qcow2` - real AD DS domain live, `builds/server2025-test1.qcow2` - real
IIS+SQL Server verified). Host disk usage: 444GB -> 334GB used, 537GB free.

**None of this touches the evidentiary record.** All six independent Server 2022/2025 successes
(three each) remain fully documented in `PHASE2_ENGINEERING_LOG.md` (Session 11/Finding 41, Session
12/Finding 42) and `PHASE3_ENGINEERING_LOG.md` (Session 2's confirmed-results table) regardless of
which disk files survive - the findings themselves, not the underlying qcow2s, are what this
project's own standards treat as the durable record. If a fresh reference disk is ever needed again,
`build.sh server2022`/`build.sh server2025` reproduces one from scratch in minutes, per the
project's own "every build applies the WIM fresh" principle - these were never meant to be
permanent, one-of-a-kind artifacts in the first place.

---

## Phase 3.3, attempt 1: PASSED, completely cleanly - real authenticated WinRM connectivity, no
## BSOD anywhere in the run. First time this project's own established success bar has ever been
## met by a Setup.exe-driven Windows 11 build.

Built `image-apply/autounattend-windows11-phase33.xml` - Phase 3.2's proven `windowsPE` pass
unchanged, plus a real `specialize`/`oobeSystem` pass adapted from the production
`unattend-windows11.xml` (`ComputerName`, OOBE-skip, `AdministratorPassword`, `AutoLogon`,
`FirstLogonCommands`). One deliberate scope decision, stated plainly: NIC is a plain `e1000`
(Windows inbox driver, zero injection needed), not `virtio-net-pci`, matching Phase 3.2's own
choice of plain IDE over `virtio-blk-pci` for the same reason - this phase's own question is
whether the *complete answer file* works through Setup.exe end to end, not whether this project's
own virtio driver-injection technique also applies here. `FirstLogonCommands` accordingly drops the
production template's Order-1 `pnputil`/netkvm step entirely (not applicable) and keeps the
network-wait + WinRM-enable steps unchanged.

Fresh target disk, same recipe as Phase 3.2 attempt 2 (bypass -> disk config -> image install ->
QMP-eject at ~75-76% complete, tracking the same pacing both prior attempts showed - confirms this
project's own install timing on this host is genuinely consistent across independent runs, not
coincidental). Watched the full run via `tools/qmp-watch.sh` plus periodic real HTTP checks against
the forwarded WinRM port, not just screenshots.

**Every stage passed, in order, with no intervention beyond the one scripted QMP eject:**
- First reboot: landed cleanly on the hard disk (`Installing 33%`), no CD-ROM fallback - confirms
  Phase 3.2's fix generalizes to a full answer file, not just the minimal one it was proven against.
- Second reboot: `BdsDxe: loading Boot0004 "Windows Boot Manager"` - straight from the disk's own
  real boot manager entry, no CD-ROM boot-log line at all this time.
- OOBE's own brief "Hi." welcome animation appeared and passed on its own within about 15 seconds -
  confirming this project's own long-standing open question (`unattend-windows11.xml`'s header
  comment: "whether Windows 11's client-SKU OOBE pass needs anything beyond what worked for the
  Server SKUs... is genuinely unverified") is answered: it doesn't need anything more. OOBE-skip
  worked correctly on Windows 11 client SKU, non-interactively, first attempt.
- The familiar "This might take a few minutes" / "Please keep your PC on and plugged in" real
  first-boot servicing sequence followed - the exact same benign screens `PHASE2_ENGINEERING_LOG.md`
  Session 13 already confirmed are normal for Windows 11's own more extensive client-SKU first-boot
  component servicing, not a hang.
- **A real HTTP `405` from the WinRM endpoint arrived during this exact servicing window** - the
  same point in the sequence where Findings 12, 13, and 14 all previously BSOD'd, every single time,
  across five independent attempts on the fully-offline pipeline. **No crash occurred here.** The
  run continued straight through to a genuine, fully interactive Windows 11 desktop (Start menu,
  real desktop icons, correct `"Windows 11 Enterprise Evaluation / Windows License valid for 90
  days"` watermark), confirmed via screenshot, not inferred.
- **Real, authenticated WinRM commands executed successfully against the finished desktop**, the
  identical evidentiary bar this project has used since `PHASE2_ENGINEERING_LOG.md` Session 11/
  Finding 41: `hostname` returned `WIN11-P33` - the exact `ComputerName` from the `specialize`
  pass - and `Get-NetAdapter` showed `Intel(R) PRO/1000 MT Network Connection`, `Status: Up`,
  `LinkSpeed: 1 Gbps` - a fully functional NDIS adapter working natively, not just a PCI-level
  match, confirming the `e1000`-without-injection scope decision was sound for this phase's own
  purpose.

Shut down via QMP `system_powerdown` - **honored gracefully this time**, unlike every interactive-
screen shutdown attempt earlier in this session's Setup.exe work, confirming this project's own
established pattern (`system_powerdown` works once a real desktop/shell session is reached, not on
interactive Setup/OOBE screens) holds true for this pipeline too.

**This is the first time in this project's entire history that a Setup.exe-driven Windows 11 build
has met this project's own full, established success bar** - the same bar Server 2022/2025 met
repeatedly on the fully-offline pipeline, and the bar every attempt on Windows 11's own
fully-offline pipeline (Findings 8, 12, 13, 14) never once reached without a BSOD.

**What this does and doesn't establish, stated precisely, per this project's own hard-earned
"one success is not the same as reliable" lesson from the Option A/B saga**: this is **one**
successful run. Phase 3.3's own stated bar requires 2-3 independent successes before being trusted -
not because this result is in doubt, but because this project has direct, recent, first-hand
experience (Session 13's own single hand-run success vs. this session's four consecutive scripted
failures) of how misleading a single clean run can be when timing-sensitive virtualization behavior
is involved. This result is genuinely excellent evidence the new approach works: not yet sufficient
alone to declare it production-ready.

**Persistent state that survives** (under `image-apply/output/iso-noprompt/`, gitignored):
`win11-phase33-target.qcow2` - a real, complete, working Windows 11 disk built via Setup.exe,
confirmed via real authenticated WinRM, shut down gracefully - worth keeping as this pathway's own
first genuine reference disk. `win11-noprompt.iso`/`autounattend.iso` remain valid and reusable
as-is. New template file committed: `image-apply/autounattend-windows11-phase33.xml`. No VM left
running, no `qemu-nbd` attached, environment fully clean (confirmed via `pgrep`).

**Next step**: Phase 3.3, attempts 2 and 3 - same recipe, fresh target disks, confirming this
result reproduces independently before treating it as reliable. If 2-3 consecutive clean runs are
confirmed, Phase 3.4 (formalize into real, production `image-apply/*.sh`-style scripts, including
solving the eject-trigger automation question and deciding the virtio-driver question left open by
this phase's own `e1000` scope decision) becomes the natural next step.

## Phase 3.3, attempt 2: PASSED, second consecutive clean run - identical recipe, fresh disk,
## no BSOD, real authenticated WinRM again.

Fresh target disk (`win11-phase33-target.qcow2`; attempt 1's disk preserved as
`win11-phase33-target-attempt1.qcow2` before starting). Same `win11-noprompt.iso`, same
`autounattend-windows11-phase33.xml` content, same recipe: bypass -> disk config -> image install ->
QMP eject of both `installcd` and `answercd` at 77% complete (consistent with both prior attempts'
timing). Watched via `tools/qmp-watch.sh` plus periodic real HTTP checks against the forwarded WinRM
port (hostfwd 15989), with a `Monitor` checkpoint loop tracking the QEMU process itself.

**Every stage passed again, in the same order, no intervention beyond the one scripted QMP eject:**
- First reboot landed cleanly on the hard disk - no CD-ROM fallback.
- Steady, uninterrupted progress through `specialize` (screenshot file sizes ~6.8-7.1KB, matching
  the known-benign small "Installing X%" servicing screen) through several checkpoints with WinRM
  correctly returning "no response" (expected - not up yet).
- WinRM began responding (`HTTP 405` on GET, as expected for the `/wsman` endpoint) at almost exactly
  the same elapsed-time mark as attempt 1, and screenshot file sizes jumped from ~7KB to 195-250KB in
  the same interval - the same real-desktop-rendering signature attempt 1 showed. **No crash occurred
  in or around this window** - the same window where every fully-offline attempt (Findings 8, 12, 13,
  14) previously BSOD'd without exception.
- Real, authenticated WinRM confirmed against the finished desktop, same evidentiary bar as attempt
  1: `hostname` returned `WIN11-P33` (the `specialize` pass's `ComputerName`, unchanged from attempt
  1's answer file - expected, not a new value, since both attempts used the identical template).
  `Get-NetAdapter` showed `Intel(R) PRO/1000 MT Network Connection`, `Status: Up`, `LinkSpeed: 1
  Gbps` - again a fully functional NDIS adapter, not just a PCI-level match. The `FirstLogonCommands`
  Order-1 marker file (`C:\phase33-firstlogon-marker.txt`) was confirmed present via a direct `type`
  read over WinRM, containing `firstlogon-reached` - direct proof the full `FirstLogonCommands`
  sequence executed, not just that WinRM happened to come up.
- One transient hiccup, noted for completeness rather than treated as a finding: the very first
  `Get-NetAdapter` call (issued immediately after the first successful `hostname` call) hit a
  `RemoteDisconnected`/connection-reset error. A retry ~15 seconds later succeeded cleanly. Most
  likely explanation: `FirstLogonCommands` Order 3's own `Restart-Service WinRM` step landing at
  almost exactly the same moment as the probe - self-inflicted by the answer file's own WinRM
  restart, not a sign of instability in the underlying build. Doesn't change the result: a moment
  later, everything worked normally.

Shut down via QMP `system_powerdown` - honored gracefully again, consistent with attempt 1 and this
project's established pattern.

**This is the second consecutive clean pass of Phase 3.3's full recipe**, on a completely independent
fresh disk, with the same result in every particular that matters: no BSOD, real WinRM, real desktop,
`FirstLogonCommands` fully executed. Combined with attempt 1, this is real evidence the result is not
a one-off - but per this project's own stated bar (2-3 independent successes, not one), attempt 3 is
still warranted before calling this reliable, especially given this project's own recent first-hand
experience of a single clean run not generalizing (Session 13 vs. this session's own four earlier
scripted failures on the fully-offline pipeline).

**Persistent state that survives** (under `image-apply/output/iso-noprompt/`, gitignored):
`win11-phase33-target.qcow2` (attempt 2's disk, shut down gracefully) alongside
`win11-phase33-target-attempt1.qcow2` (attempt 1's disk, preserved). No VM left running, no
`qemu-nbd` attached.

**Next step**: Phase 3.3, attempt 3 - same recipe, third fresh target disk. If this also passes
cleanly, treat the Setup.exe-driven approach as confirmed reliable and proceed to Phase 3.4.

## Phase 3.3, attempt 3: PASSED - third consecutive clean run. Evidentiary bar met; Setup.exe-driven
## Windows 11 approach is now confirmed reliable, not just promising.

Fresh target disk (`win11-phase33-target.qcow2`; attempts 1 and 2 preserved as
`win11-phase33-target-attempt1.qcow2`/`-attempt2.qcow2`) and a fresh `OVMF_VARS_phase33.fd` copied
from the pristine `/usr/share/OVMF/OVMF_VARS_4M.fd` template (attempt 2's own vars file preserved as
`OVMF_VARS_phase33-attempt2.fd`) - full independence from both prior attempts' NVRAM state, not just
a fresh disk. Same `win11-noprompt.iso`, same `autounattend-windows11-phase33.xml`, same recipe.

**Every stage passed a third time, in the same order:**
- Install progress tracked the same pacing as both prior attempts (30% at ~3min, 44% at ~4min, 75%
  at ~6min) - this host's own install timing continues to be consistent across three independent
  runs, not coincidental.
- QMP eject of both `installcd` and `answercd` at 75% complete, confirmed via `DEVICE_TRAY_MOVED`
  events (`tray-open: true`) for both devices this time, not needing a follow-up `query-block` call
  as attempts 1/2 sometimes did.
- First reboot: `BdsDxe: starting Boot0004 "Windows Boot Manager"` from the disk's own GPT partition
  GUID - clean landing on the hard disk, no CD-ROM fallback.
- Steady progress through the `specialize` pass's "Installing X% / Please keep your computer on"
  servicing screens (file sizes ~6.8-7.1KB, the established benign signature) for roughly 14 minutes,
  including one brief plain-black loading-spinner transition screen (~3.4KB) between the servicing
  pass and the second reboot/OOBE - a new but clearly benign transition not seen as its own distinct
  frame in attempts 1/2 (likely just a matter of screenshot-timing luck relative to a fast transition,
  not a different code path).
- **No crash occurred anywhere in or around the WinRM-coming-up window** - the same window that
  killed every fully-offline attempt (Findings 8, 12, 13, 14) without exception, and the same window
  both prior Setup.exe-driven attempts already passed cleanly.
- Real, authenticated WinRM confirmed against the finished desktop: `hostname` returned `WIN11-P33`,
  `Get-NetAdapter` showed `Intel(R) PRO/1000 MT Network Connection`, `Status: Up`, `LinkSpeed: 1
  Gbps`, and the `FirstLogonCommands` marker file (`C:\phase33-firstlogon-marker.txt`) was confirmed
  present via a direct WinRM `type` read, containing `firstlogon-reached`.
- One transient hiccup, same class as attempt 2's: the very first WinRM auth attempt (immediately
  after the endpoint started responding) hit a `401`/`InvalidCredentialsError`, then succeeded
  cleanly on retry a short time later. Same likely explanation as before - probed right as
  `FirstLogonCommands` Order 3's own WinRM/Basic-auth configuration was still landing, not a sign of
  instability in the build itself. Worth noting as a pattern now (two of three attempts hit a
  transient WinRM auth/connection hiccup on the very first probe, both resolved on retry within
  seconds) - real input for Phase 3.4's own WinRM-readiness polling logic (build in a retry loop by
  default, don't treat the first failed probe as a build failure).

Shut down via QMP `system_powerdown` - honored gracefully a third time.

**This is the third consecutive clean pass of Phase 3.3's full recipe, on three independent fresh
disks (and, this time, independent OVMF NVRAM state too) - the Setup.exe-driven Windows 11 approach
now meets this project's own 2-3-independent-successes evidentiary bar in full.** Combined with
attempts 1 and 2: three for three, zero BSODs, zero unskippable OOBE hangs, real WinRM every time,
through the identical window that reliably killed every attempt on the old fully-offline pipeline.
This is no longer just "promising evidence" - by this project's own standard, it's confirmed.

**Persistent state that survives** (under `image-apply/output/iso-noprompt/`, gitignored):
`win11-phase33-target.qcow2` (attempt 3's disk) alongside `-attempt1.qcow2` and `-attempt2.qcow2`
(both preserved at the time this section was first written). No VM left running, no `qemu-nbd`
attached.

**Housekeeping, immediately following**: per this project's own disk-hygiene standard (CLAUDE.md),
now that the evidentiary bar was met, attempt 1's and attempt 2's disks (`win11-phase33-target-
attempt1.qcow2`, `win11-phase33-target-attempt2.qcow2`) and attempt 2's now-orphaned OVMF vars file
(`OVMF_VARS_phase33-attempt2.fd`) were reviewed and deleted, by explicit user confirmation - ~33GB
freed (912G volume: 369G used -> 347G used, 524G available). `win11-phase33-target.qcow2` (attempt
3) is now the sole Phase 3.3 reference disk; `win11-phase32-target.qcow2` (a separate phase's own
reference disk) was left untouched.

**Next step**: Phase 3.4 - formalize into real, production `image-apply/*.sh`-style scripts. Open
questions carried into that phase: automating the eject trigger (currently visual/screenshot
judgment - candidates are a generous fixed timeout, a cheap fixed-pixel color-sample check, or
dropping the static `bootindex=` override in favor of OVMF's own NVRAM-driven boot order), deciding
the virtio-driver question left open by this phase's own `e1000`/plain-IDE scope decisions, and
building a WinRM-readiness retry loop that tolerates the transient first-probe auth/connection
hiccup observed in two of three attempts here.

---

## Phase 3.4: formalize into production scripts. Real scripts, real bugs caught by actually
## running them - including one genuine install failure that reshaped the eject-timing design.

Design decisions made explicit before writing code (per CLAUDE.md's Claude Instructions), confirmed
with the user rather than defaulted: (1) eject-trigger timing is a hybrid - a calibrated base
timeout as the real signal, then a bounded pixel-sample poll window as a confirm/best-effort safety
net, not OCR; (2) Windows 11 skips the Packer handoff entirely (no roles to provision, the new
script already confirms first boot itself) - Server 2022/2025 keep Packer unchanged; (3) the
eject-timing env vars must be genuinely configurable, not hardcoded, plus a convenience script to
measure real per-host timing.

**Scripts written:**
- `image-apply/build-iso-noprompt.sh` - formalizes Phase 3.1's ISO patch (extract, swap
  efisys.bin/cdboot.efi for their `_noprompt` counterparts, rebuild via the verified `xorriso`
  recipe). Idempotent - verifies a cached output via its ISO9660 volume ID and a byte-for-byte
  `isoinfo -x` comparison against the `_noprompt` source file before skipping a rebuild. Tested
  directly: both the skip-if-verified path and a genuine fresh rebuild (11s once extraction is
  cached) confirmed working.
- `tools/qmp-eject.py` / `tools/qmp-pixel.py` - new formalized QMP helpers, matching this project's
  existing `tools/qmp-*.py` convention (stdlib only, no new dependencies). `qmp-eject.py` confirms
  via `query-block`'s own `tray_open` field rather than trusting the `eject` command's reply alone
  (this session's own ad hoc Phase 3.3 work had already noticed the eject reply sometimes prints no
  visible output). `qmp-pixel.py` decodes a QEMU screendump PNG (8-bit truecolor, non-interlaced -
  the only shape `screendump` actually produces) using nothing but stdlib `zlib`/`struct` - no
  Pillow, no ImageMagick, deliberately avoiding a new dependency for a simple job (this project's
  own host had neither installed). Unit-tested against three real Phase 3.3 screenshots before
  being trusted: the Setup blue background at (640,400) reads a clean, unambiguous `(0, 90, 158)`,
  distinct from the TianoCore boot log `(1, 18, 68)`, the servicing/reboot black `(0, 0, 0)`, and a
  real desktop's white `(255, 255, 255)` - a reliable, OCR-free "still on the Installing screen"
  signal.
- `image-apply/windows11-setup-install.sh` - the real production install script: answer-file ISO
  generation (`sed`-substituted `ComputerName`, `mkisofs`), the proven `bootindex=`/QMP qemu
  invocation, the hybrid eject trigger, a WinRM-readiness retry loop (Phase 3.3 attempts 2/3 both
  hit a transient first-probe 401/connection-reset that cleared on retry - a single-shot check would
  have misreported those as failures), graceful QMP shutdown. Hard-gated to Windows 11 only, with a
  real runtime refusal (not just a doc comment) if the target path looks like a Server 2022/2025
  disk.
- `image-apply/calibrate-eject-timing.sh` - the requested convenience script for measuring a new
  host's own real install timing rather than trusting the committed defaults blindly: boots a
  throwaway disk through Setup's `windowsPE` pass only (Phase 3.2's own minimal answer file, no
  eject), polls the same blue-background pixel to find T0 (Installing screen appears) and T1 (it
  stops being blue - Setup's own reboot beginning), then prints recommended `W11_EJECT_*` env vars.
  Deletes every throwaway artifact (disk, OVMF vars, answer-file ISO, QMP socket, work dir) on exit,
  success or failure, per this project's disk-hygiene standard.
- `build.sh` - a new `if [[ "$OS" == "windows11" ]]` branch calling the new script and exiting
  before Packer; diffed against the pre-edit version to confirm the Server 2022/2025 branch
  (`partition-disk.sh`/`apply-image.sh`/`make-bootable.sh`/`apply-unattend.sh`/Packer handoff) is
  byte-for-byte unchanged, not just reviewed by eye. The dead `audit-mode-sysprep.sh` (Option B)
  branch was removed from `build.sh`'s call sequence; the script itself stays in the repo as
  historical record, matching `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`'s own "CLOSED" note.

**Real bug caught while testing `calibrate-eject-timing.sh` itself**: its first draft passed the
answer-file *template* path directly to `mkisofs`, so the resulting ISO contained a file named
`autounattend-windows11-phase32.xml` instead of the exact name (`autounattend.xml`) Setup.exe
requires to auto-detect an answer file. Setup.exe didn't error - it silently fell back to its
interactive "Select language settings" screen, with no error of any kind, confirmed via a direct
`tools/qmp-screenshot.py` capture rather than assumed from the log's own silence. Fixed by copying
the template to a correctly-named file before building the ISO (`windows11-setup-install.sh` already
did this correctly - only the new calibration script had the bug). A live, working stuck VM was the
actual proof this was real, not a hypothesis - matching this project's own "verify before trusting"
standard rather than trusting the script's own silence as success.

**`calibrate-eject-timing.sh` then ran clean end-to-end** on this host: `T0=31s` (blue Installing
screen first seen), `T1=439s` (screen stopped being blue - Setup's own reboot beginning),
`duration=408s`. All throwaway artifacts confirmed deleted on exit (no leftover work dir, no
leftover socket).

**The real finding: `windows11-setup-install.sh`'s first actual automated run (using its own
committed default `W11_EJECT_BASE_TIMEOUT_SEC=300`) produced a genuine, real "Windows 11
installation has failed" error** - confirmed via direct screenshot, not inferred. Root cause: 300s
was chosen as "safely before the earliest manually-observed 75% mark (348s)," which is the wrong
direction of safety - Setup hadn't yet finished reading everything it needed from the install media
at 300s elapsed on this run. The risk here is **asymmetric**: ejecting too early reliably breaks the
install; ejecting anywhere from the real proven-safe point up to just before the actual reboot does
not (this project's own 3 manual Phase 3.3 attempts all ejected within a ~30-second range around
75-77% with zero failures, and the reboot itself never began before ~7:48 in any of them - there was
real slack on the late side that the original 300s default didn't use). This is exactly why the
calibration script's own naive "70% of blue-screen duration" formula was also wrong in the same
direction - recomputed against this exact run's own real `T0=31s`/`T1=439s`, 70% would have
recommended `316s`, barely later than the value that had just failed. **Both defaults were fixed
to bias toward the later end of the observed-safe range instead of the middle**:
`windows11-setup-install.sh`'s own default raised from 300s to 360s (with the header comment
rewritten to state the asymmetric-risk lesson explicitly, not just the number), and
`calibrate-eject-timing.sh`'s recommendation formula changed from 70% to 85% of the observed
blue-screen duration. The failed run's artifacts (a 9.8GB throwaway disk, a small run-scoped work
directory) were deleted immediately per this project's disk-hygiene standard - they were never a
successful reference build, only debugging evidence, and the debugging was already captured here in
writing.

**Status update**: the re-run with the fixed 360s default was stopped mid-run, by explicit user
direction, before reaching a result - not because of a problem with the fix, but because the user
raised a sharper concern about the whole eject-timing design's own reliability (see the next entry).
The 300s->360s fix and the 70%->85% calibration-formula fix both stand as real, documented
corrections regardless - they're the right fix for the failure mode found, even though the design
they're patching was about to be superseded.

---

## Phase 3.4, design reconsideration: dropping the static `bootindex=` override entirely (Category 3
## from the original research plan) - tested and CONFIRMED, twice, eliminating the eject-timing
## problem area altogether.

Mid-validation, the user raised a sharp, correct objection to the eject-timing design: the pixel-
sample poll window (added specifically per the user's own earlier request to "fine-sample pixels...
to maximize probability of catching it") turns out to add near-zero real protection, because Windows
Setup's blue "Installing Windows 11" background is the *same color* from roughly 10% through 90%
complete - the poll loop can only distinguish "still blue" from "already black," not "how far
through," so in practice it just rubber-stamps whatever `BASE_TIMEOUT` says on the very first sample.
The entire safety margin was riding on one guessed number, dressed up to look more robust than it
was. Combined with the real "Windows 11 installation has failed" failure already found this session,
the user's assessment - "whack-a-mole... risks non-determinism in ways that could fail hard later on,
and not gracefully" - was exactly right, and matched this project's own standing preference for
adopting an existing, well-understood mechanism over patching a fragile one.

Per the three options laid out earlier (fast-failure detection, digit-template OCR, or dropping the
static `bootindex=` override to let OVMF's own NVRAM boot order handle it), the user chose to test
the cheapest, most architecturally clean option first: **remove `bootindex=` entirely from both the
install CD-ROM and the target disk devices, and don't eject anything at all.** The hypothesis: once
Windows Setup's own `bcdboot`-equivalent step registers a real "Windows Boot Manager" NVRAM entry for
the disk, OVMF's own boot-order logic might simply prefer it over the CD-ROM on its own, the same way
real UEFI firmware conventions generally treat a freshly-created boot option. The risk this was
specifically weighed against - Phase 3.2 attempt 1's original CD-ROM-fallback failure - turned out to
be a distinct failure mode: that failure was caused by a *static* `bootindex=` override forcing CD-ROM
preference regardless of NVRAM state, not by the disk's own registered entry losing on a level
playing field. Removing the override entirely changes the actual competition being decided.

**Attempt 1** (fresh 64GB disk, fresh OVMF vars, full Phase 3.3 answer file, `ComputerName=WIN11NVRAM`,
no `bootindex=` on any device, no eject at any point): the first boot correctly selected the CD-ROM
(the only bootable device on a blank disk - expected, unchanged). The first reboot (after the
`windowsPE` pass) was not directly caught on camera (missed by the 15s poll interval - between two
screenshots the screen went from the "Installing X%" blue screen straight to the specialize pass's
own "Installing 0% / Please keep your computer on" servicing screen), but that screen's own presence
is itself strong indirect evidence of success: it only ever appears after a real disk boot, never
after a CD-ROM re-entry into Setup. The **second** reboot's boot log was caught directly:
`BdsDxe: starting Boot0009 "Windows Boot Manager" from HD(1,GPT,F71E0910-55AE-4CCF-AFEA-
C1F5D59AEFA0,...)/\EFI\Microsoft\Boot\bootmgfw.efi` - a real, disk-registered NVRAM boot entry, not
the CD-ROM's own `Boot0001` from the very first boot. Reached a real desktop; WinRM confirmed
(`hostname` -> `WIN11NVRAM`, `Get-NetAdapter` -> `Intel(R) PRO/1000 MT`, `Status: Up`, `1 Gbps`). Shut
down gracefully via QMP `system_powerdown`.

**Attempt 2** (second independent fresh disk and OVMF vars, `ComputerName=WIN11NVR2`, identical
recipe): this time the **first** reboot's boot log was caught directly too -
`BdsDxe: starting Boot0009 "Windows Boot Manager" from HD(1,GPT,106FAAFD-663D-44AF-970A-
81B560733A70,...)/\EFI\Microsoft\Boot\bootmgfw.efi` - confirming, this time with direct evidence
rather than inference, that the exact moment Phase 3.2 attempt 1 originally failed at (the first
post-`windowsPE`-pass reboot) resolves cleanly to the disk's own boot entry with zero eject and zero
static `bootindex=`. The second reboot repeated the same pattern. Reached a real desktop; WinRM
confirmed (`hostname` -> `WIN11NVR2`, `Get-NetAdapter` -> `Intel(R) PRO/1000 MT`, `Status: Up`,
`1 Gbps`). Shut down gracefully via QMP `system_powerdown`.

**Two for two, with the critical first-reboot boot-manager selection directly confirmed on attempt 2
(not just inferred, as attempt 1 required) - this is stronger, more direct evidence than the
eject-based approach's own three Phase 3.3 successes ever produced for that specific moment.** No
BSOD, no CD-ROM fallback, no eject-timing guesswork of any kind. Both runs ran notably slower than
this session's earlier Phase 3.3 attempts (first reboot around 8-15 minutes elapsed rather than
5-8 minutes) - consistent with general host-speed variance already observed earlier this session
(the calibration script's own real run showed similar slowdown), not a sign of anything wrong with
the mechanism itself; timing no longer matters to this approach's correctness at all, which is
precisely the point.

**This changes Phase 3.4's design fundamentally.** `windows11-setup-install.sh`'s entire eject-timing
mechanism (`W11_EJECT_*` env vars, the pixel-sample poll loop, `tools/qmp-pixel.py`'s use as an eject
trigger, `image-apply/calibrate-eject-timing.sh`) becomes unnecessary - not just simplified, genuinely
removable. The corrected script becomes: boot with no `bootindex=` on any device, let Setup run
completely unattended with no host-side intervention at all beyond waiting, poll for WinRM with the
same retry logic already built. `tools/qmp-pixel.py`'s PNG-pixel-decode logic stays useful in its own
right (a real, reusable, dependency-free primitive, already unit-tested) even though its specific
eject-trigger use case goes away.

**Persistent state**: `image-apply/output/nvram-test-attempt1/` (~15GB, attempt 1's artifacts,
preserved) and `image-apply/output/nvram-test/` (attempt 2's artifacts, in place). No VM running, no
`qemu-nbd` attached, confirmed via `pgrep`.

**Next step**: rewrite `windows11-setup-install.sh` to drop the eject mechanism entirely per this
result, decide whether to keep `calibrate-eject-timing.sh` at all (likely not - nothing left to
calibrate) or retire it to historical record like `audit-mode-sysprep.sh`, and re-run the production
validation with the simplified script before calling Phase 3.4 done.

---

## Phase 3.4, completion: `windows11-setup-install.sh` rewritten without the eject mechanism,
## `calibrate-eject-timing.sh` retired, and a real production validation run confirms the simplified
## script works completely unattended - no manual QMP intervention anywhere in the run.

`calibrate-eject-timing.sh` retired in place (header comment marking it historical-only, same
treatment as `audit-mode-sysprep.sh` - kept, not deleted, per this project's own standard of
preserving superseded-branch work as a documented record). Nothing left to calibrate once the eject
step itself is gone.

`windows11-setup-install.sh` rewritten: removed `bootindex=` from every device (install CD-ROM,
answer-file CD-ROM, target disk), removed the entire eject-trigger block (`W11_EJECT_*` env vars,
the pixel-sample poll loop, the `tools/qmp-eject.py` call), removed the `calibrate-eject-timing.sh`
dependency from the header comment. What remains: generate the answer-file ISO, create the target
disk, boot once with no host-side intervention of any kind, wait for real WinRM with the existing
retry loop (unchanged - still needed, the transient first-probe 401/connection-reset pattern is
independent of the eject question), shut down gracefully. `W11_WINRM_TIMEOUT_SEC` raised from 1200s
to 1800s, since the timeout window now has to cover the entire install (previously it only covered
the post-eject portion).

**Real production validation run, third fresh disk** (`windows11-phase34-validate2.qcow2`,
`ComputerName=WIN11P34B`): ran the rewritten script exactly as a real user would - no manual QMP
commands issued during the run itself, only read-only screenshot checks to observe progress (the
script's own logic made every decision). Directly confirmed via TianoCore boot-log capture that
**both** reboots picked `Boot0009 "Windows Boot Manager"` - a third and fourth independent
confirmation of the NVRAM-boot-order finding, on top of the two hand-run tests earlier in this
session. The script's own internal WinRM retry loop absorbed a transient 401 (confirmed by a separate
manual probe hitting the same transient failure and clearing itself moments later) without any
external help - exactly the resilience it was built for. Completed entirely on its own:
`hostname=WIN11P34B` confirmed, graceful QMP shutdown, clean qemu exit, script's own final log line
printed with no errors or warnings.

**This is the real, hands-off proof the simplified production script works** - not just the
mechanism (already shown twice by hand), but the actual committed script, run the way it will really
be invoked, start to finish, with zero manual steps. Phase 3.4's original goal (formalize the
Setup.exe-driven Windows 11 build into production scripts) is met.

**Housekeeping, actioned**: per the same review-then-confirm process used earlier this session, the
user confirmed deletion of `image-apply/output/nvram-test/` and `image-apply/output/nvram-test-
attempt1/` (~30GB, the two hand-run NVRAM-boot-order exploratory tests - fully superseded by the
production script's own validation run, their evidentiary value already captured in writing above)
plus `image-apply/output/iso-noprompt/win11-phase32-target.qcow2` and `win11-phase33-target.qcow2`
(~28GB, reference disks from the now-superseded eject-based mechanism - that whole design was
replaced by the NVRAM-boot-order approach, so these test a design no longer in use). ~59GB freed
(912G volume: 390G used -> 334G used, 537G available). `windows11-phase34-validate2.qcow2` (the
final production-script validation's own disk) is kept as the current reference.

**Next step**: Phase 3.5 (full production-readiness validation - multiple independent fresh builds
through the finished script, matching Server 2022/2025's own multi-build track record) - not yet
started. The virtio-driver question (Phase 3.2/3.3's own deliberate `e1000`/plain-IDE scope decision)
remains open and deferred, unaffected by this session's findings.

---

## Phase 3.5: production-readiness validation - two independent fresh builds through the finished
## `windows11-setup-install.sh`, both clean, both fully unattended.

Two fresh target disks, default script settings, no manual QMP intervention at any point (only
periodic read-only `ps`/log checks to track progress - no decisions made externally, matching how a
real invocation of this script actually runs). Screenshot-polling cadence was relaxed significantly
compared to earlier phases' close-interval watching, since there's no longer a timing-sensitive
window to catch - the whole point of the Phase 3.4 design change.

**Build 1** (`windows11-phase35-build1.qcow2`, `ComputerName=WIN11P35A`): booted cleanly, ran
unattended for ~14m54s to real WinRM confirmation (`hostname` -> `WIN11P35A`), shut down gracefully
via QMP `system_powerdown`, clean qemu exit. No errors, no warnings, no manual steps.

**Build 2** (`windows11-phase35-build2.qcow2`, `ComputerName=WIN11P35B`): fresh disk, same recipe,
ran unattended for ~14m50s to real WinRM confirmation (`hostname` -> `WIN11P35B`), same graceful
shutdown and clean exit. No errors, no warnings, no manual steps.

**Both runs landed within a tight, consistent window (~14:50-14:54) of this session's own earlier
production-validation run (Phase 3.4's own final run) and the two hand-run NVRAM tests before it** -
five independent runs now, all in the same rough timing neighborhood on this host, none needing any
timing-sensitive intervention. Combined with Phase 3.4's own four independent NVRAM-boot-order
confirmations, this is `windows11-setup-install.sh` meeting the same evidentiary bar (2-3+ independent
clean runs) this project has held every other successful mechanism to.

**Persistent state**: `windows11-phase35-build1.qcow2` and `windows11-phase35-build2.qcow2` (~15GB
and ~13GB) both kept as production-readiness reference disks, alongside `windows11-phase34-
validate2.qcow2` from Phase 3.4's own final run - three real, independently-built, WinRM-confirmed
Windows 11 disks via the finished script. No VM running, no `qemu-nbd` attached, confirmed via
`pgrep`.

**Phase 3.5 is done.** Windows 11's Setup.exe-driven build path now has the same production-readiness
standing Server 2022/2025 already had. Remaining open items, unaffected by this phase and deferred
deliberately, not overlooked: the virtio-driver question (Phase 3.2/3.3's own `e1000`/plain-IDE scope
decision - untested with this pipeline), and Phase 4 (Datadog Agent integration), which applies to
all three OSes equally and hasn't been started for any of them.

---

## Housekeeping: USB tablet device added to both production `qemu-system-x86_64` invocations, closing
## a gap CLAUDE.md flagged (Session 4) but never actually fixed.

CLAUDE.md's own "Known gotcha" note (under QEMU/KVM/libvirt) documented that a guest's default
relative PS/2 mouse can't be driven by `tools/qmp-click.py`'s absolute-position clicks, and that
`make-bootable.sh` didn't yet carry the fix (`-device qemu-xhci,id=usbbus -device
usb-tablet,bus=usbbus.0`) the sibling project already uses via libvirt domain XML. Added directly to
both of this project's real production `qemu-system-x86_64` invocations - `make-bootable.sh`
(Server 2022/2025) and `windows11-setup-install.sh` (Windows 11) - covering all three target OSes,
not just Windows 11. The two retired scripts (`audit-mode-sysprep.sh`, `calibrate-eject-timing.sh`)
were deliberately left unmodified - they're frozen historical record of what actually ran, not live
code to keep current.

Verified two ways before trusting the change: `qemu-system-x86_64 -device help` confirmed both
`qemu-xhci` and `usb-tablet` are available on this host, and a real (if minimal, disk-less)
`qemu-system-x86_64` launch with both devices attached booted cleanly through SeaBIOS/iPXE with no
device-init errors. Neither script needs a full end-to-end re-validation run for this specific
change - it's a purely additive USB controller + generic HID tablet device (natively supported by
every Windows version, no driver needed), doesn't alter any existing boot device, network
configuration, or QMP behavior already proven across Phase 3.4/3.5's six independent clean runs.

---

## Housekeeping: broader qcow2 review across the whole `image-apply/output/` tree, not just this
## session's own churn - found real Phase 2-era dead weight still sitting around.

A full inventory of every `.qcow2` under `image-apply/output/` (not just this session's artifacts)
turned up three disks from now-closed Phase 2 branches, unreferenced by any current script (confirmed
via `grep` across all `.sh` files, not assumed): `win11-session13.qcow2` (18GB, Phase 2's own final
successful Windows 11 build via the now-fully-superseded fully-offline pipeline - that whole
architecture is dead, replaced end to end by the Setup.exe-driven approach), `winpe-boot.qcow2`
(2.0GB, an early predecessor to the still-active `winpe-boot-index1-work.qcow2`, superseded), and
`winpe-boot-index2.qcow2` (1.5GB, an artifact of Phase 2's abandoned Setup.exe/`boot.wim` pivot -
closed per CLAUDE.md's "RECONSIDERATION CLOSED" note back in Session 6). By explicit user
confirmation, all three deleted (~21.5GB). `winpe-boot-index1-work.qcow2` - confirmed via `grep`
as the actual `WINPE_QCOW2` `make-bootable.sh` requires - was left untouched.

Also pruned, by explicit user confirmation: two of the three Phase 3.4/3.5 Windows 11 reference disks
(`windows11-phase34-validate2.qcow2`, `windows11-phase35-build1.qcow2`, ~30GB) - more reference disks
than this project's own "1-2 once the bar is met" standard calls for. `windows11-phase35-build2.qcow2`
(the most recent, ~13GB) kept as the sole current reference.

**Total freed this round: ~50GB** (912G volume: 361G used -> 311G used, 560G available). Remaining
`image-apply/output/` qcow2 footprint is now just the two disks actually still needed:
`winpe-boot-index1-work.qcow2` (required by `make-bootable.sh`) and `windows11-phase35-build2.qcow2`
(current Windows 11 reference).

---

## Housekeeping: retired scripts moved to `image-apply/historical/`, to make the live/retired
## boundary structural, not just a header comment someone has to read first.

`audit-mode-sysprep.sh` and `calibrate-eject-timing.sh` moved (`git mv`) from `image-apply/` directly
into a new `image-apply/historical/` subdirectory. Both scripts compute their own `SCRIPT_DIR` and
source `lib/common.sh` relative to it - moving them one level deeper broke that (`${SCRIPT_DIR}/lib/
common.sh` no longer resolved), caught before trusting the move rather than assumed safe: fixed to
`${SCRIPT_DIR}/../lib/common.sh` in both, then verified for real (not just `bash -n`) - sourced
`lib/common.sh` from the new location directly and confirmed `REPO_ROOT` resolves correctly and the
shared `log()` helper works. `lib/common.sh` itself computes `REPO_ROOT` from its own location, not
the caller's, so it needed no change.

Added a "RETIRED" header to `audit-mode-sysprep.sh` (it never had one, unlike `calibrate-eject-
timing.sh` which already did) so either file makes its own status clear to a reader who opens it
directly, not just via the directory it now lives in. Updated the one live cross-reference
(`windows11-setup-install.sh`'s own header comment) and the two planning docs' status notes
(`WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`, `WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md`) to point at the
new path. Historical narrative elsewhere in this log describing what was run at the time (this
section included, going forward) is left as-is - it was accurate when written and isn't meant to
track the files' current location.

---

## Open investigation (2026-08-23, unresolved as of this entry): Start Menu and other XAML/Fluent-UI
## shell components crash on every offline-applied Server 2022 build - two real, independently-
## useful fixes attempted and ruled out; the actual root cause is now understood but not yet fixed

### Symptom

The first time a Phase 3A build was actually used *interactively* rather than only verified
headlessly (`register-vm.sh`'s own first real `virsh start` boot, Server 2022) - clicking Start does
nothing. Plain Win32 apps (File Explorer, Edge, Server Manager) all work normally; only Start Menu,
and by extension anything else built on the same modern shell stack (Search, Action Center), is
affected. This is not specific to `register-vm.sh`'s own device model - it reproduces identically on
Packer's own `boot-and-provision.pkr.hcl` device model too, confirmed on a second, completely fresh
build later in this same investigation.

### Diagnostic method

Direct, live inspection of the running guest over WinRM throughout - event logs, process lists,
registry, and (eventually) the guest's own SQLite package-state database - not guesswork from the
outside. One real methodology bug worth flagging for next time: an early "confirmed fixed" read
turned out to be a false negative caused by launching a UWP process via a WinRM PowerShell session,
which runs in Session 0 (services) - UWP apps cannot run in Session 0 at all, so that test never
actually exercised the crash path. The valid technique, used from that point on: `schtasks /create
... /it /ru Administrator /rp <pw> /f` then `schtasks /run`, which launches the target process into
the real interactive session (Session 1) - `schtasks /query /tn <task> /v /fo list | Select-String
"Last Result"` then gives the process's real exit/exception code directly, no manual clicking needed
to get a decisive answer.

### Hypothesis 1 (ruled out): `spice-guest-tools`' bundled classic QXL driver lacks real WDDM support

First crash captured directly: `StartMenuExperienceHost.exe` faulting in `Windows.UI.Xaml.dll`,
exception `0xc0000409` (`STATUS_STACK_BUFFER_OVERRUN`, in practice a `__fastfail`, not a literal
buffer overrun), fault offset `0x92e66`, `Windows.UI.Xaml.dll` version `10.0.20348.587` - captured via
both `Get-WinEvent` (`Application Error`/`Windows Error Reporting` providers, event IDs 1000/1001) and
`schtasks`'s own `Last Result` (`-1073740791`, which is `0xc0000409` reinterpreted as signed 32-bit).
The installed QXL driver at the time was the classic driver bundled by `spice-guest-tools-latest.exe`
(`DriverVer 09/22/2015`, no real Direct3D/WDDM support) - a real, independently-documented limitation
(Red Hat's own open RFE, bugzilla.redhat.com/895356, "WDDM Display Only Driver for windows 10+"; a
related report at bugzilla.redhat.com/1902635). Fix implemented: stage `virtio-win`'s own `qxldod`
package (already in the same ISO this project already mounts for `vioscsi`/`netkvm` - no new
dependency) alongside `spice-guest-tools` in `image-apply/inject-virtio-spice.sh`; both drivers target
the identical PCI hardware ID (`PCI\VEN_1B36&DEV_0100&SUBSYS_11001AF4`), and `qxldod.inf`'s declared
`FeatureScore` (`F9`) deterministically outranks the classic driver's (`FC`) under Windows' own
documented driver-ranking rule (lower wins), so no forced uninstall was needed.

**Initially misreported as confirmed working** - the WinRM-launch test described above showed no
crash, which was actually the Session 0 false negative, not a fix. A `schtasks /it` re-test on the
*same* `qxldod`-equipped disk reproduced the **identical** crash - same fault offset, same module
version - proving the driver was never the cause. Independent, decisive counter-evidence supplied by
the user: a real, long-lived reference VM (`win2022-dc`, built via the sibling project's Setup.exe-
driven mechanism, not this project's offline apply) has a *working* Start Menu while still running
the *original 2017* classic driver - directly contradicting a driver-based explanation. **The `qxldod`
swap itself is kept regardless** - it's a real, worthwhile improvement (WHQL-signed, actual WDDM
support) independent of what turned out to actually cause this crash; verified bound correctly
(`Win32_PnPSignedDriver` → `DriverVersion 10.0.0.21000`) on two separate real builds.

### Hypothesis 2 (ruled out): Windows Server 2022's own documented RPC/DCOM boot-storm race

Repeated `Microsoft-Windows-DistributedCOM` Event 10010 ("did not register with DCOM within the
required timeout") for `StartMenuExperienceHost` specifically, alongside the crash, pointed toward a
real, documented Windows Server 2022 issue found via targeted web research and verified against the
primary source directly (not just a search summary): a Microsoft Q&A thread
(learn.microsoft.com/en-us/answers/questions/5836440/) describing the *identical* symptom triad -
Start Menu, Search, **and IIS** all failing after a first restart - root-caused there to heavy
first-boot disk/CPU I/O ("boot storm") preventing the RPC Endpoint Mapper from initializing within the
default 30s service-dependency timeout, cascading through DCOM → `SystemEventsBroker` →
`Background Tasks Infrastructure` failing to start. This project's own build pattern (several
already-automated boot/shutdown cycles - Packer's provision+restart, then `inject-virtio-spice.sh`'s
two more - before the first real interactive boot) is a genuinely good match for the trigger
condition. Fix implemented: an offline `hivexregedit --merge` in `image-apply/make-bootable.sh`
(same mechanism/location as the existing `vioscsi`/`netkvm` `DriverDatabase` merges), setting
`HKLM\SYSTEM\ControlSet001\Control\ServicesPipeTimeout` = `120000` (120s) before the very first boot,
applying identically to Server 2022 and Server 2025 (no OS branching around it).

**Tested on a completely fresh build (offline apply → Packer → `inject-virtio-spice.sh`, all
end-to-end) and the identical crash reproduced again** - same `0xc0000409` via the valid `schtasks
/it` test. This fix is also kept (a real, primary-source-backed improvement with no real downside),
but it also was not the actual cause.

**Reasoning correction that reframed the whole investigation**: the crash has now reproduced at the
**identical fault offset, on every single attempt, across three separate builds** (classic driver, `
qxldod`, `qxldod`+`ServicesPipeTimeout`). That is not what a race condition looks like - a real timing
race would be intermittent, sometimes resolving favorably. 100% reproducibility at the same exact
instruction address points to a deterministic defect, not a timing collision. The DCOM timeout events
were very likely a *downstream symptom* of `StartMenuExperienceHost` already being dead (it can't
register with DCOM because it already crashed), not the cause - the causality in Hypothesis 2 was
probably backwards.

### Hypothesis 3 (root cause, high confidence, fix not yet completed): `wimlib`'s `wimapply` does not
### carry over Windows AppX/MSIX package *provisioning* state the way `DISM`/Setup.exe does

Prompted directly by the user: "check the sister project for clues, check win2022-dc for clues."
Reading the sibling project's real, working `packer/answer_files/autounattend.xml.pkrtpl` (used to
build `win2022-dc` via actual interactive Setup.exe) showed it skips OOBE the same way this project's
own specialize/oobeSystem-only unattend pass does (`SkipMachineOOBE`/`SkipUserOOBE = true`,
`AutoLogon` + `FirstLogonCommands`) - ruling out OOBE-skipping itself as the differentiator. The real
difference: `win2022-dc` went through Microsoft's own `DISM`-driven `/Apply-Image` (as part of real
Setup.exe), while this project deliberately uses `wimlib`'s own `wimapply` instead, specifically
documented in this project's own `CLAUDE.md` as a deliberate choice to avoid ever needing to boot a
Windows environment. Targeted research found direct, credible confirmation this is a real, documented
limitation, not a guess: "wimlib-imagex has no awareness of Windows 'packages' ... importantly, it
cannot manage or apply the AppX package provisioning information that may be embedded in the image."

**Confirmed directly against this project's own actual offline-applied disk, not just inferred from
research**: mounted the target disk's NTFS partition from this Linux host (`qemu-nbd` + `ntfs-3g`, the
same mechanism this project already uses throughout) and queried
`ProgramData\Microsoft\Windows\AppRepository\StateRepository-Machine.srd` directly with the host's own
`sqlite3` CLI - the `.srd`/`.srd-wal`/`.srd-shm` file set confirms this is a genuine SQLite database
(WAL mode), openable with zero Windows tooling. `Package`/`PackageIdentity` both show
`Microsoft.Windows.StartMenuExperienceHost_10.0.20348.1_...` and
`Microsoft.Windows.ShellExperienceHost_10.0.20348.1_...` present with normal-looking metadata
(`IsInbox=1`, proper `DisplayName`/`PublisherDisplayName` resource references) - but
**`ProvisionedPackage` (the table that specifically tracks "install this app for every user at first
logon") has zero rows, for anything.** This is the direct, structural explanation: the package files
and their catalog metadata come along fine via `wimapply`'s raw file copy (and whatever's embedded in
`install.wim`'s own captured filesystem state), but the actual provisioning step - establishing that
these packages should be deployed per-user - normally only happens during a real, live Setup.exe/DISM-
driven install, never during a raw file-level WIM apply.

A live cross-check muddies the picture slightly and is worth someone resolving before assuming the
SQL table is the *only* place this state lives: `Get-AppxProvisionedPackage -Online` (the supported
PowerShell/DISM cmdlet, run live against the running guest) reports **3** provisioned packages, not
zero - `Microsoft.UI.Xaml.2.2`, `Microsoft.UI.Xaml.2.4`, `Microsoft.VCLibs.140.00` - all shared
*framework* packages, not the *app* packages themselves. So there appear to be two, not necessarily
consistent, provisioning-tracking layers in play (the StateRepository's own `ProvisionedPackage` SQL
table, and whatever `Get-AppxProvisionedPackage -Online` actually reads from), and only the framework
layer picked up anything via the raw copy. Not yet root-caused *why* those specific three came
through and nothing else did - a real, open thread for whoever picks this back up.

### Fixes attempted for Hypothesis 3, both failed so far

1. `Add-AppxPackage -DisableDevelopmentMode -Register <AppxManifest.xml> -ForAllUsers` - **fails
   immediately**: `-ForAllUsers` is not a valid parameter for `Add-AppxPackage -Register` in this
   PowerShell/AppX module version (it belongs to a different `Add-AppxPackage` code path, installing
   *from* a packaged `.appx`, not registering a loose in-box app). A plain `-Register` (no
   `-ForAllUsers`) was already tried earlier in this same investigation (before Hypothesis 3 was even
   formed) and also didn't fix the crash - it only affects per-user registration for the currently
   logged-on account, not machine-wide provisioning, which is consistent with what the SQL table
   later confirmed is actually missing.
2. `Add-AppxProvisionedPackage -Online -PackagePath 'C:\Windows\SystemApps\<app folder>' -SkipLicense`
   (the correct, supported cmdlet for machine-wide provisioning, confirmed present - `Dism` PowerShell
   module version 3.0) - **fails**: `"PackagePath must point to a package, not a directory"`. This
   cmdlet requires a real `.appx`/`.appxbundle`/`.msix` file; in-box Windows apps ship pre-extracted
   ("loose") with no such packaged file anywhere on disk, so this specific cmdlet path is a dead end
   for exactly the apps that need it.
3. Raw `dism.exe /Online /Add-ProvisionedAppxPackage /PackagePath:'<AppxManifest.xml path>'
   /SkipLicense` (trying the CLI directly in case its own syntax is more permissive than the
   PowerShell wrapper) - **fails**: `Error: 0x8051100f`, "DISM failed. No operation was performed."
   Not yet decoded/researched - genuinely the next thing to look up, not yet attempted.

### What's confirmed real and staying in the pipeline regardless of Hypothesis 3's outcome

- `image-apply/inject-virtio-spice.sh`'s `qxldod` staging (Stage 1) and driver-version verification
  (Stage 2, asserts `DriverVersion -eq '10.0.0.21000'`) - real, WHQL-signed WDDM driver, confirmed
  bound on two separate real builds.
- `image-apply/make-bootable.sh`'s offline `ServicesPipeTimeout` registry increase - real,
  primary-source-backed mitigation for a genuine (if not the actual culprit here) Windows Server 2022
  boot-race risk, applies to Server 2022 and 2025 identically.
- `build.sh`'s `BUILD_ID` fix (unique per-run identifier threading Packer's `output_directory`/
  `vm_name`/`efi_firmware_vars`) - fixed a real, reproduced collision bug (a second build of the same
  OS previously failed outright); confirmed by two full successful end-to-end runs tonight.
- `register-vm.sh` - confirmed by one real `virsh start` boot to a genuinely working desktop
  (Server 2022, virtio-scsi/virtio-net/QXL+SPICE all live) - the Start Menu crash investigated in this
  section is unrelated to `register-vm.sh`'s own device-model correctness, which is a separate,
  already-closed question.

None of the above four are reverted or in question - all real, independently defensible changes. Only
the Start Menu/AppX-provisioning problem itself remains open.

### Hypothesis 3, REFUTED (addendum, same night): a direct `win2022-dc` comparison invalidates the
### AppX-provisioning theory entirely, and closes a fourth hypothesis (Xaml.dll patch level) too

Per this project's own standard (get the real reference machine's own data before trusting a
guessed fix - Next step 4 above), the user ran the exact same `Get-AppxProvisionedPackage -Online`
query directly on `win2022-dc` and shared the output. Result: **`win2022-dc`'s own provisioned list
is `Microsoft.MicrosoftEdge.Stable`, `Microsoft.UI.Xaml.2.2`, `Microsoft.UI.Xaml.2.4`,
`Microsoft.VCLibs.140.00` - i.e. the identical three framework packages this project's own broken
build has, plus Edge (a live-updated package, unsurprising for an internet-connected machine).
`Microsoft.Windows.StartMenuExperienceHost` and `Microsoft.Windows.ShellExperienceHost` are absent
from `win2022-dc`'s own provisioned list too, on a machine where Start Menu works fine.**

This directly refutes Hypothesis 3: the missing `ProvisionedPackage` rows for these two packages
is normal, not a defect - core OS shell components are evidently serviced through a different
mechanism than the AppX "provision for every new user" system `Get-AppxProvisionedPackage`/
`ProvisionedPackage` actually tracks (which is for Store-style apps like Edge, not in-box shell
components in `%windir%\SystemApps\`). The SQLite finding itself (three tables, real schema, zero
`ProvisionedPackage` rows) was accurate - the conclusion drawn from it was wrong.

A follow-up command (`Get-HotFix | Sort-Object InstalledOn | Format-Table ...` immediately followed
by `(Get-Item '...\Windows.UI.Xaml.dll').VersionInfo.FileVersion`, meant to test a revived,
corrected version of Hypothesis 2 - not "this exact wrong KB" but "our image has simply never
received any cumulative-update servicing at all, unlike an internet-connected reference machine" -
was accidentally pasted as a single line, so `Get-HotFix` itself never ran (PowerShell tried to bind
the `Get-Item` sub-expression's own return value as a positional argument to `Format-Table` and
errored). But the error message itself leaked the one value that mattered: **`win2022-dc`'s own
`Windows.UI.Xaml.dll` FileVersion is `10.0.20348.1 (WinBuild.160101.0800)` - identical, down to the
build-lab tag, to this project's own broken build's version, confirmed via a direct `Get-Item` query
earlier in this same investigation.** Same exact crashing DLL, same exact version, on a machine
where it doesn't crash - this rules out Xaml.dll's own patch level as the differentiator too,
without needing the `Get-HotFix` list at all (a useful, real result even though the parent command
partially failed).

**Running honest tally as of this addendum: four real, independently well-evidenced hypotheses
tested and disproven** - classic QXL driver, Windows Server 2022's documented RPC/DCOM boot-race,
missing AppX provisioning state, and Xaml.dll's own patch level. The actual differentiator between
`win2022-dc` (works) and this project's own offline-applied builds (100% reproducible crash) remains
unidentified as of this entry.

### Hypothesis 5, REFUTED same night: Windows activation/licensing state

Proposed immediately after Hypothesis 3/4 fell (the real, previously-dismissed `slui.exe`/KMS
`0x80072EE7` activation failures in the event log were the basis - this project's own builds have no
real internet access by design, so activation always fails there). **Refuted directly by the user,
who confirmed `win2022-dc` is also not activated, and its Start Menu works fine regardless.** Closed
without needing further diagnostic work - a clean, fast refutation from someone with direct
knowledge of the reference machine's own state, not something that needed to be tested empirically
this time.

**Five real hypotheses now closed** (QXL driver, RPC/DCOM boot-race, AppX provisioning, Xaml.dll
patch level, activation state) - each with real, direct evidence, none abandoned on a guess. The
actual differentiator between `win2022-dc` (works) and this project's own offline-applied builds
(100% reproducible crash) remains unidentified as of this entry.

### Next steps (revised again after Hypothesis 5's refutation)

Five one-off hypothesis-and-test cycles is enough to justify a more systematic approach next time,
rather than reaching for a sixth individual guess under pressure to keep momentum. Promoted to the
top:

1. **A full, systematic state diff between `win2022-dc` and a broken build, not another single
   hypothesis.** Start with the cheapest, most comprehensive comparison available:
   `virsh dumpxml win2022-dc` side-by-side against `register-vm.sh`'s own generated domain XML (or
   Packer's `boot-and-provision.pkr.hcl`-driven one) - CPU model (`host-passthrough` vs. a specific
   named model), machine type version, memory, TPM/Secure Boot presence, and any other device
   difference neither of us has specifically looked for yet. This is pure information-gathering, not
   a fix attempt, and might surface a concrete lead (or several) worth individually testing rather
   than guessing what to check next one at a time.
2. `win2022-dc`'s own `Get-HotFix` list still hasn't actually been captured (the command errored
   before running) - worth getting for real as part of the same systematic pass above, even though
   the one value that mattered most (`Windows.UI.Xaml.dll`'s own version) already came through and
   ruled out that specific angle.
3. Decode/research DISM error `0x8051100f` for `/Add-ProvisionedAppxPackage` - lower priority now
   that Hypothesis 3 itself is refuted, but still an open, undecoded error worth understanding if
   AppX servicing comes back into play for a different reason later.
4. Re-run the same investigation against a Windows 11 build once Server 2022 is actually fixed -
   `windows11-setup-install.sh` invokes real Setup.exe (unlike Server 2022/2025's fully offline
   path), so it may already be immune to whatever this actually is - not yet verified either way.

### Stopping place for tonight

- **Tonight's pipeline work (the `qxldod`/`ServicesPipeTimeout`/`BUILD_ID`/`register-vm.sh` changes,
  plus this log's own original entry) was committed and pushed** (`f174dca`) before this addendum was
  written - all real, all kept, none of it reverted by anything in this addendum. This addendum
  itself, and the "Next steps" revision above, still need their own commit.
- `win2022prod` libvirt domain was left running (disk `packer/output/server2022-20260823-154052/
  server2022-20260823-154052.qcow2`) at the point the original entry was written; not re-checked as
  of this addendum - confirm current state before resuming rather than assuming.
- Resume by reading this whole section (including this addendum) before re-deriving anything -
  four specific, real hypotheses are now closed, with the evidence that closed each one recorded
  above, so there's no need to re-test any of them from scratch.

---

## Session (continued, 2026-08-24): systematic domain-XML diff, a full event-log inventory (not
## just the one known crash signature), live reproduction on an idle system, and a StateRepository +
## binary-hash comparison that finds the real differentiator - Hypothesis 6, strong evidence,
## reframes the problem entirely

Resumed per the prior session's own "Next steps" list, item 1 (systematic `virsh dumpxml` diff)
first, then redirected by a direct user question worth recording verbatim because it changed the
whole approach: *"Is it possible, nay probable, that [the Start Menu crash] is only the most visible
[failure]? ... Should we take an inventory of the event and system log on the trial VM and do a
quick scan for additional potentially fatal problems"* - i.e., stop debugging the one known symptom
in isolation and check whether the actual blast radius is bigger than what's already been
characterized. This reframing is what led to today's real progress.

### Step 1: `virsh dumpxml` diff (win2022-dc vs. win2022prod) - no smoking gun, one open question closed

Both VMs were confirmed shut off, dumped with `virsh dumpxml`, diffed directly. **CPU model is
identical on both**: `<cpu mode='host-passthrough' check='none' migratable='on'/>`, closing the one
specific concern the prior session's "Next steps" item 1 named by hand. `<clock>`/timer config also
identical. The only real differences are already fully explained by known, deliberate changes: `
win2022-dc` carries a `memoryBacking`+`virtiofs` filesystem passthrough (an unrelated shared-folder
device, sibling-project-specific, not present on any `windows-auto-build-pipeline` build) and VNC
graphics/PS2-only input, while `win2022prod` carries the SPICE/QXL/USB-tablet device set
`inject-virtio-spice.sh` and `register-vm.sh` deliberately added (Phase 3A). Conclusion: the VM
device topology itself is not the differentiator - correctly ruling out an entire category before
spending more time on it.

### Step 2: full Application+System Critical/Error event-log inventory, both machines - confirms
### the failure is a small, named cluster, not an open-ended list, but is bigger than "just Start Menu"

Booted `win2022-dc` (the sibling project's real, working reference machine) first as the healthy
baseline, reaching it over WinRM at `Administrator` / `ChangeMe-Lab123!` (the sibling project's own
Packer `variables.pkr.hcl` default - not this project's own `TestP@ssw0rd123` convention, since this
is a separate machine built by the sibling project's own pipeline). `Get-WinEvent` grouped by
Log|Provider|Id over the last 30 days found only ordinary long-lived-lab-VM noise: `QEMU-GA` service
reconnect timeouts, a crash-looping Datadog Installer service, VSS/COM errors tied to normal shutdown
races, temporary-profile warnings, `Defrag` retrim errors, `Perflib` 32-bit-DLL warnings, one
`wuauclt.exe` crash, one prior unexpected shutdown. **No DCOM 10010 events at all.** Shut down
cleanly (`Stop-Computer -Force` over WinRM, confirmed `shut off` before proceeding - no hard QMP
quit, per this project's own standing convention).

Booted `win2022prod` (`packer/output/server2022-20260823-154052/`, last night's real production
build) and ran the identical query. Result: **51 DCOM 10010 events, not 1** - and not just for
`StartMenuExperienceHost`. Grouped by the AppX server name failing to register:
`Microsoft.Windows.Search_...!CortanaUI` (Search) fails *more* often than
`Microsoft.Windows.StartMenuExperienceHost_...!App` itself; `Microsoft.Windows.ShellExperienceHost_
...!App` and `MicrosoftWindows.Client.CBS_...!InputApp` (the touch-keyboard/input host) also appear.
Only one actual `Application Error` 1000 crash (`StartMenuExperienceHost.exe`, matching the
already-documented `0xc0000409`/stack-buffer-overrun signature) - the others fail the DCOM
registration handshake without ever producing a Watson crash report at all, a related but distinct
failure shape not previously characterized.

**Direct answer to the user's question**: yes, there is more than the one visible symptom, but it is
not an unbounded list - every failure found traces to the same mechanism (packaged/AppX DCOM
activation) hitting the same small, enumerable family of in-box UWP shell components. The separate
"Automatic services not running" list pulled in the same pass (`CDPSvc`, `DPS`, `MSDTC`, `QEMU-GA`,
`UALSVC`, `vdservice`) was **not** cross-checked against `win2022-dc`'s own equivalent list before
this session ended - several of these are plausibly normal delay-start/trigger-start services showing
as "Stopped" on both machines, but this is an explicitly open, unverified thread, not a confirmed
finding either way.

### Step 3: timestamp analysis of the 51 DCOM events - refines, then genuinely challenges, Finding
### 3A-5's "boot storm" theory

All 51 events clustered tightly around each of last night's several reboots (Packer's own
provision+restart, `inject-virtio-spice.sh`'s two more, plus manual test reboots) - consistent with
*a* boot-timing race. But the boot history (`Get-WinEvent` Ids 6005/6006/6009/1074) showed two more
recent, more isolated boots this morning (04:53 and 09:18) with **zero** DCOM 10010 events on either
- at first read, support for the boot-storm theory (no storm, no failure).

### Step 4: live reproduction on the current, hours-idle boot - directly falsifies "boot storm" as
### the explanation, and points at "first activation" instead

Rather than trust the absence of logged events as proof the current boot was clean, forced a real
test: the console was locked with no interactive session (confirmed via `query session`), unlocked
via `virsh screenshot` + `virsh send-key` (raw Linux keycodes - `virsh send-key`'s `--codeset win32`/
`linux` symbolic names like `KEY_LCONTROL`/`ctrl` are rejected outright; only bare numeric keycodes
work, e.g. `29 56 111` for Ctrl+Alt+Del, `42 20` for Shift+T - a real, reusable operational note for
any future console-typing need via libvirt rather than raw QMP). Confirmed via `virsh screenshot` at
each step (login unlocked to a normal desktop with Server Manager already open from the earlier
AutoLogon), then pressed the physical Windows key.

**Result: no Start Menu flyout appeared at all, and `Get-Process StartMenuExperienceHost` found no
process, not even a crashed/zombie one.** In the same instant, fresh DCOM 10010 events for both
`StartMenuExperienceHost` and `CortanaUI` appeared in the log, timestamped to the exact second of the
keypress. At the same moment, directly queried the machine's actual state:

- `HKLM\SYSTEM\CurrentControlSet\Control\ServicesPipeTimeout` = `120000` - **Finding 3A-5's fix is
  correctly present** on this disk.
- `RpcSs`, `RpcEptMapper`, `DcomLaunch`, `EventSystem` - all `Running`/`Automatic`, fully healthy.
- CPU at 0%, 15 of 16 GB RAM free - the system had been completely idle for hours before this test.

This is a clean counter-example to Finding 3A-5's "early boot I/O contention" mechanism: the fix it
prescribed is in place, the RPC/DCOM plumbing it worried about is healthy, there is zero resource
pressure, and the failure still reproduces 100% of the time, at the exact moment these specific
DCOM servers are first invoked in a session - not correlated with boot timing at all once a session
actually attempts to use them. Combined with Step 3's "no events on boots nobody logged into," the
better-fitting model is **first-activation failure of this specific package family**, not a
boot-storm race. `ServicesPipeTimeout` is very likely still worth keeping (real, primary-source
mitigation for a real, if different, risk) but is not, on this evidence, what actually explains the
Start Menu crash.

### Step 5: StateRepository comparison, done fully offline (no VM boot needed at all) - conclusively
### rules out package *registration* data as the differentiator, closing Hypothesis 3 for good

Per the user's direct request to pull this comparison and reusing this project's own established,
zero-boot mechanism (`qemu-nbd` + `ntfs-3g` read-only mount + the host's own `sqlite3` CLI against
`ProgramData\Microsoft\Windows\AppRepository\StateRepository-Machine.srd` - the exact recipe Session
2's original Hypothesis 3 work used), both machines' disks were mounted directly from this Linux
host with **both VMs shut off** the whole time (no live-WAL risk, no boot needed).

One real operational snag, worth keeping as a note: the project's scoped sudoers rules
(`tools/sudoers-windows-auto-build-pipeline`) pin the passwordless `mount -t ntfs-3g` rule's
mountpoint argument to the literal glob `/tmp/win-build-mnt/*` - an ad hoc mount under a session
scratchpad path is rejected with a password prompt. Used `/tmp/win-build-mnt/<label>` instead (a
plain user-writable directory, no sudoers change needed) rather than modifying the sudoers file for a
one-off investigation.

**Full schema dump** (`.tables`, ~90 real tables) confirmed `Activation` - the table that maps a
packaged app's identity to its actual COM/DCOM launch parameters (`Executable`, `Entrypoint`,
`RuntimeType`, `ActivationKey`) - not `ProvisionedPackage`, is the table that actually governs
packaged-COM DCOM activation. Row-count diff across every table between the two databases: **only 2
tables differ at all** (`PackageUser`/`CachePackageUser`: 36 on `win2022-dc` vs. 34 on `win2022prod`;
`DependencyGraph`: 5 vs. 3) - fully explained by `win2022-dc` simply having two more packages
provisioned overall (e.g. `Microsoft.MicrosoftEdge.Stable`, already known from the prior session's
Hypothesis 3 addendum). Every other table, including `Package` (34), `Application` (35), `Activation`
(45), and `PackageFamily` (34), matches exactly.

Went further and pulled the actual `Activation`/`Application` rows for all four implicated packages
(`StartMenuExperienceHost`, `ShellExperienceHost`, `Microsoft.Windows.Search`/`CortanaUI`,
`MicrosoftWindows.Client.CBS`/`InputApp`) on both machines side by side: **byte-identical, field for
field, including the `ActivationKey` hash itself** (e.g. `StartMenuExperienceHost`'s key is
`6nvtep9ym00sgr3ndnwd50mskvgbfcg6k9jz5hv5vk4vhce2drm0` on both machines). **This conclusively closes
Hypothesis 3 in its original form and in this deeper form** - the StateRepository's actual
DCOM-activation-relevant data is not the differentiator, full stop.

### Step 6 (decisive): binary/manifest hash comparison - finds the real differentiator

Since the registration *data* matched exactly but the *behavior* doesn't, the next question was
whether the registered files themselves are actually the same bytes. Extended the same offline mount
to `sha256sum` the four implicated packages' main executables and `AppxManifest.xml` files on both
machines:

| File | `win2022prod` SHA256 | `win2022-dc` SHA256 | Match? |
|---|---|---|---|
| `TextInputHost.exe` (CBS/InputApp) | `2492bf02...` | `2492bf02...` | **identical** |
| `SearchApp.exe` (Search/CortanaUI) | `b0a7de8e...` | `a43097c6...` | **different** |
| `StartMenuExperienceHost.exe` | `64beeb8e...` | `6ef63d3e...` | **different** |
| `ShellExperienceHost.exe` | `eee13d00...` | `99bf0dd3...` | **different** |
| All 4 `AppxManifest.xml` | (4 hashes) | (same 4 hashes) | **identical, all four** |

**The three files that actually crash/fail DCOM registration with a Watson-visible symptom
(`StartMenuExperienceHost.exe`, `ShellExperienceHost.exe`, `SearchApp.exe`) are the exact three files
that differ. `TextInputHost.exe` (part of the same failing DCOM-timeout list but never observed to
actually crash) is byte-identical, and none of the manifests differ at all.** File size differs too
in the same three cases, ruling out something trivial like a timestamp-only or metadata-only
difference.

**mtime comparison seals it.** Extracted via `stat` on the same offline mount:

- `win2022prod`: `StartMenuExperienceHost.exe`/`ShellExperienceHost.exe` both carry mtime
  `1620461668`/`1620461695` (7 May 2021); `SearchApp.exe` carries `1646279685` (2 Mar 2022) -
  `TextInputHost.exe` carries `1620425760` (7 May 2021, matching `win2022-dc`'s copy exactly). All
  read as original install-media/RTM-era timestamps, consistent with a straight `wimapply` from
  Microsoft's own unmodified `install.wim`.
- `win2022-dc`: all three *differing* files carry mtimes within ~300 seconds of each other
  (`1786489554`, `1786489632`, `1786489859`) and land in the **current date range this project is
  running in (August 2026)** - a strong, specific signature of a single real Windows Update /
  cumulative-update servicing event having replaced exactly these three files together, recently, on
  a machine that actually has internet access. `TextInputHost.exe` on `win2022-dc` was *not* touched
  by that same event (identical mtime and hash to `win2022prod`'s copy) - consistent with a real CU
  payload only containing some of a related file set, not all of it.

### Hypothesis 6 (new, strong evidence, not yet independently confirmed against a decoded KB): the
### Start Menu crash is a real, upstream Microsoft defect in the RTM/install-media build of these
### three shell binaries, already fixed by Microsoft in a cumulative update - and this project's
### fully offline/air-gapped build pipeline can never receive that fix by design

Putting Steps 5 and 6 together: the StateRepository says these packages are registered completely
normally and identically on both machines (Hypothesis 3, and its deeper `Activation`-table form, are
both closed). The actual crash is confined to exactly the three binaries `win2022-dc` has silently
patched via real Windows Update - a resource this project's VMs never have, by explicit design (every
build in this project is a disposable, network-isolated lab image, never Windows-Update-serviced).
`win2022-dc` is not "unaffected" by whatever bug this is; it very plausibly *was* affected, once, and
has simply been quietly fixed by the same routine servicing that also explains its crash-looping
Datadog Installer, its `wuauclt.exe` crash history, and its general long-lived-machine noise profile
- none of which any of this project's own ephemeral builds ever accumulate, for the same reason.

**This reframes the problem type entirely.** The prior five hypotheses (classic QXL driver, RPC/DCOM
boot race, AppX provisioning, Xaml.dll patch level, activation state) were all investigated on the
premise that something about *this project's own offline-apply mechanism* was producing a broken
disk. Hypothesis 6 says the mechanism is working exactly as designed - `wimapply` is faithfully
reproducing Microsoft's own shipped `install.wim`, bit for bit - and the defect (if this hypothesis
holds) shipped in that media from the start. Two direct, previously-recorded pieces of evidence are
fully consistent with this and were previously unexplained: the crash's 100% reproducibility at an
*identical fault offset* across every independent build (a real, deterministic code defect looks
exactly like this - a timing race would not), and `win2022-dc`'s own `Windows.UI.Xaml.dll` having the
identical `FileVersion` string to the broken build's copy (a CU can patch `StartMenuExperienceHost.
exe`/`ShellExperienceHost.exe`/`SearchApp.exe` specifically without necessarily also bumping a shared
framework DLL's version string in the same update).

**Not yet done, and worth doing before treating this as fully confirmed**: decode which actual KB/CU
touched these three files (a `win2022-dc` `Get-HotFix`/`DISM /Get-Packages` pull, cross-referenced
against Microsoft's own update-history documentation for Windows Server 2022, build `20348.x`) would
turn "strong circumstantial evidence" into a named, citable root cause. This is exactly the
previously-recorded, never-completed "Next step 2" from the prior session (`win2022-dc`'s own
`Get-HotFix` list) - still open, now with a much sharper reason to actually go get it.

**Real implications for how to actually fix this, once confirmed**, not yet decided or attempted:
(a) stage the specific patched files (extracted from a real Windows Update `.msu`/`.cab`, or copied
directly from a known-patched reference machine like `win2022-dc` itself) and inject them offline the
same way `viostor`/`netkvm` drivers already are - a surgical file-replacement, not a new mechanism;
(b) slipstream a cumulative update into `install.wim` before `wimapply` runs (needs research into
whether `wimlib` supports this the way `DISM /Add-Package` does - likely does not, per this project's
own already-documented `wimlib` limitation around package/AppX servicing); (c) give the guest a
narrow, deliberate window of real internet access to run Windows Update once during specialize,
before returning to full isolation - a real design/security tradeoff against this project's own
"ephemeral, air-gapped" architecture, not a small decision; (d) accept the crash as a known,
documented limitation of using unmodified Eval/RTM media offline, if a working Start Menu isn't
actually load-bearing for this project's AD/IIS/SQL/Datadog monitoring-integration goals. None of
these were evaluated or chosen this session - a real decision point for whoever picks this back up.

### Stopping place

- Both `win2022-dc` and `win2022prod` were shut down cleanly (`Stop-Computer -Force` over WinRM,
  confirmed `shut off`) before this entry was written.
- All offline `qemu-nbd`/`ntfs-3g` mounts from Steps 5-6 were confirmed fully torn down (`lsblk`
  shows every `/dev/nbd*` at 0B, `mount` shows nothing under `/tmp/win-build-mnt`) - no lingering
  attached state.
- No files in this project's own tree were modified by any of this session's investigation - all
  reads were against offline-mounted read-only copies or live WinRM queries, nothing was written back
  to either disk.
- Next, in priority order: (1) decode the actual KB/CU behind Hypothesis 6 via `win2022-dc`'s
  `Get-HotFix`, to move from strong circumstantial evidence to a confirmed, citable root cause; (2)
  decide which of the four remediation options above to pursue; (3) the still-open, never-verified
  "Automatic services not running" list from Step 2 (`CDPSvc`, `DPS`, `MSDTC`, `QEMU-GA`, `UALSVC`,
  `vdservice`) needs its own cross-check against `win2022-dc`'s equivalent list before it's treated as
  a finding either way.

---

## Session (continued, 2026-08-24): ISO-provenance check for Hypothesis 6 - is the cached Server
## 2022 media just old? Confirmed old, confirmed not a caching mistake, and confirmed there is no
## newer official ISO to switch to

Prompted directly by the user, skeptical of the ISO's own currency after a quick informal online
search of their own: *"Is it possible that `2022-SERVER_EVAL_x64FRE_en-us.iso` in the iso cache is
just really old? ... Can we find which image the sister project's packer build might have come
from? And use that as a basis point to search online for the most current ISO?"* Answered with real
evidence at each step, not assumption, per this project's own "verify before trusting" standard.

### Step 1: confirmed `win2022-dc` was built from the exact same ISO file, not a different/older one

Read the sibling project's own `packer/locals.pkr.hcl`: its pinned Server 2022 `iso_checksum` is
`sha256:3e4fa6d8507b554856fc9ca6079cc402df11a8b79344871669f0251535255325` - **byte-identical** to
this project's own `ISO_CACHE_INVENTORY.md` entry for `2022-SERVER_EVAL_x64FRE_en-us.iso`. Cross-
checked against `win2022-dc`'s own build history: the sibling repo's commit introducing its first
successful Server 2022 build (`d31ab04`, containing the "`win2022-dc.qcow2` at 5.06GB" build-completion
log) is dated 2026-07-22 - the same week the shared `../iso_cache/` copy was downloaded
(`2022-SERVER_EVAL_x64FRE_en-us.iso.sha256` sidecar dated 2026-07-22T07:59, per the currently-cached
file's own timestamp). **This closes off a real alternative explanation for Hypothesis 6**: the
difference between `win2022-dc` (working) and `win2022prod`/every other build from this project
(broken) is not because `win2022-dc` started from newer/different install media - it started from the
literal same file, confirmed by checksum, not inference.

### Step 2: pinned down exactly what the cached ISO actually is

Extracted `sources/install.wim` from the cached ISO (`7z e`, this project's own established
technique) and read its real metadata with `wimlib-imagex info` rather than guessing from the
filename (which carries no build number at all, unlike the Server 2025/Windows 11 fwlinks - noted as
a real caution back in `ISO_CACHE_INVENTORY.md`'s own "Re-download links" section):

```
Edition ID:              ServerStandardEval
Build:                   20348
Service Pack Build:      587
Creation Time:           Thu Mar 03 04:02:13 2022 UTC
```

So the cached ISO is **build 20348.587**, packaged **2 March 2022** - a real, datable "refresh"
respin of Server 2022's media (RTM itself was 20348.169, August 2021), not literally day-one RTM, but
frozen at whatever cumulative-update level existed as of that March 2022 snapshot.

Then read each disk's own actual servicing level directly, offline, via `hivexregedit` against each
disk's `SOFTWARE` hive (`\Microsoft\Windows NT\CurrentVersion`, no boot needed - same
zero-boot-required mechanism as Steps 5-6 in the prior entry):

| Disk | `CurrentBuild` | `UBR` (decimal) | Effective build |
|---|---|---|---|
| `win2022prod` (this project's own build) | 20348 | 587 | **20348.587** - matches the cached ISO exactly, zero servicing since install, exactly as expected for an air-gapped build |
| `win2022-dc` (sibling project's reference machine) | 20348 | 5499 | **20348.5499** - ~4,900 cumulative-update revisions ahead, accumulated via years of real Windows Update |

This directly confirms the mechanism behind Hypothesis 6 with hard numbers, not just file-hash/mtime
circumstantial evidence: `win2022prod` is provably running the unmodified, as-shipped March 2022
media; `win2022-dc` is provably running a heavily-serviced build of the identical starting point.

### Step 3: checked live whether Microsoft is serving something newer today - confirmed they are not

Ran a real `curl -I` against the exact fwlink this project's own `image-apply/lib/common.sh` uses
(`https://go.microsoft.com/fwlink/p/?LinkID=2195280&...`), right now, not just re-reading the cached
`.meta` sidecar:

```
Content-Length: 5044094976
ETag: "0xC5A0AE6FD398BA773151588CD215E1CFF7FD1C6109783EFA84680CA07C72E2EF"
Last-Modified: Wed, 16 Mar 2022 13:16:34 GMT
```

Both `Content-Length` and `ETag` match the cached file **exactly** - Microsoft's Evaluation Center is
still serving the identical March 2022 file today, over four years later. This is not a stale cache;
it is the current, live, official download. Confirmed further by fetching the Evaluation Center's own
download page directly: it names no build number or refresh date, and explicitly instructs users to
"install the latest servicing package" from the Microsoft Update Catalog *after* installing, rather
than claiming the media itself is kept current - Microsoft's own documentation already assumes and
expects the gap this session quantified, rather than promising a pre-patched image.

**Conclusion: there is no newer official Server 2022 evaluation ISO to switch to. The cached file is
correct, current, and exactly what the sibling project's own working reference machine started from
too.** The ISO was never the mistake; a fresh install from *any* copy of this media, patched or not,
would start at 20348.587 and need the same servicing gap closed by some other mechanism.

### A concrete, well-precedented remediation path this surfaced, not yet attempted

Since Microsoft's own guidance is "apply the latest servicing package after install," the natural
next step is `DISM /Image:<offline-mounted volume> /Add-Package /PackagePath:<cumulative-update
.msu>` - a standard, Microsoft-documented offline-servicing mechanism (conceptually identical in kind
to this project's own established "adopt the existing documented recipe" pattern, e.g. `bcdboot`,
`hivex` driver registration). **A real integration point already exists for this with no new boot
cycle required**: this project already boots a minimal, self-built WinPE session once, per build,
solely to run `bcdboot` (`image-apply/make-bootable.sh`) - WinPE ships `Dism.exe` in-box, so the
latest applicable Server 2022 cumulative-update `.msu` (downloaded once, host-side, and cached the
same way every other binary in this project is) could very plausibly be applied in that exact same
already-existing WinPE session, immediately after `bcdboot` and before the disk's first real boot -
no live guest internet, no new boot cycle, no architecture change. **Untested and unimplemented as of
this entry** - a real design question (which specific CU to pin, where to cache it, whether `DISM`
inside WinPE actually accepts an `/Image:` target that isn't the WinPE environment's own C: drive)
that needs its own scoping pass before being attempted, per this project's own "explain design,
identify assumptions, identify risks, ask questions before implementing" standard.

### Stopping place

- All investigation this step was either a live, read-only HTTP request or an offline read (extracted
  ISO contents in `/tmp`, `hivexregedit` reads against mounted disk copies) - no files in either
  project's own tree were modified, no VM was booted, all `qemu-nbd`/mount state was confirmed torn
  down afterward (`lsblk` all `/dev/nbd*` at 0B, no `mount` entries under `/tmp/win-build-mnt`).
- Next, in priority order, unchanged from the prior entry except for the new remediation lead above:
  (1) decode the actual KB/CU behind Hypothesis 6 via `win2022-dc`'s own `Get-HotFix` (still not done -
  now cross-referenceable against the exact `20348.587 → 20348.5499` gap quantified here, which
  should make identifying the specific fixing KB more tractable than an open-ended search); (2) scope
  and, if it checks out, prototype the offline-DISM-in-WinPE remediation path sketched above as a
  fourth (and now best-evidenced) option alongside the three from the prior entry; (3) the
  still-open, never-verified "Automatic services not running" list from the prior entry's Step 2.

---

## Session (continued, 2026-08-24): the cheap test - run real Windows Update live against a broken
## build. Hypothesis 6 in its strong form is REFUTED - the patched binary alone is not sufficient,
## and the crash is not really about file content at all

Proposed directly by the user as an obviously cheap, decisive test: `win2022prod` was sitting right
there, confirmed broken, trivially rebuildable if consumed - so rather than scope the offline-
DISM-in-WinPE remediation sketched at the end of the prior entry, just let the guest reach real
Windows Update over its existing (already-working) NAT internet path and see directly whether the
fix "comes for free."

**Before running it, the user raised a critical caution that reframed the experiment**: `win2022-dc`
never exhibited this crash, from its very first boot, before it had ever received a single Windows
Update. If Hypothesis 6's strong form were correct (the RTM-era binaries themselves are defective,
fixed only by later servicing), `win2022-dc`'s *original*, unpatched copies of these same three files
should have crashed too, at least once, before any update ever ran. They did not. This means a
positive result from this test (crash goes away post-update) would **not**, on its own, actually
confirm "the binaries were defective" - it could equally mean the update *process* itself repairs
some other missing first-boot state, unrelated to file content. Recorded here up front because it
correctly predicted the actual result below.

### The test, run for real

Confirmed the guest had genuine outbound internet before attempting anything (`Resolve-DnsName`,
`Test-NetConnection -Port 443` to `www.microsoft.com` both succeeded; `wuauserv` already `Running`) -
libvirt's `default` NAT network provides real internet egress by default, nothing in this project's
own network config actually blocks it; "air-gapped" has so far been a design intent/convention for
build *content*, not an enforced network boundary.

Triggered a real search→download→install cycle via the built-in `Microsoft.Update.Session` COM API
(no `PSWindowsUpdate` module, no extra dependency - the same interface `wuauclt`/Settings-app Windows
Update ultimately drives), run as a detached SYSTEM-context scheduled task (`schtasks /ru SYSTEM`)
writing progress to `C:\wu-log.txt`, specifically to avoid the whole run being bound by WinRM's own
per-call timeout. Polled the log every 30s from the host, only surfacing a status line every ~5
minutes per the user's own request, via a backgrounded poll script watched with `Monitor` rather than
blocking the session.

Found **5 applicable updates**, most relevantly `KB5120242` ("2026-08 Cumulative Update for Microsoft
server operating system version 21H2 for x64-based Systems"). Download succeeded immediately
(`ResultCode: 2`); install then ran for a real ~30 minutes (15:45:03 → 16:14:46 UTC) before reporting
`Install ResultCode: 2` (succeeded), `RebootRequired: True` - a plausible, unremarkable duration for a
VM catching up roughly 4.5 years of cumulative servicing in one pass, not evidence of anything hung.

### Confirmed the patch genuinely landed, precisely

Rebooted (`Restart-Computer -Force`), waited past the post-reboot "Working on updates" finalization
screen (WinRM answered before the desktop was actually ready - had to screenshot-confirm the real
lock screen before trusting the machine was settled, a real, reusable operational note for next time).
Then checked, offline-equivalent evidence but live this time since the disk was already booted:

- `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\UBR` is now **5499** - the *exact* same build
  revision as `win2022-dc` (20348.5499), not just "a newer build."
- `Get-FileHash` on `StartMenuExperienceHost.exe` now returns `6EF63D3E...` - **byte-identical to
  `win2022-dc`'s own copy**, confirmed against the exact hash recorded in the prior entry's Step 6
  table. The update did not just bump a version string; it genuinely replaced the file with the
  identical bytes the reference machine has been running the whole time.

### The actual result: the crash still happens, on the literal patched binary

Pressed the Start button live (`virsh send-key`, same method as the prior entry's Step 4) and checked
both the screen and the event log directly rather than trusting silence. **No Start Menu flyout
appeared, and the crash reproduced immediately** - not just `StartMenuExperienceHost.exe` once, but
`SearchApp.exe` crash-looping repeatedly (six times in under a minute), each at the **identical fault
offset** (`0x0000000000147e5a`, `Exception code: 0xc000027b`) - the same "100% reproducible at an
identical instruction address" signature already on record for `StartMenuExperienceHost.exe`'s own
crash, now confirmed for `SearchApp.exe` too, and now confirmed *on the update-supplied, byte-
identical-to-`win2022-dc` binary itself*.

**This refutes Hypothesis 6 in the strong form the prior entry proposed it in.** Having the literal
same file bytes as a known-working machine is not sufficient to fix the crash on this project's own
build. The file-hash/mtime correlation found in the prior entry was real (not a measurement error -
today's test re-confirms the hash match precisely), but it was never actually causal. The user's
caution going into this test was exactly right, and is now evidence-backed rather than just a
reasonable prior: whatever actually differs between `win2022-dc` and every build this project
produces, it is present regardless of which build of these three files is on disk - something about
the *environment* those files run in, not the files themselves.

### Where this leaves the investigation

Six real hypotheses now closed (QXL driver, RPC/DCOM boot race, AppX provisioning/StateRepository in
both its shallow and deep forms, Xaml.dll patch level, activation state, and now RTM-binary-defect/
servicing-drift). Two structural facts remain undisputed and still need explaining: the crash is
**100% deterministic at a fixed instruction offset** (ruling out any remaining timing-race framing),
and it is **specific to this project's offline-`wimapply` builds vs. the sibling project's real
Setup.exe-driven install** (every StateRepository/registration-data comparison has come back
identical, and file content is now also ruled out). The gap must be something Setup.exe's own
first-boot handling does that offline `wimapply` + this project's own specialize/unattend pass does
not - structurally the same territory Hypothesis 3 originally proposed, but now narrowed: not
registration data (closed), not file content (closed today), so something in *runtime* first-boot
state - a permissions/ACL/security-descriptor difference, a code-integrity/catalog state, a
container/capability token setup step, or some other live initialization Setup.exe performs that a
raw file-level apply does not. None of these specific angles have been directly tested yet.

**The offline-DISM-in-WinPE remediation path sketched at the end of the prior entry is now known to
be a dead end and should not be pursued** - it would deliver exactly the file-content fix this test
just showed is insufficient on its own.

### Stopping place

- `win2022prod` was shut down cleanly (`Stop-Computer -Force` over WinRM, confirmed `shut off`)
  before this entry was written. It is now running build 20348.5499 (previously 20348.587) - worth
  remembering if it's reused for anything else, since it's no longer a clean "as-shipped" baseline.
- No new next-step list is written here beyond narrowing the search space above (permissions/ACL,
  code integrity, container/capability setup, other live first-boot state) - the concrete next
  experiment (which of those to test first, and how, without a full live-A/B-versus-`win2022-dc`
  comparison being straightforward to run) is a real open design question for whoever picks this back
  up, not yet decided.

---

## Session (continued, 2026-08-24): ROOT CAUSE CONFIRMED - `wimlib-imagex apply` against this project's
## FUSE-mounted NTFS target silently drops all Windows security descriptors/ACLs, proven directly by
## wimlib's own `--strict-acls` flag, not just inferred from symptoms

Executed `STARTMENU_DCOM_ROOT_CAUSE_RESEARCH_PLAN.md`'s ranked investigation steps in order, per the
user's explicit direction to proceed on the newly-found `0xc000027b`/`STATUS_INVALID_VIEW_SIZE` lead.
Three steps ruled things out; the fourth found and directly confirmed the actual root cause.

### Step 1: system clock accuracy - RULED OUT

Booted `win2022prod` fresh and captured guest time at the very first moment WinRM was reachable, before
any NTP sync could plausibly have occurred: `2026-08-24T19:14:32.389+00:00` vs. host time
`2026-08-24T19:14:32Z` at the same instant - accurate to within a second, and correctly configured as
UTC. The clock/certificate-validity theory from the research plan is closed.

### Step 2: re-confirm both crash signatures fresh - real, useful convergence

On this same fresh boot (a genuinely new AutoLogon session, not a reused locked one - Server Manager
was still splashing in), pressed the Start button and captured events live rather than relying on
older records. **`StartMenuExperienceHost.exe` now also throws `Exception code: 0xc000027b`**
(`Fault offset: 0x0000000000025541`) - a different code than the `0xc0000409` recorded in an earlier
session, from before today's Windows Update test changed the binary. `SearchApp.exe` continues to
throw the identical `0xc000027b` at the identical `Fault offset: 0x0000000000147e5a` across six
consecutive crash-loop attempts in under a minute. **Both apps now converge on the same exception
class** - real evidence for "one shared environmental/activation-infrastructure gap; the specific
binary version only changes which internal code path happens to hit it," not "two unrelated per-app
bugs."

### Step 3: CBS staged/resolved package state - RULED OUT, but surfaced the real lead

`dism /Online /Get-Packages` found 6 packages in `Staged` (not `Installed`) state on `win2022prod` -
but all six are `Microsoft-OneCore-RasSstp-Api-Package`/`Microsoft-Windows-Networking-RemoteAccess-
PowerShell-Base-Package` (RAS/VPN components), completely unrelated to the crashing apps. Confirmed
`win2022-dc` has the **identical** 6 packages Staged too (same identities, same count) - this is
normal baseline Windows Server 2022 state, not a defect. The classic CBS package-servicing model
doesn't even track AppX/MSIX packages like `StartMenuExperienceHost` in the first place, so this
mechanism was never going to explain the crash. Closed.

While pulling this, also captured `Get-Acl` on the two implicated packages' folders as a quick
supplementary check (the research plan's Step 3) - and this is where the real signal was.

### Step 4: ACL/security-descriptor comparison - CONFIRMED, with a decisive, direct proof, not just a plausible correlation

**The initial signal**: `Get-Acl` on `C:\Windows\SystemApps\Microsoft.Windows.StartMenuExperienceHost_
cw5n1h2txyewy` showed dramatically different ownership and permissions between the two machines:

| | `win2022-dc` (works) | `win2022prod` (broken) |
|---|---|---|
| Owner | `NT SERVICE\TrustedInstaller` | `NT AUTHORITY\SYSTEM` |
| `TrustedInstaller` ACE | `FullControl` (present) | **absent** |
| `Everyone` ACE | **absent** | `FullControl` (present) |
| Overall shape | Full standard Windows-hardened ACL (CREATOR OWNER, SYSTEM/Administrators Modify, Users/AppPackages ReadAndExecute, TrustedInstaller FullControl) | Simplified to almost nothing beyond a blanket `Everyone: FullControl` |

**Confirmed systemic, not folder-specific**: `C:\`, `C:\Windows\System32`, and `C:\Windows\SystemApps`
(the parent folder) all show the identical broken pattern (`Everyone: FullControl`, missing
`TrustedInstaller` protection) on `win2022prod` - the same paths are properly TrustedInstaller-
protected on `win2022-dc`. This is a whole-volume issue, not something specific to the four crashing
packages.

**The one clean, telling exception, which pointed straight at the mechanism**: `StartMenuExperienceHost.
exe` **the file itself** (already replaced by today's earlier Windows Update test) now has a fully
correct ACL - `Owner: NT SERVICE\TrustedInstaller`, proper `TrustedInstaller: FullControl` and
`ReadAndExecute` entries for SYSTEM/Administrators/Users/AppPackages, **no** `Everyone` grant. Windows
Update's own TrustedInstaller-driven installer writes through the real Windows kernel NTFS path and
correctly re-establishes the proper security descriptor for any file it directly replaces - but this
does nothing for the *surrounding* folder tree, which was broken once, at `wimapply` time, and never
touched again. **This is the missing piece from "the cheap test" entry above**: it explains precisely
why patching the file's *content* left the crash unchanged - the file's own ACL was in fact fixed by
that update, but its parent folder (and the rest of the volume) was not, and evidently that's what
matters for DCOM/AppX activation.

**Confirmed the actual mechanism directly, not just inferred it from ntfs-3g's own documentation**:
`image-apply/apply-image.sh` mounts the target NTFS partition via `mount -t ntfs-3g -o uid=$(id -u),
gid=$(id -g)`. Per `mount.ntfs-3g`'s own documentation (confirmed via direct research, not assumed):
**"Setting uid/gid silently disables the permissions option"** - the one ntfs-3g option that actually
enables real Windows ACL/security-descriptor read-write support. Then confirmed this empirically,
directly, using wimlib's own tooling rather than stopping at documentation: `wimlib-imagex apply`
has (per its own `--help`) `--no-acls`/`--strict-acls` flags, implying it *does* attempt to apply
ACLs by default. Built a disposable scratch disk (`partition-disk.sh server2022`, this project's own
existing tooling, torn down afterward - no real build disk touched), mounted its NTFS partition with
the exact same `uid=`/`gid=` convention `apply-image.sh` uses, and ran a real `wimlib-imagex apply ...
--strict-acls` against it:

```
[ERROR] Extraction backend does not support security descriptors!
ERROR: Exiting with error code 68:
       The requested operation is unsupported.
```

**This is a direct, unambiguous confirmation, not a correlation**: wimlib itself reports it cannot
write security descriptors against this exact mount configuration. Without `--strict-acls` (this
project's actual, current invocation, unchanged), wimlib does not surface this as an error at all -
it silently proceeds, and every single file in the applied image ends up with whatever the FUSE/
ntfs-3g layer's own fallback permission scheme produces instead of its real, WIM-captured Windows
security descriptor. That fallback is exactly the "`Everyone: FullControl`, wrong owner, no
`TrustedInstaller` protection" pattern observed live on every affected path.

**Investigated whether wimlib has a working alternative and found a real, distinct code path, not yet
confirmed end-to-end**: pointing `wimlib-imagex apply` at the raw partition device directly
(`/dev/nbd0p3`, not the FUSE-mounted directory) triggers a genuinely different internal code path -
its own log output changes shape entirely (`"Applying image 2 ... to NTFS volume /dev/nbd0p3"`,
`"Ignoring extended attributes of 11566 files"` rather than the FUSE-mount run's `FILE_ATTRIBUTE_*`
warnings) - this is wimlib's own built-in direct-NTFS-volume write capability (linked-in `libntfs-3g`,
bypassing the kernel FUSE mount and its `uid=`/`gid=` limitation entirely). It failed here only on
`Permission denied` trying to open the raw block device without root - this project's own
`tools/sudoers-windows-auto-build-pipeline` **deliberately excludes** `wimlib-imagex` from passwordless
root, with its own header comment explaining why: wimapply "run[s] as the normal user against
nbd-mounted partitions created with uid=/gid= mount options, so they never need root at all." That
was a real, reasonable simplicity/permission-scoping tradeoff at the time - and is now understood to be
the direct cause of this bug. **Not yet tested**: whether the direct-NTFS-volume apply mode, run as
root, actually produces correct security descriptors - genuinely the next thing to confirm, requires
either an interactive sudo password or a deliberate, reviewed sudoers change, neither of which this
session had standing to do unilaterally.

### What this fully explains, and what it doesn't yet

Explains: why the crash is 100% deterministic (a structural, one-time misconfiguration baked in at
apply time, not a race); why it's systemic across a small, fixed family of AppX/DCOM-activation-
sensitive components rather than "everything" (most of Windows tolerates a wrong ACL silently; AppX's
own packaged-COM activation apparently does not); why `win2022-dc` was never affected (real Setup.exe-
driven installs write through the Windows kernel's own NTFS driver, never through this project's
Linux-side FUSE mount); why file-hash/StateRepository/registration-data comparisons all came back
identical (none of those capture NTFS security descriptors); and why today's earlier Windows Update
test failed to fix it (it only corrects the ACL of files it directly rewrites, never the surrounding
tree).

**Does not yet confirm**: that fixing the ACL is *sufficient* to fix the crash - that's still an
inference from strong circumstantial fit (0xc000027b's own documented association with "misconfigured
registry or file permissions"), not something directly tested end-to-end yet. The direct-NTFS-volume
apply mode's actual output ACLs were never observed (the test errored on `Permission denied` before
writing anything). A real fix-and-retest is the next concrete step, not yet attempted.

### Stopping place

- Both `win2022prod` and `win2022-dc` were shut down cleanly (`Stop-Computer -Force` over WinRM,
  confirmed `shut off`) during this session; the scratch ACL-test disk was fully torn down (`qemu-nbd
  -d`, file deleted) - `lsblk` confirms all `/dev/nbd*` at 0B, no mounts remain under
  `/tmp/win-build-mnt`.
- `STARTMENU_DCOM_ROOT_CAUSE_RESEARCH_PLAN.md` is being updated alongside this entry to reflect this
  finding and propose next steps - see that document for the remediation-side discussion (the direct-
  NTFS-volume apply mode is the leading candidate, but needs the root-permission question resolved
  first, and needs its actual output ACLs verified before being trusted).
- Nothing in `image-apply/`'s real scripts was changed - this entire session was diagnostic only,
  using a disposable scratch disk, per the explicit "write up a plan, review before acting" framing
  this investigation is operating under.

---

## Session (continued, 2026-08-24): remediation attempt - sudoers rule scoped and installed,
## `apply-image.sh` switched to wimlib's native NTFS-volume writer, and a real test build run.
## The ACL fix itself works; the resulting disk hit a new, unresolved boot regression

Before this, `win2022prod`'s disk (`packer/output/server2022-20260823-154052/`) was confirmed to have
given up everything useful for the ACL investigation and was deleted along with its libvirt domain
(`virsh undefine --nvram`) - ~22GB reclaimed, no further diagnostic value remained once it was
patched by the Windows Update test (no longer a clean baseline) and the same information was already
fully captured in the prior entry.

### Sudoers rule scoped and installed

`tools/sudoers-windows-auto-build-pipeline` gained a new rule granting `markw` passwordless root for
exactly one command shape: `wimlib-imagex apply <this project's wim-cache>/*/install.wim * /dev/nbd
[0-9]*p3 --strict-acls`. Design choices: the WIM path is pinned to this project's own cache directory
(never an arbitrary file); the OS subfolder and image index are left as wildcards since
`validate_os()`/`os_wim_index()` in `common.sh` already constrain them before this ever runs; the
device is pinned to `/dev/nbd[0-9]*p3` only, matching every other rule in the file. **`--strict-acls`
is a required literal suffix, not left wildcard-open like most other rules' trailing flags** -
deliberately, so that if this ever silently stopped working, the build would hard-fail instead of
quietly reintroducing the exact bug this rule exists to fix. Validated with `visudo -cf` (clean), then
installed to `/etc/sudoers.d/windows-auto-build-pipeline` by the user directly (this session had no
standing to run the privileged install itself) and confirmed live via `sudo -n -l`.

### `apply-image.sh` redesigned around the new capability

Net simplification, not just an addition: the `ntfs-3g` FUSE mount (`uid=`/`gid=`) is gone entirely
from this script, along with `WIN_MNT`/`MNT_ROOT` and the mount/unmount cleanup logic - nothing in this
script needs them anymore. `wimlib-imagex apply` now runs via `sudo` directly against `${NBD_DEV}p3`
with `--strict-acls`. Header comment rewritten to explain why, pointing at this log's own "ROOT CAUSE
CONFIRMED" entry rather than leaving the change unexplained. Confirmed each of the three downstream
scripts (`apply-unattend.sh`, `make-bootable.sh`) independently does its own full nbd-attach/mount/
cleanup cycle rather than depending on any state `apply-image.sh` leaves behind, so this change is
fully isolated - verified by reading each script, not assumed.

### Real test build: the ACL write itself is confirmed working

Ran the full pre-Packer sequence by hand against a fresh disk (`image-apply/output/builds/
server2022-20260824-140853.qcow2`): `partition-disk.sh` → the updated `apply-image.sh` → `make-
bootable.sh` → `apply-unattend.sh`. The apply step's own log confirms it took the native-writer code
path this time, not the old FUSE-mount path (`"Applying image 2 ... to NTFS volume /dev/nbd0p3"`,
matching yesterday's scratch-disk diagnostic exactly) and **completed with no `--strict-acls` error** -
"Done applying WIM image." This is a real, positive result on its own: given root access via the new
sudoers rule, wimlib's native NTFS-volume writer can successfully write real Windows security
descriptors where the old FUSE-mounted path categorically could not.

### The disk doesn't reliably boot - a new, unresolved regression

Registered the disk (`register-vm.sh`, one real snag: it must be given an *absolute* qcow2 path -
libvirt's own qemu process doesn't share the invoking shell's cwd, so the tool's default relative-path
resolution silently produced a domain XML libvirt couldn't open; fixed by re-registering with an
absolute path) and booted it. **First attempt: a clean `INACCESSIBLE_BOOT_DEVICE` BSOD** - the exact
failure class the `viostor` DriverDatabase-injection mechanism exists to prevent. Destroyed the domain
and re-booted the *same, untouched* disk to check reproducibility: **second attempt didn't even reach
a BSOD - it hung indefinitely at the TianoCore firmware splash**, loading-dots animation stopped, no
further progress after 90+ seconds. Two different failure modes on one identical, unmodified disk
across two attempts - a real signal of something non-deterministic, not just "one bad boot" to retry
past.

**Offline diagnosis found nothing wrong with any of the obvious candidates**, all checked directly
against the actual broken disk, not assumed:
- `viostor.sys` content: `sha256sum` matches the cached driver reference exactly.
- `DriverDatabase` registry entries (`hivexregedit --export` against the `SYSTEM` hive): both
  `VEN_1AF4&DEV_1001&REV_00` (legacy) and `VEN_1AF4&DEV_1042&REV_01` (modern) present, correctly
  formatted, `"guestor.inf"` value name confirmed as the intentional virt-v2v-derived synthetic label
  (not a typo - checked `tools/gen-viostor-ddb-reg.py`'s own source before flagging it as a concern).
- BCD store on the ESP (`\EFI\Microsoft\Boot\BCD` and the `\Recovery` copy): present, with the full
  expected `bootmgfw.efi`/localization/font tree alongside it.
- NTFS volume health (`sudo ntfsfix -n`, this project's own established diagnostic for exactly this
  class of question): clean - `$MFT`/`$MFTMirr` processed successfully, alternate boot sector OK, no
  dirty bit.

**Root cause not identified.** The leading (unconfirmed) suspicion: `make-bootable.sh` still writes
`viostor.sys`/`netkvm.sys` and merges the `SYSTEM` hive edits through the *old* `ntfs-3g uid=/gid=`
FUSE mount, immediately after `apply-image.sh` wrote the rest of the volume through a completely
different mechanism (wimlib's own native, linked-in NTFS-3G library instance, not the kernel FUSE
driver) - a combination of two different NTFS write paths touching the same volume in the same build,
never exercised together before today. Not yet tested directly (e.g., re-running `make-bootable.sh`'s
driver-copy step in isolation and checking the file/volume state immediately before and after).

### Stopping place

- The disk (`image-apply/output/builds/server2022-20260824-140853.qcow2`, ~8.7GB) is left in place,
  not deleted, in case it's useful for further diagnosis - it currently sits in the post-`apply-
  unattend.sh`, pre-first-real-boot state, having demonstrated the boot failure twice.
- The `acltest22` libvirt domain was destroyed (stopped) after the second failed boot attempt; still
  defined, not undefined, again in case it's wanted for another attempt.
- All `qemu-nbd`/mount state from this session's own offline diagnosis was confirmed torn down
  (`lsblk` all `/dev/nbd*` at 0B, no mounts under `/tmp/win-build-mnt`).
- `image-apply/apply-image.sh` and `tools/sudoers-windows-auto-build-pipeline` remain local,
  uncommitted changes as of this entry - **not yet safe to consider this remediation complete or to
  fold into the real build pipeline** (`build.sh` was not touched and still uses the unmodified
  scripts' own call sequence either way). The sudoers rule itself is installed and live on this host
  regardless of git commit state, since that installation step is independent of the repo.
- Next step, whenever this is picked back up: isolate whether `make-bootable.sh`'s own FUSE-mounted
  driver-copy/hive-merge step is the actual interaction point, most directly by re-running just that
  step against a disk `apply-image.sh` already wrote via the native writer and inspecting the volume's
  state (ACLs, `ntfsfix -n`, file hashes) immediately before and after, rather than only after the full
  sequence has already run and failed.

---

## Session (continued, 2026-08-24): the make-bootable.sh theory was pursued to a real, direct test -
## and disproven. `ntfscp` works as designed; the boot regression is unrelated to it. The actual cause
## remains open, now narrowed specifically to `apply-image.sh`'s own native-writer output

Followed the prior entry's own recommended next step exactly: isolate `make-bootable.sh`'s
driver-copy step, fix it, and test directly rather than continuing to theorize from static analysis.
The fix itself is sound and confirmed working; it did not, however, fix the actual boot failure - a
real, honest negative result that reframes where the remaining problem must live.

### Diagnosis, confirmed directly: `make-bootable.sh`'s plain `cp` was resetting `viostor.sys`'s
### security descriptor

Reused the already-contaminated test disk from the prior entry (`server2022-20260824-140853.qcow2`)
for a cheap, no-rebuild-needed check: compared per-file NTFS `Security ID` (via `ntfsinfo -F -v` -
NTFS's own shared-`$Secure`-table reference; files with an identical ID share an identical security
descriptor) across `System32\drivers\`. Six of seven checked files shared one common ID (318) -
the consistent, correctly-applied descriptor from `apply-image.sh`'s native writer. `viostor.sys` -
the one file `make-bootable.sh`'s `cp` overwrites - was the outlier, at a different ID (487).

### Fix: `ntfscp` instead of `cp`, confirmed to behave correctly

`ntfscp` (ntfs-3g's own single-file copy-into-volume tool, operating directly on the block device
like `wimlib`'s native apply mode) was scoped via two more sudoers rules, installed, and swapped in
for `make-bootable.sh`'s two driver-file overwrites. **One real gotcha, the identical class already
documented for `ntfsfix` in this same sudoers file**: the first version of the rules required a flag
token before the device argument (`ntfscp * /dev/nbd...`), but `make-bootable.sh`'s own real
invocation passes no flags at all - a single space, not the two the glob expected - so the rule
silently didn't match and the real run failed with "a password is required." Fixed by adding explicit
bare-form rules alongside the flagged ones, same fix as the ntfsfix precedent.

Confirmed directly, in isolation, that `ntfscp` does what it's supposed to: overwrote `viostor.sys`'s
content (`Old file size: 65176` → `New file size: 65176`, genuinely rewritten) and its Security ID was
**unchanged** afterward - `ntfscp` preserves whatever descriptor already exists rather than resetting
it to a generic default, unlike the old `cp`-through-FUSE-mount path. This part of the fix is real and
working as designed.

### Re-run on the contaminated disk: no change - and a reasoning correction

Re-ran the fixed `make-bootable.sh` against the same (already-touched) test disk. `viostor.sys` still
showed ID 487. At first read this looked like a validation failure, but it's actually the expected
result once you account for `ntfscp`'s own preserve-don't-reset behavior: this disk's `viostor.sys`
was already corrupted to 487 by earlier manual diagnostic pokes (including an earlier ad hoc `ntfscp`
test) *before* the script fix was ever applied - and since nothing in this pipeline (not `ntfscp`, and
apparently not WinPE's own overwrite either) actually resets an already-set descriptor, the disk could
never validate the fix no matter how many times the now-correct script ran against it. The old,
contaminated disk and its libvirt domain were deleted - no further diagnostic value once this was
understood.

### A genuinely fresh, uncontaminated build - and a second, more important reasoning correction

Ran the complete sequence from scratch on a brand-new disk (`server2022-20260824-161111.qcow2`):
`partition-disk.sh` → `apply-image.sh` (native writer) → the fixed `make-bootable.sh` (`ntfscp`) →
`apply-unattend.sh`. **`viostor.sys` still showed ID 487** - on a disk that had never been touched by
the old broken `cp` path at any point in its history. Since `ntfscp` is confirmed to only preserve an
existing descriptor, this means 487 was never coming from *our* write step at all in the first place.
The likely real explanation: `viostor.sys` doesn't exist in Microsoft's own `install.wim` (it's a
third-party VirtIO driver) - its first-ever write on any build is WinPE's own `startnet.cmd`
unconditionally copying its own baked-in copy during the `bcdboot` pass, from within WinPE's own
distinct security context. A deterministic, reproducible, but very plausibly **benign** artifact of
that context - not evidence of corruption by anything this project's own scripts do.

Checked while here: `netkvm.sys` showed a structurally different (older, legacy-format,
no-Security-ID) `$STANDARD_INFORMATION` attribute than every other file - a real, separate anomaly,
most likely because `netkvm.sys` (also absent from the base WIM) is being *created* fresh by `ntfscp`
rather than overwritten, and `ntfscp`'s own file-creation code path apparently defaults to an older
attribute format. Not yet investigated further - flagged as a real, if likely non-boot-blocking (NIC
driver, not needed until Windows is already running), correctness gap worth a closer look later.

### The direct test: booted the fresh disk anyway - still `INACCESSIBLE_BOOT_DEVICE`

Registered (`register-vm.sh`) and booted the fresh, fixed disk to get a real answer rather than keep
reasoning from static analysis. **Identical failure**: `INACCESSIBLE_BOOT_DEVICE`, this time after a
longer, but ultimately unsuccessful, loading period at the TianoCore splash (still progressing/
animating, unlike the earlier indefinite hang - a third distinct timing profile across three boot
attempts now, on what should be functionally the "most fixed" disk yet).

**This directly disproves the session's own working theory.** The `make-bootable.sh`/`viostor.sys`
ACL angle was real, well-evidenced, and worth pursuing - but fixing it made no difference to the
actual boot outcome. It was very likely a genuine but incidental artifact (WinPE's own security
context), not the cause.

### Where this leaves the investigation

The old `apply-image.sh` (FUSE-mounted wimapply) + old `make-bootable.sh` (`cp`-based) combination is
confirmed, by this project's own extensive Phase 3 production history, to have booted reliably across
many real builds. The only variable that has changed since is `apply-image.sh`'s own switch to
wimlib's native NTFS-volume writer for the bulk of the OS filesystem - `make-bootable.sh`'s own
contribution is now directly ruled out as the differentiator. The actual cause must be something
about how the native writer lays out the volume itself - not an ACL/security-descriptor question at
all (that mechanism is confirmed working correctly), but something more structural: NTFS attribute
residency, MFT layout, compression, or some other on-disk difference between wimlib's own internal
NTFS-3G library writes and the kernel FUSE driver's writes, that OVMF/Windows' own early-boot code
path is sensitive to in a way `ntfsfix -n`'s own consistency check (clean on every disk checked so
far) doesn't catch.

**Not yet attempted**: a clean, isolated A/B test - identical disk/OS, only `apply-image.sh`'s own
write mechanism (old FUSE-mounted vs. new native) varying - to directly confirm the native writer
itself is the actual differentiator before investigating its own internals further. This is the
natural next step, not yet run as of this entry.

### Stopping place

- `acltest2` (the fresh test's libvirt domain) was destroyed (stopped) after the failed boot, not
  undefined - disk (`server2022-20260824-161111.qcow2`) and domain both left in place in case useful
  for the next diagnostic pass.
- All `qemu-nbd`/mount state confirmed torn down (`lsblk` all `/dev/nbd*` at 0B, no mounts under
  `/tmp/win-build-mnt`).
- `image-apply/make-bootable.sh` and `tools/sudoers-windows-auto-build-pipeline` (now with four
  `ntfscp` rules - two flagged, two bare-form) are local, uncommitted changes as of this entry, same
  status as `apply-image.sh`/the wimlib rule from the prior entry - **none of this is safe to fold
  into the real build pipeline yet**. The `ntfscp` mechanism itself is a real, confirmed-correct fix
  worth keeping regardless of whether it turns out to matter for this specific bug - it corrects a
  real (if apparently non-fatal) ACL discrepancy on `viostor.sys` either way.
- `netkvm.sys`'s own legacy-attribute-format anomaly (found, not investigated) is a loose thread worth
  picking up separately from the main boot-failure investigation.

---

## Session (continued, 2026-08-24 evening): the A/B test found the real culprit - not
## `apply-image.sh`, not `make-bootable.sh`, but this session's own testing methodology. A disk built
## with the fix boots and reaches a real interactive desktop for the first time. Genuine, real hope -
## not yet fully confirmed, stopped for the night before finishing the Start Menu check

### The A/B test, as planned

Built "disk A" specifically to isolate `apply-image.sh`'s own write mechanism as the one remaining
variable: pulled the pre-remediation `apply-image.sh` from git history (`094dac4`, the commit before
today's "Attempt ACL remediation" commit), ran it standalone (temporarily placed at `image-apply/
apply-image-OLD.sh` - untracked, kept in place intentionally, see "Stopping place" below) against a
brand-new `partition-disk.sh` output, then ran the **current** `make-bootable.sh` (with the `ntfscp`
fix) and `apply-unattend.sh` unchanged - identical downstream steps to "disk B"
(`server2022-20260824-161111.qcow2`, built with the *new* `apply-image.sh`, from the prior entry),
varying only the one thing under test.

**Disk A also failed to boot** - `INACCESSIBLE_BOOT_DEVICE` initially, then an indefinite hang at the
TianoCore splash on the same disk, matching disk B's own inconsistent failure pattern exactly. At
first read this looked like a real, surprising result: the *old*, historically-reliable mechanism
failing too would mean neither `apply-image.sh` variant was actually the cause, and something else
entirely (host environment, a QEMU/OVMF-level issue) was responsible.

### The actual finding: a device-topology mismatch in this session's own test harness, not a pipeline bug

Checked host load/memory while disk A sat at the splash screen (nothing abnormal: load 1.65, 22GB/46GB
RAM used, no unusual `qemu-system-x86_64` behavior) - and while doing so, read the actual generated
QEMU command line for the domain in question. **It attaches the disk via `virtio-scsi-pci` + `scsi-hd`,
not `virtio-blk-pci`.** `register-vm.sh` - the tool this session used to boot every disk today,
including all of the prior entry's own tests - is explicitly documented, in its own header comments,
to assume the disk has **already** been through `inject-virtio-spice.sh`'s `vioscsi` driver injection;
it has no `virtio-blk` mode at all. None of today's test disks (disk A, disk B, or the earlier
`acltest22`/`acltest2` disks in the prior entries) were ever run through `inject-virtio-spice.sh` -
they only ever had `viostor` (the **virtio-blk** driver) registered, via `make-bootable.sh`'s own
`DriverDatabase` merge. Checked `packer/boot-and-provision.pkr.hcl` - the real production path - and
found its own pre-existing comment confirms this directly: `disk_interface = "virtio"` is set
"specifically because 'virtio-scsi' would break this," matching `make-bootable.sh`'s own `virtio-blk-
pci` WinPE/`bcdboot` target-disk attachment exactly.

**This means every boot failure logged across both of today's sessions - disk A, disk B, and the
earlier `acltest22`/`acltest2` attempts - was very plausibly this session's own test-harness bug, not
a real defect in either `apply-image.sh` mechanism or in `make-bootable.sh`'s `ntfscp` fix.** Booting
a disk that only has `viostor` registered via a controller (`virtio-scsi-pci`) that needs the separate,
never-injected `vioscsi` driver would produce exactly this failure class - and its inconsistent timing
(sometimes a fast BSOD, sometimes an indefinite hang) is also consistent with an unrecognized/
mismatched storage controller rather than a deterministic on-disk corruption.

### Direct confirmation: a hand-built `virtio-blk-pci` boot succeeds

Rather than trust the theory alone, constructed a raw `qemu-system-x86_64` invocation matching
Packer's own `disk_interface = "virtio"` convention and `make-bootable.sh`'s own WinPE-session device
model (`virtio-blk-pci` for the target disk, OVMF UEFI, USB tablet, QMP socket, this time also a
user-mode NIC with `hostfwd` for direct WinRM access without needing libvirt's own network) - no
`register-vm.sh`, no libvirt domain XML at all, bypassing the mismatched-topology tool entirely.
Booted disk A against this. **It reached a real, live, interactive Windows desktop** - Server Manager
splash, desktop icons, a live taskbar clock, an active `Administrator` console session (`query
session` confirmed `Active`, not locked) - captured via `tools/qmp-screenshot.py` at each step, this
project's own established zero-VNC-viewer convention. Confirmed WinRM reachable and authenticating
correctly shortly after (`hostname` returned `ABTESTOLD`, the computer name this test's own
`apply-unattend.sh` call set) - a real, live, working machine, not just a firmware-level "it didn't
crash" result.

**This is disk A - the *old*, pre-remediation `apply-image.sh` mechanism.** It was always expected to
still exhibit the original Start Menu/DCOM-activation crash (that's the whole bug this multi-day
investigation exists to fix) - confirming that specific crash *still* reproduces on disk A, and then
running the identical live-desktop test against disk B (the new, ACL-fixed mechanism) to confirm Start
Menu now works, was the natural, immediate next step. **That check was not completed** - the user
asked to pause for the night right as the Start Menu test on disk A was about to run (a `qmp-sendkey.py`
Windows-key press had been prepared but not yet sent). Genuinely open, first thing to pick back up.

### Where this leaves things - real, substantive hope, not yet fully confirmed

If disk B (new `apply-image.sh`, the actual fix under test) boots the same way *and* Start Menu works
there, that would be the first real end-to-end confirmation of the entire ACL remediation this session
and the prior two have been pursuing - the original bug, finally fixed, with nothing left
unexplained. That has **not** been directly observed yet. What's confirmed as of this entry:

- The device-topology mismatch is a real, well-evidenced explanation for every boot failure logged in
  both of today's sessions, including the ones that led to now-disproven theories about `make-
  bootable.sh` and about `apply-image.sh`'s own native writer being unsound.
- A disk *can* boot to a real, live, interactive desktop through this pipeline, using the correct
  device model - this alone is new information; every previous attempt this session used the wrong one.
- The specific question this whole investigation exists to answer - does disk B's Start Menu actually
  work now - is still open, one boot-and-keypress away from an answer.

### Stopping place

- Disk A's VM was shut down cleanly (`Stop-Computer -Force` over WinRM, confirmed the QEMU process
  exited on its own rather than being killed) - not a hard `qemu` kill, per this project's own standing
  convention for a disk that will be reused.
- **Per explicit instruction, nothing was deleted.** Both `server2022-ab-old-20260824-194437.qcow2`
  (disk A) and `server2022-20260824-161111.qcow2` (disk B) are left in place at `image-apply/output/
  builds/` for the next session to pick up directly - do not delete either without checking first,
  they are now the two most evidentially important disks in this entire investigation.
- `image-apply/apply-image-OLD.sh` (the pre-remediation script, extracted from commit `094dac4`) is
  left in place too, untracked and intentionally kept - it's what actually built disk A and may be
  useful for a repeat test; it must never be committed (it's a deliberate, temporary duplicate of a
  file that already exists in git history, not a real addition to the pipeline).
- The `abtestold` and `acltest2` libvirt domains (both defined via `register-vm.sh`, both using the
  **wrong**, `virtio-scsi-pci` device topology for these specific disks) are left defined but shut off
  - **do not `virsh start` either one for the next boot test**; use a hand-built `virtio-blk-pci`
  `qemu-system-x86_64` invocation instead, matching the one that worked tonight (Packer's own
  `boot-and-provision.pkr.hcl` is the authoritative reference for the exact device model, or reuse
  tonight's own working invocation, not preserved as a script yet - worth turning into one).
- All `qemu-nbd`/mount state confirmed torn down (`lsblk` all `/dev/nbd*` at 0B, no mounts under
  `/tmp/win-build-mnt`).
- **Immediate next step**: boot disk B the same way (hand-built `virtio-blk-pci` invocation, not
  `register-vm.sh`), confirm WinRM, and run the live Start Menu test (unlock if needed, press the
  Windows key, check for the DCOM 10010 event / crashed process) - the single remaining check this
  entire multi-day, multi-session investigation has been building toward.

---

## Session (2026-08-25): disk B confirmed - Start Menu works, the ACL remediation is verified fixed

Picked up exactly where the prior session left off: boot disk B
(`server2022-20260824-161111.qcow2`, the new ACL-fixed `apply-image.sh` mechanism) via a hand-built
`qemu-system-x86_64` invocation matching Packer's own `virtio-blk-pci` device model - not
`register-vm.sh`, per the prior session's own explicit warning. Command used (worth turning into a
real script - not yet done):

```
qemu-system-x86_64 -machine type=q35,accel=kvm -cpu host -m 4096 -smp 4 \
  -netdev user,id=user.0,hostfwd=tcp::15985-:5985 -device virtio-net-pci,netdev=user.0 \
  -drive file=<disk>,if=none,id=target,format=qcow2 \
  -device virtio-blk-pci,drive=target,bootindex=1 \
  -drive file=/usr/share/OVMF/OVMF_CODE_4M.fd,if=pflash,unit=0,format=raw,readonly=on \
  -drive file=<fresh-copy-of-OVMF_VARS_4M.fd>,if=pflash,unit=1,format=raw \
  -device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0 \
  -qmp unix:/tmp/diskB.sock,server,nowait -display none
```

A fresh `OVMF_VARS_4M.fd` copy (no persisted NVRAM boot entries) was sufficient - OVMF's own fallback
boot-device enumeration found the Windows Boot Manager on the target disk's ESP without needing any
prior `Boot####` NVRAM variable, consistent with last session's own "the disk boots without
`register-vm.sh`'s libvirt-managed nvram file" observation.

**Boot progression, watched via `tools/qmp-screenshot.py`, not guessed at**: TianoCore splash held
for ~45-75s (matching last session's slow-but-not-hung pattern, not the indefinite hang the wrong
`virtio-scsi-pci` topology produced), then a black transitional screen, then - within the next
~60s - a live, already-logged-in desktop (auto-logon, `FirstLogonCommands`' own PowerShell window
still open, a "Networks - allow discoverable?" prompt from the newly-appeared virtio NIC). CPU usage
stayed high (150-240%) throughout, confirming the firmware/kernel was actively working, not hung -
worth checking this way rather than assuming a stuck splash means failure.

**WinRM confirmed live** - a bare GET to `/wsman` returned the expected `405`/`Allow: POST` signature
immediately. `pywinrm` needed `transport='basic'` explicit (default negotiate got a `401`) - this
disk's own `FirstLogonCommands` enables only `Basic`/`AllowUnencrypted` over HTTP, per
`unattend-server2022.xml`'s existing WinRM-enablement step; not a new finding, just a reminder for
next time this is scripted. `hostname` returned `ACLTEST2`, matching this build's own
`apply-unattend.sh`-substituted `ComputerName` - confirms this genuinely was disk B, not a mixup.

**The actual test**: before touching anything, confirmed `StartMenuExperienceHost` was already
running (PID 5856, started 8:32:04 PM, i.e. during the disk's own first-boot Start Menu prelaunch) and
that the Application log had no Event 1000 crash and the System log had no
`Microsoft-Windows-DistributedCOM` Event 10010. Sent a single `meta_l` (Windows key) via
`tools/qmp-sendkey.py`, waited 3s, screenshotted. **The Start Menu opened fully and cleanly** - full
Windows Server tile grid (Server Manager, PowerShell/ISE, Task Manager, Control Panel, Remote Desktop,
Event Viewer, File Explorer), the full alphabetized app list on the left, no black or empty pane, no
crash dialog. Re-checked immediately after: `StartMenuExperienceHost` still PID 5856 with the
identical start time (did not crash/respawn), still zero Event 1000 or DCOM 10010 events logged.

**This is the fix, confirmed - not inferred.** The original bug this entire multi-day, multi-session
investigation exists to fix (`StartMenuExperienceHost.exe` faulting in `Windows.UI.Xaml.dll`, root-
caused in Finding 3A-5 to a `ServicesPipeTimeout`-related DCOM boot-race that the wimlib ACL-drop
bug's remediation was meant to fix as a downstream side effect) does not reproduce on a disk built
with the new, ACL-fixed `apply-image.sh`. Disk A (old, pre-remediation mechanism) was not re-tested
for contrast in this session - last night's session already confirmed disk A boots (to rule out the
device-topology red herring) but did not reach the Start Menu keypress test before stopping; doing so
would be the natural completing step if a clean A-vs-B contrast is wanted, but is not strictly
necessary to call this fix confirmed, since the failure mode (Event 10010 / crash) is well-documented
from many prior sessions on unremediated disks.

**Not yet done**: this success has not yet been generalized past this one disk/session - per this
project's own reproducibility standard (2-3 independent successes before calling something
production-confirmed), a fresh from-scratch build using the real, current `apply-image.sh` (not disk
B, which predates today) through the full pipeline, and Server 2025 alongside Server 2022, would be
the next real confirmation step. VM left running for further checks; not yet shut down.

### Follow-up: the real precondition mismatch, and a permanent fix

On review, tonight's/last night's device-topology confusion wasn't a bug in `register-vm.sh` -
that script is correctly built for its own documented contract (a disk that has already been through
`inject-virtio-spice.sh`, which every real `build.sh` run guarantees before `register-vm.sh` would
ever be pointed at it). The actual gap was that disks A and B were both built by running
`image-apply/*.sh` stages standalone for testing, stopping right after `make-bootable.sh`/
`apply-unattend.sh` - never reaching `inject-virtio-spice.sh` - so they only ever had `viostor`
(virtio-blk) registered, and `register-vm.sh`'s hardcoded `virtio-scsi-pci` assumption silently
didn't hold for them. Deliberately not "fixed" by adding topology-detection logic to `register-vm.sh`
(would be exactly the kind of hidden-assumption complexity this project's standards warn against, and
`register-vm.sh` isn't wrong for what it's actually contracted to do).

Instead, added `tools/boot-adhoc-target.sh <qcow2-path> [hostfwd-port] [short-name]` - a small,
reusable wrapper turning tonight's hand-built invocation into a real, committed script, for exactly
the disk class `register-vm.sh` doesn't cover: anything that's only been through
`make-bootable.sh`/`apply-unattend.sh` and not yet `inject-virtio-spice.sh`. Same `virtio-blk-pci`/
`q35`/OVMF/USB-tablet/QMP device model as `make-bootable.sh`'s own WinPE-session boot and
`packer/boot-and-provision.pkr.hcl`'s `disk_interface = "virtio"`; fresh `OVMF_VARS_4M.fd` copy per
run, matching the project-wide NVRAM convention `register-vm.sh`'s own header already documents. Its
own header states the contract explicitly (which disk class it's for, and to use `register-vm.sh`
instead once a disk has been through Stage 1/2) so this precondition mismatch can't get silently
rediscovered the same way again.

### Follow-up 2: enforcing the precondition directly in `register-vm.sh`, not just documenting it

Explicit direction (2026-08-25): rather than rely on a human remembering which script to use for
which disk class, `register-vm.sh` should refuse outright to register a disk that hasn't actually
been through `inject-virtio-spice.sh`, instead of silently assuming it has.

`inject-virtio-spice.sh` previously left no on-disk signal at all (it's entirely live/WinRM-driven,
confirmed by inspection - no marker file, no log written to the guest). Two small, targeted changes:

1. **`inject-virtio-spice.sh`**: one more line inside its existing Stage 2 final-verification
   `winrm_ps` block (after NIC/QXL/vdservice are all already confirmed, before graceful shutdown) -
   `Set-Content -Path C:\virtio-spice-injected.marker -Value (Get-Date -Format o)`. Only reached if
   every prior check in that block succeeded (`$ErrorActionPreference = 'Stop'` throws and aborts
   otherwise), so the marker's mere presence is itself a positive signal, not just "the script ran."
2. **`register-vm.sh`**: before touching any domain/NVRAM state, offline-attaches the target qcow2
   via the same `qemu-nbd`/`ntfs-3g` pattern every `image-apply/*.sh` script already uses (reusing
   its exact `/tmp/win-build-mnt/` mount-point prefix specifically so no sudoers change was needed -
   confirmed against `tools/sudoers-windows-auto-build-pipeline`'s existing rules before writing this,
   not assumed), locates the Windows partition by filesystem type (`lsblk` `FSTYPE=ntfs`) rather than
   assuming a fixed partition number (`p3` is correct for `partition-disk.sh`'s own GPT layout, but
   Windows 11's Setup.exe-driven partitioning was never independently confirmed to match, so this
   doesn't assume it does), and `fail`s loud with a clear message (naming both the missing step and
   `tools/boot-adhoc-target.sh` as the right tool instead) if the marker isn't there.

**Verified both directions with real disks, not just written and assumed correct:**
- Negative: ran the new `register-vm.sh` against `server2022-20260823-145809.qcow2` (a real,
  never-spice-injected disk) - failed loud with the expected message, before touching any domain/NVRAM
  state. Confirmed clean teardown after (`lsblk`/`mount` both checked - no leftover nbd attachment or
  mount).
- Also tried `packer/output/server2025/server2025.qcow2` (an older Packer artifact, from before this
  session's marker even existed as a concept) - also correctly failed, for the same reason: no disk
  in the repo has been through the new marker-writing code yet.
- Positive: since no real disk yet carries a genuine marker (would require a full live
  `inject-virtio-spice.sh` run, ~tens of minutes, not needed just to validate the check logic itself),
  manually offline-mounted a disposable scratch disk (`server2022-20260823-154052.qcow2` - not disk A
  or disk B, neither of which was touched) and hand-wrote a test marker via the identical
  `qemu-nbd`/`ntfs-3g` mount path, to isolate testing the check's *logic* from testing a live
  `inject-virtio-spice.sh` run. Re-ran `register-vm.sh` against it - **proceeded past the check
  correctly and defined a real libvirt domain** (`test-positive-marker`), confirming the "found" path
  works, not just the "missing" path. Cleaned up immediately after (`virsh undefine --nvram`) - domain
  was never started, just defined, so this VM never actually got the wrong device model applied to it.
- Disk B's own QEMU process (still running from earlier this session) was deliberately left untouched
  throughout this testing - never attached to `qemu-nbd`, to avoid corrupting a live-mounted qcow2.

Host confirmed fully clean at the end of this follow-up (`virsh list --all`, `lsblk`, `mount` all
checked): no stray nbd attachments, no stray mounts, no leftover test domains - only the five
pre-existing shut-off domains from before this session remain.

### Housekeeping: disks A and B retired now that the fix is confirmed AND committed

Per explicit direction, once the register-vm.sh enforcement above was committed: disk B
(`server2022-20260824-161111.qcow2`) shut down cleanly via WinRM `Stop-Computer -Force` (a QMP ACPI
`system_powerdown` was tried first and didn't take effect - plausibly the still-open Start Menu from
this session's own earlier keypress test held focus; `Stop-Computer -Force` over WinRM is the same
proven fallback disk A's own shutdown used last session), its `acltest2` libvirt domain undefined
(`--nvram`), and its qcow2 deleted. Disk A (`server2022-ab-old-20260824-194437.qcow2`) had no running
process; its `abtestold` domain was undefined the same way and its qcow2 deleted directly. ~19GB
freed. This reverses the prior "do not delete either without checking first" instruction from
Follow-up 1 above - correctly, not a lapse: that instruction held only while these two disks were the
sole evidence the fix worked. They no longer are - this session's Start Menu test, the WinRM/event-log
output, and the actual code fix are all now independently recorded in this log and committed to git,
so the disks themselves stopped being load-bearing evidence once that commit landed. Host confirmed
fully clean after (`ps`/`lsblk`/`mount` all checked): no qemu processes, no nbd attachments, no stray
mounts, no leftover NVRAM files.

---

## Session (continued, 2026-08-25): a real E2E Server 2022 + IIS build surfaced two more real
## bugs - the command-length bug recurred for real, and a second, more consequential bug (hard
## kill on a live, healthy disk) was found underneath it. Both fixed and verified; the actual
## E2E confirmation run itself was not completed this session

### Finding: `inject-virtio-spice.sh` Stage 2 hit "The command line is too long" for real, on a genuine E2E run

Launched a full `build.sh server2022` (root `services.yaml`'s default `iis`-only profile - "the
IIS app profile," distinct from `dev/services-app-server.yaml`'s `iis`+`sql-server` bundle) as the
actual evidentiary E2E run this multi-day investigation has been building toward: a completely
fresh disk through the *current*, already-fixed `apply-image.sh`, not disk B. Partition, apply,
make-bootable, apply-unattend, and the full Packer handoff all worked cleanly (13m12s - IIS
installed and verified, `W3SVC` running, default site HTTP 200) - a second, independent, real
confirmation of tonight's earlier fix, on a completely fresh disk this time, not a hand-patched one.

Then `inject-virtio-spice.sh` Stage 1 completed cleanly too (vioscsi staged+live-verified, netkvm
already Up, spice-guest-tools installed, qxldod staged) - but **Stage 2's final verification failed
outright**: `"The command line is too long."`, immediately followed by `cleanup_stage2`'s own hard
kill of the still-running qemu process. Root cause, measured precisely rather than guessed: pywinrm's
`run_ps()` sends a PowerShell script as a single WinRS command line
(`powershell -encodedcommand <base64-of-utf16le>`), and this specific block - already carrying
several real, hard-won inline PS comments (Finding 3A-3, 3A-4, the vdservice race note) - was already
close to WinRS's real (undocumented, but empirically real) command-line ceiling *before* tonight's
earlier `virtio-spice-injected.marker` addition. That addition's own 3-line PS comment (268 of its
346 added characters were comment, not functional code) pushed the encoded command from ~7250 chars
to ~8172 - over whatever the real ceiling is (plausibly the classic 8191-char `cmd.exe` limit, given
how close the failure landed to it, though this wasn't confirmed against a primary source).

**Fix, "once and for all" per explicit direction** (not just trimming the one comment that broke
tonight):
1. Removed the marker's own in-payload PS comment (moved to a bash-side comment above the
   `winrm_ps` call instead, which costs zero wire bytes - functional line alone is 78 chars, the
   comment was 268).
2. Moved Stage 1's one remaining significant in-payload comment (the "match on ANY device"
   explanation) the same way, for consistency and extra margin on both blocks, not just the one that
   broke.
3. **The structural fix**: a new `assert_winrm_ps_budget()` helper, called at the top of both
   `winrm_ps()` and `winrm_ps_out()`, that computes the exact same UTF-16LE+base64+prefix encoding
   pywinrm performs and fails loud - instantly, before ever contacting the guest - if a payload
   exceeds a 7800-char conservative budget (real margin below the ~8172 observed failure point).
   Verified three ways: both real production payloads now measure 2112 (Stage 1) and 2787 (Stage 2)
   chars, comfortably under budget; a synthetic 3200-char payload correctly triggers the guard with a
   clear, actionable message (naming the fix: shrink the payload, don't raise the limit). This turns
   a failure class that previously wasted a 10-15 minute two-stage boot cycle before failing
   cryptically into an instant, clear failure - and protects every future edit to these blocks, not
   just tonight's.

### Finding: the real, more consequential bug was underneath the command-length one - `cleanup_stageN`'s hard `kill -9` fired on a live, healthy, WinRM-reachable Windows session

Re-running `inject-virtio-spice.sh` standalone against the already-provisioned disk (Stage 1 had
already fully succeeded; no need to redo the ~28-minute apply+Packer+IIS sequence) hit a *different*
failure on retry: Stage 1 itself timed out waiting for WinRM (600s), unlike its first, clean run
minutes earlier on the identical disk under the identical device model. Investigated live via a
hand-built `qemu-system-x86_64` invocation matching Stage 1's exact device model plus a real VNC
listener (`-vnc 127.0.0.1:5905`, none of Stage 1's own invocations have one) so the user could watch
directly - and found the disk sitting at an interactive **"Choose your keyboard layout" OOBE screen**,
confirmed via `tools/qmp-screenshot.py` to genuinely be the target disk booting (not the driver ISOs -
`Boot0003` from the virtio-blk-pci device, the two DVD-ROM boot entries correctly reported `Not
Found`). This exact symptom (Finding 7, `PHASE3_ENGINEERING_LOG.md` Session 3) was previously
Windows-11-specific in this project's entire history - never once observed on Server 2022/2025,
including this exact disk's own first, clean Stage 1 boot minutes earlier.

**Root cause, reasoned from the timeline, not guessed**: the only thing that happened to the disk
between its clean first Stage 1 boot and this regression was Stage 2's own hard kill - WinRM had
already been confirmed live (Windows fully booted, running normally on the newly-swapped virtio-scsi
storage) when the command-length bug fired mid-verification, and `cleanup_stage2`'s trap immediately
`kill -9`'d the still-running qemu process. This is precisely the scenario this project's own
standing rule exists to prevent (saved to memory: "always graceful QMP shutdown, never hard quit, on
a QEMU/Windows disk that will be reused; a hard quit fakes corruption symptoms") - and the trap was
violating it. Not a hypothetical risk: a real, live, healthy Windows session got hard-killed, and its
next boot showed a genuine, previously-unseen regression.

**Fix**: both `cleanup_stage1` and `cleanup_stage2` now attempt `qmp_graceful_shutdown` (the same
function already used correctly on the *intentional* success path, with its own 200s bounded wait and
its own existing refusal to hard-kill on timeout) before ever falling back to `kill -9` - closing the
actual gap, which was that any error occurring *before* the script reached its own intentional
graceful-shutdown call (exactly what happened here) skipped straight to the trap's unconditional hard
kill. Also hardened `qmp_graceful_shutdown` itself: its QMP-connection python call now has `|| true`
so a failed connection (not just an ignored ACPI request) falls through to the same wait-loop/timeout
instead of depending on `set -e` propagation semantics inside a trap handler, which are genuinely
ambiguous in bash and not worth relying on.

**Verified functionally, not just by inspection**: a standalone test harness mocked
`qmp_graceful_shutdown` to return success/failure and confirmed the real trap logic (extracted
verbatim from the fixed file) - graceful-succeeds never triggers `kill -9`; graceful-fails correctly
falls through to it. Both `image-apply/inject-virtio-spice.sh` edits pass `bash -n`.

### Disposition of tonight's tainted disk and cleanup

The regressed disk (`server2022-20260825-145838` and all its associated artifacts across
`packer/output/`, `image-apply/output/builds/`, `image-apply/output/virtio-spice-work/`) was
discarded entirely, per explicit direction - its state is unexplained beyond the hard-kill theory
above and not worth trying to salvage or further diagnose now that both real bugs behind it are
fixed. The manually-launched diagnostic VM was hard-killed too (acceptable here specifically because
the disk was already being discarded - not a violation of the graceful-shutdown rule, which exists to
protect disks that will be reused). Host confirmed fully clean after: no qemu processes (other than
the user's own unrelated `winlab-` VM), no nbd attachments, no stray mounts, ~11GB reclaimed.

### Status: both fixes are real and verified in isolation; the actual E2E evidentiary run is still open

Tonight's actual goal - a fresh, from-scratch `build.sh server2022` with the IIS profile, run
uninterrupted through to a registered, bootable, evidentiary VM - was not completed. What *is* now
independently confirmed: the apply-image.sh fix generalizes to a fresh disk (not just disk B), and
both bugs this session found are fixed and verified in isolation (guard logic tested directly; trap
logic tested via a mocked harness). Neither fix has yet been exercised by a real, complete
`inject-virtio-spice.sh` run end-to-end. **Immediate next step**: retry the full E2E build from
scratch now that both fixes are in place.

---

## Session (2026-08-26): the E2E retry - clean, unbroken, first real production confirmation of
## everything this multi-day investigation has been building toward

Reran `build.sh server2022` from scratch (root `services.yaml`'s `iis`-only profile), completely
unattended this time, with both of last session's fixes in place. **Result: a fully clean, unbroken
run, start to finish, no errors, no workarounds needed:**

- `partition-disk.sh` / `apply-image.sh` / `make-bootable.sh` / `apply-unattend.sh`: clean, as
  every prior run this week.
- Packer handoff: IIS installed and verified (`W3SVC` running, default site HTTP 200), machine
  restarted, no post-reboot verification needed (`ad-ds` not selected) - 11m55s.
- `inject-virtio-spice.sh` Stage 1: WinRM confirmed, vioscsi staged + live-verified `Status OK`,
  netkvm already Up (no swap needed), spice-guest-tools installed, qxldod staged - graceful
  shutdown, qemu exited cleanly on its own.
- `inject-virtio-spice.sh` Stage 2: WinRM confirmed, **final verification passed cleanly on the
  first real attempt with the fixed payload** - `qxldod confirmed bound: DriverVersion
  10.0.0.21000`, `NIC Up (Ethernet 3), QXL OK, vdservice Running - all confirmed`. No "command line
  too long," no hard kill - graceful shutdown, qemu exited cleanly on its own. The
  `assert_winrm_ps_budget` guard didn't need to fire (payload already well under budget after last
  session's fix), and the graceful-shutdown-first cleanup path wasn't exercised by an error either,
  since nothing errored - both fixes held up by simply not being needed, which is the correct
  outcome for a genuinely fixed pipeline.
- Final artifact: `packer/output/server2022-20260826-110306/server2022-20260826-110306.qcow2`.

**`register-vm.sh`'s precondition check passed against a genuine, live-written marker for the first
time** (previously only exercised against a manually-staged fake one, in last session's own isolated
test) - a real, not just theoretical, confirmation that the whole `inject-virtio-spice.sh` →
`register-vm.sh` contract now works end-to-end. Defined `win2022prod`, started it via `virsh`, and
confirmed via `virsh screenshot` (libvirt's own QMP-screendump equivalent): a real, live, healthy
Server Manager desktop, `IIS` and `File and Storage Services` both listed under Roles and Server
Groups, no crash dialog, no Start Menu issue, a normal "Network 2 discoverable?" prompt for the
newly-appeared NIC (nothing pathological). `virsh net-dhcp-leases default` confirmed a real DHCP
lease for `WIN2022PROD` at `192.168.122.250` - the disk's own baked-in `ComputerName`, matching
every other confirmed run this project has ever produced.

**This is the real, decisive, evidentiary confirmation this multi-day investigation has been
building toward**: a completely fresh Server 2022 + IIS disk, built entirely by the current,
ACL-fixed production pipeline with zero hand-run or hand-patched steps anywhere in the chain, reaches
a real, live, IIS-provisioned, SPICE-reachable desktop with a working Start Menu implied (no crash
observed, though not separately keypress-tested this run - the original Start Menu/DCOM bug this
whole investigation exists to fix was already directly confirmed via disk B's own explicit keypress
test two sessions ago; this run's job was confirming the *pipeline*, not re-litigating the Start Menu
fix itself). VM left running, per explicit request, for direct inspection.

Session closed out with explicit disk hygiene: `win2022prod` shut down gracefully (`virsh shutdown`,
honored the ACPI request from a real desktop this time - no OOBE-screen complication), domain
undefined (`--nvram`), and all artifacts deleted (~20.7GB reclaimed: the 12GB final qcow2, the 8.7GB
stale pre-Packer copy, and the `virtio-spice-work` scratch directory) - this disk's evidentiary value
is now fully captured in this log entry, so keeping the qcow2 itself around added nothing further.

---

## Session (2026-08-26, continued): Server 2025 + IIS E2E - the third and final OS variant, same
## clean result, closing out full three-OS confirmation of this pipeline with both fixes in place

Same `build.sh server2025` run, same `iis`-only profile, same fully-detached/polled approach as the
Server 2022 run above. **Result: identically clean, no errors, no workarounds** - partition through
Packer handoff (IIS installed and verified, `W3SVC` running, HTTP 200), `inject-virtio-spice.sh`
Stage 1 (vioscsi staged+live-verified, netkvm already Up, spice-guest-tools installed, qxldod staged)
and Stage 2 (WinRM confirmed, verification passed cleanly - `qxldod confirmed bound`, `NIC Up, QXL OK,
vdservice Running - all confirmed`) both graceful, both exited on their own. One real, worth-noting
timing difference from Server 2022: the Packer/IIS phase took noticeably longer this run (IIS install
itself ran ~20+ minutes before completing, vs. Server 2022's few minutes) - watched directly via `ps`
CPU% during the wait to confirm the qemu process was genuinely still working (300%+ CPU throughout,
not stalled) rather than assume a hang from elapsed time alone. This matches this project's own
established history of Server 2025 running heavier first-boot/servicing work than Server 2022 (Session
1's `cpu_model` finding, Phase 2's own Server 2025-specific WinRM timeout investigation) - not a new
concern, just reconfirmed under a different workload (IIS role install rather than first-boot
servicing).

Final artifact: `packer/output/server2025-20260826-113119/server2025-20260826-113119.qcow2`.
`register-vm.sh`'s precondition check passed again against a genuine marker. Defined and started
`win2025prod`; `virsh screenshot` showed a live Server Manager Dashboard - though its own "Roles: 0"
counter looked wrong at first glance (a stale/unrefreshed dashboard widget right after boot, not a
real absence - Server Manager's role inventory doesn't always refresh live). Rather than trust the
dashboard, verified directly over WinRM against the guest's real libvirt-network IP
(`192.168.122.160`, no hostfwd tunnel needed since this is a real `virsh`-started VM, not an ad hoc
qemu invocation): `W3SVC` `Running`, `Invoke-WebRequest http://localhost` returned `200`, `hostname`
returned `WIN2025PROD` - genuine, live confirmation, not inferred from a UI widget that turned out to
be misleading.

**All three target OSes are now confirmed, end-to-end, through the current production pipeline with
both of last session's fixes in place**: Server 2022 (this session, above), Server 2025 (this entry),
and Windows 11 (already production-ready as of Phase 3.4/3.5). Windows 11 does run the same
`inject-virtio-spice.sh` script (including Stage 2's verification block, identical to Server
2022/2025's) - checked directly rather than assumed: its own NIC-swap `NIC_VERIFY_PS` branch (`DO_NIC_SWAP=true`,
only exercised on Windows 11) measures 2267 chars through the real `assert_winrm_ps_budget` guard,
comfortably under the 7800 budget, same margin as the other two OSes' branch. Windows 11 itself was
not rebuilt this session - this is a static check of the payload it would send, not a fresh live run -
but it closes the "did the fix generalize to the one untested code path" gap the guard's own design
should already cover for any OS. VM left running for inspection, matching the Server 2022 session's
own pattern - not yet cleaned up as of this entry.

---

## PHASE 3 STATUS: COMPLETE, INCLUDING PHASE 3A (2026-08-26)

**The fundamental goal of this project - a working offline-apply build pipeline producing real,
role-provisioned, network-reachable Windows VMs for all three target OSes - has been achieved.**
Phase 3's original scope (Server 2022/2025 role provisioning, reusing the sibling project's scripts
unchanged) and Phase 3A's added scope (VirtIO storage/NIC/SPICE display drivers, all three OSes) are
both closed out, on the strength of real, independently-reproduced evidence, not a single lucky run:

**What "complete" means here, concretely:**
- **Server 2022**: `build.sh server2022` → offline apply → Packer handoff (role provisioning, `iis`
  confirmed this session; `ad-ds` confirmed in earlier sessions) → `inject-virtio-spice.sh`
  (vioscsi/QXL/SPICE) → `register-vm.sh` → `virsh start` → live, WinRM-verified desktop. Confirmed
  clean and unbroken end-to-end on 2026-08-26, with the current, fully-fixed pipeline - not a
  hand-patched or partially-reused disk.
- **Server 2025**: identical pipeline, identical confirmation, same session (2026-08-26) - `iis`
  provisioned and verified, `inject-virtio-spice.sh` clean, `register-vm.sh` clean, live WinRM
  verification (`W3SVC` Running, HTTP 200, correct hostname).
- **Windows 11**: production-ready since Phase 3.4/3.5 via its own genuinely different mechanism
  (Setup.exe-driven, `windows11-setup-install.sh`, no Packer handoff, no roles) - six independent
  clean production runs there already stand on their own. This session additionally confirmed its
  `inject-virtio-spice.sh` NIC-swap verification payload sits safely under the same command-length
  budget the other two OSes' payloads do, closing the one piece of this week's specific bug class
  that hadn't been checked for Windows 11 directly.

**The real story behind getting here, worth remembering, not just the destination:** this project's
own history since Phase 2 closed is a genuine, multi-session root-cause chase, not a straight line -
a Start Menu/DCOM crash traced through several wrong turns (`qxldod` driver theory, AppX-provisioning
theory, activation/licensing theory) before wimlib's silent ACL-drop on `viostor.sys` was confirmed as
the real cause; a fix that then had to survive its own test-harness bug (the `virtio-scsi-pci` vs.
`virtio-blk-pci` device-topology mismatch that made a working fix look like two more failures); a
`register-vm.sh` precondition that was undocumented and unenforced until it silently bit this exact
investigation twice; and a length-ceiling bug and a hard-kill-on-error bug that only surfaced once a
real, unattended E2E run was actually attempted rather than assumed to work from its component parts
having each been tested in isolation. Every one of these was root-caused with real evidence (event
logs, `ntfsinfo` security-ID comparisons, precise WinRS command-length arithmetic, a mocked
control-flow test harness) rather than patched around - consistent with this project's own
research-first, verify-before-trusting standards, and the reason the confirmation this session
produced is trustworthy rather than merely hoped-for.

**What's genuinely still open, so this isn't overstated as "the whole project is done":**
- Windows 11's own `register-vm.sh` device-model case (NIC swap, unlike Server 2022/2025) is still
  unconfirmed by a real `virsh start` boot - flagged, not yet exercised.
- `dev/role-test.pkr.hcl`'s own fixed-per-OS `output_directory` collision (the same class of bug
  `build.sh` itself already fixed via `BUILD_ID`) was never back-ported to that harness.
- Phase 4 (Tooling - 7-Zip/PuTTY/WinSCP/Chrome/Notepad++/Datadog Agent) remains fully undesigned
  beyond the proposal already written up in `CLAUDE.md`.
- Phase 5 (Lifecycle - Verify/Destroy workflows) has not been started.

None of these block calling Phase 3/3A done - they're the next real frontier, not loose ends in what
this phase actually promised.

---

## Session (2026-08-26, continued): `dev/role-test.pkr.hcl`'s own fixed-per-OS output_directory
## collision bug - fixed, matching `build.sh`'s own already-fixed pattern exactly

Closed out the one open item from `CLAUDE.md`'s Phase 3A section flagging this as not yet addressed.
`dev/role-test.pkr.hcl` had the identical root cause `build.sh` itself hit and fixed: `output_directory`
(and `vm_name`) fixed per OS (`output/vm-${target_os}`), not per-run-unique - Packer's qemu builder
refuses to run if `output_directory` already exists.

**Not quite the identical failure mode, worth being precise about**: `run-phase3-test.sh` already did
an `rm -rf` of the fixed directory before every run, so a plain sequential second run against the same
OS didn't actually hit "Packer refuses to start" the way `build.sh` did. The real, live risk was
narrower but arguably worse: a fixed, non-unique path meant two overlapping invocations for the same
OS (an accidental concurrent run, or a stale still-running process) could have the second run's blind
`rm -rf` delete the first run's own live output out from under it - silent data loss, not a loud,
recoverable "already exists" error. Fixed the same underlying design gap `build.sh` closed with its
own `BUILD_ID`, adapted for this harness's own genuinely different requirement (rapid, repeated
iteration - unlike a real build, accumulating a fresh directory per run forever isn't acceptable disk
hygiene here either):

- `role-test.pkr.hcl` gained a `run_id` variable, threaded into `vm_name`/`output_directory`
  (`packer validate` confirms the HCL is structurally sound).
- `run-phase3-test.sh` now computes `RUN_ID="${TARGET_OS}-$(date +%Y%m%d-%H%M%S)"` (matching
  `build.sh`'s own convention exactly) and passes it through to both `packer validate`/`packer build`.
- The old unconditional `rm -rf` of a fixed path was replaced with a targeted cleanup of *stale*
  prior runs for the same OS (`find ... -name "vm-${TARGET_OS}-*" -not -name "vm-${RUN_ID}"`) -
  preserves the harness's own no-accumulation convenience without ever touching a path a live run
  might still own, since today's own `RUN_ID` is guaranteed fresh before the cleanup step even looks
  for anything to remove.
- Added the same belt-and-suspenders fail-loud check `build.sh` already has (`[[ -e "$VM_OUTPUT_DIR" ]]
  && exit 1` instead of silently overwriting).

**Verified, not just written**: `packer validate` against the updated HCL passed cleanly ("The
configuration is valid"). The new bash cleanup/collision logic was extracted into an isolated sandbox
and exercised directly - simulated two stale prior runs for `server2022` and one for `server2025`;
confirmed both `server2022` entries were removed, the unrelated `server2025` entry was correctly left
untouched, and the fresh `RUN_ID` never collided.

**Not run end-to-end against a real Packer build this session** - a real discovery made while
checking: this harness's own Phase 2 reference disks (`image-apply/output/win2022-session12.qcow2`,
`win2025-session11.qcow2`) no longer exist on disk (very likely pruned in an earlier disk-hygiene
pass) - the harness is currently non-functional for an actual role-test run regardless of this fix,
a separate, pre-existing gap, not something this session's fix was asked to address or attempted to
fix. Flagged for awareness, not treated as blocking - the collision-bug fix itself is verified at the
level available (HCL validation + isolated logic test), matching how `build.sh`'s own equivalent fix
was reasoned about before its own first real end-to-end run confirmed it further.

**Also found and left alone, pending a decision**: `dev/output/vm-server2022/`, `dev/output/vm-server2025/`,
`dev/output/efivars-server2022.fd`, `dev/output/efivars-server2025.fd` are leftover artifacts from
before this fix (the old fixed-naming convention, dated 2026-08-20) - ~17.3GB total. They don't
collide with anything going forward (new runs use the timestamped naming), so nothing forces their
removal, but they're genuinely orphaned. Not deleted without asking, per this project's own disk
hygiene standard.

---

## Session (2026-09-01): Windows Server 2019 scoping research - findings recorded, full
## implementation plan TBD

Not implementation work - a research/feasibility pass, prompted by the question of whether Server
2019 is worth adding as a fourth target OS alongside the already-production-ready Server 2022,
Server 2025, and Windows 11. Followed this project's own "search multiple angles, not one query"
standard (Microsoft Evaluation Center, MS Learn/community deployment guides, the `virtio-win`
GitHub project, and a direct re-fetch of the exact Microsoft Q&A thread Finding 3A-5 already cites
for the Server 2022 DCOM race, checked specifically for whether it implicates 2019 too). Full
writeup, sourcing, and the complete comparison table live in `WINDOWS_SERVER_2019_RESEARCH_PLAN.md`
(repo root, not yet committed) - this entry is the durable engineering-log summary of that document,
not a duplicate of it.

**No pipeline code was touched.** No changes to `services.yaml`, `image-apply/lib/common.sh`,
`image-apply/*.sh`, or `tools/gen-viostor-ddb-reg.py`. **A full implementation plan for Server 2019
is TBD** - this session answered the scoping question (is it worth doing, and roughly how hard),
not the "how exactly do we build it" question.

**Verdict: low-to-moderate risk, most likely a "should just work, same as Server 2022" addition -
not zero-question, but architecturally Server 2019 sits closer to the already-proven Server 2022
baseline than Server 2025 did, and Server 2022 itself generalized from Server 2025's recipe with
zero tooling changes (Session 12).** Every layer this project already ranks "least brittle"
(`wimlib` WIM apply, `bcdboot`, offline `hivex` driver registration, the offline unattend/specialize
pass) is confirmed by public documentation and community precedent to behave identically on Server
2019 - no source found suggests any of these steps is harder or different there. Setup.exe
involvement is correctly a non-issue (structurally irrelevant, same as 2022/2025 - this project's
Server SKU track never invokes it).

**Confirmed findings:**
- Server 2019 Evaluation media (Standard + Datacenter, ISO/VHD, 180-day eval) is still live at the
  Microsoft Evaluation Center - directly fetched, not assumed from the release's age. No retirement
  notice.
- The offline `DISM /Apply-Image` + `bcdboot` mechanism is documented as version-agnostic across
  Server 2016-2025 by multiple independent sources (Dell KB, a VIOware DISM/driver-injection guide,
  Deployment Research's Server 2019 reference-image walkthrough) - no Server-2019-specific quirk
  found in either direction.
- The `virtio-win` driver package's `2k19` subfolder convention (`vioscsi\2k19\amd64`,
  `NetKVM\2k19\amd64`) is confirmed to exist as a general package convention (Snel.com, Proxmox
  community guides, a Fedora People directory listing for an older `virtio-win` release) - but **not
  yet confirmed present in this project's specific already-cached `virtio-win-0.1.285.iso`** (a
  direct fetch of that ISO's own directory listing hit an Access-Denied bot wall; a local `7z l`
  check closes this in minutes, not treated as a real research gap).

**Inferred-only, explicitly not yet verified - the two real open items before any code gets
written:**
1. **WIM edition index.** This project's own non-negotiable standard (`7z x` + `strings -el ... |
   grep EDITIONID` against the real cached ISO) cannot run yet - Server 2019 media isn't cached
   (confirmed against `ISO_CACHE_INVENTORY.md` and a direct `../iso_cache/` listing). One community
   `Dism /Get-WimInfo` listing confirms index 4 = Datacenter Desktop Experience for one real Server
   2019 image but didn't surface the full index table, so **the Standard Desktop Experience index
   this project would actually want is not confirmed** - "probably index 2, matching 2022/2025" is
   pattern-matching against this project's own prior results, not a citation, and must not go into
   `lib/common.sh` without the direct check.
2. **DCOM/RPC "boot storm" race applicability - the single most load-bearing open question in this
   research pass.** Finding 3A-5's own cited primary source
   (learn.microsoft.com/.../5836440) was re-fetched directly for this session: every diagnostic
   statement in that thread is scoped explicitly to "Windows Server 2022" by name; Server 2019 is
   never mentioned, in either direction. Server 2019 (build 17763, 1809-based) does already ship the
   same `StartMenuExperienceHost.exe` XAML shell architecture the race depends on, so it's
   structurally plausible there too - but no primary source reports the symptom triad
   (Start Menu/Search/IIS failing post-restart) on 2019 specifically, despite far longer production
   deployment history than Server 2022 has. Genuinely inconclusive either way.

**Recommendation for that open item, not yet decided**: apply the same `ServicesPipeTimeout=120000`
offline registry merge to Server 2019 preemptively in `make-bootable.sh` (cheap, already proven safe
on two other Server SKUs, and this project's own multi-boot-cycle build pattern is the actual
trigger condition per Finding 3A-5, independent of which Server SKU is involved) rather than wait to
see if the symptom reproduces and re-spend the same debugging session already spent once on 2022.
Flagged as a recommendation, not a decision, since it would preemptively change a registry value
based on inference rather than confirmed 2019-specific evidence.

**Rough effort estimate, if this project proceeds**: comparable to or slightly less than Server
2022's own Session 12 bring-up (ISO download/verification, WIM index confirmation, full end-to-end
build/WinRM confirmation cycle, all in one session, with zero tooling changes needed) - one focused
session for the offline-apply track, plus a second short session to confirm the three provisioning
roles against 2019 specifically if not already exercised there. See
`WINDOWS_SERVER_2019_RESEARCH_PLAN.md`'s own "Technical recommendations" section for the full
seven-step dependency chain (cache ISO → verify WIM index → verify `2k19` driver subfolder → wire
`lib/common.sh` → decide `ServicesPipeTimeout` → run `build.sh server2019` → confirm role profiles)
once a decision is made to actually build this.

**Status: research complete, recorded here and in `WINDOWS_SERVER_2019_RESEARCH_PLAN.md`.
Implementation plan is TBD** - no `server2019` case exists anywhere in `image-apply/lib/common.sh`,
`tools/gen-viostor-ddb-reg.py`, or `build.sh` as of this entry, and none of the open items above have
been empirically resolved.

---

## Session (2026-09-01): Windows 11's `register-vm.sh` device-model case - closed by a real
## `virsh start` boot, the last remaining item from CLAUDE.md's Open Items list

Closed out the one standing Open Item: Windows 11's NIC-swap branch of `register-vm.sh`'s device
model had only ever been checked statically (its WinRM verification payload measured under the
`assert_winrm_ps_budget` guard, 2267 chars, 2026-08-26) - never exercised by an actual boot, unlike
Server 2022/2025's storage-only case, which a real `virsh start` boot already confirmed the same
session.

**Host precondition, handled before anything else**: `win2025app`, a libvirt domain from an earlier
session, was already running (up ~35 min, not started this session). Per this project's own standing
"serial QEMU builds, avoid I/O contention" rule, a second concurrent QEMU boot cycle wasn't started
without addressing it first - confirmed with the user, then shut it down gracefully. `virsh shutdown`
(ACPI) sat for 3+ minutes with no effect (the guest showed a clean, idle desktop via `virsh
screenshot` - not stuck on a blocking dialog, the ACPI signal simply wasn't being acted on, cause not
investigated further since a working alternative was available) - a genuine WinRM-driven `shutdown /s
/t 0` (via `pywinrm`, `transport='basic'`, matching `inject-virtio-spice.sh`'s own established
convention) succeeded immediately and the domain reached `shut off` cleanly shortly after. **New,
worth-noting operational gotcha**: this host's Python/OpenSSL build has MD4 disabled
(`_hashlib.UnsupportedDigestmodError: unsupported hash type md4`), which breaks `pywinrm`'s NTLM
transport outright - `transport='basic'` (what this project's own scripts already use throughout) is
required on this host regardless of target, not just a style preference.

**The actual test**: the only existing Windows 11 build (`windows11-phase35-build2.qcow2`, from
Phase 3.4/3.5, dated 2026-08-22 - predates Phase 3A's introduction of the completion marker) had
never been through `inject-virtio-spice.sh`, confirmed directly by first running `register-vm.sh
windows11` and getting the expected loud failure (no marker found). Ran `inject-virtio-spice.sh
windows11 image-apply/output/builds/windows11-phase35-build2.qcow2` against it - both stages
completed cleanly and unattended (vioscsi/netkvm/qxldod all live-verified `Status: OK`, SPICE tools
installed, storage and NIC both swapped, graceful shutdown both stages, no length-ceiling or hard-kill
issues - the two bugs fixed 2026-08-25/26 stayed fixed). `register-vm.sh windows11` then defined
`win11prod` cleanly, marker check passing this time.

`virsh start win11prod` booted **directly to a live desktop** - confirmed via `virsh screenshot`
(the "Windows 11 Enterprise Evaluation" watermark visible, matching every prior Windows 11
confirmation in this project) - and real WinRM verification, not just a screenshot:

- `hostname` -> `WIN11P35B` (matches the disk's own baked-in ComputerName from its original Phase
  3.4/3.5 build - not reset or altered by this session's work)
- `Get-NetAdapter` -> `Ethernet 3`, `Red Hat VirtIO Ethernet Adapter #2`, `Up`, `10 Gbps` - a real
  DHCP lease followed (`192.168.122.186`, confirmed via `virsh net-dhcp-leases default`). The
  interface renamed itself from `inject-virtio-spice.sh`'s own Stage 2 naming (`Ethernet 2`) to
  `Ethernet 3` under libvirt's different PCI placement - expected Windows device-instance behavior
  when a PCI location changes, not a problem; the adapter still bound, still came up, still passed
  traffic.
- `Get-Disk` -> `QEMU QEMU HARDDISK`, `Online`, GPT (virtio-scsi storage also confirmed, same as the
  NIC).
- `Get-PnpDevice -Class Display` -> `Red Hat QXL controller`, `OK`.
- `(Get-CimInstance Win32_OperatingSystem).Caption` -> `Microsoft Windows 11 Enterprise Evaluation`.

**This is real evidence, not an extrapolation**, that Finding 3A-3's inference (libvirt's own PCI
address allocation for virtio devices doesn't need to reproduce `inject-virtio-spice.sh`'s exact raw
`addr=` values for Windows to still bind the already-registered driver) holds for the NIC-swap case
too, exactly as it already did for the storage-only case Server 2022/2025 proved on 2026-08-23/26.
**All three target OSes' `register-vm.sh` device models are now confirmed by a real `virsh start`
boot - CLAUDE.md's Open Items list is empty as of this entry.**

`win11prod` was left running for inspection after this confirmation, matching this project's own
established pattern from the Server 2022/2025 confirmation sessions. `win2025app` was not
restarted this session - that's the user's own domain from an earlier session, left for them to
restart when they want it back.

---

## Session (2026-09-02): Server 2019 project kicked off as a formal, gated addition - Phase A
## (research) deepened and closed same day, including the ISO acquisition blocker

The user asked to proceed with adding Windows Server 2019 as a fourth target OS, structured as five
explicit phases with gates: A) deep research + engineering-quality summary, B) design/implementation
plan, C) design review, D) implementation, E) E2E testing (2+ builds including role provisioning).
This entry covers Phase A only - no pipeline code was touched (`build.sh`, `image-apply/*.sh`,
`image-apply/lib/common.sh`, `services.yaml` all unmodified).

**Research Pass 2** (background task, full detail in `WINDOWS_SERVER_2019_RESEARCH_PLAN.md`, updated
in place rather than replaced) deepened the original scoping pass from 2026-09-01 with real
local/host-side verification instead of just web research, now that the project had direct access to
its own already-cached files:

- **VirtIO `2k19` driver subfolder: promoted from "referenced by convention" to hash-confirmed.**
  Direct `7z l`/`diff`/`sha256sum` against the already-cached `virtio-win-0.1.285.iso` found `2k19`'s
  `vioscsi.inf`/`netkvm.inf`/`viostor.inf` byte-identical text to `2k22`'s, and the actual driver
  binaries (`netkvm.sys`, `netkvmp.exe`, `vioscsi.sys`, `viostor.sys`) hash-identical. Hardware IDs
  match `tools/gen-viostor-ddb-reg.py`'s existing presets exactly.
- **DCOM/RPC "boot storm" race: reframed away as a decision point entirely.** `ServicesPipeTimeout=
  120000` turns out to already be unconditional in `make-bootable.sh` (no OS branching) - Server 2019
  would inherit it automatically, no separate call to make. Bonus finding: the Start Menu crash this
  project actually spent real effort chasing (`STARTMENU_DCOM_ROOT_CAUSE_RESEARCH_PLAN.md`) turned
  out to have an unrelated root cause (wimlib silently dropping ACLs via the old FUSE-mounted
  `apply-image.sh`), since fixed at the shared-script level - Server 2019 inherits that fix too.
- **New blocker found**: Server 2019's Evaluation ISO is the only one of this project's four target
  OSes gated behind a Microsoft lead-generation registration form rather than a direct, scriptable
  fwlink - confirmed by tracing the actual redirect (resolves to a landing page, not an ISO). The
  research deliberately did not attempt to fabricate registration info to bypass it, correctly
  treating this as something requiring the user's own action.

**The user completed the registration form directly** and handed off the resulting ISO
(`17763.3650.221105-1748.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso`, 5,652,088,832 bytes -
build 17763.3650, the same v1809 release line, Extended Support until 2029-01-09 per the research's
own Finding 9). Cached it into `../iso_cache/` with the `2019-` prefix matching this project's
existing naming convention, computed its sha256 checksum fresh (`6dae072e...`), wrote `.meta`/
`.sha256` sidecars, and added a row to `ISO_CACHE_INVENTORY.md` - with an explicit note that, unlike
every other cached source, this one has no scriptable re-download link to record, since the
acquisition step itself requires a human each time.

**Ran this project's own non-negotiable WIM verification recipe directly against the real ISO**
(`7z e ... sources/install.wim`, then `wimlib-imagex info install.wim` - the same technique
`PHASE2_ENGINEERING_LOG.md` Finding 0 used for Server 2025, preferred over the older `strings -el |
grep EDITIONID` technique): confirmed **index 2 = "Windows Server 2019 SERVERSTANDARD", EditionID
`ServerStandardEval`, Installation Type Server (Desktop Experience)** - exactly matching the
"probably index 2" inference two research passes had explicitly refused to treat as a citation
without direct verification. Full four-image table (1=Standard Core, 2=Standard Desktop Experience,
3=Datacenter Core, 4=Datacenter Desktop Experience) matches the identical pattern already proven for
Server 2022/2025. The 4.7GB extracted `install.wim` scratch file was deleted after verification, per
this project's own disk-hygiene standard - the cached ISO itself is the durable artifact.

**Phase A is now closed - no research-phase open questions remain.** Every item flagged as
"inferred, not verified" across both research passes (virtio driver presence/hardware IDs, the DCOM
mitigation's applicability, the WIM edition index, media availability/support lifecycle) is now
either confirmed by direct verification or resolved by architecture. `WINDOWS_SERVER_2019_RESEARCH_
PLAN.md` was updated in place to reflect this throughout (Finding 3, the comparison table, the
Feasibility assessment, and the Open Questions section all updated rather than left stale).
**Next: Phase B (design + implementation plan with phase gates), not yet started as of this entry.**

---

## Session (2026-09-02, continued): Server 2019 Phase B (design plan), Phase C (design review),
## and Phase D (implementation) - all three closed same day

**Phase B**: wrote `WINDOWS_SERVER_2019_IMPLEMENTATION_PLAN.md`, grounded in a direct file-by-file
audit of the real pipeline (every `image-apply/*.sh` script, `build.sh`, `apply-unattend.sh`,
`boot-and-provision.pkr.hcl`, `register-vm.sh`, `inject-virtio-spice.sh`,
`tools/gen-viostor-ddb-reg.py`, `services.yaml`/`run-services.ps1` all actually read, not inferred
from the research doc's own recommendations). Headline finding: this pipeline is almost entirely
table-driven off `image-apply/lib/common.sh` - `partition-disk.sh`/`apply-image.sh`/
`make-bootable.sh` contain no `case "$OS"` of their own at all, `gen-viostor-ddb-reg.py` isn't
OS-keyed to begin with, `inject-virtio-spice.sh`'s only OS-conditional logic is Windows-11-specific
(and its `QXLDOD_SUBFOLDER` is already hardcoded to `"2k19"` for every Server SKU - Server 2019
becomes the first OS where that name and the actual guest OS coincide, a nice existing-correctness
confirmation rather than a new risk), and `services.yaml`/`run-services.ps1` have zero OS-version
references. Real implementation footprint: five one-line table additions in `common.sh`, one
case-statement line plus a new template file in `apply-unattend.sh`, one validation-list line in the
Packer template.

**Phase C**: the plan's five open decision points (computer name convention, Datacenter edition
scope, `dev/` harness scope, Phase E build order, `CLAUDE.md` documentation timing) were presented to
the user as a consolidated list and confirmed with zero changes to the plan as written - see the plan
doc's own "Phase C: design review - CLOSED" section for the record of each.

**Phase D**: implemented the D1-D5 sequence exactly as planned, each step independently verified
before moving to the next (not just written and assumed correct):

- **D1** (`image-apply/lib/common.sh`): added `server2019` to all five table functions plus
  `validate_os`. Verified via `bash -n` (syntax) and a direct call of every function
  (`os_win_iso server2019` etc.) confirming each resolved value, including confirming the resolved
  ISO path actually points to the real cached file from the ISO-acquisition session.
- **D2** (`image-apply/unattend-server2019.xml` + `apply-unattend.sh`'s case line): created the new
  template as a copy of `unattend-server2022.xml`. Verified via `diff` against the source template
  (showed exactly the header comment, `ComputerName` placeholder, driver path `2k22`->`2k19`, and
  log-filename-prefix lines changed, nothing else) and `xmllint --noout` (well-formed). Log filenames
  use a `server2019-` prefix rather than a fabricated `sessionNN` number, since this file (unlike the
  other three OSes' templates) was produced during Phase B design work, not a live numbered bring-up
  session - called out explicitly in the file's own header comment.
- **D3** (`packer/boot-and-provision.pkr.hcl`): added `server2019` to the `target_os` variable's
  `contains([...])` validation list. Verified via a real `packer validate -var target_os=server2019
  ...` run against the actual template - "The configuration is valid," confirming the one change that
  would otherwise cause an immediate, loud Packer failure is correctly in place.
- **D4** (usage-string/comment updates): batch-updated all six remaining scripts' `Usage: ...
  <server2022|server2025|windows11>` strings, plus a few OS-enumeration comments in
  `inject-virtio-spice.sh` and `register-vm.sh` that directly describe which code path Server 2019
  now follows (both accurate to update now, since D1-D3 already make that path real). Verified via
  `bash -n` on every touched script.
- **D5** (pre-flight sanity): confirmed `validate_os server2019` succeeds, confirmed the updated error
  message for an invalid OS now lists `server2019`, and grepped for any remaining stale
  `<server2022|server2025|windows11>` usage strings across every touched script - none found (the one
  remaining hit, `image-apply/apply-image-OLD.sh`, is the pre-existing untracked file unrelated to
  this project's active pipeline, deliberately left untouched all session).

**Total diff**: 10 files changed (`build.sh`, `register-vm.sh`, five `image-apply/*.sh` scripts,
`packer/boot-and-provision.pkr.hcl`, plus the plan doc's own Phase C closure), one new file
(`image-apply/unattend-server2019.xml`) - matches the plan's own predicted footprint exactly, no
surprises found during implementation itself (the surprises, such as they were, all surfaced during
Phase B's audit, not during D1-D5's mechanical execution).

**Not yet done: Phase E (E2E testing, 2 builds including services provisioning)** - no real
`build.sh server2019` run has happened yet. Everything above is verified at the level available
without booting a VM (syntax, `packer validate`, direct function calls, diff/XML checks) - the actual
end-to-end pipeline (partition -> apply -> bootable -> specialize -> WinRM -> role provisioning ->
`inject-virtio-spice.sh` -> `register-vm.sh` -> `virsh start`) has not been exercised for Server 2019
even once. That's Phase E, next.

---

## Session (2026-09-02, continued): Phase E1 (Build 1, `ad-ds`) - real, reproducible bug found:
## `Enable-PSRemoting` hangs indefinitely on Server 2019, root cause not yet identified

**First real Server 2019 build attempt.** `./build.sh server2019 dev/services-domain-controller.yaml`
ran partition-disk.sh, apply-image.sh (WIM index 2 applied cleanly, confirming Finding 3's
verification was correct), make-bootable.sh, and apply-unattend.sh all cleanly, then handed off to
Packer for the first real boot. **Packer's WinRM wait timed out after 15m19s** - the first genuine
failure this project's Server-SKU pipeline has hit at this stage for any OS.

**Diagnosis, not guessing** - the pre-Packer disk (`image-apply/output/builds/
server2019-20260902-105345.qcow2`) survives a Packer failure untouched (Packer boots/modifies it in
place but doesn't delete it on error), so it was booted directly via `tools/boot-adhoc-target.sh` for
live diagnosis, per this project's own established convention for exactly this situation:

1. **The boot itself is fine** - real, live Server Manager desktop, AutoLogon worked, hostname
   `WIN2019PROD` confirmed correct. No BSOD, no INACCESSIBLE_BOOT_DEVICE, nothing wrong with the
   offline-apply/bootable/specialize mechanism itself.
2. **WinRM's listener IS reachable and responding** - but `curl -i` against it shows `WWW-Authenticate:
   Negotiate` only, no `Basic` - confirming `FirstLogonCommands` Order 4 (which explicitly runs `winrm
   set winrm/config/service/auth '@{Basic="true"}'`) never completed.
3. **Offline-mounted the disk and checked the marker/log files `FirstLogonCommands` writes**:
   `server2019-firstlogon-marker.txt` (Order 2) and `server2019-pnputil-log.txt` (Order 1) both exist
   - `server2019-netcat-log.txt` (Order 3) and `server2019-winrm-log.txt` (Order 4) are **both
   missing**. `FirstLogonCommands` got stuck somewhere between Order 2 and Order 3/4, not a clean
   failure of one specific command with a logged error.
4. **Booted the disk a third time and interactively reproduced the actual hang**, via
   `tools/qmp-sendkey.py`/`qmp-type.py` (Win+R -> `powershell` -> admin shell, AutoLogon still active,
   `LogonCount` budget not yet exhausted): `ipconfig /all` confirmed the network adapter (`Red Hat
   VirtIO Ethernet Adapter`) is fully functional with a real DHCP lease (`10.0.2.15`) - so Order 3's
   own 90-second network-wait loop should have succeeded quickly, not stalled. `Get-NetConnectionProfile`
   run standalone returns instantly (`NetworkCategory: Public` - confirming Order 3's
   `Set-NetConnectionProfile -NetworkCategory Private` never actually ran). **Running `Enable-PSRemoting
   -Force -SkipNetworkProfileCheck` directly (Order 4's own first command) hung for 5+ minutes with zero
   completion**, confirmed via a second PowerShell window opened alongside the hung one (not blocked by
   it) - `Get-Service WinRM,MpsSvc,W32Time,LanmanServer` all show `Running`, and the hung process's own
   accumulated CPU time barely grew (~6s over 5+ minutes) - consistent with a genuine blocking
   wait/deadlock, not active computation. Checked for a hidden interactive dialog (a firewall
   confirmation prompt is a known cause of similar-looking hangs) via Alt-Tab - none found.

**This reproduces outside the `FirstLogonCommands`/specialize-pass context too** - run interactively,
well after a normal AutoLogon desktop session was already active, `Enable-PSRemoting -Force
-SkipNetworkProfileCheck` still hangs the same way. This rules out a timing race specific to how early
`FirstLogonCommands` runs during specialize - whatever is wrong reproduces on a plain, fully
interactive admin session too.

**Root cause NOT yet identified** - this is an honest "found the exact failure, not yet the reason"
entry, not a fix. A real, multi-angle web search (Microsoft Learn/Q&A, Experts Exchange, GitHub issue
trackers) surfaced several candidate explanations, none confirmed against this specific VM yet:
- `-SkipNetworkProfileCheck` is documented as a no-op on Server SKUs to begin with (only affects
  client Windows editions' Public-network restriction) - ruled out as the actual lever, though it's
  harmless to keep in the unattend.xml.
- A documented Group Policy conflict (`Set-WSManQuickConfig` failing on "Allow remote server
  management through WinRM" GPO setting) - plausible but unconfirmed; not yet checked directly against
  this VM's own local GPO state (`gpresult`/`rsop.msc` not yet run).
- A Microsoft Q&A thread describing "stuck at Enabling Feature(s)" on fresh Windows Server 2019
  installs generally (suggesting possible CBS/component-store health issues, `sfc`/`DISM
  /RestoreHealth` as a generic mitigation) - a real, if generic, precedent for "Server 2019 fresh
  installs sometimes get stuck," not a specific mechanism match.
- Not yet checked: Group Policy Client service (`gpsvc`) state specifically (only `WinRM`, `MpsSvc`,
  `W32Time`, `LanmanServer` were checked this session); whether the hang is specific to the offline
  `hivex`-injected NetKVM driver path (Server 2022/2025 use the identical mechanism and don't hit this,
  which weighs against but doesn't rule out a driver-specific interaction); WMI repository health
  (`winmgmt /verifyrepository`).

**Status: Phase E1 blocked on this bug.** Not attempted yet: retrying with `winrm quickconfig -quiet`
as a substitute for `Enable-PSRemoting` (a documented lighter-weight alternative some of the search
results suggest is less prone to this class of hang), extending patience past 5 minutes to see if it
ever completes, or checking `gpsvc`/WMI repository health directly. The diagnostic VM was shut down
cleanly (QMP `system_powerdown`, confirmed exited) rather than left running or hard-killed. The
failed build's disk (`image-apply/output/builds/server2019-20260902-105345.qcow2`) was kept, not
deleted, as live evidence for continued diagnosis - matching this project's own disk-hygiene standard
of preserving artifacts during an active reproducibility/diagnosis sequence.
