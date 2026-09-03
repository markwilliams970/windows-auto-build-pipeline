# Phase 3A: VirtIO Storage, VirtIO NIC, and SPICE Display Drivers — Research and Phased Plan

**Phase numbering note:** filed as **Phase 3A**, not a `Phase 3.X` sub-number, deliberately — the
`Phase 3.1`-`3.5` numbering in `PHASE3_ENGINEERING_LOG.md` is specifically the Windows-11-Setup.exe-
pivot story (the research question "how is Windows 11 actually built unattended elsewhere," through
production-readiness). This work starts *after* that story closed (Phase 3.5 done) and is a distinct,
cross-cutting addition — the same three drivers, generalized across all three target OSes — not a
continuation of that specific sub-story. `../CLAUDE.md`'s own Phase 3 section links back to this
document (added once real findings existed here, matching how `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`
was referenced once its own work was underway, not before).

## Status

**Phase 3A is done for all three target OSes** — Windows 11, Server 2022, and Server 2025 each have
`vioscsi` storage + SPICE confirmed via 2 independent clean runs apiece through the same,
single, OS-parameterized `image-apply/inject-virtio-spice.sh` (Windows 11 also gets the `netkvm` NIC
swap; Server 2022/2025 deliberately don't — see the "Scoping revised" note below). See the
"Phase 3A status summary" table further down for the full per-OS breakdown. Getting here surfaced
three real implementation bugs (a QMP socket path over the 108-byte limit, a WinRM-wait loop that
didn't fail fast on early QEMU exit, a PowerShell array-vs-scalar verification bug) and one genuine
architectural finding caught specifically *because* a clean run was insisted on rather than trusting
an earlier retried-script success — see Finding 3A-3: a Stage 1 "verify" device isn't a trustworthy
stand-in for Stage 2's real device unless their PCI topology is byte-identical. That fix was then
confirmed to generalize across every target OS, not just Windows 11 — every clean run, on every OS,
negotiated the identical `VEN_1AF4&DEV_1048` PCI ID.

- **Storage (`vioscsi`)**: proven — boots fully on `virtio-scsi-pci`, `Get-Disk` confirms `Online`.
  See Finding 3A-1 (live-verify-before-swap) and Finding 3A-3 (verify-topology-must-match-real-topology).
- **NIC (`netkvm`)**: proven — `Red Hat VirtIO` adapter `Up`, real WinRM entirely over the virtio NIC.
  See Finding 3A-2 (a genuine firmware-level hang, root-caused to PCI topology placement).
- **SPICE (QXL + vdagent)**: proven — `Red Hat QXL controller` `Status: OK`, `spice-guest-tools-latest.exe
  /S` installed cleanly, `vdservice` confirmed `Running` (the script proactively nudges past a known
  first-boot start-order race rather than leaving it to chance). Also interactively test-driven by the
  user over a real SPICE client during the manual proof that preceded formalization.

**Decisions locked in:**
1. Storage controller: **`vioscsi`/virtio-scsi** — matches the user's own proven
   `windows11vm-t14` setup.
2. SPICE listener: **loopback-only, no auth** — matches this project's existing WinRM `hostfwd`
   convention (local testing only, no remote/public exposure).
3. `spice-guest-tools-latest.exe` **is cached under `../iso_cache/`**, sha256-sidecar'd, same
   convention as `virtio-win-0.1.285.iso` (pinned-filename caching applied to a non-ISO artifact —
   the convention is about avoiding silent re-fetches, not about the file being an ISO specifically).
   Cached and verified 2026-08-23 (`b5be0754...`, a real NSIS installer, not an error page).
4. **Generalize to Server 2022/2025, not just Windows 11** — per explicit user direction: "I'd like
   to be able to install the same driver set in the Server 20xx pipelines as well." See "Generalizing
   across OSes" below. Execution order stayed Windows 11 first (proving the mechanism there before
   porting it), but the mechanism was written OS-parameterized from the start rather than hardcoded to
   `windows11` — confirmed: porting to Server 2022/2025 later was a config change, not a rewrite.

## Generalizing across OSes

The live-install-then-swap mechanism this plan uses has nothing Windows-11-specific about it: boot
*any* already-WinRM-reachable disk on its current device model, live-install the driver package over
WinRM, graceful QMP shutdown, swap the relevant QEMU device flag, reboot, verify. That applies
identically to a Server 2022/2025 disk built by `image-apply/build.sh` as it does to a Windows 11 disk
built by `windows11-setup-install.sh` — the only per-OS variable is which driver subfolder to pull from
the virtio-win ISO, and `image-apply/lib/common.sh` **already has that exact table**
(`2k22`/`2k25`/`w11`, confirmed via `7z l` per its own header comment) since Server 2022/2025's
existing offline-hivex mechanism needs the same mapping.

**What this does and doesn't mean for Server 2022/2025's existing pipeline:**
- Server 2022/2025 **already has** working `viostor`/`netkvm` in production, via the proven offline
  `hivex`/`DriverDatabase` mechanism (`make-bootable.sh`/`apply-unattend.sh`) — nothing about that is
  broken or being replaced. This plan doesn't touch it.
- **SPICE/QXL was equally unaddressed for Server 2022/2025** — Packer's own qemu builder invocation
  for Server 2022/2025 used a plain `-vnc` display (per `PHASE3_ENGINEERING_LOG.md` Session 1's own
  captured Packer command line), no QXL, no SPICE, same gap Windows 11 had. **Confirmed done**: the
  identical live-install-then-swap technique proven against Windows 11 generalized to Server 2022/2025
  directly, no changes needed beyond the OS-parameterized inputs already in `lib/common.sh` — see the
  "Phase 3A status summary" table.
- `image-apply/inject-virtio-spice.sh` **is** written taking an OS argument (reusing `lib/common.sh`'s
  existing subfolder table and its `windows11`/`server2022`/`server2025` naming), exactly as planned
  here — confirmed, not just intended.

## Revision note

The first draft of this plan proposed build-time driver injection via Windows Setup's own
`DriverPaths`/`PnpCustomizationsWinPE` mechanism for storage and NIC, reasoning that storage
"must" be available before Setup can partition the disk. **The user corrected this directly**: they
have personally done exactly this class of driver swap before, manually, on this host (a separate
libvirt VM, `windows11vm-t14`) — install normally on the original controller (SATA), mount the
virtio-win ISO *inside the running guest* and run the installer to stage the drivers, shut down,
update the device model to virtio-scsi, and boot again. It worked. The user asked explicitly that
this "safe build approach + manual installation of the drivers later" be treated as a first-class,
viable approach for this plan, not a fallback or a hack.

That correction changes the plan's shape more than cosmetically: **this technique is real,
well-precedented outside this project too** (it's the same principle `virt-v2v` and most
"prepare a Windows VM for hypervisor migration" guides use for boot-critical storage drivers — a
live `pnputil`/PnP-managed install of a storage-class driver package updates
`HKLM\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase` automatically, which is exactly the
registration this project's own old offline-`hivex` script (`tools/gen-viostor-ddb-reg.py`,
`PHASE2_ENGINEERING_LOG.md` Finding 29) had to hand-construct from scratch). Using it means:

- **Zero new risk to Setup.exe.** The build stays exactly the current, three-times-proven
  `windows11-setup-install.sh` recipe (`ide-hd`/`e1000`), unmodified. Everything new happens
  *after* a real desktop and real WinRM are already confirmed — the same evidentiary point every
  prior phase in this project has already treated as "done, don't re-risk it."
