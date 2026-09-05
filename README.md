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
customer setups those integrations actually run against in the wild. That requires real,
disposable Windows Server and Windows 11 VMs that can be
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
  its own design/research trail lives in `project_documentation/WINDOWS_SERVER_2019_RESEARCH_PLAN.md` and
  `project_documentation/WINDOWS_SERVER_2019_IMPLEMENTATION_PLAN.md`.
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
`project_documentation/PHASE2_ENGINEERING_LOG.md`, `project_documentation/PHASE3_ENGINEERING_LOG.md`,
`project_documentation/WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md`, `project_documentation/WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`, and — for
Server 2019 specifically, added after the original three OSes were already production-ready —
`project_documentation/WINDOWS_SERVER_2019_RESEARCH_PLAN.md` (research/feasibility),
`project_documentation/WINDOWS_SERVER_2019_IMPLEMENTATION_PLAN.md` (design), and
`project_documentation/PHASE3_ENGINEERING_LOG.md`'s own later sessions (bring-up, including two
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
browser first; see `project_documentation/WINDOWS_SERVER_2019_RESEARCH_PLAN.md`'s Finding 3 for the full detail and the
`ISO_CACHE_INVENTORY.md` row for exactly what's cached today.

## Using windows-pipeline

Every part of this project's lifecycle — apply an image, boot it, register it with libvirt,
start/stop it, check its health, tear it down — is driven through one CLI, `windows-pipeline`. It's
an orchestration layer only: every real operation (partitioning, `wimlib` apply, `bcdboot`, Packer,
driver injection, tool install) still runs exactly the same `image-apply/*.sh` scripts and
`packer/boot-and-provision.pkr.hcl` this project has always used — `windows-pipeline` just tracks
state across them and gives them one consistent interface. Full design rationale and the real bugs
found building it: `project_documentation/PHASE5_ENGINEERING_LOG.md`.

### Installing it

```
python3 -m venv .venv
.venv/bin/pip install -e .
source .venv/bin/activate   # or just call .venv/bin/windows-pipeline directly, unactivated
```

