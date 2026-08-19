# CLAUDE.md

# Project: Windows Auto-Build Pipeline (offline image application)

## Purpose

This project builds the same kind of fully reproducible Windows lab environment as its sibling
project, `../windows-server-vm-automation/`, for the same reason: Datadog Agent testing,
Windows/AD/IIS/SQL Server monitoring integration validation, simulating realistic enterprise and
regulated-cloud (FedRAMP/GovCloud-style) customer environments.

**Read `HANDOFF_FROM_UNATTENDED_INSTALL.md` before doing anything else.** It explains in detail
why this project exists as a separate thing rather than a fix inside the sibling repo: the sibling
project's Windows Server 2022 build (interactive Setup driven by `autounattend.xml`, with Packer
typing keystrokes over VNC to catch the install media's "press any key to boot" prompt) works
reliably — but the identical mechanism *reliably fails* for Windows Server 2025 and Windows 11
media, a real, currently-unresolved upstream Packer/QEMU/OVMF issue, not a configuration mistake.
This project takes a different approach to the *installation* mechanism entirely: apply the
Windows image to disk **offline** (`DISM /Apply-Image`-equivalent via `wimlib`, done from this
Linux host directly, no interactive installer boot involved at all), and reuse the sibling
project's post-install provisioning layer unchanged once a disk is bootable.

The goal is not to create or maintain a golden image, same as the sibling project — see the
handoff doc's section on why a golden-image-and-clone model is specifically incompatible with
time-limited Windows evaluation media (the activation countdown doesn't reset on clone, and the
`sysprep`/`rearm` mechanism that could extend it is capped at a small number of total uses for the
life of the original install, not per clone). Every build applies the WIM fresh, every time.

---

# Implementation Status

**Phase 1** (architecture) is done: this document plus `HANDOFF_FROM_UNATTENDED_INSTALL.md`, including sourced prior-art research confirming the offline `DISM`/`bcdboot` approach for all three target OSes.

**Phases 2-5** are not yet started. Phase 2 (the offline-apply installation mechanism itself) is where almost all of the real, unsolved work is — see its entry under Development Approach below for the specific sub-milestones and the one open technical question ("does WinPE's own boot avoid the sibling project's UEFI boot-key landmine") that the whole rest of this project depends on.

---

# Relationship to `../windows-server-vm-automation/`

This is a genuinely separate project (different install mechanism, different tooling, different
repository structure) but shares real DNA with the sibling project and should reuse rather than
reinvent wherever the two overlap:

- **Reuse directly**: the role-provisioning layer (`services.yaml`, `scripts/run-services.ps1`,
  `scripts/install-iis.ps1`, `scripts/install-ad.ps1`, `scripts/verify-post-reboot.ps1`,
  `scripts/install-sql-server.ps1`) — none of it cares how Windows got onto the disk, only that
  there's a booted VM with WinRM reachable. Copy these over as a starting point rather than
  rewriting them.
- **Reuse directly**: `../iso_cache/` — the cache of binary install media (Windows ISOs,
  virtio-win ISO) now lives one level above both repos (shared with `../windows-server-vm-automation/`
  rather than duplicated per-repo) and is no longer inside either repo's git tree. Its location is
  parameterized via the `ISO_CACHE_DIR` environment variable, defaulting to
  `${REPO_ROOT}/../iso_cache` — matching the sibling project's `build.sh`/`build-windows11.sh`
  convention exactly, so any script in this project should resolve the cache the same way rather
  than hardcoding a path. The currency-check convention itself (version-keyed ISO filenames,
  `.sha256`/`.meta` sidecars, ETag-based freshness checks before re-downloading) carries over
  unchanged — see the sibling project's `CLAUDE.md`/`README.md` for the history of the move.
- **Reuse the pattern, not necessarily the exact files**: the `dev/` fast-iteration harness pattern
  (a frozen baseline disk + Packer's `disk_image = true`/`use_backing_file = true` copy-on-write
  overlay, for testing changes in minutes instead of a full rebuild).
