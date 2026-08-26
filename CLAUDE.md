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

**Phase 2** (the offline-apply installation mechanism itself, where almost all of the real, unsolved work was) is **done** for its own success criterion — offline image application → bootable → specialized → real, unattended WinRM connectivity — confirmed end-to-end for **all three target OSes** (Windows Server 2025, Windows Server 2022, Windows 11 Enterprise Evaluation) when hand-run (see its entry under Development Approach below, and `PHASE2_ENGINEERING_LOG.md`'s Session 11/Finding 41, Session 12/Finding 42, and Session 13/Finding 43 for the full trail). `image-apply/`'s real scripts formalizing that recipe were written and confirmed during Phase 3's own Session 2 for Server 2022/2025 specifically; Session 3 then ran the same scripts against Windows 11 and found real, blocking problems the hand-run recipe never hit — see `PHASE3_ENGINEERING_LOG.md` Session 3 and `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`.

**Phase 3** (role provisioning) is **done**, including the production pipeline — the same three roles (IIS, AD DS, SQL Server) reused unchanged from the sibling project are confirmed live against both Windows Server 2025 and Windows Server 2022, under two mutually-exclusive profiles (domain-controller vs. app-server), through both a fast-iteration test harness (`dev/`) and the real production path (`image-apply/`'s scripts + `packer/boot-and-provision.pkr.hcl` + `build.sh`, taking a blank disk all the way to a provisioned VM with no hand-run steps). See its entry under Development Approach below and `PHASE3_ENGINEERING_LOG.md` for the full trail across both sessions. **Phases 4-5** are not yet started.

**Windows 11 is also production-ready, as of Phase 3.4/3.5**, via a genuinely different mechanism than Server 2022/2025's Phase 2/3 pipeline above (Setup.exe-driven, `image-apply/windows11-setup-install.sh`, no Packer handoff, no roles - Windows 11 doesn't get AD DS/IIS/SQL Server). See the "RESOLVED" note under Phase 3's own section below and `PHASE3_ENGINEERING_LOG.md`'s Phase 3.4/3.5 entries for the full trail - six independent clean production runs total.

---

# Open Items

Standing list of concrete, not-yet-done work called out explicitly so it doesn't get lost in phase
narrative below. Each item still has its full context/evidentiary trail in the relevant phase section
and the matching `PHASE*_ENGINEERING_LOG.md` - this list exists purely for discoverability. Remove an
item (and update the phase section it points at) once it's actually resolved, don't just leave it
stale here.

- **Windows 11's `register-vm.sh` device-model case is unconfirmed.** `register-vm.sh`'s
  virtio-scsi + virtio-net + QXL/SPICE device model has been proven by a real `virsh start` boot for
  Server 2022 and Server 2025 (2026-08-26), but never for Windows 11 specifically - its NIC-swap
  branch (Windows 11 swaps NIC too, unlike Server 2022/2025, which leave it untouched) has only been
  checked for its WinRM-command-length budget, not exercised by an actual boot. See Phase 3A's own
  section below and `PHASE3_ENGINEERING_LOG.md`'s "PHASE 3 STATUS: COMPLETE" entry (2026-08-26) for
  full context.

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
  Since the cache itself is binary and untracked, `ISO_CACHE_INVENTORY.md` (this repo, git-tracked)
  is the durable record of what's cached, when, and from where — checksums independently
  re-verified against their sidecars, not just copied. Regenerate it (recipe included in the file
  itself) whenever the cache's contents change, rather than letting it go stale.
- **Reuse the pattern, not necessarily the exact files**: the `dev/` fast-iteration harness pattern
  (a frozen baseline disk + Packer's `disk_image = true`/`use_backing_file = true` copy-on-write
  overlay, for testing changes in minutes instead of a full rebuild).
- **Do not reuse**: anything related to `boot_command`, VNC keystroke injection, or
  `autounattend.xml`'s `Microsoft-Windows-Setup` disk-partitioning/image-selection component. That
  entire mechanism is what this project exists to replace. **Server 2022/2025: this ban is absolute,
  no exception. Windows 11: partially relaxed — see the second "RECONSIDERED" note below.**

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

  **RECONSIDERED AGAIN, Windows 11 only, as of `PHASE3_ENGINEERING_LOG.md`'s "HARD STOP" section
  (end of Session 4): the ban on `Microsoft-Windows-Setup` is relaxed for Windows 11 specifically —
  Server 2022/2025 stay fully banned from it, unchanged, no exception.** This is not a reversal on a
  whim: the fully-offline approach this rule protects (apply → bootable → specialize → real first
  boot, no Setup.exe anywhere) was pursued for Windows 11 through two full architectural variants —
  staying entirely offline (Option A, Session 3) and inserting a live Audit Mode + Sysprep cycle
  matching Microsoft's own OEM manufacturing flow (Option B, Session 4) — and **both terminate at
  the identical, deterministic, kernel-level NTFS BSOD** during Windows 11's real first boot. A full
  audit ruled out this project's own code, host environment, and input media as the cause; targeted
  research found no community precedent for the exact combination. See the HARD STOP section for
  the complete evidentiary record before assuming this note alone justifies anything.

  **What's actually different this time, so this doesn't quietly re-open the door Findings 19/24/
  25/27/28 closed**: `WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md` (Phase 3) proposes driving Setup.exe
  via an ISO patched with Microsoft's own, officially-shipped `_noprompt` boot files
  (`efisys_noprompt.bin`/`cdboot_noprompt.efi` — genuine 15-year-old Microsoft tooling, verified
  present on this project's own cached install media, not a community hack) — this *eliminates* the
  "press any key" prompt by construction, rather than timing a keystroke against it — combined with
  a hand-built `qemu-system-x86_64` invocation using this project's own already-proven `bootindex=`
  device control (not Packer's QEMU builder, whose own documented inability to set UEFI boot order
  is what both this project's and the sibling project's prior Setup.exe investigations were actually
  blocked on). **`boot_command`/VNC keystroke injection remain banned, for Windows 11 too** — this
  relaxation does not readmit them; the whole point of the new approach is that no keystroke race
  exists to drive in the first place. Whether `EarlyF6DriverInstall` or some other Setup.exe gate
  refires under this different boot-medium shape is explicitly unconfirmed and is exactly what
  `WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md`'s own Phase 3.1-3.2 gates test before anything is
  trusted — treat this note as permission to attempt the plan, not confirmation the plan works.

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

**RESOLVED as of Phase 2's completion**: both tiers were actually tested, not left as open
questions. BCD-SYS and real `bcdboot` run from a self-built WinPE session (the fallback that
shipped) both independently produce a correctly-booting BCD - see "Status: Phase 2 is done" under
Phase 2 below for the full record. The production path that shipped is the WinPE `bcdboot` fallback
(`image-apply/make-bootable.sh`), not BCD-SYS - the framing above (BCD-SYS as "first attempt")
reflects the original plan, not what was ultimately adopted into production.

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

Several small tools implement this, in `tools/`:

- **`tools/qmp-screenshot.py`** — one-shot capture: `--socket <qmp.sock> --out <shot.png>`. Stdlib
  only (`socket` + `json`), no dependencies. Confirmed working end-to-end against a real QEMU
  instance (see engineering notes below).
- **`tools/qmp-watch.sh`** — loops the above at a configurable interval/count with timestamped
  filenames, for watching a boot sequence unfold frame-by-frame (e.g. diagnosing UEFI boot-prompt
  timing) instead of guessing at keystroke/timing parameters blindly.
- **`tools/qmp-sendkey.py`** — sends one or more key combos (QEMU monitor `sendkey` syntax, e.g.
  `alt-tab`, `ret`, `shift-f10`) — works against a plain PS/2 keyboard, no extra device needed.
- **`tools/qmp-click.py`** / **`tools/qmp-type.py`** — absolute-position mouse clicks and literal
  text typing. **Require a USB tablet device on the target VM** — see the gotcha immediately below;
  without it these two tools cannot work at all, not just work inaccurately.

**Known gotcha — mouse clicks need a USB tablet device, or they silently can't work.** A qemu guest's
default pointer is a relative PS/2 mouse, which `qmp-click.py`'s absolute-position clicks cannot
drive at all in this project's WinPE/Setup/Audit-Mode environments (confirmed directly: relative
`"rel"` QMP input-send-event calls succeed with no error, but the guest's on-screen cursor never
moves — `windows-auto-build-pipeline` `PHASE3_ENGINEERING_LOG.md` Session 4/Finding 10). The sibling
project (`../windows-server-vm-automation/register-vm.sh`) hit and fixed the identical problem for
its own VNC/SPICE console access via libvirt domain XML: `<input type='tablet' bus='usb'/>`, with
its own comment explaining why — *"Without this, libvirt defaults to a relative PS/2 mouse, which
desyncs from the VNC/SPICE client's absolute cursor position and makes the console unusable (clicks
land somewhere other than the visible cursor). A USB tablet reports absolute coordinates, so guest
and client cursors always agree."* This project's own ad hoc `qemu-system-x86_64` invocations don't
use libvirt domain XML, so the equivalent fix is two raw device flags, needed on **any** invocation
this project builds that might ever need `qmp-click.py` (not specific to Windows 11, or to any one
phase — general-purpose, add it up front rather than rediscovering the gap each time):
`-device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0`. Session 4's own ad hoc solo-boot
command didn't have this and had to fall back to keyboard-only `Alt+Tab`/`Escape` navigation via
`qmp-sendkey.py` instead, which happened to be sufficient there but won't always be. **Closed as of
Phase 3.4/3.5's completion**: both of this project's real production `qemu-system-x86_64`
invocations (`make-bootable.sh`, covering Server 2022/2025; `windows11-setup-install.sh`, covering
Windows 11) now include this device pair up front, verified with a real boot rather than assumed -
all three target OSes are covered.

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
- `xorriso`, `mkisofs`/`genisoimage` (Windows 11's Setup.exe-driven build path only — rebuilding the
  `_noprompt`-patched install ISO and the small answer-file delivery ISO, `image-apply/
  build-iso-noprompt.sh`/`windows11-setup-install.sh`)
