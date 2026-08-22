# Phase 3 Engineering Log: Role Provisioning Confirmed for Server 2022 and Server 2025

Status as of this writing: **Phase 3 is done.** All four OS × profile combinations (Windows Server
2022/2025 × domain-controller/app-server) were confirmed live against this project's own
offline-applied, Phase-2-proven reference disks. The reused role-provisioning scripts needed zero
changes beyond a new, project-specific mutual-exclusion guard. One real, non-obvious defect was
found and fixed in the new test harness itself (Finding 1 below) — not in the reused scripts, and
not in Phase 2's mechanism. See `CLAUDE.md`'s Phase 3 section for the current status summary and
`PHASE2_ENGINEERING_LOG.md` for the offline-apply mechanism this phase builds on.

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
`server2025-test1.qcow2` are the two confirmed-good disks this session produced (both still present,
gitignored, disposable per this project's ephemeral-infrastructure principle - not meant to be kept
long-term).

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

**Persistent state that survives** (under `image-apply/output/`, gitignored):
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
session). `windows11-bisect4.qcow2` (this session's last disk - reached the graceful "invalid answer
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
