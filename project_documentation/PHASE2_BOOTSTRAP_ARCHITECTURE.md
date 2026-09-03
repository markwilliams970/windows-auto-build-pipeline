# Phase 2 Architecture Decision: Bootstrapping the Offline-Applied Disk

## Status

**UPDATE — read `PHASE2_ENGINEERING_LOG.md` (especially Findings 9-15 and the "STATUS AND NEXT
STEPS ON RESUMPTION" section) before treating anything below as current.** BCD-SYS (this
document's central recommendation) was empirically confirmed working for bootability, but driver
injection turned into a much deeper investigation than this document anticipated, and a
significant architecture pivot (reusing Setup.exe itself via a plain-disk-boot medium, rather than
hand-rolling driver injection) was identified and is likely to supersede parts of the plan below.
This document is being kept as-is for its historical reasoning, not rewritten.

Supersedes the "make the disk bootable" plan in `HANDOFF_FROM_UNATTENDED_INSTALL.md` and the
WinPE-boot-first experiment in `START_PROMPT.md`. This document is the product of a prior-art
research pass specifically looking for existing open source tooling before we build anything —
same discipline that drove the offline-DISM pivot in the first place. **Nothing has been tested
empirically yet.** This is a design recommendation, not a confirmed result — treat every claim
below as "verify before trusting," per this project's own engineering standards.

Scope: this covers Phase 2 sub-milestones 2-4 (make the disk bootable, driver injection,
specialize/unattend) across all three target OSes — Windows 11 Enterprise Eval, Windows Server
2022, Windows Server 2025.

---

## Executive summary

The original plan treated "make the disk bootable" as the project's central unsolved problem,
requiring a self-built WinPE environment booted once under QEMU to run the real `bcdboot`. Research
turned up an actively-maintained open source tool, **BCD-SYS**, that does the BCD-construction and
boot-file-copy work `bcdboot` does — **entirely from the Linux host, with no Windows boot of any
kind involved.** If it works as documented against our specific partition layout, it doesn't just
derisk the WinPE-boot approach, it **eliminates the need for it entirely**: no second QEMU boot, no
WinPE image to build or maintain, no exposure to whatever UEFI/optical-media landmine blocked the
sibling project's Server 2025/Windows 11 tracks, because there is no boot in this step at all.

Two adjacent findings round out the picture:

- **Boot-critical driver injection** (VirtIO storage/NIC drivers) has a mature, production-proven
  offline pattern too — the same one `virt-v2v` uses in production to convert VMware/Hyper-V guests
  to KVM — via `hivex`/`hivexregedit` registry edits, no boot required. This directly replaces the
  planned "`DISM /Add-Driver`-equivalent" step, and shares the same dependency family as BCD-SYS
  (`hivexsh`/`hivexregedit`), which is a nice bit of infrastructure reuse regardless of how the BCD
  question shakes out.
- **Specialize/unattend delivery likely doesn't need `DISM /Apply-Unattend` at all** — dropping
  `unattend.xml` directly at `\Windows\Panther\unattend.xml` inside the offline-mounted image is
  Microsoft's own documented mechanism for the specialize pass to pick it up automatically on first
  real boot, which is a plain file copy rather than invoking any tool.

**Recommendation: attempt the BCD-SYS-based pipeline first.** It is cheaper and faster to test than
the WinPE approach (no image-building step, no second boot to debug), and if it works, it's a
strictly simpler system with fewer moving parts and one fewer unresolved UEFI-boot unknown in the
critical path. Keep the WinPE + real `bcdboot` plan fully documented as the fallback — it remains
Microsoft's own canonical mechanism and should not be discarded, only deprioritized as the first
thing we try.

This recommendation applies **uniformly across all three target OSes.** Windows 11, Server 2022,
and Server 2025 all use the same NT 10.x-generation BCD store format and the same UEFI boot
architecture; nothing found in this research suggests BCD-SYS or the driver-injection pattern
behaves differently per OS. Where the three OSes *do* genuinely diverge is upstream and downstream
of this step — Setup.exe's hardware-eligibility gate (Windows 11) and SAN-policy defaults (Server
editions) — covered in detail below, because both are easy to conflate with the boot mechanism
itself and shouldn't be.

---

