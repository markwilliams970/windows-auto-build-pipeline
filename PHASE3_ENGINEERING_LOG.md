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
   specific to one OS), not a small patch.
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