- `pywinrm` (`pip3 install pywinrm`) for `python3`'s own `winrm` module — Windows 11's Setup.exe-
  driven build path uses this directly for its own WinRM confirmation step, rather than reaching
  into any unrelated virtualenv (a mistake made once during Phase 3.4's own interactive testing and
  corrected before the production script was committed - see PHASE3_ENGINEERING_LOG.md). Confirmed
  already present system-wide on this host as of Phase 3.4; a fresh host needs it installed
  explicitly.

## Guest

Same as the sibling project: Windows Server 2022/2025 Evaluation, Windows 11 Enterprise
Evaluation; UEFI boot; VirtIO devices; QEMU Guest Agent.

---

# Windows Configuration Goals

Unchanged from the sibling project — see its `CLAUDE.md` for the full detail on AD DS, IIS, SQL
Server, and Datadog Agent requirements, all of which apply here identically since they're
implemented by the reused role-provisioning scripts. `services.yaml`'s Service Selection design
(roles are opt-in per build, not bundled by default) carries over unchanged.

**AD DS, IIS, and SQL Server are Server-20XX-specific — not applicable to Windows 11, full stop.**
Explicit direction: don't implement or attempt any of these three roles against a Windows 11 build,
and don't build "light"/"express" stand-ins for them on Windows 11 either — there's no interest in
that. Windows 11's role in this project is scoped separately from the Server SKUs' AD/IIS/SQL
monitoring-integration goals; whatever Windows 11 actually needs for Phase 3 (if anything beyond the
Datadog Agent itself, tracked as Phase 4) isn't decided yet — don't assume it mirrors the Server
roles. `services.yaml`'s existing `ad-ds`/`sql-server` entries being Server-only, unenforced-at-runtime
gap (`run-services.ps1` only skips a role when its script is missing, not when it's inapplicable to
the current OS) is real and already flagged in `PHASE2_ENGINEERING_LOG.md`'s Session 13 next-steps —
this is the same fact, now stated as project direction rather than just an implementation gotcha to
watch for.

---

# Datadog Validation Requirements

Unchanged from the sibling project — see its `CLAUDE.md` for the full detail (Windows service
exists, Agent service running, status healthy, connectivity succeeds, host registration confirmed
if practical; the implementation must clearly report failures). Not yet implemented in either
project — tracked here as Phase 4, now generalized beyond just Datadog (see Phase 4's own section
below for the full "Tooling" scope) but this validation bar for the Datadog Agent specifically is
unchanged by that generalization.

---

# Repository Structure

Expect this to evolve significantly as the actual offline-apply pipeline gets built — this is a
starting sketch, not a fixed target. It has not been kept fully current (e.g. `tools/qmp-eject.py`,
`tools/qmp-pixel.py`, `tools/qmp-sendkey.py`, `tools/qmp-click.py`, `tools/qmp-type.py`,
`packer/`'s `dev/role-test.pkr.hcl` sibling, and `image-apply/`'s various `.xml` templates aren't
listed below) - treat it as a rough map of the major pieces, not an exhaustive or current listing;
`find` or `ls` the real tree for that.