- **No use of `DriverPaths`/Setup-time driver injection at all**, for any of the three items — that
  mechanism (genuinely untested anywhere in this project) is no longer needed. Storage, NIC, and
  SPICE now all follow the identical pattern: boot normal → live-install the driver over WinRM →
  graceful shutdown → swap the relevant QEMU device flag(s) → boot again → verify.
- **SPICE is no longer a structurally different, lower-priority phase.** The original draft put it
  last because it seemed to need a fundamentally different (post-boot-only) mechanism from
  storage/NIC's assumed build-time one. With the mechanism unified, that asymmetry is gone — SPICE
  now runs the same pattern as the other two, per the user's explicit direction to pull it forward.

## Operational note: test builds run serially

Per explicit user direction, test builds/boot cycles across this entire plan run **one at a time** —
no overlapping QEMU experiments across phases or across OSes, even though nothing here technically
conflicts with the currently-running unrelated `winlab-*` libvirt VM noted below. Reason, stated by
the user directly: avoiding I/O contention on host storage — concurrent qcow2-heavy QEMU
builds/installs are real, simultaneous disk I/O load, not just a clarity/logging convenience. Wait
for each build/verify cycle to finish (or fail) before starting the next.

## Phase gates, one per OS

Per explicit user direction: this phase isn't done until each of the three target OSes has its own
successful end-to-end build gate, not just Windows 11's. Server 2022/2025's gate is **narrower than a
full production build** — it does not need to exercise `services.yaml`/role provisioning (AD DS/IIS/
SQL Server); the thing being gated here is driver installation, not the role layer, which is already
separately proven (`PHASE3_ENGINEERING_LOG.md`'s own Session 1/2 confirmed results table).

**Table below reflects the original plan, before the storage-swap scope revision** (see "Scoping
revised, 2026-08-23" immediately after it) — kept as-written for the historical record of what was
originally gated, rather than silently rewritten. The actual, final scope that shipped: storage
(`vioscsi`) on every OS, NIC (`netkvm`) swap Windows 11 only, SPICE on every OS — see the "Phase 3A
status summary" table near the end of this document for the real, final per-OS result.

| OS | End-to-end build gate | Driver gate(s), as originally scoped |
|---|---|---|
| **Windows 11** | Fresh disk via unmodified `windows11-setup-install.sh`, real WinRM confirmed (already this project's existing bar) | Storage (`vioscsi`) + NIC (`netkvm`) + SPICE (`qxl`/`spice-vdagent`) — all three, none of which existed yet for Windows 11 at the time. Phases 3A.1.1-3A.1.4 below. |
| **Server 2022** | Fresh disk via `image-apply/build.sh server2022`, real WinRM confirmed — **no `services.yaml` profile applied, no Packer role-provisioning handoff needed for this gate** | Originally scoped as SPICE only (`viostor`/`netkvm` already production-proven via the separate offline-hivex mechanism). Revised below to include storage too. Phase 3A.2 below. |
| **Server 2025** | Fresh disk via `image-apply/build.sh server2025`, real WinRM confirmed — same narrowed scope as Server 2022 | Originally SPICE only, same reasoning as Server 2022. Revised below to include storage too. Phase 3A.3 below. |

**Scoping revised, 2026-08-23**: storage (`vioscsi`) via the live-install-then-swap technique now runs
for **every OS**, per explicit user direction to exercise that surface area on Server 2022/2025 too.
(Context, not the basis for the decision: inspecting the user's own `win2022-dc` libvirt VM via `virsh
dumpxml` showed it uses `virtio-scsi`, not `virtio-blk-pci` — informational only, since that VM is from
the sister project and its storage config reflects a manual post-build change the user made themselves,
not a target this pipeline should emulate.) Server 2022/2025 enter `image-apply/inject-virtio-spice.sh`
already on `virtio-blk-pci` (via the separate, already-proven offline-hivex mechanism, which this
script still never touches) — `vioscsi` is new to them, so Stage 1 stages+live-verifies it fresh and
Stage 2 swaps the primary storage controller from `virtio-blk-pci` to `virtio-scsi-pci`.

**NIC stays Windows 11 only — explicitly confirmed, not defaulted into.** A first pass at this change
mistakenly read "apply the NIC swap to Server 20xx" as license to also start swapping Server's NIC
mechanism; the user caught this and clarified: Server's `netkvm`/`virtio-net-pci` (via the offline-hivex
mechanism) is "known good, and verified, and a potentially breaking change" to touch without strong
reason, so it stays exactly as-is. Storage's case is different only because `vioscsi` is genuinely new
territory for Server (nothing today registers it there), not because the underlying caution differs.

## Why this is its own document

`windows11-setup-install.sh` (the current, production-ready Windows 11 build path — see
`../CLAUDE.md`'s Phase 3.4/3.5 status and `PHASE3_ENGINEERING_LOG.md`) deliberately ships with a plain
`ide-hd` target disk and an `e1000` NIC. That was never an oversight — Phase 3.2/3.3's own scope
notes say so explicitly: the question those phases needed answered was "does the full answer file
process correctly through Setup.exe," not "does this project's virtio technique also work here."
That second question was left open on purpose and has stayed open since Phase 3.5 closed
(`PHASE3_ENGINEERING_LOG.md`: *"the virtio-driver question... remains open and deferred"*).
SPICE/QXL has never been attempted at all — the current QEMU invocation uses QEMU's default VGA
device with `-display none`, and this project's whole VM-inspection convention
(`tools/qmp-screenshot.py`) is built around QMP screendump, not a live SPICE console.

This closes those three items.

## Context that shapes every decision below

**Windows 11 has documented first-boot fragility in this project's own hands, but it's specific to a
now-closed, architecturally different pipeline.** The old fully-offline pipeline (an offline
`ntfs-3g` file-drop of `unattend.xml` onto an already-applied, never-booted disk) hit a deterministic
BSOD on Windows 11's real first boot, bisected to Windows *processing* a valid `specialize`/
`AutoLogon` pass during a real boot — not to driver injection itself (Sysprep tolerated the
offline-injected `viostor`/`netkvm` drivers cleanly; the crash reproduced even with the
`pnputil`/`netkvm` step removed entirely — `PHASE3_ENGINEERING_LOG.md` Findings 11 and 14). That
pathway is closed (`HARD STOP` section) for reasons unrelated to what this plan does. The plan below
never touches Setup.exe's own processing at all — every change happens after a real, already-working
desktop is reached — but the general lesson (Windows 11 has shown fragility Server 2022/2025 never
has) still argues for gating each change independently rather than assuming success generalizes.

**This project's own prior driver-injection experience is directly relevant, not just cautionary.**
- `netkvm.inf`'s own `[SourceDisksFiles]` section requires `netkvmp.exe`/`netkvmco.exe` staged
  alongside `netkvm.inf`/`.sys`/`.cat`, or driver installation fails outright
  (`PHASE3_ENGINEERING_LOG.md` Finding 6). Confirmed present in the cached virtio-win ISO's
  `NetKVM/w11/amd64/` folder — see Research below.
- A **live** `pnputil /add-driver` (not offline `DriverDatabase` registration) is what actually
  completed NetKVM's real NDIS class install on Server 2022/2025 — offline registration alone left
  it PCI-matched but not functional (`PHASE2_ENGINEERING_LOG.md` Finding 39/40). This plan uses live
  `pnputil` throughout, so it's already using the mechanism that's proven to work, not the one that
  wasn't sufficient.

---

## Research findings (primary-source and community, verified rather than trusted from a search summary)

### 1. The cached virtio-win ISO (`../iso_cache/virtio-win-0.1.285.iso`) has real, Windows-11-specific driver builds for storage and NIC

Verified directly via `7z l`, not assumed from a version number:

- `vioscsi/w11/amd64/` and `viostor/w11/amd64/` — both present, both W11-specific builds
  (`vioscsi.inf`/`.sys`/`.cat`, `viostor.inf`/`.sys`/`.cat`). Both real options for the storage
  controller at the time this was written — decided: `vioscsi` (see "Decisions locked in" at top).
- `NetKVM/w11/amd64/` — present, and **includes** `netkvmp.exe`/`netkvmco.exe` alongside
  `netkvm.inf`/`.sys`/`.cat`, so this project's own Finding 6 lesson (the helper executables Setup
  needs) is already satisfied by simply staging the whole `NetKVM/w11/amd64/` folder.

### 2. SPICE: the user's own actual source (spice-space.org) is a better fit than the virtio-win ISO's bundled copy

Fetched directly from [spice-space.org/download.html](https://www.spice-space.org/download.html):
the primary Windows package is **`spice-guest-tools-latest.exe`**
(`/download/windows/spice-guest-tools/spice-guest-tools-latest.exe`), described on the page as
containing "qxl video driver and the SPICE guest agent (for copy and paste, automatic resolution
switching, ...)" — i.e. both halves needed for a real interactive SPICE session in one package,
unlike the virtio-win ISO (which has the QXL driver alone, with no `spice-vdagent` at all). The page
states directly: *"When running as Local System, the guest tools installer can be deployed
non-interactively (silent install) using the `/S` switch (case sensitive)"* — confirmed primary-source
silent-install syntax: `spice-guest-tools-latest.exe /S`.

This is a materially better foundation than the first draft's plan (which was going to hand-stage
the virtio-win ISO's `qxldod/w10/amd64` driver and separately go find `spice-vdagent` from an
unspecified source). One package, one silent install, actively maintained, and it's literally the
tool the user already has hands-on, working experience with.

**Residual, unresolved risk, stated plainly**: neither the QXL-WDDM-DOD driver's own download page
nor general upstream commentary makes an explicit Windows 11 compatibility claim — a spice-devel
mailing list maintainer (checked in the first research pass) said there's "no expectation of further
development on QXL," and a QEMU GitLab issue (#2728) documents real, unresolved QXL freeze reports on
Windows 10/11 guests at higher resolutions. This isn't a reason to skip SPICE — the user has already
proven this exact tool works for them manually — but it's real, and worth going in expecting SPICE to
be the phase most likely to need troubleshooting or to hit a hard limit that isn't this project's own
bug to fix.

### 3. `pnputil` vs. the bundled GUI/silent installers — a real choice per item, not a default

- **Storage (`vioscsi`/`viostor`) and NIC (`netkvm`)**: `pnputil /add-driver <path>\<name>.inf
  /install`, run live over WinRM, matches this project's own proven Server 2022/2025
  `FirstLogonCommands` pattern exactly (just moved from an answer-file step to a WinRM-invoked
  one-off command) — minimal footprint, no GUI, no service dependency, and already known to
  correctly complete NetKVM's class install when run live (Finding 39/40).
- **SPICE**: `pnputil` alone would only stage the QXL display driver, not the SPICE agent *service*
  (`spice-vdagent`) that clipboard/resolution/interactive use actually depends on — there's no
  driver-only equivalent for a userspace service. `spice-guest-tools-latest.exe /S` is the right tool
  here, matching what the user already runs manually, and its own docs confirm silent operation "when
  running as Local System" — confirmed empirically (not just assumed) that a WinRM-invoked process
  satisfies that same context: it installed and `vdservice` came up correctly across every clean run
  in this plan.

---

## Finding 3A-1: `pnputil /add-driver` alone does not register a boot-critical driver — the device
## must actually be present and live-PnP-installed for Windows to populate `DriverDatabase`/CDDB

**Discovered empirically, during Phase 3A.1.1's first real attempt, not predicted in advance.** The
original plan (below, since corrected) assumed a plain `pnputil /add-driver <inf> /install` — run
while the target device (`virtio-scsi-pci`) wasn't even attached to the VM, only the driver *files*
were reachable via a mounted ISO — would be enough to make the boot-critical registration stick. It
was not: `pnputil` reported `"Driver package added successfully"` (true, but only describes
**driver-store staging**, not device binding), and the subsequent disk-controller swap to
`virtio-scsi-pci` produced a real, screenshot-confirmed `INACCESSIBLE_BOOT_DEVICE (0x7B)`.

**Root cause**: staging an `.inf` into the driver store makes Windows *able* to find it during a real
Plug-and-Play install, but doesn't itself touch `HKLM\SYSTEM\DriverDatabase\DeviceIds\PCI\<hwid>` —
the boot-critical registration this project's own `PHASE2_ENGINEERING_LOG.md` Finding 29 already
identified as the real mechanism the boot loader consults. That registration only happens when
Windows actually performs a live PnP install against a **present** matching device.

**Fix, verified empirically before touching the boot disk again**: attach a second, live
`virtio-scsi-pci` controller (`id=scsi1`, no boot role) alongside the still-working `ide-hd` boot
disk. Windows detected it live, found the already-staged driver in the driver store, and installed
it for real — confirmed via `Get-PnpDevice` (`Red Hat VirtIO SCSI pass-through controller`,
`SCSIAdapter`, `Status: OK`) and directly via registry
(`HKLM:\SYSTEM\DriverDatabase\DeviceIds\PCI\VEN_1AF4&DEV_1004` now present, `vioscsi` service
`Start=0`/`Type=1`/`Group=SCSI miniport` — a real boot-start driver registration). Only then was the
swap re-attempted — successfully (see Phase 3A.1.1's own result below).

**One real complication this also surfaced, worth recording**: the two consecutive
`INACCESSIBLE_BOOT_DEVICE` crashes from the failed attempt caused Windows' own Automatic Repair to
trigger on the *next* boot too — even after reverting back to the known-good `ide-hd` device model.
This is boot-status-tracking state independent of the disk's actual driver configuration, doesn't
honor QMP `system_powerdown` (matching this project's established WinRE-screen behavior), and needed
one scripted `tools/qmp-sendkey.py ret` to click through "Restart" before a normal boot resumed. Not
a sign of a deeper problem — just something to expect and handle (screenshot-detect, sendkey through
it) any time this technique produces a real crash mid-development, not just on first success.

**This changes the recommended technique for every driver in this plan, not just storage** — see the
corrected Design section immediately below. Per direct user instruction, the same live-device
verification (not just driver-store staging) applies to NIC (Phase 3A.1.2) and should be treated as
the standard for SPICE's `qxldod` driver too, even though display isn't boot-critical the same way
storage is — verifying real device binding before relying on it is cheap insurance either way.

## Finding 3A-2: the NIC swap's real hang was a PCI topology problem, not a QXL conflict — and the
## fix itself has a sharp, non-obvious rule: only give the *new* device an explicit root port, never
## relocate an already-working device's placement

**Symptom, first encountered:** with storage (`vioscsi`) and SPICE already independently proven
working (Phase 3A.1.1 and the SPICE portion of 3A.1.3), swapping the NIC from `e1000` to
`virtio-net-pci` (with `qxl-vga`/SPICE/VNC still attached, all devices placed on QEMU's implicit
default PCI bus — no explicit `pcie-root-port`s anywhere, the pattern every earlier boot in this
plan had used successfully) produced a **genuine, confirmed hang**: `tools/qmp-screenshot.py` showed
a byte-identical frame at the TianoCore splash (`BdsDxe: starting Boot0008 "Windows Boot Manager"`,
never advancing) across 90+ seconds and multiple captures, while QMP `query-status` reported the VM
as `"running"` the whole time — a real wedge, not slowness. This is a **different failure signature**
from Finding 3A-1's `INACCESSIBLE_BOOT_DEVICE` — no error message at all, just nothing ever rendering
past the firmware boot-manager handoff.

**Wrong initial hypothesis, corrected directly by the user:** the first instinct was "QXL and
virtio-net-pci conflict when combined" (bisect by dropping QXL). The user rejected this immediately,
from direct personal experience: their own separate, actively-running `windows11vm-t14`/`winlab`
libvirt VM (observed live on this same host during this session, via `pgrep`) already runs
`virtio-net-pci` and `qxl-vga` together successfully. **A real, running counterexample is stronger
evidence than a plausible-sounding theory** — the bisection-by-dropping-QXL plan was correctly
abandoned before wasting a cycle on it.

**Real hypothesis, from comparing configs directly:** the `winlab` reference VM's actual command line
(captured via `pgrep -fa`) gives **every** PCI device its own `pcie-root-port` (14 of them,
`chassis=1..14`) — only `qxl-vga` sits directly on `pcie.0`, matching normal VGA-compatible-device
convention. Every boot this plan had run so far left QEMU to place devices on the implicit root bus
with no explicit ports at all. This is a real, structural difference, not a stylistic one.

**First fix attempt: added 4 explicit `pcie-root-port`s and moved *every* non-VGA device onto one**
(`scsi0` → `rp1`, `nic0` → `rp2`, `usb` → `rp3`, `virtio-serial0` → `rp4`; `qxl-vga` left on `pcie.0`,
matching the reference exactly). **Result: mixed.** The original hang was genuinely fixed — this boot
showed real progress (a spinner animation, then "Preparing Automatic Repair" text, neither of which
ever appeared during the pure hang) — but landed in Windows' own WinRE/Automatic-Repair flow instead
of a desktop, for a reason that turned out to be **unrelated to the fix itself**:

- **Secondary finding, real and worth keeping**: WinRE (`winre.wim`) is a separate, minimal recovery
  image with its own baked-in driver set, distinct from the main OS's `C:\` driver store. This
  project's live `pnputil` driver installs (Finding 3A-1's whole technique) only ever touch the main
  OS — never `winre.wim`. Confirmed directly inside a real WinRE Command Prompt session
  (`tools/qmp-click.py`/`qmp-type.py`/`qmp-sendkey.py` driving the GUI, since WinRE has no WinRM):
  `diskpart`'s `list disk` reported **"There are no fixed disks to show."** — WinRE genuinely cannot
  see the `vioscsi` disk at all, which is exactly why "Startup Repair couldn't repair your PC" showed
  up. **This is a known-shape, well-precedented limitation** (real-world driver-injection/P2V guides
  separately call out injecting drivers into `winre.wim`, not just the main OS), not a defect in this
  session's work — but it does mean **WinRE/Automatic Repair can never usefully help debug or fix
  anything about this project's driver-injection technique**, and is a dead end whenever it triggers.
- **Why WinRE triggered at all**: the *original* hang had to be hard-killed (`SIGTERM`/`SIGKILL` —
  ACPI `system_powerdown` doesn't work on a wedged firmware-level hang any more than it works on an
  interactive OOBE/WinRE screen, per this project's established pattern). That hard-kill flagged an
  unclean shutdown, which forced WinRE on the *next* boot regardless of whether that next boot's own
  config was actually fine — the same mechanism Finding 3A-1 already documented, recurring here for
  the same underlying reason (a hard-kill was needed), not a new instance of the same bug.
- Navigated out via the WinRE GUI (`Troubleshoot → Advanced options → Command Prompt → wpeutil
  reboot`), since WinRE offered no direct "Continue" option this time (plausibly because it couldn't
  even see a disk to offer to continue to).

**Second symptom, on the retry: a *new*, different, genuine failure** — `INACCESSIBLE_BOOT_DEVICE
(0x7B)`, screenshot-confirmed, on a disk whose storage config should already have been proven working.
**Root cause, isolated by removing one variable at a time (matching this project's own bisection
discipline)**: the first fix attempt had moved `scsi0` itself onto a new `pcie-root-port` — a
different PCI bus/slot than wherever QEMU's implicit placement had put it when Phase 3A.1.1 originally
proved it working. Relocating an *already-boot-critical-registered* device's PCI placement broke it,
independent of anything to do with the NIC. This was not obvious in advance and is worth stating as a
standing rule, not just a one-off war story:

**Rule, going forward, for this entire plan (and beyond)**: when adding a new device to a QEMU
invocation that already has a working, boot-critical-registered device, **give only the new device an
explicit `pcie-root-port`. Never relocate an already-proven device's placement**, even when the
motivating reason (matching a reference topology) seems to justify reorganizing everything. Windows'
boot-critical driver matching appears sensitive to more than just the hardware ID once a device is
already registered — moving it is a real risk, not a no-op.

**Final, isolated fix — confirmed working**: relaunched with `scsi0` at its original, untouched
implicit placement and **only** `nic0` given an explicit `pcie-root-port` (a single new port, nothing
else changed). Result, real and complete: booted straight through (one expected WinRE detour from the
still-unclean prior shutdown, resolved the same way), real desktop, real WinRM (one transient timeout
then success on retry — matching this project's own long-documented first-probe-hiccup pattern, not a
new concern), `Get-NetAdapter` showing `Red Hat VirtIO Ethernet Adapter #2`/`Up`/`10 Gbps`, `Get-Disk`
still `Online` and completely unaffected. Storage and NIC are now proven working together on the same
disk.

**Net effect on this plan's own technique table above**: the "attach a live device, verify real PnP
install" discipline (Finding 3A-1) is necessary but **not sufficient** on its own once more than one
non-default device is involved — PCI placement discipline (add-only, never relocate) is a second,
independent rule this plan now carries forward, including into the eventual Server 2022/2025 SPICE
work (Phase 3A.2/3A.3), where the same "don't relocate `viostor`/`netkvm`'s existing placement" caution
applies even though those devices reach boot-critical status via the separate offline-hivex mechanism
rather than this plan's live-install technique.

**A second, meta-level mistake, made immediately after writing the finding above — recorded because
it repeated within the same session, not a hypothetical risk:** formalizing the manual recipe into
`image-apply/inject-virtio-spice.sh` combined two steps that had only ever been *separately* proven by
hand (storage-verify and NIC-verify were two different manual boots) into one Stage 1 boot, for
efficiency — without re-verifying that combination first, and without giving the newly-combined
verify devices explicit root ports defensively. That combined shape hung at the firmware level on the
script's own first real end-to-end run, the exact same signature as the original finding
(byte-identical `tools/qmp-screenshot.py` captures, near-zero CPU, QMP still reporting `"running"`).
**This is the identical class of error Finding 3A-2 itself already warned about** — composed changes
aren't safe just because each piece worked alone — repeated while writing the very script meant to
encode that lesson. Fixed the same way (explicit `pcie-root-port` for both verify devices, since
they're throwaway and never referenced again after Stage 1, so there's no relocation risk in placing
them explicitly from the start). Worth carrying forward as a standing discipline, not just this one
fix: **when formalizing/compressing a manual recipe into a script, treat any newly-combined step as
untested until it's actually run, even if every piece being combined was individually proven.**

## Design: the unified technique, and why it's the recommended default for all three

**Build unmodified → attach a live, present device of the target type alongside the original (not
just the driver files) → confirm Windows performs a REAL PnP install against it
(`Get-PnpDevice`/`Status: OK`, not just `pnputil`'s "driver package added" staging confirmation) →
graceful QMP shutdown → swap the relevant QEMU device flag(s) → boot again → verify the new device is
active and healthy.** (Revised from the original "just run `pnputil` against staged files" framing
per Finding 3A-1 above — corrected here, not left as a stale draft.)

| Item | Live-install step (device must be present, per Finding 3A-1) | Device swap | Verify |
|---|---|---|---|
| Storage (vioscsi/viostor) | Stage the `.inf` (WinRM copy, or the virtio-win ISO attached as a data-only CD-ROM) so it's in the driver store, **then attach a live, present second `virtio-scsi-pci` controller** (`id=scsi1`, no boot role) alongside the working boot disk so Windows performs a real PnP install against it — confirm `Get-PnpDevice`/`Status: OK` and `DriverDatabase\DeviceIds\PCI\<hwid>` present before proceeding | `-device ide-hd,...` → `-device virtio-scsi-pci,...`+`scsi-hd` (decided: `vioscsi`, see locked decisions) | `Get-Disk`/`Get-PhysicalDisk` over WinRM shows the virtio controller; boots cleanly with no `INACCESSIBLE_BOOT_DEVICE` |
| NIC (netkvm) | Stage the `NetKVM/w11/amd64/` package, **then attach a live, present second `virtio-net-pci` NIC** alongside `e1000` so Windows performs a real PnP install against it — confirm `Get-PnpDevice`/`Status: OK` before proceeding, same discipline as storage | `-device e1000,...` → `-device virtio-net-pci,...` | `Get-NetAdapter` over WinRM shows the Red Hat VirtIO adapter `Up`, real WinRM reachable over it |
| Display (QXL/SPICE) | `spice-guest-tools-latest.exe /S` over WinRM — not boot-critical the way storage/NIC are, but per user direction, verify `Get-PnpDevice`/`Status: OK` for the QXL device once it's live rather than assuming the installer's own success message is sufficient | add `-vga qxl` (or `-device qxl-vga`) + `-spice <args>` to the QEMU invocation (net-new — nothing currently configures a non-default display device or a SPICE listener at all) | Real desktop renders correctly under QXL; `tools/qmp-screenshot.py` still works against the new display device (verify, don't assume); a real SPICE client can connect and interact |

**On resurrecting offline `hivex` injection — still deliberately not proposed.** The old fully-offline
pipeline's `DriverDatabase` registration technique (`tools/gen-viostor-ddb-reg.py`) is real and proven
for Server 2022/2025, but building it into the Windows 11 pipeline would mean touching the
offline-write-then-first-real-boot mechanism class associated with the HARD STOP saga. The technique
above needs none of that — it only ever acts on a Windows 11 disk that's already booted successfully
under its current, proven device model.

**Why this is lower-risk than the first draft's `DriverPaths` approach, not just user-preferred:**
`DriverPaths`-during-Setup would have been a completely new mechanism for this project, exercised at
the single most fragile point in the whole Windows 11 pipeline (inside Setup.exe itself, before this
project has ever gotten a live WinRM foothold). The technique here does the opposite: it changes
nothing about how the disk gets built, and only starts experimenting *after* the point this project's
own evidentiary bar already calls "done" three times over (Phase 3.5's two clean production runs).
Each swap is also independently recoverable during development — if a device swap doesn't boot, the
pre-swap disk (with the driver already staged) still exists and the swap can be retried or debugged
without re-running Setup.exe at all.

---

## Assumptions

1. The goal is to change the **production** `windows11-setup-install.sh` path's *eventual* device
   model, not just prove the technique in isolation — i.e., once proven, this becomes how real builds
   ship (a build phase, plus a driver-stage-and-swap phase, both scripted).
2. SPICE's goal is a live, interactive SPICE-client session (confirmed by the user) — so
   `spice-vdagent`/clipboard/resolution features are in scope, not just the QXL display device.
3. This project's standing evidentiary bar (2-3 independent clean runs before calling any mechanism
   "confirmed") applies to each phase below, including the final combined shape.
4. Each of the three device swaps is validated in isolation before being combined, matching this
   project's own established bisection discipline — largely because Windows 11's documented fragility
   means composed changes shouldn't be assumed additive without checking.

## Risks

- **The boot-critical nature of the storage swap makes it the highest-stakes of the three.** Unlike
  NIC or display (where a botched swap likely means "device doesn't work yet, boots to desktop
  anyway"), a botched storage swap means `INACCESSIBLE_BOOT_DEVICE` and no boot at all. Well
  understood in principle (this is exactly what CriticalDeviceDatabase registration exists to
  prevent) and the user has direct personal proof this works — but it's the item to test first, alone,
  before anything else touches the same disk.
- **Whether a WinRM-invoked `pnputil`/silent-installer process runs with equivalent privilege/context
  to the user's own manual "logged into the desktop, run the installer" experience — resolved,
  confirmed working.** `spice-guest-tools-latest.exe /S` installed cleanly and `vdservice` came up
  correctly via a WinRM-invoked session across every one of this plan's clean runs (6 total, across
  all three OSes) — the assumption held, not just presumed.
- **QXL/SPICE has a real chance of not working perfectly on Windows 11** even with the right tool —
  upstream itself hasn't made an explicit Windows 11 compatibility claim, and there's at least one
  open, unresolved freeze report (QEMU GitLab #2728) for QXL under Windows 10/11. **In this project's
  own hands, it worked cleanly every time** (6/6 clean runs across all three OSes) — worth keeping
  this risk on record anyway, since "worked every time we tried it" isn't the same as "guaranteed
  to keep working," especially given upstream's own lack of a compatibility claim.
- **QEMU-side SPICE listener auth/exposure — resolved: loopback-only, no auth.** See "Decisions
  locked in" at the top of this document.

---

## Phased plan — 3A.1: Windows 11

Each phase is scoped like this project's own Phase 3.1-3.5 sub-phases: one variable at a time, a
stated pass/fail gate, fresh disks each attempt where practical, no combining until each piece is
independently proven. Nothing here touches `image-apply/apply-unattend.sh`, `make-bootable.sh`, or
anything else in Server 2022/2025's own path, and nothing here touches `windows11-setup-install.sh`'s
own Setup.exe-facing logic at all — every change happens strictly after that script's own existing,
three-times-proven success point (real WinRM confirmed).

### Phase 3A.1.1 — VirtIO storage: live-install, shutdown, swap, reboot

**Steps (corrected per Finding 3A-1 — driver-store staging alone is not enough):** build a fresh disk
via the unmodified, current `windows11-setup-install.sh` (no changes to that script at all). Once
real WinRM is confirmed (the script's own existing success bar), stage `vioscsi/w11/amd64/` into the
driver store (`pnputil /add-driver`, or straight off an attached virtio-win ISO). **Relaunch with a
second, live `virtio-scsi-pci` controller attached alongside the still-`ide-hd` boot disk** (no boot
role — just present) and confirm Windows performs a real PnP install against it
(`Get-PnpDevice`→`Status: OK`, and `HKLM:\SYSTEM\DriverDatabase\DeviceIds\PCI\<hwid>` present) before
touching the boot disk at all. Graceful QMP `system_powerdown` (per this project's standing rule
against hard `quit` on a disk being reused). Relaunch `qemu-system-x86_64` against the same disk with
the target-disk device changed from `-device ide-hd,...` to `virtio-scsi-pci`+`scsi-hd`, dropping the
now-unneeded second controller.

**Gate:** boots cleanly with no `INACCESSIBLE_BOOT_DEVICE`, reaches a real desktop, real authenticated
WinRM confirms `Get-Disk`/`Get-PhysicalDisk` shows the virtio controller in active use. 2-3
independent clean runs (fresh disk each time, full cycle repeated) before treating this as done.
**First attempt result**: initially failed exactly this way (screenshot-confirmed
`INACCESSIBLE_BOOT_DEVICE`) before the live-device-verification step was added — see Finding 3A-1.

**If it fails:** first confirm the live-PnP-install step actually completed (`Get-PnpDevice`/
`Status: OK`, registry check) rather than assuming a deeper problem — Finding 3A-1 already shows the
most likely failure mode is skipping or short-circuiting that verification, not a new, different bug.
If a crash does happen, expect Windows' Automatic Repair to trigger on the *next* boot regardless of
device model (Finding 3A-1's own complication) — screenshot-detect it and click through via
`tools/qmp-sendkey.py`, don't mistake it for a recurrence of the original failure.

### Phase 3A.1.2 — VirtIO NIC: same pattern, against Phase 3A.1.1's proven storage config

**Steps (same live-device-verification discipline as 3A.1.1, per direct user instruction):** starting
from a disk that already has Phase 3A.1.1's virtio storage swap proven, stage the `NetKVM/w11/amd64/`
package (driver + `netkvmp.exe`/`netkvmco.exe`, per Finding 6) into the driver store. **Attach a
second, live `virtio-net-pci` NIC alongside the still-working `e1000`** and confirm Windows performs a
real PnP install against it (`Get-PnpDevice`→`Status: OK`) before touching the primary NIC device at
all — NIC isn't boot-critical the way storage is, so a bad swap here would likely just mean "no
network" rather than a full crash, but verifying first avoids burning a boot cycle finding that out
the hard way. Graceful shutdown, swap `-device e1000,...` → `-device virtio-net-pci,...`, drop the
now-unneeded second NIC, reboot.

**Gate:** real authenticated WinRM comes up over the virtio NIC with no further live step needed;
`Get-NetAdapter` shows the Red Hat VirtIO adapter `Up`, not just PCI-present. 2-3 independent clean
runs.

**Result (first real attempt): passed, but only after real debugging — see Finding 3A-2 in full.**
Short version, stated here as the actionable rule for repeating this phase: introducing
`virtio-net-pci` on QEMU's implicit PCI placement (no explicit `pcie-root-port`) caused a genuine
firmware-level hang (not a crash — a wedge at the TianoCore splash, confirmed via byte-identical
`tools/qmp-screenshot.py` captures and QMP `query-status` still reporting `"running"`). The fix is an
explicit `pcie-root-port` for the NIC — but **`scsi0` (storage) must be left at its exact existing
placement, not also moved to a new port**, even when reorganizing topology to match a reference
config. Moving an already-boot-critical-registered device's PCI placement broke it independently of
anything to do with the NIC. Add a port only for the device actually being introduced; never relocate
a device that already works.

### Phase 3A.1.3 — SPICE display: same pattern, against Phase 3A.1.1+3A.1.2's proven config

**Steps:** live-install `spice-guest-tools-latest.exe /S` over WinRM (downloaded once, cached
locally the same way `virtio-win-0.1.285.iso` already is under `../iso_cache/`, rather than fetched
fresh per build). Graceful shutdown, add `-vga qxl`/`-device qxl-vga` plus `-spice <args>` to the QEMU
invocation (net-new — resolve the open question on listener exposure/auth first), reboot.

**Gate:** real desktop renders correctly under the QXL device (confirm `tools/qmp-screenshot.py`
still functions against it — this project's whole debugging convention depends on that continuing to
work, don't assume it survives the device change), a real SPICE client can connect and interact with
the desktop, and `spice-vdagent`'s service is running (clipboard/resolution features functional, not
just the driver loaded). 2-3 independent clean runs. Given the weaker upstream confidence here
specifically, time-box this phase rather than iterating indefinitely if it doesn't converge quickly —
matching this project's "avoid rabbit holes" standard.

### Phase 3A.1.4 — Combined shape: one live-install pass, one final device-swap boot

**Steps:** once each swap is independently proven, test the production-efficient shape: build once,
live-install all three driver packages in a single guest session (one shutdown instead of three),
then one final reboot with all three device swaps applied together (disk + NIC + display at once).

**Gate:** 2-3 independent clean runs of the fully-combined shape, specifically because composed
changes on Windows 11 shouldn't be assumed additive just because each swap passed alone. If this
regresses where the isolated phases didn't, that's a real, useful finding worth its own bisection
before proceeding.

**Formalized as real, committed, OS-parameterized production tooling** (not just an ad hoc
transcription of the manual session): `image-apply/inject-virtio-spice.sh`, taking
`<server2022|server2025|windows11> <target-qcow2-path>` like every other `image-apply/*.sh` script,
wired into `build.sh`'s `windows11` branch as its real `[2/2]` step (Server 2022/2025's own branch is
untouched — confirmed via `git diff`, not just reviewed by eye). **Storage swap runs for every OS**
(revised after this section was first written — see the "Scoping revised" note above; storage was
briefly `windows11`-only before the user directed it be exercised on Server 2022/2025 too). NIC swap
stays `windows11`-only, written generically enough to detect an already-virtio NIC on Server 2022/2025
and skip cleanly (nothing to swap there, per `packer/boot-and-provision.pkr.hcl`'s own
`net_device = "virtio-net"`); SPICE runs identically for every OS. Findings 3A-1, 3A-2, and (added
after Windows 11's own production tooling first ran cleanly) 3A-3 are all encoded directly in the
script — see each finding for the exact mechanics.

## Finding 3A-3: a Stage 1 "verify" device must match Stage 2's real device topology exactly, or it
## can verify the wrong PCI hardware ID entirely

**Discovered on the script's own first genuinely clean, single-pass end-to-end run** (a fresh disk
through the real `build.sh windows11` entry point, no manual intervention, no retried/reused disk
state) — the exact kind of run this plan's evidentiary bar exists to require, and it caught something
every earlier retry (each reusing a disk that had already been through this process before) had
papered over.

**Symptom:** Stage 1 completed cleanly — `pnputil` reported success, and the script's own
`Get-PnpDevice`/`Status: OK` verification (Finding 3A-1's whole discipline) passed. Stage 2 then
crashed with a screenshot-confirmed `INACCESSIBLE_BOOT_DEVICE (0x7B)` — the exact failure Finding
3A-1 was supposed to have closed off for good.

**Root cause, found by direct comparison of `pnputil`'s own device-ID output** between this clean run
and an earlier "successful" one: a bare (driveless) `virtio-scsi-pci` verify controller — Stage 1's
original design, deliberately left without a backing drive since it was never meant to be booted from
— negotiates a *different* PCI hardware ID (`VEN_1AF4&DEV_1048`, the "modern"/1.0-only virtio ID)
than the same controller once it has a real backing drive (`VEN_1AF4&DEV_1004`, "legacy/transitional")
— which is what Stage 2's real, drive-attached `scsi0` actually needs registered. The earlier
"successful" runs were never a real test of this: each reused a disk that had *already* accumulated a
`DEV_1004` registration from an earlier, differently-configured manual session, so Finding 3A-1's own
verification step was checking a device that happened to already be covered by leftover state, not by
that run's own Stage 1. **This is exactly the kind of false confidence a single success, or a chain of
retries against reused state, can produce** — this project's own standing evidentiary bar (2-3
independent clean runs, never trusting one result) exists precisely to catch this, and did.

**What actually determines the ID split was left genuinely unresolved, on purpose, rather than
guessed at**: drive presence and explicit-vs-implicit PCI bus placement were both plausible
explanations from the available evidence, and neither was confirmed before a fix was needed. Per this
project's own standing preference for deterministic fixes over probabilistic ones, the fix doesn't
depend on knowing which factor is the real cause: **every verify device in Stage 1 now matches its
Stage 2 counterpart's PCI placement exactly** — identical root-port `addr`/`chassis`/`port` for both
the storage and NIC verify devices, and a real (if throwaway) backing drive for the storage verify
controller specifically. Whatever QEMU actually negotiates for that topology, Stage 1 and Stage 2 are
now guaranteed to negotiate the *same* thing, since the topology itself is byte-identical between the
two boots — closing the gap regardless of the underlying mechanism.

**Also worth recording plainly**: this was caught only because a genuinely fresh, single-pass run was
insisted on rather than treating the prior retried-script success as sufficient — a real, concrete
instance of this project's own "one success is not the same as reliable" lesson (first learned the
hard way during the Windows 11 Option A/B saga) applying again here, to this plan's own work.

---

## Phased plan — 3A.2: Server 2022 (storage swap + SPICE)

**Updated 2026-08-23 — storage is now in scope, per the "Scoping revised" note above.** Server 2022
already has production-proven `netkvm` (offline-hivex mechanism, untouched by this plan — NIC swap
stays Windows 11 only, confirmed explicitly with the user after an initial miscommunication). `vioscsi`
and SPICE are both new work here, using `image-apply/inject-virtio-spice.sh server2022` directly (the
same OS-parameterized production script Windows 11 uses, not a separate mechanism).

**Steps:** fresh base disk via the underlying `partition-disk.sh`/`apply-image.sh`/`make-bootable.sh`/
`apply-unattend.sh` sequence directly (not `build.sh server2022`, which always runs *some* role set —
the repo's default `services.yaml` has `iis` enabled, and Packer's `boot-and-provision.pkr.hcl` has no
"truly no roles" mode; passing an empty `services_yaml_path` still falls through to that default). A
minimal, direct ad hoc `qemu-system-x86_64` boot (`virtio-blk-pci`/`virtio-net-pci`, matching
`make-bootable.sh`'s own device model, no Packer at all) confirms the base disk reaches real WinRM
with zero roles applied — this build's only job. Then `inject-virtio-spice.sh server2022 <disk>` runs
unmodified.

**Gate:** Stage 1 live-verifies `vioscsi` (Status OK), confirms `netkvm` already `Up` (no swap
attempted), installs SPICE tools. Stage 2 swaps storage to `virtio-scsi-pci`, confirms `Get-Disk`
`Online`, `Get-NetAdapter` `Up`, QXL `Status: OK`, `vdservice` `Running`. 2-3 independent clean runs,
matching this project's standing bar.

**Result: passed cleanly, twice, on independent from-scratch disks.** Both runs used a real base disk
(no roles), both ran `inject-virtio-spice.sh server2022` end to end with zero manual intervention:
`vioscsi` live-verified (both runs negotiated `VEN_1AF4&DEV_1048`, the same "modern" ID Windows 11's
own clean runs negotiated — confirms Finding 3A-3's topology-matching fix generalizes across OSes and
is consistent run to run, not a fluke of one disk), `netkvm` confirmed already virtio and untouched
both times, SPICE installed, storage swapped to `virtio-scsi-pci` and booted clean, all Stage 2
verifications passed both times.

**Closed at 2 runs, by explicit user judgment, not the full 3.** This project's own 2-3-run bar exists
mainly to catch a fix that looked clean once but wasn't actually reliable (exactly what happened with
Windows 11's NIC topology work earlier the same day — Finding 3A-2/3A-3 needed a 3rd run precisely
*because* earlier attempts had real, unresolved failures in between). Server 2022's two runs here were
both clean from the very first attempt, with no intervening failures to re-confirm past — 2/2 with zero
complications was judged sufficient. **Phase 3A.2 is done.**

## Phased plan — 3A.3: Server 2025 (storage swap + SPICE)

**Updated 2026-08-23 — storage in scope, same as 3A.2.** Identical to 3A.2 in every particular except
`DRIVER_SUBFOLDER=2k25` and a fresh base disk via `partition-disk.sh`/`apply-image.sh`/
`make-bootable.sh`/`apply-unattend.sh server2025`. Written as its own phase (not folded into 3A.2)
because this project's own history has repeatedly shown Server 2025 is not always a safe assumption
from Server 2022 alone (e.g. Session 1's `cpu_model`/`qemu64` finding, which hit Server 2025
specifically and not Server 2022) — worth its own independent confirmation rather than treated as
automatic.

**Gate:** same as 3A.2.

**Result: passed cleanly, twice, on independent from-scratch disks — the assumption held this time.**
Both runs: real base disk (no roles), `inject-virtio-spice.sh server2025` ran both stages with zero
manual intervention, `vioscsi` live-verified (`VEN_1AF4&DEV_1048`, identical to every Server 2022 and
Windows 11 clean run — the topology-matching fix holds across all three target OSes now), `netkvm`
confirmed already virtio and untouched both times, SPICE installed, storage swapped to
`virtio-scsi-pci` and booted clean, all Stage 2 verifications passed both times. Closed at 2 runs, same
reasoning as 3A.2 (both clean from the first attempt, no intervening failures to re-confirm past).
**Phase 3A.3 is done.**

---

## Finding 3A-4: `spice-guest-tools`' bundled QXL driver is not a real WDDM driver — Start Menu and
## other XAML/Fluent-UI shell components crash immediately; fix is `virtio-win`'s own `qxldod` package

Discovered 2026-08-23, the first time a Phase 3A-built disk was actually used interactively (not
just headlessly verified) — `register-vm.sh`'s own first real end-to-end test (Server 2022) booted
cleanly to a real desktop, but clicking Start did nothing. Root-caused live over WinRM (event log +
process inspection on the running guest, not guesswork):

- `StartMenuExperienceHost.exe` (the UWP process that renders Start/Search/Action Center) was not
  running at all. Launching it manually terminated immediately (`HasExited: True`).
- Windows Error Reporting / Application Error events showed the real signature: fault in
  `Windows.UI.Xaml.dll`, exception `0xc0000409` (a `__fastfail`, not a literal buffer overrun) —
  the XAML/Fluent-UI composition pipeline failing, not a profile or permissions issue (a separate,
  real but unrelated temporary-profile fallback was hit on the very first login too — `Get-WinEvent`
  Event IDs 1500/1511 — but a clean reboot resolved that on its own; it was not the cause of the
  Start Menu crash, which persisted after the reboot).
- Explorer.exe, Edge, and File Explorer all worked fine throughout — they don't depend on
  `Windows.UI.Xaml.dll`'s composition path the way Fluent-UI shell surfaces do.
- The installed QXL driver (via `spice-guest-tools-latest.exe`, this project's existing dependency)
  was the classic driver: `DriverVer 09/22/2015`, no real Direct3D/WDDM support behind it — this is
  a long-known, real limitation, not a one-off: Red Hat's own bug tracker has an open RFE asking for
  exactly a proper WDDM driver
  ([bugzilla.redhat.com/895356](https://bugzilla.redhat.com/show_bug.cgi?id=895356)), and there's a
  related report of QXL driver unavailability on Server 2019
  ([bugzilla.redhat.com/1902635](https://bugzilla.redhat.com/show_bug.cgi?id=1902635)).
- Confirmed, not just theorized: the user's own long-used reference VM (`windows11vm-t14`, run
  outside this project entirely) has a working Start Menu and is running a *different* QXL driver —
  `Driver Date 11/20/2020`, `Driver Version 10.0.0.21000`, `Digital Signer: Microsoft Windows
  Hardware Compatibility Publisher` (WHQL-signed). That exact driver — `qxldod`, Red Hat's "QXL
  Display Only Driver" — turned out to already be sitting in this project's own cached
  `virtio-win-0.1.285.iso`, the same ISO already mounted for `vioscsi`/`netkvm`. No new download,
  no new dependency.

**Fix, implemented in `image-apply/inject-virtio-spice.sh` (2026-08-23, not yet re-verified by a
full end-to-end run since the change)**: stage `qxldod` from the virtio-win ISO in Stage 1 (folder
`2k19`/`amd64` for Server 2022/2025, `w10`/`amd64` for Windows 11 — the `2k22`/`2k25`/`w11` folder
names simply don't exist for this driver, but `qxldod.inf`'s own `[Manufacturer]` section targets
`NTamd64.6.2` generically — Windows 8/Server 2012 and later, no per-version restriction above that —
and the `2k16`/`2k19`/`w10` folder contents are sha256-identical, confirmed directly, so the folder
choice is organizational only, not a compatibility risk). `spice-guest-tools` still runs unchanged
(`spice-vdagent`/`vdservice` has no better source); only the competing display driver is added
alongside it. Both `qxl.inf` (classic) and `qxldod.inf` target the identical PCI hardware ID
(`PCI\VEN_1B36&DEV_0100&SUBSYS_11001AF4`), so this is genuine competition, not two unrelated
drivers coexisting — and it resolves deterministically, not probabilistically: `qxldod.inf`
declares `FeatureScore = F9`, classic `qxl.inf` declares `FeatureScore = FC` — lower wins under
Windows' own documented driver-ranking rule, so simply staging both and letting the real Stage 2
device bind is sufficient, no forced uninstall of the classic driver needed. Stage 2's own
verification was extended to match: `Status: OK` alone doesn't distinguish which of the two
competing drivers bound (the classic one also reaches `Status: OK` — it's not that Windows sees it
as broken, only that XAML rendering on top of it fails), so the check now asserts the bound driver's
`DriverVersion` is specifically `10.0.0.21000` (`Win32_PnPSignedDriver`), not just device status.

**Correction, same night, after further testing: this fix does NOT actually resolve the Start Menu
crash it was written to fix.** The "no crash" result that looked like confirmation was a false
negative — it came from launching `StartMenuExperienceHost.exe` via a WinRM PowerShell session, which
runs in Session 0 (services) and can't run UWP apps at all, so the test never really exercised the
crash path. A valid test (a scheduled task launched with `/it` into the real interactive session)
reproduced the **identical** crash — same fault offset, same module version — on a disk already
running `qxldod`. Independent, decisive counter-evidence: the user's own long-lived `win2022-dc`
reference VM has a *working* Start Menu while still running the *old* 2017 classic driver, directly
contradicting a driver-based explanation. The `qxldod` swap itself is still a real, worthwhile fix
for `spice-guest-tools`' outdated driver — it just isn't what was breaking Start Menu. The actual
root cause (a documented Windows Server 2022 RPC/DCOM boot-race, triggered by this project's own
multi-boot-cycle build pattern) and its fix (an offline `ServicesPipeTimeout` registry increase in
`make-bootable.sh`) are recorded in `../CLAUDE.md`'s Finding 3A-5, not here — it's not a virtio/SPICE
driver issue and doesn't belong in this document's own scope.

**Evidentiary status**: the `qxldod` driver swap itself (the actual subject of this finding) has been
confirmed by one real end-to-end run (Server 2022) — `Win32_PnPSignedDriver` showed `qxldod` bound
(`DriverVersion 10.0.0.21000`) after a real Stage 2 boot. This project's own evidentiary standard
(2-3 independent clean runs) still applies before calling the driver swap itself fully confirmed
across all three OSes — see the status summary below.

---

## Phase 3A status summary (as of 2026-08-23)

All three target OSes had `vioscsi` storage + SPICE confirmed via the same, single, OS-parameterized
`image-apply/inject-virtio-spice.sh`, **before** Finding 3A-4's `qxldod` fix landed:

| OS | Storage swap | NIC swap | SPICE (classic QXL) | SPICE (qxldod) | Clean runs |
|---|---|---|---|---|---|
| Windows 11 | ✅ `vioscsi` | ✅ `netkvm` | ✅ | not yet re-run | 2 |
| Server 2022 | ✅ `vioscsi` (new) | — (already `netkvm`, untouched) | ✅ | not yet re-run | 2 |
| Server 2025 | ✅ `vioscsi` (new) | — (already `netkvm`, untouched) | ✅ | not yet re-run | 2 |

Every clean run across all three OSes negotiated the identical `VEN_1AF4&DEV_1048` PCI ID for
`vioscsi` — Finding 3A-3's topology-matching fix (Stage 1's verify device byte-identical to Stage 2's
real device) has now been confirmed to generalize across every target OS, not just within one.
**The "SPICE" column above reflects the pre-Finding-3A-4 state (classic QXL driver, Start Menu
broken)** — Finding 3A-4's fix needs its own fresh evidentiary pass (2-3 clean runs) before the
`vioscsi` row's own standard can be said to extend to it.

---

## Decisions that were open questions, now resolved (all three, before any implementation began)

Originally posed as blocking questions before Phase 3A.1.1 started; kept here as the resolved record
rather than deleted, since the "Decisions locked in" summary at the top of this document references
them.

1. **Storage controller: `vioscsi` or `viostor`? → Decided: `vioscsi`.** Both were present,
   OS-specific, in the cached ISO for every target OS. `viostor`/`virtio-blk-pci` had more precedent
   in this project (Server 2022/2025's own existing offline-hivex recipe uses it); `vioscsi`/
   virtio-scsi is Red Hat's more current general recommendation and is also what the user's own
   manual `windows11vm-t14` experience used. Confirmed working identically across all three OSes,
   6 clean runs total (see the status summary table).
2. **SPICE listener exposure → Decided: loopback-only (`127.0.0.1`), no auth
   (`disable-ticketing=on`).** Matches the WinRM `hostfwd` convention already in use elsewhere in
   this project; local testing only, no remote/public exposure. Implemented exactly this way in
   `image-apply/inject-virtio-spice.sh`'s `-spice` args.
3. **Driver/tool caching → Decided: yes, cache it.** `spice-guest-tools-latest.exe` is cached under
   `../iso_cache/`, sha256-sidecar'd, documented in `../ISO_CACHE_INVENTORY.md` alongside the project's
   other cached media (see that file's own "Known gap" note on the fact that spice-space.org ships a
   rolling "latest" filename rather than a versioned release, so this doesn't yet have the same
   ETag-based re-check convention the Microsoft/virtio-win sources do — a real, still-open item,
   just not one that blocked this plan).