This installs `windows-pipeline` as an editable package into a local virtualenv — editable because
the CLI orchestrates `image-apply/*.sh`/`packer/*.hcl` in this specific checkout and can't be
relocated the way a fully standalone tool could be; there's no `install.sh` that copies it anywhere
else, since that would misrepresent how it actually works. `pywinrm` is pulled in automatically (a
real, declared dependency — see the Phase 5 log for why this specifically had to be a declared
dependency and not an assumption about what's on the system `python3`).

For tab completion of every `host_id` argument (pulled live from `windows-pipeline`'s own state
store, not just static flag names):

```
.venv/bin/pip install -e ".[completion]"
eval "$(register-python-argcomplete windows-pipeline)"   # add to your shell's rc file
```

Completion is a true optional extra — the CLI works identically without it.

### Building an image

```
windows-pipeline create <server2019|server2022|server2025|windows11> [--services PATH] [--tools PATH] [--computer-name NAME]
```

- `server2019` / `server2022` / `server2025` run the full offline-apply pipeline (partition → apply
  image → make bootable → specialize → hand off to Packer for first boot + role provisioning), then
  automatically run `image-apply/inject-virtio-spice.sh` against Packer's own final,
  role-provisioned disk — so a real build's disk always ends up on virtio-scsi + QXL/SPICE, not just
  on request (NIC stays on the existing, already-proven offline-hivex VirtIO NIC mechanism,
  untouched). `--services` (optional, defaults to `services.yaml`) selects which roles get
  provisioned — see "Roles" below.
- `windows11` runs the Setup.exe-driven install, then the same `inject-virtio-spice.sh` step (storage
  *and* NIC swapped to VirtIO this time, plus SPICE) — no Packer handoff, no roles.
- `--computer-name` (optional) overrides the default computer name baked into the unattend/answer
  file for that OS. This is the guest's own NetBIOS name only — it has nothing to do with the host
  ID discussed next.
- `--tools` (optional, defaults to `$TOOLS_YAML_PATH` or `./tools.yaml`) — see "Installing tools"
  below.

`create` prints a **host ID** on success (e.g. `win2022prod-20260904-1314-a1b2c3d4`) — a unique
identifier for this specific build, generated fresh every run (`<netbios-lowercase>-<timestamp>-
<uuid8>`), decoupled from the guest's own fixed-per-OS computer name. Every other `windows-pipeline`
command takes this ID as its argument. `windows-pipeline list` shows every ID `windows-pipeline`
currently knows about, along with its OS, guest computer name, and lifecycle state (`built` →
`registered` → `running`/`stopped` → gone once destroyed):

```
windows-pipeline list
```

Example, a Windows Server 2025 IIS+SQL Server app-server build:

```
windows-pipeline create server2025 --services dev/services-app-server.yaml
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
under `image-apply/output/builds/` for Windows 11, or under `packer/output/<host-id>/` (a unique
directory per build, named for the host ID `create` printed) for Server 2019/2022/2025, with the
disk itself already on virtio-scsi/virtio-net/QXL+SPICE and confirmed reachable over WinRM.

Repeated builds of the same OS never collide on a shared path — every real build's own host ID is
unique by construction (an early version of this pipeline had a real bug here: a fixed
`packer/output/<os>/` directory that a second build of the same OS would fail against; fixed
2026-08-23, see `CLAUDE.md`'s Phase 3A entry for the full account; the host-ID scheme described
above generalizes that same fix and gives it a stable, human-readable identity usable everywhere
downstream, see `project_documentation/PHASE5_ENGINEERING_LOG.md`).

## Roles (Server 2019/2022/2025 only)

`services.yaml` (or a path passed via `create`'s `--services` flag) is a flat, commented list of
roles to provision: `iis`, `ad-ds`, `sql-server`. `ad-ds` (domain controller) and `iis`/`sql-server`
(app server) are mutually exclusive profiles — `dev/services-domain-controller.yaml` and
`dev/services-app-server.yaml` are ready-made examples of each. Windows 11 gets none of these
roles; it isn't in scope for AD/IIS/SQL Server monitoring integration testing the way the Server
SKUs are. All three Server SKUs share the identical, unmodified role-provisioning scripts — Server
2019 needed zero script changes to support any of the three roles.

## Installing tools (7-Zip, PuTTY, WinSCP, Chrome, Notepad++, Datadog Agent)

Every real build now finishes with a Phase 4 tool-install stage, wired into `windows-pipeline create`
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
`windows-pipeline create` (or `image-apply/install-tools.sh` directly) whenever `datadog-agent` is
listed in `tools.yaml` — the build fails loud, before ever starting a VM, if it's listed with no key
set. Comment that line out in `tools.yaml` to build without it, no other change needed.

```
DD_API_KEY=<your key> windows-pipeline create server2022
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
version-convergence path): `project_documentation/PHASE4_TOOLS_INSTALLER_PLAN.md`.

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

A finished build's disk is just a loose `.qcow2` file until it's registered as a libvirt domain:

```
windows-pipeline register-vm <host_id> [--cpus N] [--memory-mb N] [--network NAME] [--efi-firmware-code PATH]
```

`<host_id>` is the ID `windows-pipeline create` printed (also `windows-pipeline list`) — it becomes
the libvirt domain name directly, e.g. `virsh list --all` shows `win2022prod-20260904-1314-a1b2c3d4`,
not the guest's own `WIN2022PROD` computer name. Defaults match `register-vm.sh`'s own former
production values (4 CPUs, 16384 MiB memory, the `default` libvirt network,
`/usr/share/OVMF/OVMF_CODE_4M.fd`). The registered domain's device model (virtio-scsi disk,
virtio-net NIC, QXL + a real loopback-only SPICE channel, USB tablet) matches what
`inject-virtio-spice.sh` already proved boots, confirmed by a real `virsh start` boot, live-verified
over WinRM, for **all four target OSes**: Server 2022 and Server 2025 (2026-08-26), Windows 11
including its own NIC-swap code path (2026-09-01), and Server 2019 (2026-09-02, both role profiles).

