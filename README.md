# Windows Auto-Build Pipeline

Offline-image-application pipeline for building fully reproducible Windows Server
2022/2025 and Windows 11 lab VMs (Datadog Agent integration testing against
AD/IIS/SQL Server), without relying on Packer's interactive-installer boot path —
which reliably fails for Server 2025 and Windows 11 media due to an unresolved
upstream Packer/QEMU/OVMF issue. See `HANDOFF_FROM_UNATTENDED_INSTALL.md` for the
full background on why this project exists as a separate repo from its sibling,
`../windows-server-vm-automation/`.

## Status (as of Session 5, 2026-08-14)

**Phase 1 (architecture): done.**

**Phase 2 (offline installation mechanism): in progress; the Setup.exe pivot's
driver-load blocker has now survived four independent fix attempts.**

- **Solved:** making an offline-applied disk boot at all under UEFI/OVMF, via two
  independent methods (BCD-SYS from Linux with zero boots, and real `bcdboot` from
  a self-built WinPE session) — including `boot.wim` index 2 ("Microsoft Windows
  Setup") booting clean as a plain disk with no exposure to the "press any key"
  UEFI landmine that blocks the sibling project.
- **Solved, empirically:** the driver/hardware chain for clearing
  `INACCESSIBLE_BOOT_DEVICE (0x7B)`. The real viostor driver correctly matches the
  virtio-blk-pci hardware ID and brings up a real 40GB target disk cleanly, both
  loaded manually and pre-loaded automatically before Setup starts.
- **Not solved — a real blocker, not an automation gap:** `autounattend.xml`'s
  `DriverPaths` doesn't feed `EarlyF6DriverInstall`'s "Install driver to show
  hardware" gate, and `setupact.log` timestamps prove that gate is unconditional —
  it starts waiting before any driver state is even checked. Manually clicking
  through it (mouse-driven UI automation, confirmed working) doesn't lead anywhere
  either. **Session 5 also ruled out `$WinPEDriver$`** (Microsoft KB 2686316's
  documented driver-autoload folder): verified the driver files were placed
  correctly at the documented location (`X:\$WinPEDriver$\...` — and confirmed `X:`
  in this boot flow is the physical boot-medium partition itself, not a separate
  RAM-disk copy, a previously-wrong assumption this project had held implicitly),
  yet the same empty dialog appeared and `setupact.log` shows zero evidence Setup
  ever scanned for it. Four independent approaches have now failed:
  `DriverPaths`, pre-loaded `drvload`, manual UI click-through, and `$WinPEDriver$`.
- **One remaining untried track:** whether avoiding full unattend-driven disk
  configuration lets Setup reach a different, modern driver-load screen instead of
  the legacy one (Finding 26's "modern screen" theory) — a bigger `Autounattend.xml`
  change than anything tried so far, and still just a theory. If that also fails,
  the recommended fallback is reconsidering the Setup.exe pivot itself in favor of
  the already-solved plain-WinPE + `bcdboot` path (sub-milestone 1), with driver
  injection solved there instead via the offline `hivex` technique. See
  `PHASE2_ENGINEERING_LOG.md`'s Session 5 section for full detail.

**Phases 3-5** (Windows role configuration, Datadog integration, lifecycle
automation) are not started — gated on Phase 2 succeeding for all three target
OSes (Server 2025, Server 2022, Windows 11), not just the first one proven.

## Resuming work

Read, in order:

1. `PHASE2_ENGINEERING_LOG.md` — especially its final section, "STATUS AND NEXT
   STEPS ON RESUMPTION (Session 5)." This is the authoritative current state:
   what's solved, what's not, and the specific next action already agreed on.
2. `CLAUDE.md` — project goals, architectural principles, tool responsibilities,
   phased plan. Read its Phase 2 status line and the "Do not reuse" note under
   "Relationship to `../windows-server-vm-automation/`" specifically.
3. `PHASE2_BOOTSTRAP_ARCHITECTURE.md` — design reasoning behind trying BCD-SYS
   first; now historical context, superseded in part by the Setup.exe pivot.
4. `HANDOFF_FROM_UNATTENDED_INSTALL.md` — original prior-art research and why
   this project exists; still accurate.
5. `PREREQUISITES.md` — host tooling this project needs beyond the sibling
   project. Only relevant again if working from a different machine.

`START_PROMPT.md` is a ready-to-use resumption prompt covering the same ground,
written for handing to a fresh Claude Code session.

## Repository layout

- `image-apply/` — the offline WIM-application pipeline scripts (partitioning,
  wimlib apply, bootability, unattend). Build artifacts under `image-apply/output/`
  are gitignored — regenerated on every real run, never source.
- `tools/` — host-side Linux dev/debug tooling: QMP-based screenshot/keystroke
  injection for inspecting and driving VMs without a VNC viewer
  (`qmp-screenshot.py`, `qmp-watch.sh`, `qmp-sendkey.py`, `qmp-type.py`), plus a
  scoped sudoers file for the disk-prep commands this pipeline needs
  (`tools/sudoers-windows-auto-build-pipeline`; not installed automatically —
  see the file's own header for the `visudo`-checked install step).
  `tools/vendor/` (BCD-SYS, cloned per `PREREQUISITES.md`) is gitignored, not
  vendored into this repo's history.
- `scripts/` — reused unchanged from the sibling project's role-provisioning
  layer once Phase 3 starts (not yet copied over).

Shared Windows/virtio-win install media lives in `../iso_cache/`, one level above
this repo and the sibling project, not inside this repo's git tree.

## Host prerequisites

See `PREREQUISITES.md`. Beyond the sibling project's baseline (KVM/QEMU/libvirt),
this project additionally needs `wimlib-imagex`, `sgdisk`/`parted`, `ntfs-3g`
(`mkfs.ntfs`), and `qemu-nbd`.
