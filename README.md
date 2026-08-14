# Windows Auto-Build Pipeline

Offline-image-application pipeline for building fully reproducible Windows Server
2022/2025 and Windows 11 lab VMs (Datadog Agent integration testing against
AD/IIS/SQL Server), without relying on Packer's interactive-installer boot path —
which reliably fails for Server 2025 and Windows 11 media due to an unresolved
upstream Packer/QEMU/OVMF issue. See `HANDOFF_FROM_UNATTENDED_INSTALL.md` for the
full background on why this project exists as a separate repo from its sibling,
`../windows-server-vm-automation/`.

## Status (as of Session 7, 2026-08-14)

**Phase 1 (architecture): done.**

**Phase 2 (offline installation mechanism): the core blocker is solved.** A real
Windows Server 2025 disk now boots cleanly past `INACCESSIBLE_BOOT_DEVICE (0x7B)`
to a genuine OOBE screen, using only offline mechanisms — no Setup.exe, no
interactive install, no `media=cdrom` boot of any kind.

- **Solved:** making an offline-applied disk boot at all under UEFI/OVMF, via two
  independent methods (BCD-SYS from Linux with zero boots, and real `bcdboot` from
  a self-built WinPE session).
- **Solved:** offline virtio driver injection, clearing `INACCESSIBLE_BOOT_DEVICE
  (0x7B)` on first real boot. Session 2's original `hivex` attempt (Findings 7-8)
  failed silently because its `DriverDatabase` registry edits went under the wrong
  parent key (`ControlSet001\Control\DriverDatabase`, a reasonable-looking but
  wrong guess) — `DriverDatabase` actually lives at the **SYSTEM hive root**, a
  sibling of `ControlSet001`, confirmed empirically against a real applied image.
  Session 7 re-derived the full registration recipe directly from `virt-v2v`'s
  actual source (not memory), fixed the parent-key path, and confirmed it working
  end-to-end: `wimapply` → real `bcdboot` (run once from a plain, non-Setup WinPE
  session) → offline `hivexregedit` driver registration → boot the target disk
  alone → clean progression through the Windows boot animation to a real OOBE
  screen. See `PHASE2_ENGINEERING_LOG.md`'s Finding 29 for the full verification
  trail, and `tools/gen-viostor-ddb-reg.py` for the resulting reusable tooling.
- **Abandoned along the way — the Setup.exe pivot (Finding 15):** five independent
  attempts to get past Setup.exe's own `EarlyF6DriverInstall` driver-load gate all
  failed (it fires as a fixed, unconditional stage of Setup's execution, not
  something any answer-file configuration routes around) before this project
  returned to the original plan above, which then worked. See Findings 19, 24,
  25, 27, and 28 for that dead end's full record.
- **Not yet done:** this boot used no `unattend.xml`/specialize pass, so it
  correctly stopped at interactive OOBE rather than an automated, WinRM-reachable
  state — that offline specialize pass (`CLAUDE.md`'s Build step 6) is the
  remaining piece of Phase 2's actual success criterion. Re-verifying the fix on
  a disk built fully fresh (rather than the Session-2-era disk reused for this
  test) is also still open.

**Phases 3-5** (Windows role configuration, Datadog integration, lifecycle
automation) are not started — gated on Phase 2 succeeding for all three target
OSes (Server 2025, Server 2022, Windows 11), not just the first one proven.

## Resuming work

Read, in order:

1. `PHASE2_ENGINEERING_LOG.md` — especially its final section, "STATUS AND NEXT
   STEPS ON RESUMPTION (Session 7)." This is the authoritative current state:
   what's solved, what's not, and the specific next action already agreed on.
2. `CLAUDE.md` — project goals, architectural principles, tool responsibilities,
   phased plan. Read its Phase 2 status line and the "Do not reuse" note under
   "Relationship to `../windows-server-vm-automation/`" specifically.
3. `PHASE2_BOOTSTRAP_ARCHITECTURE.md` — design reasoning behind trying BCD-SYS
   first. Current direction again — the Setup.exe pivot that had superseded it
   was abandoned in Session 6 and this plan is what Session 7 confirmed working.
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
  (`qmp-screenshot.py`, `qmp-watch.sh`, `qmp-sendkey.py`, `qmp-type.py`,
  `qmp-click.py`), `gen-viostor-ddb-reg.py` (generates the source-verified `.reg`
  file that offline-registers the virtio-blk boot driver, clearing
  `INACCESSIBLE_BOOT_DEVICE` — see `PHASE2_ENGINEERING_LOG.md` Finding 29), plus a
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