`register-vm` refuses to register a disk that hasn't actually been through
`inject-virtio-spice.sh` (checked via a real on-disk completion marker, read offline — not just
trusting `windows-pipeline`'s own state record) rather than silently applying the wrong device model
to it. Re-registering after a fresh build reusing the same disk's name is handled the same way it
always was — it cleanly re-registers over a shut-off domain, refusing if the existing one is still
running.

Start and stop it through `windows-pipeline` too (thin `virsh` wrappers that also keep its tracked
state in sync):

```
windows-pipeline start <host_id>
windows-pipeline stop <host_id> [--force] [--timeout SECONDS]
```

`stop` is graceful by default (`virsh shutdown`, polled until the domain actually reports `shut off`,
up to `--timeout` seconds, default 120) — never a hard kill unless `--force` is given, matching this
project's own standing convention that a hard kill on a disk you intend to reuse fakes corruption
symptoms. Connect to a running VM's console directly with:

```
virt-viewer --connect qemu:///system <host_id>
```

## Verifying a VM's health

```
windows-pipeline verify <host_id> [--checks connectivity,roles,virtio,tools] [--format text|json]
```

Runs against an already-**running**, registered VM (`windows-pipeline start` it first) and reports
one of four check groups, or all of them (the default):

- `connectivity` — WinRM reachable, real OS caption, hostname.
- `roles` — detects whichever of AD DS/IIS/SQL Server is actually present and checks it the way this
  project's own build pipeline always has: NTDS/DNS/ADWS running plus a real `Get-ADDomain` call for
  AD DS; `W3SVC` running plus a real HTTP 200 for IIS; `MSSQLSERVER` running plus a real SA login and
  `SELECT 1` for SQL Server. Not gated on `services.yaml` — `verify` may run long after build time
  against a VM whose provisioning history isn't in front of it, so it checks what's actually there.
- `virtio` — the same disk/NIC/display/SPICE-agent checks `inject-virtio-spice.sh`'s own Stage 2
  already performs, run again independently.
- `tools` — the same registry-based detection `install-tools.ps1`'s own `Status` mode uses, for all
  six possible tools, plus the Datadog Agent's own service-running check. Real limitation, stated
  plainly rather than glossed over: Agent connectivity and host registration are **not** checked —
  that needs a real `DD_API_KEY,` and this project has never had reason to exercise one in testing.

Each check group is a small, self-contained PowerShell snippet sent over WinRM — the same shape
every `image-apply/*.sh` script already uses, not a verification framework. (Goss, Testinfra, and
Chef InSpec were all evaluated for this and rejected — see
`project_documentation/PHASE5_ENGINEERING_LOG.md`'s Research section for why.) Results are also saved
into `windows-pipeline`'s own state record for that host ID (`last_verified_at`/
`last_verify_result`), visible via `windows-pipeline list --format json`.

## Tearing down a VM

```
windows-pipeline destroy <host_id> [--purge-disk] [--force] [--timeout SECONDS]
```

Undefines the libvirt domain (stopping it first if it's running — gracefully unless `--force`),
deletes snapshots and managed-save state if present (both would otherwise make `virsh undefine`
fail outright), and removes `windows-pipeline`'s own tracking record for that host ID entirely — no
tombstone kept.

**The disk is kept by default.** A real build can take 15-50+ minutes to reproduce, so losing one to
an accidental destroy is expensive — pass `--purge-disk` to actually delete it. When given,
`--purge-disk` cleans up *everything* that build ever left behind across this pipeline's output
directories (the qcow2 itself, Packer's own scratch efivars file and output directory, and both
`inject-virtio-spice.sh`'s and `install-tools.sh`'s own per-run work directories) — not just the one
path `windows-pipeline` happened to track, confirmed by a real `find` sweep during development (see
the Phase 5 log for the bug this closed). Without `--force`, `destroy` prints exactly what it's
about to delete and asks for confirmation first.

One known, deliberate gap, documented rather than silently glossed over: `destroy` does not release
the VM's DHCP lease. Neither libvirt nor this host's own `virsh` (10.0.0) offers a way to force one
without hand-editing dnsmasq's own lease file as root — a real capability gap, not an oversight — so
the lease is simply left to expire on its own.

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
  
- **`windows-pipeline destroy` doesn't release DHCP leases**, and disk artifacts still need active
  management even with lifecycle automation in place: build artifacts are large (Windows and VirtIO
  ISOs alone are roughly 25 GiB cached across all four OSes, per `ISO_CACHE_INVENTORY.md`, and each
  build's own disk image is tens of GB), and `destroy` keeps the disk by default (`--purge-disk`
  opts in) precisely because a real build is expensive to reproduce — so a host running many builds
  without ever passing `--purge-disk` will still accumulate disk usage over time.
- **`windows-pipeline verify` checks what this project's own build pipeline already established as
  its success bar, not a general-purpose Windows health audit.** It doesn't check Datadog Agent
  connectivity or host registration (needs a real API key, never exercised here), doesn't check
  anything beyond the four groups it has (no disk-space/event-log/patch-level checks, for instance),
  and its role checks activate based on what's actually running on the guest rather than what
  `services.yaml` originally requested — a role that failed to install silently just won't be
  checked, rather than being reported as a missing role.
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
  testing, all five phases documented in `project_documentation/WINDOWS_SERVER_2019_RESEARCH_PLAN.md`,
  `project_documentation/WINDOWS_SERVER_2019_IMPLEMENTATION_PLAN.md`, and `project_documentation/PHASE3_ENGINEERING_LOG.md`). Both required
  builds (`ad-ds` and `iis`/`sql-server`) are independently confirmed end-to-end through the real
  production pipeline, at the same evidentiary bar as every other OS. `dev/
  run-server2019-specialize-test.sh` (new fast-iteration harness, distinct from
  `dev/role-test.pkr.hcl` — it iterates on the specialize/`FirstLogonCommands` step itself, not
  role scripts) was purpose-built to chase down two real, Server-2019-specific bugs found and fixed
  along the way; see `project_documentation/PHASE3_ENGINEERING_LOG.md`'s Phase E sessions for the full bisection trail.
- **Phase 4 (Tooling) is implemented and tested** (2026-09-03) — see "Installing tools" above for
  usage. `tools.yaml`-driven, wired into `windows-pipeline create` for all four OSes; five of the six
  tools fetch fresh from each vendor host-side on every build rather than being pinned (they churn
  too fast to usefully pin the way OS ISOs are), with the Datadog Agent as the one deliberate pinned
  exception. Full CRUD (Create/Read/Update/Delete) and idempotency confirmed against a real Server
  2022 build for all six tools — see `project_documentation/PHASE4_TOOLS_INSTALLER_PLAN.md`. Not yet
  exercised on Server 2019/2025 or Windows 11 (same code path, no OS branching, but genuinely
  untested there); real Datadog Agent connectivity was never confirmed (dummy API key used for
  testing).
- **Phase 5 (Lifecycle Automation) is done** (2026-09-05) — the `windows-pipeline` CLI (`create`,
  `list`, `register-vm`, `start`, `stop`, `verify`, `destroy`), replacing `build.sh`/`register-vm.sh`
  outright. See "Using windows-pipeline" above for usage and
  `project_documentation/PHASE5_ENGINEERING_LOG.md` for the full design/implementation trail,
  including three real bugs found and fixed along the way (a `pywinrm`/venv dependency-resolution
  failure, an incomplete `--purge-disk` artifact sweep, and two `verify`-side PowerShell/WinRM
  bugs — a `pywinrm` exit-code quirk and a `ConvertTo-Json` enum-serialization gotcha).
- **Open engineering question**: whether Server 2019/2022/2025's existing offline-hivex NIC driver
  mechanism should ever be ported onto the newer live-swap technique used for Windows 11's VirtIO
  NIC — currently left as-is (offline-hivex) since it's already proven and the swap would be a
  breaking change to a working mechanism; flagged in `project_documentation/WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`, not
  scheduled.
- A preflight script that checks cached-media WIM edition metadata and virtio driver hardware IDs
  against what's hardcoded in `image-apply/lib/common.sh`/`tools/gen-viostor-ddb-reg.py`, and fails
  loudly before a build runs against drifted media, is identified as worthwhile but not yet built
  (`CLAUDE.md`'s "Version-sensitivity and brittleness" standard).
- ~~`dev/role-test.pkr.hcl` (the fast-iteration harness, separate from the production build path)
  has the same fixed-per-OS Packer output-directory pattern that caused a collision bug fixed in the
  production path~~ — **fixed 2026-08-26**, same `run_id`-threading approach as the production fix.
  Not yet exercised by a real end-to-end Packer build, since this harness's own Phase 2 reference
  disks no longer exist on disk (a separate, pre-existing gap) - still true as of Server 2019's own
  addition, which deliberately used a new, purpose-built harness instead
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