```
windows-auto-build-pipeline/

├── README.md
├── CLAUDE.md
├── HANDOFF_FROM_UNATTENDED_INSTALL.md   # read this first
├── services.yaml                         # copied/adapted from the sibling project
├── build.sh                              # real: orchestrates image-apply/*.sh then Packer, then
│                                            # inject-virtio-spice.sh (Phase 3A, all three OSes)
├── register-vm.sh                        # real: defines a libvirt domain from a finished build's
│                                            # disk (virsh list/virt-manager visibility) - adapted
│                                            # from ../windows-server-vm-automation/register-vm.sh

├── image-apply/                # real, confirmed production for Server 2022/2025
│   │                             # (PHASE3_ENGINEERING_LOG.md Session 2). Windows 11 no longer uses
│   │                             # this offline-apply sequence at all as of Phase 3.4 - it has its
│   │                             # own separate, self-contained script (windows11-setup-install.sh,
│   │                             # not listed below - this diagram is a known-stale sketch, see the
│   │                             # note under Repository Structure's own heading)
│   ├── lib/common.sh           # per-OS config table (WIM index, driver subfolder, disk size, name)
│   ├── partition-disk.sh       # qemu-nbd + sgdisk + mkfs - Server 2022/2025 only
│   ├── apply-image.sh          # wimlib apply - Server 2022/2025 only
│   ├── make-bootable.sh        # WinPE + bcdboot, then offline viostor/netkvm driver injection - Server 2022/2025 only
│   ├── apply-unattend.sh       # drops %WINDIR%\Panther\unattend.xml - Server 2022/2025 only
│   ├── windows11-setup-install.sh  # real production script for Windows 11 - Setup.exe-driven,
│   │                                  # self-contained (partition+install+bootable+specialize in
│   │                                  # one unattended run, no Packer handoff)
│   ├── build-iso-noprompt.sh   # builds the _noprompt-patched Windows 11 install ISO
│   └── historical/              # retired scripts, kept as record - audit-mode-sysprep.sh,
│                                   # calibrate-eject-timing.sh

├── packer/
│   └── boot-and-provision.pkr.hcl   # real: disk_image=true, no ISO/boot_command - boots the
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
│   └── install-tools.ps1       # future (Phase 4, generalized "Tooling" - 7-Zip/PuTTY/WinSCP/
│                                  # Chrome/Notepad++/Datadog Agent, see Phase 4's own section;
│                                  # supersedes the originally-sketched install-datadog.ps1 name)

├── tools.yaml                    # future (Phase 4) - which tools to install + Datadog config
│                                  # (site/tags only, never the API key - see Phase 4's "Secret
│                                  # handling" note)

├── dev/                        # fast-iteration harness, same pattern as the sibling project's
│   └── ...

├── tools/                      # host-side Linux dev/debug tooling (distinct from scripts/,
│   │                             # which is Windows-side PowerShell reused verbatim)
│   ├── qmp-screenshot.py       # one-shot QEMU framebuffer capture via QMP, no VNC viewer needed
│   ├── qmp-watch.sh            # loops qmp-screenshot.py for watching a boot sequence unfold
│   ├── gen-viostor-ddb-reg.py  # generates the source-verified .reg file that offline-registers
│   │                             # a virtio PCI driver (viostor/netkvm) into a SYSTEM hive's
│   │                             # DriverDatabase, per virt-v2v's own recipe - see
│   │                             # PHASE2_ENGINEERING_LOG.md Finding 29
│   ├── sudoers-windows-auto-build-pipeline  # scoped NOPASSWD sudoers rules for the disk-prep
│   │                             # commands this pipeline needs (qemu-nbd, sgdisk, mkfs.vfat/
│   │                             # mkntfs, mount/umount, ntfsinfo/ntfsfix) - pinned to /dev/nbd*
│   │                             # only, never a real host disk; not installed automatically,
│   │                             # see the file's own header for the visudo-checked install step
│   └── vendor/                 # BCD-SYS clone target (PREREQUISITES.md) - gitignored, not
│                                   # vendored into this repo's own git history

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

**This 10-step sequence is Server 2022/2025's real production lifecycle.** Windows 11's, as of
Phase 3.4, is different and simpler: steps 3-7 collapse into one unattended Setup.exe-driven run
(`image-apply/windows11-setup-install.sh`) with no Packer handoff, and step 8 doesn't apply (no
roles for Windows 11 - see "Windows Configuration Goals" above). Steps 9-10 (Datadog, validation)
remain Phase 4, not yet implemented for any OS.

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

**Status: Phase 2 is done.** Its success criterion is met for **all three target OSes** — Windows
Server 2025, Windows Server 2022, and Windows 11 Enterprise Evaluation. Offline image application →
bootable → specialized → real, unattended, externally-reachable WinRM connectivity, no manual
interaction, no Setup.exe involved anywhere, confirmed independently for each OS with the underlying
tooling requiring zero changes between them. Read `PHASE2_ENGINEERING_LOG.md`'s "STATUS AND NEXT STEPS
ON RESUMPTION (Session 13)" section before doing anything else here — **per the explicit phase-gating
rule below, Phase 3 can now begin.** Sub-milestone 1 (make the disk bootable) remains **solved, three
times over**:
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

Session 9 then added the offline specialize/unattend pass itself (Build step 6:
`\Windows\Panther\unattend.xml`, dropped directly onto the offline-mounted image with no
DISM/Setup.exe involvement) on a third independent from-scratch disk, and **it works exactly as
documented**: `ComputerName` took effect, OOBE was skipped, `AutoLogon` reached a real desktop, and
`FirstLogonCommands` executed. A genuinely new and useful side-discovery (Finding 35): a single QEMU
session can carry a disk from "just made bootable" straight through into the target's own first real
boot, since WinPE's `wpeutil shutdown` causes OVMF to retry boot enumeration within the same process
rather than needing a second VM launch.

Session 10 then generalized `tools/gen-viostor-ddb-reg.py`'s offline `hivex` `DriverDatabase`
registration to NetKVM (`--driver netkvm`, using `PCI\VEN_1AF4&DEV_1000`/`DEV_1041` and per-driver
values confirmed from `netkvm.inf` itself, not assumed from viostor) — and this **did** get the device
correctly PCI-matched (`Service=netkvm`), but that alone turned out **not to be sufficient**: Windows'
own Config Manager reports `CM_PROB_NEED_CLASS_CONFIG` for it (Finding 39) — `DriverDatabase`
registration only replicates what a boot-critical storage driver needs; a network-class device needs
the fuller NDIS class-installation Windows normally performs live, at the moment a running OS
discovers the device, which an offline registry hack alone can't replicate. Re-reading the sibling
project's own proven `autounattend.xml.pkrtpl` (Finding 40) showed it already solved this identical
problem, for the identical reason, with a `FirstLogonCommands` step running `pnputil /add-driver`
**while the OS is live and booted** — the correct fix here is to adopt that same pattern (this project
already stages the driver files at `C:\Drivers\NetKVM\2k25\amd64` during the offline-apply stage, so no
CD-ROM is even needed), not a new offline mechanism.

Session 11 then implemented exactly that fix: a `FirstLogonCommands` `Order 1` step running `pnputil
/add-driver C:\Drivers\NetKVM\2k25\amd64\netkvm.inf /install` while the OS is live and booted, ahead of
the existing network-wait/WinRM-enable steps, in a revised `unattend.xml` now committed to the repo at
`image-apply/unattend-server2025.xml` (no longer left only in `/tmp`). Built a fourth from-scratch
disk, let `FirstLogonCommands` run fully undisturbed (watching the system tray's network icon as a
non-destructive readiness signal rather than guessing at a delay), and confirmed **real, authenticated
WinRM connectivity from the host**: `hostname` returned the exact `ComputerName` set in the answer
file, and `Get-NetAdapter` showed a fully functional `Red Hat VirtIO Ethernet Adapter` (`Status: Up`,
`10 Gbps`) — not just a PCI-level driver match. See Finding 41 for the complete verification trail,
including the `pnputil` log's own confirmation (`"Driver package installed on device:
PCI\VEN_1AF4&DEV_1000..."`).

