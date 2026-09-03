# Windows Auto-Build Pipeline

Build fully reproducible, disposable Windows lab VMs — Windows Server 2019, Windows Server 2022,
Windows Server 2025, and Windows 11 Enterprise Evaluation — without relying on an interactive
installer boot. Every build applies a fresh Windows image straight to disk from Linux and comes up
unattended, ready for automated configuration and testing.

This is a working, hand-run-from-the-command-line research/lab tool, not a packaged product. It's
documented here so it can be picked up, understood, and driven by someone who wasn't part of
building it — see "Risks and limitations" below before relying on it for anything beyond that.

## Why this exists

The original motivation is Datadog Agent testing against realistic Windows environments —
Windows/Active Directory/IIS/SQL Server monitoring integration, simulating the kind of enterprise
and regulated-cloud (FedRAMP/GovCloud-style) customer setups those integrations actually run
against in the wild. That requires real, disposable Windows Server and Windows 11 VMs that can be
built and torn down repeatedly, not a single hand-maintained golden image — a golden image can't
be cloned safely here anyway, because Windows evaluation media's activation countdown doesn't
reset on clone, and the `sysprep`/rearm mechanism that could extend it is capped at a small number
of uses for the life of one install.

This project's sibling, [`../windows-server-vm-automation/`](../windows-server-vm-automation/),
builds the same kind of environment via Packer driving a normal interactive Windows Setup boot
(`autounattend.xml` over VNC keystroke injection). That works reliably for Windows Server 2022 —
but the identical mechanism *reliably fails* for Windows Server 2025 and Windows 11 media, tracked
upstream as an open, unresolved Packer/QEMU/OVMF issue
([hashicorp/packer#13342](https://github.com/hashicorp/packer/issues/13342),
[#13514](https://github.com/hashicorp/packer/issues/13514)), not a configuration mistake on either
project's part. This project exists to install Windows a different way for the OSes where that
approach doesn't work.

## Two installation mechanisms, by OS

- **Windows Server 2019, 2022, and 2025**: fully offline image application. `wimlib` applies the
  Windows image directly onto a partitioned, formatted disk from this Linux host — no boot of any
  kind during installation. The disk is made bootable afterward (WinPE + a real `bcdboot` run,
  once), specialized via an offline-dropped `unattend.xml`, and only then booted for the first
  time, via Packer, straight into a WinRM-reachable, already-configured machine. Server 2019 was
  added after the other two OSes proved the mechanism out — see "Summary of prior work" below;
  its own design/research trail lives in `WINDOWS_SERVER_2019_RESEARCH_PLAN.md` and
  `WINDOWS_SERVER_2019_IMPLEMENTATION_PLAN.md`.
- **Windows 11**: a Setup.exe-driven install using a Microsoft-patched, prompt-free install ISO
  (the `_noprompt` boot files Microsoft has shipped for over a decade, applied via a hand-built
  QEMU invocation with explicit UEFI boot-order control) plus an answer-file ISO — one unattended
  QEMU session, no Packer handoff. The fully-offline approach used for the Server SKUs was tried
  for Windows 11 first and hit a hard, unresolved kernel-level BSOD on first real boot; the
  Setup.exe path replaced it after that investigation concluded. See "Summary of prior work" below.

Both mechanisms end in the same place: a disposable, bootable, WinRM-reachable Windows VM with no
manual steps in between. Windows Server 2022/2025 then go on to get role provisioning (Active
Directory Domain Services, IIS, SQL Server — see "Roles" below); Windows 11 doesn't get those
roles, by design, but does get VirtIO storage/NIC and SPICE display drivers for a usable
interactive desktop.

## Summary of prior work and prior art

This project leaned on existing, credible prior art rather than reinventing low-level mechanisms —
worth knowing both because it explains some of the design and because it's where credit is due
(see "Acknowledgements" below):

- **The boot-prompt failure itself** is a known community issue, not something specific to this
  host — confirmed via the two open Packer issues above and a matching report on HashiCorp's own
  Discuss forum, all describing the identical symptom (UEFI drops to the EFI shell instead of
  booting install media).
- **Making an offline-applied disk bootable** uses Microsoft's own documented mechanism
  (`DISM /Apply-Image` + `bcdboot`, run from WinPE) — not a novel approach. An alternative,
  zero-boot-required tool, [BCD-SYS](https://github.com/jpz4085/BCD-SYS), was evaluated and also
  confirmed to work, but the WinPE + real `bcdboot` path is what shipped in production.
- **Offline VirtIO driver injection** (so a freshly-applied disk doesn't hit
  `INACCESSIBLE_BOOT_DEVICE` on its very first boot) follows the same registry-injection pattern
  used by [`virt-v2v`](https://github.com/libguestfs/libguestfs) (part of the libguestfs project),
  a much larger, production-proven tool that solves the identical "new virtual hardware's driver
  isn't registered, and the disk can't boot to register it" problem. The recipe was transcribed
  directly from `virt-v2v`'s own source, not reconstructed from memory or documentation summaries.
- **Windows 11's install path** uses Microsoft's own `_noprompt` boot files
  (`efisys_noprompt.bin`/`cdboot_noprompt.efi`, genuine Microsoft tooling present on the cached
  install media, not a community hack) to eliminate the "press any key" prompt by construction,
  combined with a hand-built QEMU invocation that sets UEFI boot order directly — something
  Packer's own QEMU builder doesn't expose a way to do.
- **VM screen inspection during development** uses QEMU's own QMP `screendump` command rather than
  a VNC viewer plus a manual screenshot — see `tools/qmp-screenshot.py`.

The full engineering trail — every finding, every dead end, every root cause — lives in
`PHASE2_ENGINEERING_LOG.md`, `PHASE3_ENGINEERING_LOG.md`,
`WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md`, `WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`, and — for
Server 2019 specifically, added after the original three OSes were already production-ready —
`WINDOWS_SERVER_2019_RESEARCH_PLAN.md` (research/feasibility), `WINDOWS_SERVER_2019_IMPLEMENTATION_
PLAN.md` (design), and `PHASE3_ENGINEERING_LOG.md`'s own later sessions (bring-up, including two
real, non-obvious bugs found and fixed: a `Get-NetIPAddress | Where-Object` pipe that hangs
indefinitely when run via `FirstLogonCommands` on Server 2019 specifically, and a second, subtler
one where any two WSMan-configuration changes run in the same PowerShell process — not any single
change — hang the same way; both fixed structurally, not with a timing workaround). `CLAUDE.md`
is the current, authoritative summary of project status and design decisions; this README doesn't
duplicate it.

## Prerequisites

Full detail, exact package names, and a verification script: `PREREQUISITES.md`. Summary:

- A Linux host with KVM/QEMU/libvirt already working (same baseline the sibling project needs).
- This project's own additions: `wimlib-imagex` (`wimtools`), `sgdisk`/`parted` (`gdisk`),
  `ntfs-3g`, `qemu-nbd` (`qemu-utils`), `libhivex-bin` + `libwin-hivex-perl` (offline registry
  editing), and — for Windows 11's Setup.exe-driven path specifically — `xorriso`, `genisoimage`,
  and the `pywinrm` Python package (`pip3 install pywinrm`).
- The `nbd` kernel module loaded with `max_part=8` (`sudo modprobe nbd max_part=8`).
- [`BCD-SYS`](https://github.com/jpz4085/BCD-SYS) cloned into `tools/vendor/BCD-SYS` (not
  packaged; a plain `git clone`).
- A scoped sudoers rule set (`tools/sudoers-windows-auto-build-pipeline`) granting passwordless
  root for exactly the disk-prep commands this pipeline runs against `/dev/nbd*` devices —
  `qemu-nbd`, `sgdisk`, `mkfs.vfat`/`mkntfs`, `mount`/`umount`, `ntfsinfo`/`ntfsfix`. Review the
  file's own header before installing it (`visudo -cf ... && sudo install -m 0440 ...`); it does
  not grant a shell, package management, or arbitrary command execution.
- Cached Windows and VirtIO install media in `../iso_cache/` (one level above this repo, shared
  with the sibling project) — see the next section.

## Setting up the media cache

Builds read Windows ISOs and the VirtIO driver ISO from `../iso_cache/` (path configurable via the
`ISO_CACHE_DIR` environment variable); nothing downloads automatically during a build. Populate it
with the Windows Server 2019, Windows Server 2022, Windows Server 2025, and Windows 11 Enterprise
Evaluation ISOs, plus the latest stable `virtio-win.iso`. `ISO_CACHE_INVENTORY.md` records exactly
what's cached on this project's own development host today, including verified re-download links
and checksums — use it as a reference for what "populated" looks like, not as a guarantee those
exact links or builds are still current (see "Risks and limitations" below).

**Server 2019's ISO is the one exception to "just re-download it"**: unlike the other three
sources, its Evaluation download is gated behind a Microsoft registration form (name/email/company)
rather than a direct, scriptable fwlink — confirmed by tracing the actual redirect target. Acquiring
it (or re-acquiring it, if the cached copy is ever lost) requires a human to complete that form in a
browser first; see `WINDOWS_SERVER_2019_RESEARCH_PLAN.md`'s Finding 3 for the full detail and the
`ISO_CACHE_INVENTORY.md` row for exactly what's cached today.

## Running a build

```
./build.sh <server2019|server2022|server2025|windows11> [services_yaml_path] [computer_name]
```

- `server2019` / `server2022` / `server2025` run the full offline-apply pipeline (partition → apply
  image → make bootable → specialize → hand off to Packer for first boot + role provisioning), then
  automatically run `image-apply/inject-virtio-spice.sh` against Packer's own final,
  role-provisioned disk — so a real build's disk always ends up on virtio-scsi + QXL/SPICE, not just
  on request (NIC stays on the existing, already-proven offline-hivex VirtIO NIC mechanism,
  untouched). `services_yaml_path` (optional, defaults to `services.yaml`) selects which roles get
  provisioned — see "Roles" below.
- `windows11` runs the Setup.exe-driven install, then the same `inject-virtio-spice.sh` step (storage
  *and* NIC swapped to VirtIO this time, plus SPICE) — no Packer handoff, no roles.
- `computer_name` (optional) overrides the default computer name baked into the unattend/answer
  file for that OS.

Example, a Windows Server 2025 IIS+SQL Server app-server build:

```
./build.sh server2025 dev/services-app-server.yaml
```

Rough timings from real logged production runs on this project's own development host (expect
these to vary with host hardware, not to be portable guarantees, and note these specific numbers
predate the automatic driver-injection step above being added, which adds real time on top): Server
2022 + AD DS, ~7 minutes; Server 2025 + IIS/SQL Server, ~51 minutes; Windows 11 (install + driver
injection), on a similar order; Server 2019's own two confirming builds (Packer's own boot +
role-provisioning phase specifically, not counting offline-apply or driver injection) - AD DS,
~7 minutes; IIS/SQL Server, ~18 minutes, notably faster than Server 2025's own historical run for
the identical profile, not investigated further (plausibly host-load/caching differences between
sessions rather than a real per-OS difference). A completed build leaves a `.qcow2` disk image
under `image-apply/output/builds/` for Windows 11, or under `packer/output/<os>-<timestamp>/` (a
unique directory per build — see the note below) for Server 2019/2022/2025, with the disk itself
already on virtio-scsi/virtio-net/QXL+SPICE and confirmed reachable over WinRM.

Each real build gets its own unique build ID (`<os>-<timestamp>`), used for both the disk's own
filename and Packer's output directory — so repeated builds of the same OS never collide on a shared
path (an early version of this pipeline had a real bug here: a fixed `packer/output/<os>/` directory
that a second build of the same OS would fail against; fixed 2026-08-23, see `CLAUDE.md`'s Phase 3A
entry for the full account).

## Roles (Server 2019/2022/2025 only)

`services.yaml` (or a path passed as `build.sh`'s second argument) is a flat, commented list of
roles to provision: `iis`, `ad-ds`, `sql-server`. `ad-ds` (domain controller) and `iis`/`sql-server`
(app server) are mutually exclusive profiles — `dev/services-domain-controller.yaml` and
`dev/services-app-server.yaml` are ready-made examples of each. Windows 11 gets none of these
roles; it isn't in scope for AD/IIS/SQL Server monitoring integration testing the way the Server
SKUs are. All three Server SKUs share the identical, unmodified role-provisioning scripts — Server
2019 needed zero script changes to support any of the three roles.

## Installing tools (7-Zip, PuTTY, WinSCP, Chrome, Notepad++, Datadog Agent)

Every real build now finishes with a Phase 4 tool-install stage, wired into `build.sh`
automatically for all four OSes — nothing extra to run for a normal build.

`tools.yaml` (repo root) is a flat, commented list, same convention as `services.yaml`:

```yaml
tools:
  - 7zip
  - putty
  - winscp
  - chrome
  - notepadplusplus
  - datadog-agent   # requires DD_API_KEY - see below

datadog:
  agent_version: "7.83.0"
  site: datadoghq.com
  tags:
    - "env:lab"
    - "project:windows-auto-build-pipeline"
```

Five of the six tools (everything except the Datadog Agent) always install whichever version is
currently latest from each vendor — `image-apply/install-tools.sh` resolves and downloads it
fresh, from this Linux host (never from inside the guest), on every build; these churn too fast to
usefully pin the way the OS ISOs are pinned. The Datadog Agent is the one deliberate exception: it
installs exactly the version named in `tools.yaml`'s `datadog.agent_version`, since Agent version
can matter for monitoring-integration test comparability across builds.

**The Datadog Agent needs a real API key.** Set `DD_API_KEY` in the environment before running
`build.sh` (or `image-apply/install-tools.sh` directly) whenever `datadog-agent` is listed in
`tools.yaml` — the build fails loud, before ever starting a VM, if it's listed with no key set.
Comment that line out in `tools.yaml` to build without it, no other change needed.

```
DD_API_KEY=<your key> ./build.sh server2022
```

**Running the tool installer against an already-built disk, without a full rebuild:**

```
image-apply/install-tools.sh <server2019|server2022|server2025|windows11> <qcow2-path> [tools_yaml_path] [Install|Uninstall|Status]
```

- `Install` (default) — installs anything listed in `tools.yaml` that isn't already present;
  re-running it is a no-op for anything already installed. The Datadog Agent is the one exception:
  if it's present at a different version than `tools.yaml`'s pinned `agent_version`, it's
  reinstalled to converge on that version.
- `Uninstall` — removes anything listed in `tools.yaml` that's currently present; a no-op for
  anything already absent.
- `Status` — reports PRESENT/ABSENT and installed version for all six tools, regardless of what's
  currently listed in `tools.yaml`.

Full design/research trail and real Phase E test results (a complete Create/Read/Update/Delete
cycle confirmed against a real Server 2022 build, for every tool including the Datadog Agent's own
version-convergence path): `PHASE4_TOOLS_INSTALLER_PLAN.md`.

## Inspecting a running build

Every ad hoc QEMU invocation this project drives directly (not Packer-managed builds) exposes a
QMP control socket, so a VM's screen can be inspected without popping a VNC viewer:

```
python3 tools/qmp-screenshot.py --socket /tmp/<name>.sock --out /tmp/shot.png
```

`tools/qmp-watch.sh` loops that at an interval for watching a boot sequence unfold frame by frame;
`tools/qmp-sendkey.py`, `tools/qmp-click.py`, and `tools/qmp-type.py` send keystrokes, clicks, and
typed text into a running VM (mouse clicks need a USB tablet device on the guest — already wired
into this project's own production QEMU invocations). Every build (all four OSes) now comes up with
a SPICE display (QXL + guest tools), reachable with any SPICE client, for genuine interactive use —
not just headless automation.

## Registering a build with libvirt

A finished build's disk is just a loose `.qcow2` file until it's registered as a libvirt domain —
`register-vm.sh` does that, so it shows up in `virsh list --all` / virt-manager instead:

```
./register-vm.sh <server2019|server2022|server2025|windows11> [qcow2_path] [vm_name]
```

`qcow2_path` defaults to the most recently built disk for that OS; `vm_name` defaults to the disk's
own baked-in computer name, lowercased. The registered domain's device model (virtio-scsi disk,
virtio-net NIC, QXL + a real loopback-only SPICE channel, USB tablet) matches what
`inject-virtio-spice.sh` already proved boots. Re-running it after a fresh build for the same OS is
the normal case — it cleanly re-registers over a shut-off domain of the same name. Start it and
connect with:

```
virsh -c qemu:///system start <vm_name>
virt-viewer --connect qemu:///system <vm_name>
```

This script's device model is confirmed by a real `virsh start` boot, live-verified over WinRM, for
**all four target OSes**: Server 2022 and Server 2025 (2026-08-26), Windows 11 including its own
NIC-swap code path (2026-09-01), and Server 2019 (2026-09-02, both role profiles). No open item
remains here.

`register-vm.sh` also refuses to register a disk that hasn't actually been through
`inject-virtio-spice.sh` yet (checked via an on-disk completion marker) rather than silently applying
the wrong device model to it.

## Risks and limitations

Read this before relying on this pipeline for anything beyond disposable lab use:

- **Only ever tested on a single development host.** Every build described above, and every claim
  of "confirmed working," was validated on one specific Linux machine. Nothing here has been
  exercised on a second host, a different Linux distribution, a different QEMU/libvirt version, or
  different host hardware. Porting this to another machine should be treated as untested until
  proven otherwise, not assumed to work because it worked once here.
- **Configuration and version drift.** This pipeline hardcodes several values that are only valid
  for the exact ISO/driver/QEMU versions they were verified against: WIM image indices (which
  edition inside the Windows install image to apply), virtio PCI hardware IDs (`CLAUDE.md`'s
  Engineering Standards document a real, observed case of the *same* virtio controller negotiating
  a *different* PCI ID depending on QEMU configuration), and Windows 11's Setup.exe
  OOBE-bypass/`LabConfig` behavior (which Microsoft has changed out from under similar tooling
  before, in a documented 24H2 regression). None of these are re-verified automatically when the
  underlying ISO or QEMU version changes — a refreshed Windows ISO, a `virtio-win` update, or a
  host QEMU upgrade can silently produce a disk that used to build cleanly and no longer does, with
  no error until it fails. `ISO_CACHE_INVENTORY.md` already documents one live instance of this:
  the Windows 11 download link has moved on to a newer servicing build than what's cached.
- **Windows 11's build path is structurally more fragile than Server 2022/2025's.** It drives
  Setup.exe directly and depends on specific OOBE-bypass behavior continuing to work; Server
  2022/2025's fully offline path never invokes Setup.exe at all and is immune to that entire class
  of risk.
  
- **No automated environment lifecycle yet.** There's no "destroy" or cleanup workflow — VMs and
  their disk images are left in place until removed by hand. Build artifacts are large (Windows and
  VirtIO ISOs alone are roughly 25 GiB cached across all four OSes, per `ISO_CACHE_INVENTORY.md`,
  and each build's own disk image is tens of GB), so disk space needs active management on whatever
  host this runs on.
- **Tool installer (`tools.yaml`) is implemented and tested on Server 2022 only.** Server
  2019/2025 and Windows 11 share the identical code path with no OS branching, so this is a
  lower-risk gap than most others here, but it's still an honest one — not yet confirmed. A real
  (non-dummy) Datadog API key was also never used in testing, so Agent connectivity/telemetry
  itself is unconfirmed, only the installer mechanism. Known, honestly-stated limitation of the
  mechanism itself: MSI-based silent installs can transiently expose the Datadog API key in the
  process list — a narrow but real exposure window inherent to that install mechanism, not
  something this project's own design choice can fully eliminate. Five of the six tools also have
  no version pinning by design (see "Installing tools" above) — a build's exact tool versions
  aren't reproducible after the fact the way a pinned OS ISO is.
- **Lab-only security posture.** Passwords baked into unattend/answer files are intentionally
  disposable placeholders, not real credentials, and are not treated as secrets. There's no secrets
  vault integration, no hardening pass, and no assumption this is safe to expose beyond an isolated
  lab network.
- **SPICE/QXL driver delivery depends on an unversioned upstream installer.** Windows 11 and Server
  2022/2025's SPICE guest tools come from `spice-space.org`'s "latest" installer, which has no
  pinned release and isn't yet covered by this project's normal ETag-based freshness checking — a
  future download could silently be a different build than what was tested against.
- **This is a hand-run research tool, not a maintained product.** Scripts assume the specific
  layout and conventions documented in `CLAUDE.md` and are not defensively hardened against
  malformed input, unexpected host state, or concurrent invocation (concurrent QEMU build/boot
  cycles on the same host are explicitly avoided by convention, not prevented by tooling).

## Next steps and ongoing work

- **Server 2019 is production-ready** (2026-09-02) — the fourth target OS, added after the original
  three via a formal, gated process (research → design → design review → implementation → E2E
  testing, all five phases documented in `WINDOWS_SERVER_2019_RESEARCH_PLAN.md`,
  `WINDOWS_SERVER_2019_IMPLEMENTATION_PLAN.md`, and `PHASE3_ENGINEERING_LOG.md`). Both required
  builds (`ad-ds` and `iis`/`sql-server`) are independently confirmed end-to-end through the real
  production pipeline, at the same evidentiary bar as every other OS. `dev/
  run-server2019-specialize-test.sh` (new fast-iteration harness, distinct from
  `dev/role-test.pkr.hcl` — it iterates on the specialize/`FirstLogonCommands` step itself, not
  role scripts) was purpose-built to chase down two real, Server-2019-specific bugs found and fixed
  along the way; see `PHASE3_ENGINEERING_LOG.md`'s Phase E sessions for the full bisection trail.
- **Phase 4 (Tooling) is implemented and tested** (2026-09-03) — see "Installing tools" above for
  usage. `tools.yaml`-driven, wired into `build.sh` for all four OSes; five of the six tools fetch
  fresh from each vendor host-side on every build rather than being pinned (they churn too fast to
  usefully pin the way OS ISOs are), with the Datadog Agent as the one deliberate pinned exception.
  Full CRUD (Create/Read/Update/Delete) and idempotency confirmed against a real Server 2022 build
  for all six tools — see `PHASE4_TOOLS_INSTALLER_PLAN.md`. Not yet exercised on Server 2019/2025
  or Windows 11 (same code path, no OS branching, but genuinely untested there); real Datadog
  Agent connectivity was never confirmed (dummy API key used for testing).
- **Phase 5 (lifecycle automation)**: build/verify/destroy workflow. Not started.
- **Open engineering question**: whether Server 2019/2022/2025's existing offline-hivex NIC driver
  mechanism should ever be ported onto the newer live-swap technique used for Windows 11's VirtIO
  NIC — currently left as-is (offline-hivex) since it's already proven and the swap would be a
  breaking change to a working mechanism; flagged in `WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`, not
  scheduled.
- A preflight script that checks cached-media WIM edition metadata and virtio driver hardware IDs
  against what's hardcoded in `image-apply/lib/common.sh`/`tools/gen-viostor-ddb-reg.py`, and fails
  loudly before a build runs against drifted media, is identified as worthwhile but not yet built
  (`CLAUDE.md`'s "Version-sensitivity and brittleness" standard).
- `register-vm.sh`'s device model (virtio-scsi + QXL/SPICE) is now confirmed by a real `virsh start`
  boot, live-verified over WinRM (not just a screenshot), for **all four target OSes** — Server 2022
  and Server 2025 (2026-08-26), Windows 11 including its own NIC-swap code path (2026-09-01), and
  Server 2019 (2026-09-02). No open item remains here.
- `register-vm.sh` now enforces its own precondition instead of assuming it: it refuses to register a
  disk that hasn't actually been through `inject-virtio-spice.sh` (checked via an on-disk completion
  marker), closing a real device-topology-mismatch bug that cost real debugging time before it was
  caught.
- ~~`dev/role-test.pkr.hcl` (the fast-iteration harness, separate from the production `build.sh`
  path) has the same fixed-per-OS Packer output-directory pattern that caused the collision bug fixed
  above in the production path~~ — **fixed 2026-08-26**, same `run_id`-threading approach as
  `build.sh`'s own fix. Not yet exercised by a real end-to-end Packer build, since this harness's own
  Phase 2 reference disks no longer exist on disk (a separate, pre-existing gap) - still true as of
  Server 2019's own addition, which deliberately used a new, purpose-built harness instead
  (`dev/run-server2019-specialize-test.sh`) rather than extending this one.

## Acknowledgements

This project's own engineering is almost entirely the work of adapting existing, credible prior art
to this specific pipeline shape, not inventing new low-level mechanisms. Real credit belongs to:

- **[BCD-SYS](https://github.com/jpz4085/BCD-SYS)** (jpz4085) — constructing a Windows BCD store
  and boot files directly from Linux with no boot required.
- **[libguestfs](https://libguestfs.org/) / `virt-v2v`** — the offline VirtIO driver registration
  pattern (`DriverDatabase` registry injection) this project's own driver-injection tooling is
  transcribed from.
- **Microsoft** — the documented `DISM /Apply-Image` + `bcdboot` offline-install recipe,
  `\Windows\Panther\unattend.xml` specialize-pass mechanics, and the `_noprompt` boot files used to
  drive Windows 11's Setup.exe unattended.
- **Red Hat / the `virtio-win` project** — the VirtIO storage, network, and QXL/SPICE display
  drivers this pipeline injects.
- **[spice-space.org](https://www.spice-space.org/)** — the SPICE guest tools installer providing
  usable interactive desktop access to built VMs.
- **QEMU / OVMF (TianoCore)** — the virtualization and UEFI firmware this entire pipeline runs on,
  including the QMP protocol this project's own inspection tooling is a thin wrapper around.
- **`../windows-server-vm-automation/`**, this project's sibling — the role-provisioning layer
  (IIS, AD DS, SQL Server scripts) reused here unchanged, and the original research that identified
  the interactive-installer boot failure this project exists to work around.
