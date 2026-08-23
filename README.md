# Windows Auto-Build Pipeline

Fully reproducible Windows Server 2022/2025 and Windows 11 lab VMs, built without
relying on Packer's interactive-installer boot path — which reliably fails for
Server 2025 and Windows 11 media due to an unresolved upstream Packer/QEMU/OVMF
issue. Two different mechanisms per OS, not one: Server 2022/2025 use offline
image application (`DISM /Apply-Image`-equivalent via `wimlib`, no boot involved
until the disk is already bootable); Windows 11 uses a Setup.exe-driven install
with a patched, prompt-free ISO instead, after the offline-apply mechanism hit an
unresolved BSOD specific to Windows 11 (see `CLAUDE.md` and
`PHASE3_ENGINEERING_LOG.md`'s Phase 3.4 entries). Server 2022/2025 additionally
get AD DS/IIS/SQL Server role provisioning for Datadog Agent integration testing
— Windows 11 doesn't (those roles are Server-20XX-specific by design, not yet
implemented for Windows 11). See `HANDOFF_FROM_UNATTENDED_INSTALL.md` for the
full background on why this project exists as a separate repo from its sibling,
`../windows-server-vm-automation/`.

## Status (as of Phase 3.5)

**Phase 1 (architecture): done.**

**Phase 2 (offline installation mechanism): done for all three target OSes**
(Windows Server 2025, Windows Server 2022, Windows 11 Enterprise Evaluation).
Offline image application → bootable → specialized → real, unattended WinRM
connectivity, confirmed end-to-end for each OS. See `PHASE2_ENGINEERING_LOG.md`'s
final "STATUS AND NEXT STEPS ON RESUMPTION" section for the complete trail
(BCD-SYS/WinPE bootability, offline virtio driver injection via a corrected
`DriverDatabase` registry path derived from `virt-v2v`'s own source, and the
offline specialize/unattend pass).

**Phase 3 (Windows role configuration): done, including the production pipeline.**
The same three roles (IIS, AD DS, SQL Server), reused unchanged from the sibling
project, are confirmed live against both Windows Server 2025 and Windows Server
2022 through the real production path (`image-apply/*.sh` + `packer/
boot-and-provision.pkr.hcl` + `build.sh`). Windows 11 has no Phase 3 roles by
design (AD DS/IIS/SQL Server are Server-20XX-specific) — see `CLAUDE.md`'s
"Windows Configuration Goals."

**Windows 11's own build path (Phase 3.4/3.5): done, and production-ready.**
Windows 11 doesn't use the offline-apply mechanism above at all — after that
architecture hit a hard, unresolved kernel-level BSOD on Windows 11's real first
boot (see `PHASE3_ENGINEERING_LOG.md`'s "HARD STOP" section), it was replaced
with a Setup.exe-driven install (`image-apply/windows11-setup-install.sh`) using
a `_noprompt`-patched install ISO and OVMF's own NVRAM boot order for
disk-vs-CD-ROM selection — no `boot_command`/VNC keystroke racing, no timing-
sensitive eject step. Confirmed via six independent clean builds total (four
during Phase 3.4's own mechanism validation, two full Phase 3.5 production-
readiness runs) with real, authenticated WinRM confirmed each time. See
`PHASE3_ENGINEERING_LOG.md`'s Phase 3.4/3.5 entries and
`WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md` for the complete design and
evidentiary trail.

**Phases 4-5** (Datadog Agent integration, lifecycle automation) are not started,
same as the sibling project's own Phase 4/5 status.

## Resuming work

Read, in order:

1. `CLAUDE.md` — project goals, architectural principles, tool responsibilities,
   phased plan, and current per-phase status (checked into the repo as project
   instructions — read this first, it's the authoritative current state).
2. `PHASE3_ENGINEERING_LOG.md` — the active engineering log. Its final entries
   cover Phase 3.4 (Windows 11's Setup.exe-driven build path, and the
   NVRAM-boot-order design pivot) and Phase 3.5 (production-readiness
   validation).
3. `WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md` — the research plan and phased
   design behind Windows 11's current build path, for the full evidentiary
   trail from the original BSOD hard stop through to a working mechanism.
4. `PHASE2_ENGINEERING_LOG.md` — Phase 2's own engineering log (offline image
   application, bootability, driver injection) for Server 2022/2025 and
   Windows 11's now-superseded offline-apply mechanism.
5. `HANDOFF_FROM_UNATTENDED_INSTALL.md` — original prior-art research and why
   this project exists; still accurate.
6. `PREREQUISITES.md` — host tooling this project needs beyond the sibling
   project. Only relevant again if working from a different machine.

`START_PROMPT.md` is a ready-to-use resumption prompt covering the same ground,
written for handing to a fresh Claude Code session — but check it against
`CLAUDE.md`'s own status before trusting it, since it can go stale between
sessions faster than the files above.

## Repository layout

- `image-apply/` — the real build scripts. For Server 2022/2025: the offline
  WIM-application pipeline (`partition-disk.sh`, `apply-image.sh`,
  `make-bootable.sh`, `apply-unattend.sh`). For Windows 11:
  `build-iso-noprompt.sh` and `windows11-setup-install.sh` (Setup.exe-driven,
  a completely different mechanism — see `CLAUDE.md`). Build artifacts under
  `image-apply/output/` are gitignored — regenerated on every real run, never
  source. `image-apply/historical/` holds retired scripts
  (`audit-mode-sysprep.sh`, `calibrate-eject-timing.sh`) kept as documented
  record of closed architectural branches, not live tooling.
- `tools/` — host-side Linux dev/debug tooling: QMP-based screenshot/keystroke/
  eject/pixel-sample helpers for inspecting and driving VMs without a VNC viewer
  (`qmp-screenshot.py`, `qmp-watch.sh`, `qmp-sendkey.py`, `qmp-type.py`,
  `qmp-click.py`, `qmp-eject.py`, `qmp-pixel.py`), `gen-viostor-ddb-reg.py`
  (generates the source-verified `.reg` file that offline-registers the
  virtio-blk boot driver, clearing `INACCESSIBLE_BOOT_DEVICE` — see
  `PHASE2_ENGINEERING_LOG.md` Finding 29), plus a scoped sudoers file for the
  disk-prep commands this pipeline needs
  (`tools/sudoers-windows-auto-build-pipeline`; not installed automatically —
  see the file's own header for the `visudo`-checked install step).
  `tools/vendor/` (BCD-SYS, cloned per `PREREQUISITES.md`) is gitignored, not
  vendored into this repo's history.
- `scripts/` — reused unchanged from the sibling project's role-provisioning
  layer (`run-services.ps1`, `install-iis.ps1`, `install-ad.ps1`,
  `install-sql-server.ps1`, `verify-post-reboot.ps1`); Server 2022/2025 only —
  Windows 11 has no Phase 3 roles.

Shared Windows/virtio-win install media lives in `../iso_cache/`, one level above
this repo and the sibling project, not inside this repo's git tree.

## Host prerequisites

See `PREREQUISITES.md`. Beyond the sibling project's baseline (KVM/QEMU/libvirt),
this project additionally needs `wimlib-imagex`, `sgdisk`/`parted`, `ntfs-3g`
(`mkfs.ntfs`), `qemu-nbd`, and — for Windows 11's Setup.exe-driven build path
specifically — `xorriso`, `mkisofs`/`genisoimage`, and the `pywinrm` Python
package (`pip3 install pywinrm`).