Session 12 then repeated the entire sequence for **Windows Server 2022** — and it generalized with
**zero changes to any of the reusable tooling** (`tools/gen-viostor-ddb-reg.py`'s existing presets,
the WinPE bootability medium itself, the `FirstLogonCommands` structure), only OS-specific input values
differed (`install.wim` index 2 again, confirmed independently rather than assumed; the virtio driver
subfolder `2k22` instead of `2k25`; `ComputerName` and the `pnputil` driver path in a new
`image-apply/unattend-server2022.xml`). Confirmed the same way: real WinRM `hostname` returned
`WIN2022-S12`, and `Get-NetAdapter` showed a working `Red Hat VirtIO Ethernet Adapter`. One useful
side-confirmation (Finding 42): the **same WinPE bootability medium works unmodified across target OS
versions** — `bcdboot` copies the target's own boot binaries, not WinPE's, so no per-OS WinPE medium is
needed.

Session 13 then repeated the sequence for **Windows 11 Enterprise Evaluation** — the one target OS with
no prior "it just worked" data point (this project's own Setup.exe pivot was abandoned there in
Sessions 3-6, and the sibling project's own separate Windows 11 build, with a real `swtpm` + Secure-Boot
firmware, never got past a Setup.exe boot-timing issue either). Re-reading the sibling project's
`WINDOWS11_UNATTENDED.md` first (Finding 43) confirmed *why* this project's approach sidesteps that
problem entirely: TPM 2.0/Secure Boot are enforced by **Setup.exe's own hardware-compatibility check**,
not by the boot process of an already-installed system — since this pipeline never runs Setup.exe, that
gate is never evaluated. Confirmed empirically, not just inferred: the Windows 11 target booted cleanly
to a real desktop (its own "Windows 11 Enterprise Evaluation" watermark visible) with no
hardware-compatibility warning of any kind, and real WinRM connectivity followed the same way as both
Server builds — `hostname` returned `WIN11-S13`, `Get-NetAdapter` showed a working `Red Hat VirtIO
Ethernet Adapter`. Once again, **zero tooling changes** were needed, only OS-specific inputs (`w11`
driver subfolder, a new `image-apply/unattend-windows11.xml`). One new operational note: Windows 11 has
**Fast Startup enabled by default** (Server SKUs don't) — a normal shutdown hibernates rather than fully
powers off, which `ntfs-3g` correctly detects and falls back to read-only for; harmless, but worth
knowing before attempting a future offline read-write edit of a Windows 11 disk.

**Phase 2 is done.** See `PHASE2_ENGINEERING_LOG.md` for the complete, detailed record across all
thirteen sessions — it's long, but everything needed to resume Phase 3 without re-deriving any of this
is there.

---

# Phase 3: Windows Configuration

**Process gate satisfied as of Session 13 — Phase 3 work may now begin.** The gate required Windows
Server 2025, Windows Server 2022, *and* Windows 11 Enterprise Evaluation to each individually
bootstrap successfully (offline apply → bootable → specialized → real WinRM connection, no manual
steps) under this project's mechanism, precisely to avoid investing in the service layer on the
assumption that Phase 2's mechanism generalizes across all three OSes before actually confirming it
does. All three are now confirmed independently — see `PHASE2_ENGINEERING_LOG.md` Findings 41
(Server 2025), 42 (Server 2022), and 43 (Windows 11) for the full verification trail on each.

**Scope note: Phase 3 as specified below (AD DS, IIS, SQL Server) is Server-20XX-specific.** Windows
11 does not get these roles — see "Windows Configuration Goals" above. Phase 3's own success
criteria therefore only concern Windows Server 2025 and Windows Server 2022; Windows 11's Phase 2
success already stands on its own and doesn't gate on anything below.

Implement:

- Reuse `services.yaml` and `scripts/run-services.ps1`/`install-iis.ps1`/`install-ad.ps1`/`install-sql-server.ps1`/`verify-post-reboot.ps1` from the sibling project unchanged, **plus one small addition not present in the sibling project**: two mutually-exclusive profiles (`ad-ds` alone vs. `iis`/`sql-server` together) enforced by a small guard added to `scripts/run-services.ps1` and a fast host-side pre-check in `dev/run-phase3-test.sh`. See `dev/services-domain-controller.yaml` / `dev/services-app-server.yaml` for the two ready-made profile files.

Success criteria:

The same three roles (IIS, AD DS, SQL Server) that work against the sibling project's Server 2022 baseline also work unmodified against this project's offline-applied disks, for both Windows Server 2025 and Windows Server 2022.

**Phase 3 is done, including the production pipeline, not just a test harness proving the
reused scripts work.** `image-apply/`'s real scripts (`lib/common.sh`, `partition-disk.sh`,
`apply-image.sh`, `make-bootable.sh`, `apply-unattend.sh`) and the production
`packer/boot-and-provision.pkr.hcl` + `build.sh` orchestrator now exist, transcribed directly from
`PHASE2_ENGINEERING_LOG.md`'s proven recipe rather than reconstructed from memory. Confirmed
end-to-end from a completely blank disk through to a WinRM-reachable, role-provisioned VM for both
target OSes:

- Server 2022 + `ad-ds`: 6m49s, NTDS/DNS up, domain live after reboot
- Server 2025 + `iis`/`sql-server`: 50m57s, HTTP 200, SA login + live `SELECT 1`

A separate `dev/`-based fast-iteration test harness (`dev/role-test.pkr.hcl` +
`dev/run-phase3-test.sh`) also exists for quick role-script iteration against Phase 2's own
reference disks without repeating a full fresh build each time — this is the harness, not the
production path, and it's what the first Phase 3 session (below) originally validated all four OS ×
profile combinations against.