- **Do not reuse**: anything related to `boot_command`, VNC keystroke injection, or
  `autounattend.xml`'s `Microsoft-Windows-Setup` disk-partitioning/image-selection component. That
  entire mechanism is what this project exists to replace.

  **RECONSIDERATION CLOSED as of `PHASE2_ENGINEERING_LOG.md`'s Findings 15-28: rule is back in
  force, do not reuse `Microsoft-Windows-Setup`.** This rule was temporarily relaxed when Setup.exe
  looked like a promising pivot — the UEFI "press any key" landmine turned out to be specific to
  `media=cdrom` boot, not Setup.exe itself, so a self-built Setup.exe boot medium (`boot.wim` index
  2) attached as a plain disk boots clean with zero landmine exposure (Finding 15/18, confirmed).
  But that only solved *bootability*; Setup.exe's own `EarlyF6DriverInstall` gate turned out to be
  a separate, unconditional blocker that five independent fix attempts (across Findings 19, 24, 25,
  27, and 28) all failed against — including deliberately testing whether avoiding disk-config
  automation would route around it (it doesn't; the gate fires at identical timing regardless).
  This pivot is now set aside in favor of the original plan: making the disk bootable via BCD-SYS
  or plain (non-Setup) WinPE `bcdboot`, with driver injection solved offline via `hivex`, exactly as
  this rule originally specified. `boot_command`/VNC keystroke injection remain correctly banned
  regardless, for the original reason (they solve a boot-prompt problem that doesn't exist here).

---

# Architectural Principles

## Ephemeral Infrastructure, Still

Every Windows Server/11 instance this project builds should be considered temporary, exactly like
the sibling project. The expected lifecycle is the same:

```
Apply Windows image to disk offline (no boot required)
  |
  v
Make the disk bootable
  |
  v
Boot once, apply specialize/unattend configuration
  |
  v
Configure services automatically (reused role-provisioning layer)
  |
  v
Validate functionality
  |
  v
Perform testing
  |
  v
Destroy completely
```

**Never cache or reuse a previously-applied disk as the starting point for a new "real" build.**
Each real build applies the WIM fresh. The only exception is the `dev/`-style fast-iteration
harness explicitly used for testing *provisioning script* changes during development, which is
allowed to clone from a frozen baseline the same way the sibling project's `dev/` harness does —
that's a development convenience, never the actual build workflow, and the distinction matters
(see `HANDOFF_FROM_UNATTENDED_INSTALL.md`'s eval-expiration section for exactly why).

---

# Tool Responsibilities

## wimlib

Responsible for extracting and applying the Windows image (`.wim`) directly onto a formatted NTFS
partition, without ever booting a Windows environment to do it. `wimapply`/`wimlib-imagex apply`
targeting the correct image index (matched by `<NAME>`/`<EDITIONID>`, using the same direct
`install.wim` inspection technique the sibling project used — extract with `7z`, read the XML
metadata with `strings -el ... | grep EDITIONID` — don't assume an index or name without checking
the actual ISO).

## qemu-nbd + partitioning tools

`qemu-nbd` exposes a qcow2 disk file as a `/dev/nbdN` block device so it can be partitioned and
written to directly from this Linux host, the same tool the sibling project used for read-only
forensic mounting (see its engineering log's "Practical Operating Notes"). `sgdisk`/`parted`
create the GPT layout (EFI System Partition, MSR, primary NTFS — matching the sibling project's
proven-working layout). `mkfs.vfat` and `mkfs.ntfs` (via `ntfs-3g`/`ntfsprogs`) format the
resulting partitions.

## Making the disk bootable

**Two-tier plan — see `PHASE2_BOOTSTRAP_ARCHITECTURE.md` for the full comparison and rationale.**

**First attempt: BCD-SYS** (`github.com/jpz4085/BCD-SYS`), an actively-maintained open source tool
that constructs the BCD store and copies boot files to the ESP directly from the Linux host, via
`hivexsh`/`hivexregedit`, with **no boot of any kind required** — not even WinPE. If this works
against our wimapply'd partition layout, it removes an entire boot cycle (and the UEFI-boot-timing
risk that comes with it) from the pipeline entirely. Untested by us as of this writing — verify
before depending on it, same standard as everything else in this project.

**Fallback, if BCD-SYS doesn't produce a disk that boots cleanly**: boot a minimal, self-built
WinPE environment under QEMU just long enough to run the real `bcdboot W:\Windows /s S: /bootex`
once, then never boot that WinPE environment again. This is Microsoft's own documented mechanism
(`DISM /Apply-Image` then `bcdboot`, run from WinPE), confirmed against real-world deployment
guides for all three target OSes (see `HANDOFF_FROM_UNATTENDED_INSTALL.md`'s "Prior art / community
research" section) — not a guess, and not something to reimplement from scratch.

**The fallback's one genuinely open question**: whether WinPE's own boot is affected by the same
"press any key" UEFI landmine that blocks the sibling project's full-installer approach. Untested.
The leading theory (also unverified) is that this landmine is specific to optical/CD-ROM boot media
(a UX convention to avoid accidentally reinstalling from media left in the drive — not applicable
to a plain disk boot), so attaching a self-built WinPE image as a regular virtio-blk/virtio-scsi
*disk* rather than `media=cdrom` may sidestep the issue entirely. This only needs testing if the
BCD-SYS attempt fails first.

## QEMU/KVM/libvirt

Same responsibilities as the sibling project: virtualization, VM lifecycle, CPU/memory allocation,
disks, networking, device models. UEFI firmware, VirtIO storage/networking, QEMU Guest Agent.
Once a disk is bootable and specialized, Packer's QEMU builder in `disk_image = true` mode (no
ISO, no `boot_command`, no interactive install of any kind) boots it for the
provisioning/validation phase — this part directly reuses the sibling project's `dev/
role-test.pkr.hcl` pattern.

### VM screen inspection: QMP screendump, not VNC-viewer-plus-manual-screenshot

The sibling project's debugging workflow (pop a `vncviewer` window, manually screenshot it, hand
the image to Claude) is a real hassle and is **not the recommended approach here.** QEMU exposes a
JSON control channel, QMP, over a Unix socket — any `qemu-system-x86_64` process started with
`-qmp unix:/path/to/qmp.sock,server,nowait` accepts a `screendump` command that writes the current
framebuffer straight to a PNG on disk. No VNC client, no window, no window manager, no host display
session required at all — this works identically whether the host has a desktop session open or
not.

Two small tools implement this, in `tools/`:

- **`tools/qmp-screenshot.py`** — one-shot capture: `--socket <qmp.sock> --out <shot.png>`. Stdlib
  only (`socket` + `json`), no dependencies. Confirmed working end-to-end against a real QEMU
  instance (see engineering notes below).
- **`tools/qmp-watch.sh`** — loops the above at a configurable interval/count with timestamped
  filenames, for watching a boot sequence unfold frame-by-frame (e.g. diagnosing UEFI boot-prompt
  timing) instead of guessing at keystroke/timing parameters blindly.

**Convention going forward**: whenever a `qemu-system-x86_64` invocation is constructed for testing
or experimentation in this project (not necessarily Packer-managed builds — see caveat below), add
`-qmp unix:/tmp/<short-name>.sock,server,nowait` to it. A VNC display (`-vnc :N`) can still be added
too if a human wants to look at it live — QMP and VNC coexist without conflict; QMP is simply the
mechanism for on-demand or scripted capture without needing anyone to open a viewer.

**Known gotcha**: Unix domain socket paths have a hard 108-byte kernel limit. Keep QMP socket paths
short and directly under `/tmp/` (e.g. `/tmp/bcdsys-test.sock`) — a path nested under a long
session-scoped scratchpad directory will exceed the limit and fail with
`UNIX socket path ... is too long`.

**Caveat — does not cover Packer-managed builds, confirmed the hard way, not just predicted.**
Packer's QEMU builder plugin does not expose a QMP socket option of its own, and per the sibling
project's own hard-won lesson (see `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`), setting `qemuargs`
on it replaces its auto-generated arguments wholesale rather than appending to them. This was
originally flagged here as a predicted risk; the sibling project actually tried adopting this same
QMP tooling directly (commit `0167012`) and had to revert it (commit `fa46ebe`) because wiring in
`-qmp` via `qemuargs` broke boot there — confirming the reconstruction problem is real, not
theoretical, and not a small lift. This remains a solved problem only for ad hoc
`qemu-system-x86_64` invocations run directly (which covers this project's Phase 2 experiments —
BCD-SYS testing, the WinPE-based work). Don't attempt to wire QMP into a Packer-managed build here
without first fully reconstructing its `qemuargs` list by hand (as the sibling project's own
Windows 11 vTPM investigation once did) — treat that as real, non-trivial work, not a quick add.

## PowerShell

Same responsibility as the sibling project: all Windows configuration (role provisioning, Datadog
Agent installation, validation) is automated, repeatable, idempotent where possible, logged
clearly. The actual scripts are reused from the sibling project, not rewritten.

---

# Target Platform

## Host

Same as the sibling project (Linux Mint/Ubuntu-based, KVM enabled, QEMU installed, libvirt
configured), plus additional packages this project specifically needs:

- `wimlib-imagex` (or equivalent `wimlib`-provided tooling)
- `gdisk` (`sgdisk`) and/or `parted`
- `ntfs-3g` (already used by the sibling project for forensic mounting; also needed here for
  `mkfs.ntfs`)
- `qemu-utils` (for `qemu-nbd` — already available if the sibling project's tooling is installed)

## Guest

Same as the sibling project: Windows Server 2022/2025 Evaluation, Windows 11 Enterprise
Evaluation; UEFI boot; VirtIO devices; QEMU Guest Agent.

---

# Windows Configuration Goals

Unchanged from the sibling project — see its `CLAUDE.md` for the full detail on AD DS, IIS, SQL
Server, and Datadog Agent requirements, all of which apply here identically since they're
implemented by the reused role-provisioning scripts. `services.yaml`'s Service Selection design
(roles are opt-in per build, not bundled by default) carries over unchanged.

---

# Datadog Validation Requirements

Unchanged from the sibling project — see its `CLAUDE.md` for the full detail (Windows service
exists, Agent service running, status healthy, connectivity succeeds, host registration confirmed
if practical; the implementation must clearly report failures). Not yet implemented in either
project — tracked here as Phase 4, same as the sibling project's own Phase 4.

---

# Repository Structure

Expect this to evolve significantly as the actual offline-apply pipeline gets built — this is a
starting sketch, not a fixed target:

```
windows-auto-build-pipeline/

├── README.md
├── CLAUDE.md
├── HANDOFF_FROM_UNATTENDED_INSTALL.md   # read this first
├── services.yaml                         # copied/adapted from the sibling project
├── build.sh                              # or per-OS build scripts, TBD once the pipeline exists

├── image-apply/                # the new, unsolved core: offline WIM application + bootability
│   ├── partition-disk.sh       # qemu-nbd + sgdisk/parted + mkfs
│   ├── apply-image.sh          # wimlib apply
│   ├── make-bootable.sh        # the open problem - bcdboot equivalent
│   └── apply-unattend.sh       # DISM /Apply-Unattend equivalent, or whatever this becomes

├── packer/
│   └── boot-and-provision.pkr.hcl   # disk_image=true, no ISO/boot_command - boots the
│                                      # already-applied disk and hands off to scripts/

../iso_cache/                  # shared cache of binary install media (Windows ISOs, virtio-win
│                                 # ISO) - lives one level above this repo (ISO_CACHE_DIR default),
│                                 # shared with the sibling windows-server-vm-automation project
│                                 # rather than duplicated per-repo; not inside this repo's git tree

├── scripts/                    # copied from the sibling project's scripts/, reused as-is
│   ├── run-services.ps1
│   ├── install-iis.ps1
│   ├── install-ad.ps1
│   ├── install-sql-server.ps1
│   ├── verify-post-reboot.ps1
│   └── install-datadog.ps1     # future

├── dev/                        # fast-iteration harness, same pattern as the sibling project's
│   └── ...

├── tools/                      # host-side Linux dev/debug tooling (distinct from scripts/,
│   │                             # which is Windows-side PowerShell reused verbatim)
│   ├── qmp-screenshot.py       # one-shot QEMU framebuffer capture via QMP, no VNC viewer needed
│   └── qmp-watch.sh            # loops qmp-screenshot.py for watching a boot sequence unfold

└── tests/
    ├── verify-connectivity.ps1
    ├── verify-iis.ps1
    ├── verify-ad.ps1
    └── verify-datadog.ps1
```

---

# Lifecycle Requirements

Same three stages as the sibling project (Build, Verify, Destroy), with Build's internals
completely different:

## Build

1. Validate prerequisites (including the new tooling: `wimlib`, `sgdisk`/`parted`, `ntfs-3g`,
   `qemu-nbd`).
2. Resolve/cache the Windows install ISO (reuse `../iso_cache/`'s existing entries and convention,
   via the shared `ISO_CACHE_DIR` default).
3. Partition a fresh disk image directly (no boot required).
4. Apply the Windows image (`wimlib`) to the primary partition.
5. Make the disk bootable (the open problem).
6. Apply an offline unattend/specialize pass (computer name, WinRM enablement, driver injection —
   `DISM /Apply-Unattend` and `/Add-Driver` equivalents).
7. Boot the disk (Packer, `disk_image = true`), confirm WinRM connectivity.
8. Configure Windows roles (reused `services.yaml`/`scripts/` layer, unchanged).
9. Install Datadog Agent.
10. Run validation.

## Verify / Destroy

Same requirements as the sibling project — see its `CLAUDE.md` for the detail. Not yet
implemented there either (tracked as an open item in its own engineering log); no reason to
diverge on approach once it's built here too.

---

# Development Approach

Work incrementally.

Do not generate the entire implementation immediately.

Build and validate each phase.

Phase numbers below are deliberately kept aligned with the sibling project's own Phase 1-5
structure (Architecture → Windows Installation → Windows Configuration → Datadog → Lifecycle),
even though this project's different install mechanism means Phase 2 needs more internal
sub-milestones than the sibling's did. Don't renumber these to match the finer-grained sequence
this project actually has to build in — cross-referencing between the two projects' engineering
logs depends on "Phase 3" meaning the same thing (role configuration) in both.

---

# Phase 1: Architecture and Repository

Deliver:

- repository structure
- tool decisions
- dependency list
- workflow documentation
- prior-art research confirming the chosen approach before committing to it

**Status:** done — this document, `HANDOFF_FROM_UNATTENDED_INSTALL.md`, and the sourced research within it confirming `DISM /Apply-Image` + `bcdboot` (run from WinPE) for all three target OSes.

---

# Phase 2: Automated Windows Installation (offline image application)

Implement:

- Disk partitioning directly from this Linux host (`qemu-nbd` + `sgdisk`/`parted` + `mkfs.ntfs`/`mkfs.vfat`), no boot required
- WIM application (`wimlib`) onto the formatted NTFS partition
- Disk bootability via BCD-SYS (first attempt, no boot required) or, as fallback, a minimal self-built WinPE boot environment used exactly once per build to run `bcdboot` — see `PHASE2_BOOTSTRAP_ARCHITECTURE.md`
- An offline specialize/unattend pass (`\Windows\Panther\unattend.xml` dropped directly onto the offline-mounted image: computer name, WinRM enablement) and driver injection (offline `hivex`/`hivexregedit` registry edits, following the `virt-v2v` pattern), applied to the offline image before its first real boot
- Handoff to Packer's `disk_image = true` mode (no ISO, no `boot_command`) for the first real boot and WinRM confirmation

This single phase covers meaningfully more sub-milestones than the sibling project's equivalent phase did, because the install *mechanism* itself is the actual unsolved problem here (the sibling project's Phase 2 could take Packer's ISO-boot approach as a given; this one can't). Suggested internal sequence, each gating the next (see `PHASE2_BOOTSTRAP_ARCHITECTURE.md` for full rationale):

1. Partition + apply + attempt BCD-SYS against the resulting partition, then boot the disk directly under QEMU/OVMF (no WinPE, no interactive installer). Succeeds if Windows Boot Manager comes up and Windows begins loading. This resolves the project's single biggest open question — making the disk bootable at all — without needing a second boot cycle to do it.
2. If step 1 fails: fall back to a self-built WinPE boot medium (attached as a plain disk, not `media=cdrom`) running the real `bcdboot`, per the original plan — this also resolves whether WinPE avoids the "press any key" UEFI landmine that blocks the sibling project's Server 2025/Windows 11 tracks, but only needs testing if BCD-SYS doesn't pan out first.
3. Offline specialize/unattend + driver injection, verified by a real WinRM connection with no manual steps.

Success criteria:

A Windows Server 2025 VM (per explicit direction — its eval media/checksum/WIM-image-index work already exists in the sibling project and can be reused directly) installs and becomes WinRM-reachable without manual interaction, via offline image application rather than a booted interactive installer. **Then repeat this same success criterion for Windows Server 2022 and Windows 11 Enterprise Evaluation before considering Phase 2 done.** Server 2025 is the first proving ground (per the existing "Starting point" direction below), not the only target that needs to actually work — see the explicit process note under Phase 3 below.

**Status:** in progress, **and the core blocker is now solved and confirmed twice, independently** —
read `PHASE2_ENGINEERING_LOG.md`'s "STATUS AND NEXT STEPS ON RESUMPTION (Session 8)" section before
doing anything else here. Sub-milestone 1 (make the disk bootable) remains **solved, twice over**:
BCD-SYS (first approach) and real `bcdboot` run from a self-built WinPE session both independently
produce a correctly-booting BCD. The Setup.exe pivot (Finding 15, Sessions 3-5) was **abandoned in
Session 6** after five independent attempts to get past `EarlyF6DriverInstall`'s "Install driver to
show hardware" gate all failed — see Findings 19, 24, 25, 27, 28 for the full record; the short
version is that the gate is a fixed, unconditional stage of Setup's own PE-hosted execution, not
something any answer-file configuration routes around. **The "do not reuse `autounattend.xml`'s
`Microsoft-Windows-Setup` component" rule (under "Relationship to `../windows-server-vm-automation/`"
above) is back in force as a result.**

Returning to the original plan (plain, non-Setup WinPE + real `bcdboot` + offline driver injection)
then **worked**: Session 7 root-caused why the project's first `hivex` driver-injection attempt
(Findings 7-8, Session 2) failed silently — its `DriverDatabase` registry edits went under the wrong
parent key (`ControlSet001\Control\DriverDatabase`, a reasonable-looking but wrong guess);
`DriverDatabase` actually lives at the **SYSTEM hive root**, a sibling of `ControlSet001`, confirmed
empirically against a real applied image via `hivexsh`. Re-deriving the full registration recipe
directly from `virt-v2v`'s actual source (`libguestfs/libguestfs-common`,
`mlcustomize/inject_virtio_win.ml` — cloned and read line-by-line, not worked from memory) and
fixing the parent-key path (now `tools/gen-viostor-ddb-reg.py`) produced a disk that **boots
cleanly past `INACCESSIBLE_BOOT_DEVICE (0x7B)` all the way to a real Windows Server 2025 OOBE
screen**, confirmed via `tools/qmp-screenshot.py` at each stage of the boot sequence. See Finding
29 for the complete verification trail.

Session 8 then repeated this entire sequence from scratch against a completely blank disk
(`win2025-target.qcow2`, no shared history with the disk Session 7 used) — same recipe, same
result, confirming the fix generalizes rather than depending on some quirk of one specific disk's
history. See Findings 30-33 for the full record, including a reusable, fully unattended
`startnet.cmd` for the WinPE bootability step (Finding 31) that replaces the manual/interactive
approach Session 7 used.

**What's left for Phase 2**: both runs used no `unattend.xml`/specialize pass, so they correctly
stopped at interactive OOBE rather than an automated WinRM-reachable state — the offline
specialize pass (Build step 6 below: `\Windows\Panther\unattend.xml`, computer name, WinRM
enablement) is what turns this into the actual Phase 2 success criterion, and is now the clear next
priority. See `PHASE2_ENGINEERING_LOG.md` for the complete, detailed record — it's long, but
everything needed to resume without re-deriving it is there.

---

# Phase 3: Windows Configuration

**Explicit process gate — do not start any Phase 3 work until Phase 2 is proven for all three
target OSes, not just Server 2025.** Server 2025 is Phase 2's first proving ground, but Phase 3
(the service/provisioning layer) does not begin until Windows Server 2025, Windows Server 2022,
*and* Windows 11 Enterprise Evaluation have each individually bootstrapped successfully (offline
apply → bootable → specialized → real WinRM connection, no manual steps) under this project's
mechanism. The risk being managed here: investing in the service layer on the assumption that
Phase 2's mechanism generalizes across all three OSes before actually confirming it does, on the
theory that it should per `PHASE2_BOOTSTRAP_ARCHITECTURE.md`'s cross-cutting analysis — confirm,
don't assume, the same discipline as everything else in this project.

Implement:

- Nothing new — reuse `services.yaml` and `scripts/run-services.ps1`/`install-iis.ps1`/`install-ad.ps1`/`install-sql-server.ps1`/`verify-post-reboot.ps1` from the sibling project unchanged.

Success criteria:

The same three roles (IIS, AD DS, SQL Server) that work against the sibling project's Server 2022 baseline also work unmodified against this project's offline-applied disks, for Windows Server 2025 (and later Windows 11, once its track is reattempted here too).

**Status:** not started — blocked on Phase 2, and specifically on Phase 2 succeeding for **all
three** target OSes (Server 2025, Server 2022, Windows 11), not just the first one bootstrapped.

---

# Phase 4: Datadog Integration

Implement:

- runtime secret injection
- Agent installation
- configuration
- validation

Success criteria:

Datadog Agent is healthy.

**Status:** not started — same as the sibling project's own Phase 4.

---

# Phase 5: Lifecycle Automation

Implement:

- build workflow
- verification workflow
- destroy workflow

Success criteria:

The environment can be repeatedly created and destroyed.

**Status:** not started — same as the sibling project's own Phase 5.

---

# Engineering Standards

Same standards as the sibling project, restated because they mattered more than expected there:

## Research-first discipline: search before you troubleshoot, reuse before you build

**The default first move on hitting any problem — a bug, a "how do we do X" design question, or a
missing capability — is a real, multi-angle web/community search, not an iterative trial-and-error
loop, and not a blank-page implementation.** This applies at two levels, and the difference matters:

- **Symptom-level**: before spending real time diagnosing something that looks broken, search for
  the literal, exact symptom (error text, log line, observed behavior) verbatim. Chances are good
  someone else hit it first.
- **Capability-level — bigger, more valuable, and easier to skip**: before building *any* new
  mechanism, even a small one, search for whether an existing, reasonably-maintained tool already
  does the whole job, or a documented recipe already exists from a primary source (vendor docs, or
  a mature open source project solving the same underlying problem in a different context). This
  is a search for *solutions*, not just *known bugs* — bigger in scope than "has someone hit this
  exact error before."

This project's own history so far is the evidence this works, not just a principle stated in the
abstract:

| Problem | What we almost built | What existing prior art turned up instead |
|---|---|---|
| Server 2025/Win11 interactive Setup boot failure (sibling project) | Hours more of keystroke-timing tuning | A known, open, unresolved upstream Packer/QEMU/OVMF issue (`hashicorp/packer#13342`/`#13514`) — confirmed via community search, not re-derived |
| Make an offline-applied disk bootable | A self-built WinPE image, booted once under QEMU just to run `bcdboot` | **BCD-SYS** — an actively-maintained tool that does the entire job from Linux with zero boots, found by searching for the *capability* ("BCD from Linux without booting Windows"), not a specific error |
| Inject boot-critical VirtIO drivers offline | A `DISM /Add-Driver`-in-WinPE mechanism | `virt-v2v`'s production-proven offline `hivex` registry-injection pattern — the exact same "disk won't boot because its new virtual hardware's driver isn't registered, and it can't boot to register it" problem, already solved by a much larger, better-funded project |
| Inspect VM screen state without the vncviewer-plus-manual-screenshot hassle | Automating a screenshot of a popped-open vncviewer window | QEMU's own built-in QMP `screendump` command — the "build" that happened was a ~50-line wrapper around an existing protocol, not new screenshot-capture logic |

Four for four. **None of these problems needed original engineering to solve the core mechanism —
each needed real engineering only to adapt an existing mechanism to our specific pipeline.** That
ratio is the goal here, and it's worth actively expecting it going forward rather than treating it
as luck.

**How to search well (concrete technique, not just "look it up"):**

- Search multiple angles per problem, not one query: the literal symptom/error text, the mechanism
  name framed as "from Linux" / "without Windows" / "offline" (when trying to avoid a heavyweight
  dependency), and a GitHub-native search (repo/topic search, not just a general web search) for
  tools that already wrap the primitive about to be built.
- **Verify the primary source; don't trust a search summary.** This project already caught one
  stale/wrong claim this way (a search result asserting MDT "doesn't support Windows Server 2022,"
  contradicted by checking the actual walkthrough it was supposedly based on). A tool's README,
  real commit history, and issue tracker are ground truth; an AI-generated search summary is a
  pointer to go check that ground truth, not a citation in its own right.
- Prefer sources that show their work (a real deployment walkthrough with actual commands run, a
  GitHub repo with visible recent activity) over sources that only assert a conclusion.
- A negative result is still a result: if a genuine multi-angle search turns up nothing, that's a
  legitimate signal to proceed to original engineering — not a reason to keep searching
  indefinitely. This is a mandate to search *before*, and to search *properly* (multi-angle,
  primary-source-verified), not a mandate to search forever.

**Deciding what to build vs. what to adopt** — not every finding is a clean "use this instead"; be
deliberate about how much of an existing tool to take on:

- **An existing tool solves the whole problem** (BCD-SYS, `virt-v2v`'s driver pattern, QEMU's own
  QMP protocol): adopt it directly as a dependency. Don't reimplement it "to keep things simple" —
  a well-established external tool a subprocess call away is simpler than an in-house
  reimplementation of the same logic, not more complex, even though it looks like "one more
  dependency" on paper.
- **An existing tool solves most of the problem but doesn't fit our pipeline shape as-is**: build
  the thin adapter/wrapper, not the underlying mechanism. `tools/qmp-screenshot.py` is the model
  for this — glue around a protocol QEMU already implements, not a new screenshotting system.
- **No tool exists, but a documented mechanism from a primary, credible source does** (Microsoft's
  own `DISM /Apply-Image` + `bcdboot` recipe, `\Windows\Panther\unattend.xml` for specialize):
  implement that documented mechanism directly rather than deriving a novel approach through trial
  and error.
- **Only build genuinely from scratch when neither of the above holds** — no tool, no documented
  recipe — or when an existing option was *actually tried and empirically found insufficient* for
  our specific constraints (not just "seemed complicated"). Even then, keep and document what was
  learned from the failed adoption attempt (same "document findings as you go" standard below)
  rather than discarding it silently.
- Treat "is this actually maintained and does it actually do what it claims" as part of the
  evaluation, not an afterthought — a single-maintainer project with real recent activity and a
  documented use case matching ours (BCD-SYS) is worth a cheap empirical test; an abandoned or
  vague one isn't worth the same trust without more scrutiny.

## The rest of the standards

- **Verify before trusting.** Check download URLs with a real request before using them, not just
  a search-result summary. Confirm WIM image names/edition IDs by direct extraction before writing
  them into a config. Don't assume a mechanism (`bcdboot`-equivalent, `DISM /Apply-Unattend`
  behavior, etc.) works the way you expect without testing it.
- **Prefer simple designs, explicit commands, readable scripts.** Avoid unnecessary abstractions,
  hidden dependencies, manual intervention, storing secrets, overly complex frameworks — same list
  as the sibling project's own standards, unchanged.
- **This is genuinely unsolved R&D in places (Phase 2 especially).** It's fine — expected,
  even — for early attempts to fail and require real debugging. Document findings as you go, the
  same way the sibling project's engineering logs do (symptom, diagnosis, root cause, fix, or
  honestly "shelved, here's what we tried and why it didn't work") rather than only writing things
  down once something fully succeeds.
- **Inspect VM screen state via `tools/qmp-screenshot.py`, not a `vncviewer` window plus a manual
  screenshot.** See the "VM screen inspection" note under QEMU/KVM/libvirt above. This was a real
  hassle in the sibling project's debugging sessions and has a clean fix here — use it from the
  start rather than falling back to the old workflow out of habit.

---

# Claude Instructions

Before generating significant implementation code:

1. **Search for existing tooling or a documented mechanism first** — see "Research-first
   discipline" under Engineering Standards above. Don't start designing a new mechanism before
   checking whether one already exists to adopt or adapt.
2. Explain the proposed design.
3. Identify assumptions.
4. Identify risks.
5. Ask questions where requirements are unclear.

Do not produce a large monolithic implementation. Work in phases, per the Development Approach
above. Given how much of this project is still genuinely unsolved (particularly "make the disk
bootable"), expect to spend real time on investigation and small experiments before writing
substantial code — that's the actual shape of this work, not a detour from it.