## Pipeline stage 1: Making the disk bootable

### Candidate approaches

| Approach | Mechanism | Boots required | Status |
|---|---|---|---|
| **A. BCD-SYS** (recommended, try first) | `hivexsh`/`hivexregedit` construct the BCD hive directly; boot files copied to ESP; all from a mounted NTFS volume on the Linux host | Zero | Untested by us; active OSS project |
| **B. WinPE + real `bcdboot`** (fallback, already researched) | Boot a minimal self-built WinPE image once under QEMU, run Microsoft's actual `bcdboot W:\Windows /s S: /bootex` | One (WinPE) | Microsoft-documented; untested by us; carries the "does WinPE hit the same UEFI landmine" open question |
| C. Manual BCD hive construction from scratch | Hand-build the BCD registry hive's object/element schema using raw `hivex` primitives, no reference implementation | Zero | Rejected — this is what BCD-SYS and `bcdboot` both already do properly; reimplementing it ourselves is the single most fragile option on the table and was already correctly deprioritized in the original handoff doc |

### Why approach A first: detailed rationale

**1. It removes an entire boot cycle from the critical path, and with it, an entire category of
risk.** The sibling project's whole Server 2025/Windows 11 failure mode was UEFI-boot-timing
related (the "press any key" prompt, PXE fallthrough, OVMF Interactive Shell). The leading theory
was that this is specific to optical/CD-ROM boot media conventions and that a WinPE image attached
as a plain virtio-blk/virtio-scsi disk would sidestep it — plausible, but *unverified*, and the
only way to verify it is to actually build a WinPE image and boot it. BCD-SYS's approach requires
no boot at all for this step, so that whole open question becomes moot for *this* step specifically
(it may still matter for the disk's first *real* boot later in the pipeline, see Stage 3's overlap
with this concern below — but that's a boot we need regardless, not an extra one).

**2. It's a strict complexity reduction.** The WinPE approach requires: extracting `boot.wim` +
EFI boot files from install media, constructing a bootable disk image or virtual medium for WinPE
itself, getting *that* to boot under QEMU/OVMF, injecting a custom `startnet.cmd`-equivalent to run
`bcdboot` and then cleanly shut down, and only then inspecting the *target* disk's result. BCD-SYS
collapses all of that into one CLI invocation against an already-mounted partition, as part of the
same host-side script that just ran `wimapply`. Fewer moving parts is fewer things that can break,
and — just as importantly — fewer things a future reader of this codebase has to understand.

**3. It's fast and cheap to falsify.** "Attempt BCD-SYS against a wimapply'd partition, then boot
the real disk under QEMU/OVMF and see if Windows Boot Manager comes up" is an experiment that takes
minutes and produces an unambiguous pass/fail, with none of the "is it the timing, the keystroke,
the device ordering, or something else entirely" ambiguity that plagued the sibling project's
`boot_command` debugging. If it fails, we've lost very little time and fall back to the
already-researched WinPE plan with nothing wasted.

### Rationale for keeping approach B as documented fallback, not discarding it

BCD-SYS is a promising find, but it is **a single-maintainer GPL-3.0 bash project with 43 stars and
8 forks** — real, active (pushed within the last day as of this writing), and it explicitly states
compatibility with wimlib-applied images as one of its intended use cases, but it is not a
Microsoft-blessed mechanism and hasn't been battle-tested by us against our exact partition layout,
our exact wimlib version's output, or Windows Server 2025/Windows 11's exact BCD schema
requirements. Two of its open issues are relevant and worth reading before depending on it:

- An NVMe partition-matching bug (`p1` substring-matching `p10` via `lsblk` parsing) — low risk for
  us since we're planning virtio-blk/virtio-scsi (`/dev/vda`-style naming), not NVMe, but confirms
  the tool has real edge-case bugs, as any actively-developed single-maintainer project will.
- A user in an open issue is literally building "a bash script that installs windows from linux"
  around this exact tool right now — useful corroboration that this pattern is being independently
  pursued in the wild, not just a theoretical fit.

The Microsoft-documented WinPE + real `bcdboot` mechanism remains correct, sourced, and confirmed
against real deployment guides for all three target OSes (see the existing "Prior art" section in
`HANDOFF_FROM_UNATTENDED_INSTALL.md`). If BCD-SYS's output doesn't produce a disk that boots
cleanly under OVMF — for any reason, including reasons unrelated to BCD-SYS itself — that plan is
still fully specified and ready to execute without repeating the research. **Do not delete or
rewrite that section of the handoff doc; this document adds a preferred first attempt in front of
it, it doesn't replace the substance.**

### An implementation nuance worth flagging now, before the first experiment

BCD-SYS's own primary use case (per its README) appears to be adding Windows to a *live* machine's
real UEFI NVRAM boot menu (dual-boot scenarios) — its `-f`/`-e` flags and "firmware entries"
language describe registering boot entries into the running system's own UEFI variable store. Our
use case is different: we're preparing a qcow2 disk image for a VM that hasn't booted yet, so
there's no "live UEFI NVRAM" to register an entry into at prep time.

This is very likely not a blocker, for a reason grounded in the UEFI spec itself rather than
anything BCD-SYS-specific: firmware with no valid `Boot####` NVRAM entries (which describes a
freshly-created OVMF VARS file, as every one of our per-build VMs will have) falls back to loading
`\EFI\Boot\bootx64.efi` by default — and `bcdboot` (and, per BCD-SYS's stated purpose, BCD-SYS
itself) writes exactly that fallback file as a matter of course, alongside the "real" boot manager
path under `\EFI\Microsoft\Boot\`. **Working theory, to be verified in the first experiment, not
assumed:** we should be able to invoke BCD-SYS with its `-s <path>` option (documented as "specify a
system volume without creating firmware entries") to get the BCD store and boot files written
without it attempting any live-NVRAM interaction that doesn't apply to our context. If this theory
is wrong, the fallback is simply constructing OVMF's VARS file with a `Boot0000` entry directly
using a tool like `virt-firmware` (a separate, actively-maintained Red Hat project for editing OVMF
variable stores offline) — worth knowing this exists as a second-tier fallback, but not worth
building against speculatively before the simpler path is actually tried and found wanting.

---

## Pipeline stage 2: Boot-critical driver injection (VirtIO storage + NIC)

### Candidate approaches

| Approach | Mechanism | Precedent |
|---|---|---|
| **A. Offline registry injection via `hivex`/`hivexregedit`** (recommended) | Register the VirtIO storage driver's service key under `CurrentControlSet\Services` and `CriticalDeviceDatabase` directly in the offline `SYSTEM` hive, copy the driver files into `\Windows\System32\drivers\`, no boot required | `virt-v2v` (Red Hat, production, actively maintained) does exactly this for VMware/Hyper-V→KVM conversions — same problem (boot-critical storage driver must be present *before* first boot or the disk won't come up at all), same tool family we're already bringing in for BCD-SYS |
| B. `DISM /Add-Driver` against the offline-mounted image | Documented Microsoft mechanism, requires a Windows or WinPE environment (DISM.exe itself doesn't run on Linux) | Superseded — this only made sense in the WinPE-boot-required version of the plan |

### Rationale

This is the same insight as Stage 1, arrived at independently: a problem the original plan assumed
required booting *something* Windows-flavored (DISM.exe is a Windows/WinPE-only tool) turns out to
have a mature Linux-native offline equivalent, because a well-known, well-funded open source project
(`virt-v2v`) had to solve this exact "the disk won't boot because the storage driver for its new
virtual hardware isn't registered yet, and it can't boot to register it — chicken and egg" problem
years ago, in production, for a much larger user base than we have. We should follow their pattern
rather than reinvent it: `hivex`/`hivexregedit` edits against the offline `SYSTEM` hive to add the
VirtIO stor driver's service entry and mark it `BOOT_START` (load type 0), plus the matching
`CriticalDeviceDatabase` entry mapping the virtio-blk/virtio-scsi PCI hardware ID to that service —
copy the actual `.sys`/`.inf`/`.cat` files from `virtio-win.iso` (already a sibling-project
dependency) into place at the same time.

The NIC driver is lower-stakes — it's needed for the eventual WinRM connection in Stage 3, but its
absence doesn't prevent the disk from booting at all, only from being reachable once it has. It can
be injected the same way (offline registry + file copy) for consistency, or, if that turns out
fiddly, installed via the normal Windows PnP mechanism on first boot instead (slower, but not
blocking — the machine is at least alive and diagnosable via the QEMU console at that point).

### Shared infrastructure note

Both Stage 1 and Stage 2 now depend on the same `hivex` toolchain (`hivexsh`, `hivexregedit`).
This is worth calling out explicitly as an architectural benefit: even in the scenario where
BCD-SYS specifically doesn't pan out and we fall back to the WinPE+`bcdboot` plan for Stage 1, the
`hivex` dependency for Stage 2's driver injection is unaffected and doesn't need to be revisited —
it's independently justified by the `virt-v2v` precedent regardless of how Stage 1 resolves.

---

## Pipeline stage 3: Specialize / unattend delivery

### Candidate approaches

| Approach | Mechanism | Notes |
|---|---|---|
| **A. Drop `unattend.xml` at `\Windows\Panther\unattend.xml`** (recommended) | Plain file copy onto the offline-mounted NTFS volume; Windows' specialize pass discovers and consumes it automatically on first real boot | No tool invocation at all — simplest possible mechanism |
| B. `DISM /Apply-Unattend` against the offline-mounted image | Real, documented DISM offline-mount command | Requires DISM.exe (Windows-only) *or* would need to be run against the image before it's ever unmounted from a Windows-side mounting tool — doesn't fit a Linux-native pipeline without a Windows step somewhere |

### Rationale

Both mechanisms are genuinely Microsoft-documented; the difference is that A requires nothing
beyond what we already need (a mounted NTFS partition and a file to write to it), while B requires
DISM specifically, which only runs on Windows or WinPE. Given we're trying to keep Windows/WinPE
out of this pipeline entirely (that's the whole point of the offline-apply approach), A is the
clear choice unless empirical testing turns up settings that only work correctly when applied via
the DISM-specific `offlineServicing` pass rather than the on-boot `specialize` pass Panther-drop
uses. Microsoft's own docs draw a real distinction between these passes (DISM's
`/Apply-Unattend` is documented as intending `offlineServicing`-pass content specifically, with a
caveat against including `specialize`-pass settings when applying it that way) — which, read
carefully, actually argues *for* approach A for our use case, since the settings we need (computer
name, WinRM enablement, first-logon driver/role work) are exactly the kind of thing the
`specialize`/`oobeSystem` passes were always meant for, not `offlineServicing`.

---

## Cross-cutting: how Windows 11, Server 2022, and Server 2025 differ for *this* phase

This is where it matters to be precise about what's actually OS-specific versus what's a property
of the install *mechanism* that applies uniformly. Getting this distinction wrong is exactly how
the sibling project spent real time chasing keystroke-timing fixes for a problem that was actually
about media vintage, not OS family. Below is what's genuinely different, and — just as
importantly — what looks different at first glance but isn't.

| Concern | Windows 11 Enterprise Eval | Server 2022 | Server 2025 | Uniform across all three? |
|---|---|---|---|---|
| BCD store format / `bcdboot`-equivalent mechanism | Same NT 10.x BCD schema | Same | Same | **Yes** — BCD-SYS's own docs confirm it uses "a Windows 10/11 equivalent" template regardless of target, and nothing in the research suggests Server-vs-client or 2022-vs-2025 changes the schema itself |
| Offline WIM apply / driver injection mechanism | Same `wimapply` + `hivex` pattern | Same | Same | **Yes** |
| TPM 2.0 / Secure Boot hardware-eligibility gate | **Enforced, but only inside `Setup.exe`** (the `appraiserres.dll`/`MoSetup` "unsupported hardware" check) | N/A — Server SKUs don't carry this consumer-facing gate | N/A — same as Server 2022 | **Irrelevant to our pipeline for all three** — since offline WIM application never runs `Setup.exe` at all, this entire gate is bypassed structurally, not via a registry workaround. This independently confirms deploymentresearch.com's finding (cited in the handoff doc) that TPM/Secure Boot has "no technical requirement" for the imaging step itself |
| Secure Boot certificate rotation (UEFI CA 2023) | Relevant *if* Secure Boot is enabled at runtime | Relevant *if* Secure Boot is enabled at runtime | Relevant *if* Secure Boot is enabled at runtime | This is a *runtime firmware* concern, not an OS-family concern — it only matters at all if we choose to run these lab VMs with Secure Boot enabled in OVMF. **Recommendation: disable Secure Boot in OVMF for all three targets in this lab context** (it's not a testing requirement per ../CLAUDE.md's Datadog-integration goals) and this entire concern disappears; if Windows 11 realism later requires Secure Boot specifically, `bcdboot`'s `/bootex` flag exists for exactly this, and confirming BCD-SYS has an equivalent is a scoped follow-up item, not a blocker now |
| SAN policy (`OfflineShared` default bringing disks up offline) | **Not applicable** — Windows client SKUs default to `OnlineAll`, this is a Server-only default | Applies in principle, but only to *non-boot* SAN-presented disks; the boot volume itself is excluded from this policy by design | Same as Server 2022 — the community report that surfaced this (Proxmox forum thread, cited in the handoff doc) described the *interactive installer* hitting this with virtio storage, not an offline-applied boot disk | **Low risk for our topology specifically** — we have a single boot disk per VM, and SAN policy targets non-boot SAN-class storage. Worth a footnote in case this project ever adds secondary data disks to a build (e.g. for a SQL Server data volume), not a concern for the boot volume itself |
| Media vintage / build number | Very new (24H2/25H2-era builds) | Oldest, most conservative build baseline | Newer, closer to Windows 11's build lineage than to Server 2022's | This is exactly the axis the sibling project's *interactive-installer* failures correlated with — but that correlation was specific to `Setup.exe`'s own boot-catalog/UEFI-shell interaction, which this project's mechanism never invokes. No evidence found that media vintage affects offline WIM-apply, `hivex` registry editing, or BCD-SYS's approach |
| WIM image index / `<NAME>`/`<EDITIONID>` selection | Must be verified per-ISO (unchanged requirement) | Already confirmed in sibling project's engineering log | Already confirmed in sibling project's engineering log | Not a mechanism difference — just ordinary due diligence per `../CLAUDE.md`'s "verify before trusting" standard, same as always |

**The headline conclusion from this table**: everything that made Server 2025 and Windows 11
*uniquely* hard for the sibling project was a property of `Setup.exe`'s interactive boot process
specifically (the UEFI "press any key"/optical-media boot-catalog behavior, and the appraiser
hardware gate). None of that surface exists anywhere in this project's mechanism, because
`Setup.exe` is never invoked. That's not a coincidence — it's the entire architectural reason this
project exists, and this research pass reinforces rather than complicates that reasoning. The one
place a real OS-family difference could still bite us (Server SAN policy) doesn't apply to our
single-boot-disk topology, and the one place a real *runtime* difference could still bite us
(Secure Boot certificate rotation) is avoidable by a firmware configuration choice we control
outright, not something inherent to any of the three OSes.

---

## Revised Phase 2 sub-milestone sequence

Replacing the sequence in `../CLAUDE.md`/`HANDOFF_FROM_UNATTENDED_INSTALL.md`'s Phase 2 section:

1. **Partition + apply WIM** (unchanged from original plan) — `qemu-nbd` + `sgdisk` + `mkfs.ntfs`,
   then `wimapply` targeting Windows Server 2025's confirmed image index, per the existing
   `../iso_cache/` reuse plan (shared cache directory, `ISO_CACHE_DIR`-parameterized).
2. **Attempt BCD-SYS against the applied partition** (new first experiment, replacing the
   WinPE-boot-medium experiment as the first thing tried). Success criterion: the disk boots to
   Windows Boot Manager and begins loading Windows under QEMU/OVMF (Secure Boot disabled, per the
   recommendation above), with no interactive installer or WinPE involved anywhere in the process.
3. **If step 2 succeeds**: inject VirtIO drivers via `hivex`/`hivexregedit` (Stage 2 above), drop
   `unattend.xml` at `\Windows\Panther\` (Stage 3 above), then attempt the disk's first real boot
   with Packer (`disk_image = true`) and confirm WinRM reachability — this is the Phase 2 success
   criterion from `../CLAUDE.md`, unchanged.
4. **If step 2 fails**: fall back to the WinPE + real `bcdboot` plan exactly as already documented
   in `HANDOFF_FROM_UNATTENDED_INSTALL.md`'s "Technical building blocks" section, starting with its
   own first sub-question (does a disk-attached WinPE image avoid the optical-media UEFI landmine).
   Nothing from steps 1-3 is wasted in this case — the WIM-apply step is identical either way, and
   the `hivex` driver-injection work from Stage 2 is unaffected by which bootability mechanism wins.

This sequence should be attempted against Windows Server 2025 first, per the existing "Starting
point" direction in the handoff doc (its `../iso_cache/` entry and WIM image-index work already exist)
— and per the cross-cutting analysis above, there's no principled reason to expect the result to
differ for Windows 11 or Server 2022 once it's proven for Server 2025.

---

## Open verification items (do not assume these; test them)

1. ~~Does BCD-SYS's `-s <path>` mode produce a disk that boots under OVMF with a blank/fresh VARS
   file, given our virtio-blk/virtio-scsi partition layout (not the NVMe layout its one open bug
   report concerns)?~~ **CONFIRMED YES** — see `PHASE2_ENGINEERING_LOG.md` Findings 1-6. `-s` mode
   works, produces a disk that boots cleanly under OVMF with a blank/fresh VARS file (no NVRAM
   entry needed, exactly as theorized), against a virtio-blk-attached qcow2. One real bug surfaced
   and was fixed along the way: a sudoers-scoping gap silently corrupted the BCD's device-locator
   GUIDs on the first attempt (Finding 5) — not a BCD-SYS bug, a gap in this project's own sudo
   scoping for BCD-SYS's internal `sfdisk` calls.
2. Does the offline `hivex`-based VirtIO driver registration (service key + `CriticalDeviceDatabase`
   entry) actually get consulted by Windows' boot loader before the storage stack initializes, the
   same way it does for `virt-v2v`'s conversions — or does anything about our specific VirtIO
   device model (virtio-blk vs virtio-scsi; PCI vs PCIe topology) require a different
   hardware-ID mapping than what `virt-v2v`'s own driver database already documents?
3. Does the `\Windows\Panther\unattend.xml` drop reliably trigger the specialize pass on first boot
   for all three OSes, including the settings we actually need (computer name, WinRM enablement) —
   or does anything about arriving there via offline WIM-apply (versus arriving there via a live
   Setup.exe run, which is what Panther-drop was originally designed around) change that?
4. Confirm whether Secure Boot will in fact be disabled for these lab VMs (recommended above) or
   whether Windows 11 realism requirements mean it needs to stay on — this determines whether the
   UEFI CA 2023 / `/bootex` question needs to be chased down before Windows 11 is attempted.

---

## Licensing note

BCD-SYS (GPL-3.0) and the `hivex` toolchain (also GPL-family) would be used here as external
command-line dependencies invoked via subprocess — the same relationship this project already has
with `wimlib-imagex`. This is a standard and low-risk way to depend on GPL-licensed tooling for
internal/lab infrastructure (no linking, no redistribution of a combined work), but worth noting
explicitly since this project is now accumulating several GPL CLI dependencies rather than just
one, in case this project's tooling is ever redistributed rather than just run internally.

---

## Recommended documentation updates

- `HANDOFF_FROM_UNATTENDED_INSTALL.md`: add a pointer from its "Technical building blocks" section
  to this document, noting the WinPE plan is now the documented fallback rather than the first
  attempt. Its own content stays accurate and shouldn't be rewritten — it's still the fallback
  plan's specification.
- `../CLAUDE.md`: Phase 2's sub-milestone list and "Making the disk bootable" section should reference
  BCD-SYS as the first approach to attempt, with WinPE demoted to documented fallback.
- `START_PROMPT.md`: its "Run the single highest-value experiment" section currently names the
  WinPE-boot test as that experiment — recommend updating it to name the BCD-SYS test instead, same
  reasoning as above.

Have not made these edits yet — flagging them here so the update can happen as a deliberate,
reviewed step rather than silently while writing this analysis.

**Update: done.** `../CLAUDE.md`'s "Making the disk bootable" section now documents BCD-SYS as the
first attempt with WinPE as the fallback, matching this recommendation. `START_PROMPT.md` was
updated too at the time, though that file is itself now a stale Session-7 snapshot superseded by
later phases (see its own top-of-file note) - not relevant to this specific TODO's own resolution.