Getting from "the recipe is proven" to "the recipe is a real script" surfaced five more real,
non-obvious bugs (sudoers scoping, nbd attach-timing races, a boot-order idempotency gap that
permanently poisons a disk's one-shot Windows Setup passes if hit, and a missing driver-package file
`pnputil` needs but offline `DriverDatabase` registration doesn't) — see `PHASE3_ENGINEERING_LOG.md`
Session 2 for the full record of each, plus Session 1's original `cpu_model` finding. **Still open,
not blocking Server 2022/2025 (confirmed production-ready, six independent successful builds across
both OSes):** `image-apply/build-winpe-medium.sh` (documenting how to rebuild the WinPE bootability
medium from scratch) wasn't written, so a genuinely fresh environment with no prior
`image-apply/output/` state currently has no way to produce one; `build.sh` itself wasn't run
start-to-finish as a single invocation (each stage was confirmed individually while iterating on the
bugs above).

**Windows 11 was run through the new scripts in Session 3 and found genuinely blocking problems —
not just "untested but presumably fine"**: an interactive OOBE screen unattend settings alone can't
suppress, and a real kernel-level NTFS BSOD, both root-caused to Windows actually processing a valid
`unattend.xml` (not the offline write that delivers it). Server 2022/2025 show none of this. See
`PHASE3_ENGINEERING_LOG.md` Session 3 (Findings 7-9) for the full trail.

**HARD STOP on the fully-offline (Setup.exe-free) Windows 11 pathway, by explicit direction, as of
Session 4.** Both architectural options this project considered — staying fully offline (Option A)
and inserting a live Audit Mode + Sysprep cycle matching Microsoft's own OEM manufacturing flow
(Option B, `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`) — were pursued to a real, evidence-backed
conclusion and both terminate at the identical BSOD. A full audit ruled out this project's own code,
host environment, and input media as the cause (byte-identical to the one hand-run build that did
succeed); multi-angle research found no community precedent for the exact combination. See
`PHASE3_ENGINEERING_LOG.md`'s "HARD STOP" section (end of Session 4) for the complete record.
**Server 2022/2025's production pipeline is unaffected and remains confirmed production-ready** —
none of the Windows-11-specific work is in its code path. Next step for Windows 11 is a new research
question (how unattended Windows 11 builds are actually done successfully elsewhere), not a further
variant of Option A/B — not yet started as of this entry.

**RESOLVED as of `PHASE3_ENGINEERING_LOG.md`'s Phase 3.4/3.5 entries: Windows 11 is now
production-ready too**, via the Setup.exe-driven path this research question led to (see the
"RECONSIDERED AGAIN, Windows 11 only" note above under "Relationship to
`../windows-server-vm-automation/`" for why Setup.exe is back in play for Windows 11 specifically).
`image-apply/windows11-setup-install.sh` is the real production script - confirmed via six
independent clean runs total (Phase 3.3's three eject-based confirmations, since superseded, plus
Phase 3.4's four NVRAM-boot-order confirmations and Phase 3.5's two full production-readiness
builds). `build.sh` routes `windows11` through this script directly, with no Packer handoff (no
Phase 3 roles apply to Windows 11).

**Phase 3A (new, cross-cutting, done as of 2026-08-23): VirtIO storage/NIC/SPICE display drivers,
`WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`.** Not a continuation of Phase 3.1-3.5's own numbered
sequence (that closed with Windows 11 production-ready, above) - a distinct addition layered on top
of already-proven builds. Real, committed production tooling exists
(`image-apply/inject-virtio-spice.sh`, OS-parameterized) and is confirmed done for **all three target
OSes**, 2 independent clean runs each (6 total): Windows 11 gets `vioscsi` + `netkvm` + QXL/SPICE;
Server 2022/2025 get `vioscsi` + QXL/SPICE (`netkvm` stays on the existing, already-proven
offline-hivex mechanism, deliberately untouched - see the plan doc's "Scoping revised" note for why
NIC stays Windows-11-only while storage doesn't). Every clean run, on every OS, negotiated the
identical `VEN_1AF4&DEV_1048` PCI ID for `vioscsi`. See the plan doc's own Findings 3A-1 through 3A-3
for the real, hard-won mechanics (live-PnP-verify-before-swap; never relocate an already-primary
device's PCI placement; a Stage 1 "verify" device must match Stage 2's real device topology exactly,
or it can verify the wrong PCI hardware ID) - also generalized into the "Version-sensitivity and
brittleness" standard under Engineering Standards below, since Finding 3A-3 specifically exposed that
PCI/driver hardware-ID assumptions are QEMU-version-sensitive, not just Windows-version-sensitive.

**Finding 3A-4 (2026-08-23): `qxldod` swap is real and worth keeping, but it did NOT fix the Start
Menu crash - that was a wrong initial conclusion, corrected the same night by further testing.**
`spice-guest-tools`' own bundled QXL driver is a genuinely outdated, non-WDDM driver (real gap,
worth fixing on its own merits - see the `qxldod` staging/verification described above, still a good
change). But the actual Start Menu crash (`StartMenuExperienceHost.exe` faulting in
`Windows.UI.Xaml.dll`, `STATUS_STACK_BUFFER_OVERRUN`) was first "confirmed fixed" based on an invalid
test: launching the process via a WinRM PowerShell session, which runs in Session 0 (services), not
the real interactive Session 1 - UWP apps can't run in Session 0 at all, so that test's "no crash"
result was a false negative, not evidence of a fix. A real test (a scheduled task with `/it`,
launching into the actual interactive session) reproduced the **identical** crash - same fault
offset (`0x92e66`), same module version - on a disk already running `qxldod`, proving the driver was
never the cause. Independent, decisive counter-evidence from the user: a real, long-lived reference
VM (`win2022-dc`) has a *working* Start Menu while still running the *old* 2017 classic driver -
directly contradicting a driver-based explanation. See Finding 3A-5 below for the real root cause
and fix. The `qxldod` change itself is unaffected by this correction and stays in
`inject-virtio-spice.sh` - a real WDDM driver is still the right choice regardless of what turned out
to actually cause the crash.

**Finding 3A-5 (2026-08-23): the real root cause is a documented Windows Server 2022 RPC/DCOM
boot-race, triggered by this pipeline's own multi-boot-cycle build pattern - fixed via an offline
`ServicesPipeTimeout` registry increase, not yet re-verified by a fresh end-to-end run.** Root-caused
live over WinRM: the crash's exact signature (identical fault offset across two separate builds) plus
repeated `Microsoft-Windows-DistributedCOM` Event 10010 ("did not register with DCOM within the
required timeout") for `StartMenuExperienceHost` specifically pointed away from the display driver
entirely. A targeted search found a primary-source match describing this exact symptom triad -
Start Menu, Search, **and IIS** all failing after a Windows Server 2022 restart -
(https://learn.microsoft.com/en-us/answers/questions/5836440/): under heavy first-boot disk/CPU I/O
("boot storm"), the RPC Endpoint Mapper doesn't finish initializing within the default 30s
service-dependency timeout, so DCOM can't register local servers, so `SystemEventsBroker` and
`Background Tasks Infrastructure` fail to start, so anything depending on them (Start Menu, Search,
IIS) fails or crashes. This project's own build pattern is an unusually good match for the trigger
condition: every real build's first *interactive* boot follows several already-automated
boot/shutdown cycles on a freshly-applied, cold-cache disk (Packer's provision+restart, then
`inject-virtio-spice.sh`'s two more) - real "boot storm" conditions, not a one-off. Fix: an offline
`hivexregedit` merge in `make-bootable.sh` (same mechanism/location as the existing
viostor/netkvm `DriverDatabase` merges), setting `HKLM\SYSTEM\ControlSet001\Control\
ServicesPipeTimeout` = `120000` (120s - double the community-cited 60s, to leave real margin under
this project's own heavier-than-typical four-boot-cycle pattern) before the very first boot ever
happens, since the race is in early service startup and has usually already resolved (one way or the
other) by the time `FirstLogonCommands` would otherwise be the place to fix it. Applies to Server
2022 and Server 2025 identically (`make-bootable.sh` runs unmodified for both, no OS branching around
this change) - not yet confirmed for Server 2025 specifically, and not yet re-verified for Server
2022 either as of this entry; a fresh end-to-end run is in progress.

**`build.sh` wiring, and `register-vm.sh` (added 2026-08-23; live-verified for Server 2022 and Server
2025 as of 2026-08-26 - see below):**
`inject-virtio-spice.sh` was originally wired into `build.sh` only for the `windows11` branch; it now
also runs for `server2022`/`server2025`, after the Packer handoff completes, against Packer's own
final artifact rather than the pre-Packer copy under `image-apply/output/builds/` - so a real
`build.sh server2022`/`server2025` run now produces a vioscsi+QXL/SPICE disk unconditionally, matching
Windows 11's own build path exactly, not just on request.

**Real bug found and fixed while first testing this wiring (2026-08-23), not hypothetical**: Packer's
`output_directory` was fixed per OS (`packer/output/<os>/`), so a second `build.sh` run for the same
OS always failed - `packer build` refuses to run if `output_directory` already exists, and this
project's own earlier real Server 2022 production run (Phase 3, 2026-08-20) had already left that
directory populated. This would have hit every subsequent build of the same OS, not just this one; it
also would have made `inject-virtio-spice.sh`'s own per-run work-directory naming (derived from the
disk's basename) collide the same way, one level down. Fixed by threading a single unique `BUILD_ID`
(`build.sh`'s own `<os>-<timestamp>`, matching `image-apply/output/builds/*.qcow2`'s existing
convention) through everything Packer-side that used to be OS-only-named: `boot-and-provision.pkr.hcl`
gained a `build_id` variable driving `vm_name`/`output_directory`/`efi_firmware_vars`, and
`build.sh` now fails loud with a clear message (rather than silently colliding) if its computed
`TARGET_QCOW2`, Packer efivars path, or Packer output directory ever already exist before proceeding.
Packer's final artifact is now at `packer/output/<build_id>/<build_id>.qcow2` (build-unique), not a
fixed per-OS path - `register-vm.sh`'s own default disk resolution for Server 2022/2025 was updated to
match (picks the most recently modified build, same convention already used for Windows 11's own
timestamped builds). **`dev/role-test.pkr.hcl` (the separate fast-iteration harness, not the
production path) has the identical fixed-per-OS `output_directory` pattern and was not touched by this
fix** - flagged, not yet addressed; lower stakes there since that harness is explicitly a
repeated-iteration tool, but the same collision would reproduce if run twice for the same OS.

A new `register-vm.sh` (repo root, adapted from
`../windows-server-vm-automation/register-vm.sh`'s own proven `virsh define` pattern) defines a
libvirt domain from a finished build's disk so it shows up in `virsh list --all`/virt-manager instead
of existing only as a loose qcow2 file - device model (virtio-scsi disk, virtio-net NIC, qxl-vga + a
real SPICE channel, USB tablet) matches what `inject-virtio-spice.sh` already proved boots.

**`build.sh`'s own Server 2022/2025 wiring (including the `build_id` fix) is now confirmed by a real
run, not just written**: a fresh `build.sh server2022` run (2026-08-23, after the fix above) completed
the full sequence end-to-end - offline apply, Packer handoff (IIS provisioned, WinRM confirmed),
then `inject-virtio-spice.sh` Stage 1 (`vioscsi` live-verified `Status: OK`, SPICE tools installed) and
Stage 2 (real boot on virtio-scsi as primary storage, WinRM confirmed again, disk Online/NIC Up/QXL
OK/vdservice Running all verified). This is real evidence the Finding 3A-3 inference (a drive-attached
virtio-scsi-pci controller negotiates the same PCI hardware ID regardless of exact bus address) holds
for Server 2022, not just Windows 11. Final artifact:
`packer/output/server2022-20260823-141034/server2022-20260823-141034.qcow2`.

**`register-vm.sh` itself is now confirmed too, by a real `virsh start` boot (2026-08-23, same
session)**: `./register-vm.sh server2022` (no args - default disk/vm_name resolution both worked)
defined `win2022prod` cleanly, and `virsh start` booted it to a real, stable, logged-in Server Manager
desktop entirely through libvirt's own generated device topology (not `inject-virtio-spice.sh`'s own
raw QEMU flags) - confirmed via `tools/qmp-screenshot.py`-style evidence (here, `virsh screenshot`,
libvirt's own equivalent) at three points: OVMF's own boot log showing it loading `Boot0001 "UEFI
QEMU QEMU HARDDISK"` via `Scsi(0x0,0x0)` (proof libvirt's auto-assigned PCI address for the
virtio-scsi controller still negotiated a hardware ID Windows already had registered), a live desktop
with a "Networks" discoverability prompt for the newly-appeared NIC, and `virsh net-dhcp-leases
default` showing a real DHCP lease for hostname `WIN2022PROD` (matching the disk's own baked-in
ComputerName) at `192.168.122.214`. This is real evidence the Finding 3A-3 inference (libvirt's own
PCI address allocation doesn't need to reproduce `inject-virtio-spice.sh`'s exact raw `addr=` values)
holds, not just a plausible theory. **Not yet exercised: the Windows 11 device-model case** (NIC also
swapped, unlike Server 2022/2025) - same script, different code path, still unconfirmed by a real
boot.

**`register-vm.sh` now enforces its own precondition instead of just assuming it, and two real bugs
found via a genuine E2E run are fixed (2026-08-25/26, `PHASE3_ENGINEERING_LOG.md`'s corresponding
sessions have the full trail):** `inject-virtio-spice.sh` now writes a completion marker
(`C:\virtio-spice-injected.marker`) only once its own Stage 2 verification fully succeeds;
`register-vm.sh` checks for it offline before ever defining a domain, and fails loud (naming
`tools/boot-adhoc-target.sh` as the right tool instead) if a disk hasn't actually been through it -
closing the exact device-topology-mismatch confusion that cost real debugging time earlier this
project. Separately, a real `build.sh server2022` E2E run hit two genuine bugs in
`inject-virtio-spice.sh`: pywinrm's WinRM-command-line encoding has a real, hard length ceiling that
an accumulation of inline PowerShell comments had crept right up against (fixed with a deterministic
`assert_winrm_ps_budget()` guard, checked before ever booting a VM); and the error-path cleanup traps
were hard-killing a still-running qemu process with no graceful attempt first, which corrupted a live,
healthy Windows session's OOBE state on one run (fixed - both traps now try `qmp_graceful_shutdown`
first, matching this project's own standing graceful-shutdown convention). **Both fixes are now
confirmed by clean, unbroken, fully-detached `build.sh` E2E runs for both Server 2022 and Server 2025**
(2026-08-26) - IIS provisioned and verified, `inject-virtio-spice.sh` Stage 1/2 both clean, no
command-length error, no hard kill, `register-vm.sh`'s precondition check passed against a genuine
marker, both VMs booted via `virsh start` and verified live over WinRM (not just a screenshot -
`W3SVC` Running, HTTP 200, correct hostname). Windows 11's own NIC-swap verification payload was also
checked against the new length guard directly (2267 chars, well under budget) though Windows 11 itself
wasn't rebuilt this session - the device-model gap noted above remains genuinely open.

---

# Phase 4: Tooling (generalized from "Datadog Integration", 2026-08-23)

**Scope generalized, by explicit direction, from "install the Datadog Agent" to "install a
configurable set of post-build tools, of which Datadog is one."** The original three-line Phase 4
(runtime secret injection, Agent installation, configuration, validation) is now the Datadog-specific
slice of a broader, YAML-driven tool installer covering: 7-Zip, PuTTY, WinSCP, Google Chrome,
Notepad++, and the Datadog Agent. Nothing about Datadog's own success criterion changes (Agent
healthy, same validation bar the sibling project uses) — it's just no longer the *only* thing this
phase installs, and the mechanism that installs it should be reusable for the other five tools rather
than Datadog-specific.

**Why this belongs here, not as a one-off script**: Phase 3A gave every OS (including Windows 11,
which gets none of Phase 3's AD/IIS/SQL roles) a real, interactive, SPICE-reachable desktop for the
first time in this project's history. A desktop a human might actually sit at benefits from having
7-Zip/Chrome/Notepad++/PuTTY/WinSCP on it, not just headless monitoring - this phase is now genuinely
useful to all three target OSes, not just the Server SKUs Phase 3's roles are scoped to.

## Research first (per this project's own "search before you build" standard)

- **The sibling project has a `tools.txt`** (`../windows-server-vm-automation/tools.txt`) listing
  Notepad++, Google Chrome, Git For Windows, PuTTY, WinSCP, Visual Studio Code, 7-zip - confirmed via
  direct inspection that it is **not referenced anywhere** in that project's own scripts (`grep -rn
  "tools.txt"` there returns nothing). A real signal of intent, not working automation to adopt or
  reuse - there is no existing mechanism to search for tools, download them, or install them silently
  anywhere in either project. `install-datadog.ps1` also does not exist in either project's `scripts/`
  despite being listed in this project's own repo-structure sketch as "future" - Phase 4 has never
  been started anywhere.
- **Chocolatey** (Windows' own established package manager) has real, actively-maintained community
  packages for every tool on this list, including a documented silent-install-with-API-key syntax for
  Datadog Agent specifically (`choco install -ia="APIKEY=""<key>"""  datadog-agent`, MSI properties
  under the hood, `/qn /norestart`). **Considered and set aside, not adopted**: Chocolatey's own
  ecosystem documentation states plainly that its public community repository's reliability "cannot be
  guaranteed" for organizational/production use, and recommends internalizing packages or using a
  private/proxy repository (Artifactory, Nexus, ProGet) for reliable, repeatable builds - i.e.,
  Chocolatey's own maintainers say the same thing this project's own `ISO_CACHE_DIR` convention exists
  to solve (pinned, checksummed, locally-cached binaries rather than live fetches during a build).
  Adopting it as-is would also add a new bootstrapping dependency (Chocolatey itself needs installing
  on the guest, needing live internet access from inside the guest at exactly the right unattended
  moment) that this project's own Engineering Standards already warn against ("hidden dependencies").
  **Recommended instead**: extend this project's own already-proven `../iso_cache/`/
  `ISO_CACHE_INVENTORY.md` pattern (pinned URL, sha256 sidecar, downloaded once host-side, delivered
  to the guest via a mounted ISO or WinRM copy - exactly how `image-apply/inject-virtio-spice.sh`
  already delivers `spice-guest-tools-latest.exe`) to the other five tools' own official silent
  installers, and run each vendor's own documented silent-install flags directly - no new runtime
  dependency, no live-internet-from-the-guest requirement, consistent with every other binary this
  project already handles.

## Proposed design (not yet implemented - documentation only, per explicit request)

- **`tools.yaml`** (new, sibling to `services.yaml`, same flat-list-with-comments convention):
  ```yaml
  tools:
    - 7zip
    - putty
    - winscp
    - chrome
    - notepadplusplus
    - datadog-agent

  # Datadog credentials are NOT stored here (see "Secret handling" below) - this file only
  # says *whether* datadog-agent installs; the API key comes from outside this file.
  datadog:
    site: datadoghq.com   # or datadoghq.eu, etc. - real config, not a secret
    tags:
      - "env:lab"
      - "project:windows-auto-build-pipeline"
  ```
  Applies to all three OSes (unlike `services.yaml`, which is Server-only per "Windows Configuration
  Goals" above) - `tools.yaml` has no OS-exclusivity concept, every entry is expected to work
  identically on Server 2022/2025 and Windows 11.
- **`../iso_cache/` gains one pinned, checksummed installer per tool** (7-Zip, PuTTY, WinSCP, Chrome,
  Notepad++, Datadog Agent), each documented in `ISO_CACHE_INVENTORY.md` exactly like the existing
  five entries - same convention, not a new one.
- **A new `scripts/install-tools.ps1`**, mirroring `run-services.ps1`'s own orchestrator model: reads
  `tools.yaml`, and for each listed tool runs that vendor's own documented silent-install command
  against the pre-staged installer (already delivered to the guest, matching
  `inject-virtio-spice.sh`'s existing delivery pattern) - not a live download from inside the guest.
- **Wiring into the build**: a new step in `build.sh` (or a dedicated `install-tools.sh` at the
  `image-apply/` level, orchestrating delivery + the WinRM-invoked PowerShell call) - exact placement
  still open, see below.

## Secret handling for Datadog credentials - a real design constraint, not an afterthought

The API key is a genuine secret (unlike this project's disposable lab passwords, e.g.
`TestP@ssw0rd123`, which are intentionally not treated as real credentials). This project's own
Engineering Standards already list "storing secrets" among the things to avoid - `tools.yaml` itself
must never contain a real API key, and must stay safe to commit to git. Proposed approach, preserving
the original Phase 4 requirement's own wording ("runtime secret injection") rather than replacing it:
the key is supplied at build-invocation time via an environment variable (e.g. `DD_API_KEY`, matching
this project's existing `ADMIN_PASSWORD`-style env-var-with-default convention used throughout
`image-apply/*.sh`), never written to a git-tracked file, and passed through to the guest only at the
point `install-tools.ps1` actually runs (WinRM call parameter, not a value baked into any delivered
file). **Known, honestly-stated limitation, not glossed over**: Datadog's own MSI-based silent install
takes the API key as an installer property, which can be transiently visible in the host or guest
process list while the installer runs - a real, if narrow, exposure window inherent to MSI-based
silent installs generally, not something this project's own design choice can fully eliminate.

## Assumptions

1. All six tools' own official installers support a real, documented silent-install flag (`/S`,
   `/VERYSILENT`, `msiexec /qn`, etc.) - true for every tool on this list based on their vendors' own
   published documentation, but not yet independently verified against this project's own cached
   copies the way `CLAUDE.md`'s "verify before trusting" standard would want before shipping.
2. `tools.yaml` applies uniformly to all three OSes - no per-OS tool exclusions anticipated, unlike
   `services.yaml`'s Server-only roles.
3. Datadog Agent validation reuses the sibling project's own already-documented bar (Windows service
   exists, Agent service running, status healthy, connectivity succeeds, host registration confirmed)
   unchanged - see "Datadog Validation Requirements" above.

## Open questions

1. **Exact delivery + orchestration point**: does `install-tools.ps1` run as its own new
   `image-apply/install-tools.sh` stage (mirroring `inject-virtio-spice.sh`'s own two-script pattern),
   or fold into `build.sh` directly as a new numbered step? No strong reason yet to prefer one over
   the other - a real design decision, not resolved here.
2. **Per-tool version pinning discipline**: should `tools.yaml` allow pinning a specific version per
   tool (matching `virtio-win-0.1.285.iso`'s own pinned-version convention), or always track "latest"
   for these six (lower risk of drift for general-purpose desktop tools than for boot-critical OS
   media, but not risk-free - see the new "Version-sensitivity and brittleness" standard above)?
3. **Confirm the six-tool list and the `tools.yaml` schema sketch above** before any implementation
   starts, per this project's own "explain design, identify assumptions, identify risks, ask
   questions" instruction - this section is a proposal, not a locked decision.

**Status:** design documented, nothing implemented yet.

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

## Version-sensitivity and brittleness: what actually breaks when the pinned ISO/driver/QEMU version changes

Asked and answered directly (2026-08-23, during Phase 3A work) because it's a real, standing risk
this project's own history already has concrete evidence for, not a hypothetical to gesture at.
Ranked by how brittle each layer actually is, most fragile first:

**Most brittle — PCI/driver hardware-ID assumptions.** `WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`'s
Finding 3A-3 (discovered on this project's own first genuinely clean, single-pass Phase 3A run) found
that a bare `virtio-scsi-pci` controller and the identical controller with a backing drive attached
negotiate *different* PCI hardware IDs (`VEN_1AF4&DEV_1048` modern vs. `DEV_1004` legacy/transitional)
under the exact same QEMU version - meaning this layer is sensitive to **QEMU version/configuration
behavior**, not just Windows version. A host QEMU upgrade could silently shift virtio legacy/modern
negotiation and break the hardcoded hardware IDs baked into both the offline `hivex` `DriverDatabase`
registration (`tools/gen-viostor-ddb-reg.py`) and `image-apply/inject-virtio-spice.sh`'s own
topology-matching approach - with no error, just a disk that used to boot and now doesn't. A virtio-win
driver version bump carries the same risk from the other direction: Phase 3 Finding 6 already found one
real INF dependency gap (`netkvmp.exe`, required by `netkvm.inf`'s own `[SourceDisksFiles]` section but
invisible until a live `pnputil` install actually needed it) that a routine driver-package update could
easily reintroduce in a different form.

**Second — WIM image index (`os_wim_index` in `image-apply/lib/common.sh`).** Hardcoded per OS
(Server 2022/2025 index 2, Windows 11 index 1), each verified exactly once against one specific
pinned ISO (`PHASE2_ENGINEERING_LOG.md` Session 12 Finding 42, Session 13 Finding 43) via direct `7z`
extraction and `strings -el ... | grep EDITIONID` - never assumed, per this project's own "verify
before trusting" standard. A new Server 2022/2025 servicing baseline or Windows 11 release reordering
editions within the WIM breaks this silently: `wimapply` would apply the wrong SKU with no error,
since there's no validation that the resolved index still matches the expected `EDITIONID` before
using it. Cheap to re-verify against a new ISO (the exact recipe is already documented above), but
nothing currently *forces* that re-verification before a build runs against a refreshed ISO. **Not
hypothetical**: `ISO_CACHE_INVENTORY.md`'s own re-download-link verification (2026-08-23) found the
Windows 11 media fwlink already resolving to a 25H2 build, a full servicing generation past what's
actually cached - confirming this class of drift happens on this project's own real timeline, not
just in theory.

**Third — Setup.exe's own OOBE/hardware-compatibility-bypass behavior (Windows 11's Setup.exe path
only).** Already has one real, documented precedent of Microsoft changing this class of behavior
out from under existing tooling: an NTLite forum thread (cited during `PHASE3_ENGINEERING_LOG.md`
Session 3's research pass) documents a Windows 11 24H2 regression where `windowsPE`-pass unattend
settings are silently ignored by WinPE Setup. This project's own `windows11-setup-install.sh` depends
on `LabConfig` bypass registry keys and specific OOBE-skip settings continuing to work exactly as
currently observed - a future Windows 11 servicing update changing Setup.exe's own gate behavior again
is a real, not theoretical, risk category for this one pathway specifically. Server 2022/2025's
offline path doesn't invoke Setup.exe at all, so it's structurally immune to this particular risk.

**Least brittle — the core offline mechanism** (`wimlib` WIM apply, `bcdboot`, `hivex` registry
edits). Built on long-stable, Microsoft-documented primitives (`DISM /Apply-Image` + `bcdboot`'s own
behavior changes slowly and deliberately, unlike Setup.exe's own UX/compatibility-check surface) -
this is the part of the pipeline least likely to break from a routine ISO refresh.

**What to actually do about it, not just note it**: this project's own "verify before trusting"
discipline is already the right mitigation in principle - the real gap is that nothing *forces*
re-verification (WIM index, driver hardware IDs, PCI negotiation behavior) when the pinned ISO/
driver/QEMU version changes; it only happens when someone remembers to check by hand. A worthwhile,
not-yet-built addition: a preflight script that dumps WIM edition metadata and virtio-win driver
hardware IDs against whatever is currently cached, diffs that against what's hardcoded in
`lib/common.sh`/`tools/gen-viostor-ddb-reg.py`, and fails loud *before* a build runs rather than
producing a silently-wrong or silently-broken disk after one.

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
- **Disk hygiene for qcow2 test artifacts.** Every hand-run experiment in this project (Phase 2's
  bootability work, Option A/B's bisections, the Setup.exe reproducibility attempts) leaves behind
  a 5-20GB+ `.qcow2` disk. Left unmanaged, these accumulate fast enough to threaten the host's disk
  space — this happened twice in one session (2026-08-22): once from Option A/B's now-dead-branch
  artifacts (~91GB), once from redundant Server 2022/2025 reference disks (~110GB) once 6
  independent successes had already been confirmed and most no longer needed preserving.
  Concretely:
  - **Check `df -h /` before starting a new multi-attempt sequence** (e.g. a fresh round of
    reproducibility attempts), not just when a command starts failing from lack of space.
  - **During an active reproducibility sequence** (the project's own 2-3-independent-successes
    standard), keep each attempt's disk until the sequence concludes — they're the evidence a
    result reproduces, not disposable scratch.
  - **Once a sequence concludes and the evidentiary bar is met**, that's the natural checkpoint to
    prune: keep at most one or two reference disks going forward (e.g. the most recent clean
    success), not every attempt that got there.
  - **Once a branch of work is explicitly closed** (a HARD STOP, an abandoned option, a superseded
    approach), its artifacts stop being useful evidence and become pure disk pressure — clean them
    up promptly rather than leaving them "just in case."
  - **Always confirm with the user before deleting anything**, and prefer a targeted, reviewed list
    (state what's being proposed for deletion and why) over a broad/wildcard delete — same standard
    as any other destructive operation in this project.

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
