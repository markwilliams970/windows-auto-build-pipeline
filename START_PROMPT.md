This is a resumption prompt, not a fresh kickoff — this project has real history and real
in-progress investigation behind it. Read documents before doing or suggesting anything else, in
this order:

1. **`PHASE2_ENGINEERING_LOG.md` — read this first, especially its final section, "STATUS AND NEXT
   STEPS ON RESUMPTION (Session 3)."** This is the actual current state of the investigation: what's
   solved, what's not, what was tried and failed (with root causes where we found them), and the
   specific next action already agreed on. Don't skip this to save time — it exists precisely so
   nothing in it has to be re-derived, and re-deriving it has already burned full sessions before.
2. `CLAUDE.md` — project goals, architectural principles (no golden image, ever — the eval-media
   expiration reasoning is a hard constraint), tool responsibilities, and the phased development
   plan. Its Phase 2 status line and the "Do not reuse" note under "Relationship to
   `../windows-server-vm-automation/`" both have update markers pointing back at the engineering
   log — read those two spots specifically even if skimming the rest.
3. `PHASE2_BOOTSTRAP_ARCHITECTURE.md` — the design reasoning that led to trying BCD-SYS first. Now
   labeled historical context (it has its own update marker at the top) — BCD-SYS's core claim
   (avoids WinPE entirely) was confirmed true for bootability specifically, but driver injection
   needed WinPE anyway, which changes the calculus. Read for the reasoning, not as current
   direction.
4. `HANDOFF_FROM_UNATTENDED_INSTALL.md` — the original prior-art research (why this project exists,
   what the sibling project already solved vs. couldn't). Still accurate; nothing here has changed.
5. `PREREQUISITES.md` — host tooling this project needs beyond the sibling project. Already
   installed on this host; only relevant again if working from a different machine.

---

## Where things actually stand (updated end of Session 3)

**Solved:** making an offline-applied Windows Server 2025 disk boot at all, via UEFI/OVMF, with
zero exposure to the sibling project's "press any key" landmine — confirmed for **both** `boot.wim`
index 1 (plain WinPE) and index 2 ("Microsoft Windows Setup"), each attached as a plain disk (never
`media=cdrom`). Setup.exe launches automatically and reaches its real graphical UI with no landmine
of any kind. This was the project's single biggest open risk at the start and it's fully retired.

**Also now solved, empirically, not theoretically:** the actual driver/hardware/disk chain for
clearing `INACCESSIBLE_BOOT_DEVICE (0x7B)`. Session 3 attached a real 40GB target disk via
`virtio-blk-pci`, manually loaded the real `viostor` driver through Setup's own "Install driver to
show hardware" dialog (driven entirely via keyboard through QMP — see `tools/qmp-sendkey.py`/
`tools/qmp-type.py`, no mouse or VNC needed), and confirmed via `wmic diskdrive` that the disk comes
up fully healthy:
```
Caption                          Size          Status
Red Hat VirtIO SCSI Disk Device  42944186880   OK
```
The driver file, the hardware ID match, and the whole disk-attachment architecture are proven
sound. Two hand-rolled driver-injection attempts before this (offline `hivex` registry edits
following `virt-v2v`'s recipe; a `DISM`-via-WinPE attempt root-caused to an out-of-process
COM-hosting failure) both failed and are documented in detail (Findings 7-13) — not re-attempted,
superseded by this approach.

**The one remaining gap, narrowly scoped:** it's purely about *automation*, not mechanism.
autounattend.xml's `DriverPaths` setting (`Microsoft-Windows-PnpCustomizationsWinPE`) does not
automatically feed the specific gate that shows "Install driver to show hardware" —
that gate is a separate, legacy code path (`EarlyF6DriverInstall`, literally Windows Setup's old
"press F6" mass-storage-driver mechanism) that only responds to a manual Browse-and-Install, not to
the modern unattend-driven mechanism. Confirmed directly via `setupact.log`: `UnattendDriverInstall`
(the action that *would* read `DriverPaths`) reaches its Prepare phase every time but its Execute
phase never runs before `EarlyF6DriverInstall` blocks first. Tried two placements (separate CD-ROM;
same floppy as the answer file, matching a real working community template) — no difference either
way. Full detail in Findings 19-20.

**The fix, identified but not yet attempted (Finding 21):** this project already has an
already-proven technique for exactly this situation — Finding 12 (from the earlier hand-rolled
driver-injection investigation) showed that running `drvload <path-to-viostor.inf>` from our *own*
`startnet.cmd`, *before* anything else launches, successfully loads a boot-critical VirtIO driver
into a running WinPE session. Applying that same technique **before `setup.exe` itself launches**
(rather than after WinPE boots for a different purpose, which is how Finding 12 used it) should
mean the target disk is already visible the instant Setup performs its own first disk enumeration —
never triggering `EarlyF6DriverInstall`'s gate, and its interactive-only prompt, at all.

---

## What to do first this session

1. Confirm you've read the engineering log's Session 3 resumption section, then **implement
   Finding 21**:
   - Mount `image-apply/output/winpe-boot-index2.qcow2`'s NTFS partition directly (`qemu-nbd` +
     mount — the WIM is already applied to it, so this is a plain filesystem edit, no need to
     re-mount/re-apply anything). **Do the whole attach→edit→unmount→detach sequence in one single
     Bash tool call** — see Finding 16 below for why.
   - Edit `Windows\System32\startnet.cmd` to run `wpeinit` (if not already first), then
     `drvload <path>\viostor.inf` for the real Server 2025 viostor driver, **before** whatever
     already launches `setup.exe` (this image's stock `winpeshl.ini` currently launches it
     automatically — check what's actually in `startnet.cmd`/`winpeshl.ini` right now before
     editing, don't assume). Consider baking the driver files directly into the boot medium itself
     (e.g. under a fixed `\drivers\viostor\` path, matching Finding 12's own convention) rather than
     depending on the floppy still being attached at exactly the right moment — a floppy that
     already has the files (`image-apply/output/answer-floppy.img`, `viostor\2k25\amd64\*`) also
     still exists and works, so either is fine, just be deliberate about which.
   - Boot the same way as Session 3's last test: boot medium on AHCI/IDE (**never** `virtio-blk-pci`
     for the boot medium itself — see Finding 17), target disk
     (`image-apply/output/win2025-target.qcow2`, still blank/unpartitioned) on `virtio-blk-pci`, the
     cached Server 2025 ISO and `virtio-win-0.1.285.iso` as secondary non-boot `media=cdrom`
     CD-ROMs, and the answer floppy. `Autounattend.xml` is already correctly placed (partition root
     and `\sources\`) and already confirmed found/used by Setup — no changes needed there unless
     this step reveals a new problem.
   - Watch via `tools/qmp-watch.sh`/`tools/qmp-screenshot.py`. If the target disk is visible
     immediately (no "Install driver" prompt at all), Setup should proceed through its own
     `DiskConfiguration`/`ImageInstall` and actually start installing Windows Server 2025 — watch
     for it reaching `oobeSystem`'s `FirstLogonCommands` (WinRM enablement), then attempt a real
     WinRM connection. That's Phase 2's actual success criterion.
2. **If `drvload` alone doesn't clear the gate** (e.g. if Setup re-enumerates disks in a way that
   doesn't pick up a driver already loaded beforehand): fall back to Finding 15's original idea of
   explicit `setup.exe /unattend:<path>` invocation from `startnet.cmd`, instead of relying on the
   stock `winpeshl.ini`'s autodetection — not yet tried, since autodetection has worked fine for the
   answer file itself throughout Session 3.
3. **Check what's ephemeral before assuming it's still there.** Everything under `/tmp/` from
   Session 3 is gone (extracted `boot.wim`, `virtio-extract/` driver files, the `qmp-sendkey.py`/
   `qmp-type.py` scratchpad originals — their *permanent* copies are in `tools/`, already committed
   there, so no need to re-extract those two scripts specifically). Everything under this project's
   own `image-apply/output/` persisted — see the full inventory in the engineering log's Session 3
   STATUS section, but in short: `winpe-boot-index2.qcow2` (needs its `startnet.cmd` customized per
   step 1 above), `win2025-target.qcow2` (blank, ready), `answer-floppy.img` (has the answer file
   and viostor driver files, confirmed working), `winpe-boot-index1.qcow2.bak` (safety copy of the
   older, still-working index-1 medium), plus a pile of throwaway `OVMF_VARS_*.fd` copies worth
   cleaning up whenever convenient — harmless clutter, not urgent.

---

## Process reminders (still not optional)

- **Research first — search for existing tooling or a documented mechanism before building
  anything new.** See `CLAUDE.md`'s "Research-first discipline" section. This is exactly how
  BCD-SYS, the `virt-v2v` driver-injection pattern, and Microsoft's own "Implicit Answer File Search
  Order" documentation were all found and used directly instead of guessed at.
- **Verify before trusting.** Don't assume a BCD element ID, a hardware ID, a WIM image index, or a
  mechanism's behavior — decode a real reference, extract directly, or test it, the way every
  finding in the engineering log actually got confirmed. Session 3's biggest time-savers were
  exactly this discipline: pulling `setupact.log` out via a floppy copy instead of guessing why
  something wasn't working, and re-reading Finding 12 closely enough to catch a self-inflicted
  device-model mistake before writing it up as a fake new landmine.
- **Give periodic status updates during long-running steps** (boot watches, `wimapply`, anything
  that takes more than a couple minutes) — don't go silent until the very end. This is a standing
  preference, not a one-off ask.
- **Work in small, verified steps and document as you go — including dead ends.** Session 3's two
  "attempt X, didn't work, here's the precise reason" findings (19 and the `virtio-blk-pci`
  device-model mistake, Finding 17) are recorded in as much detail as the successes, for the same
  reason as always: re-treading the same ground is the actual cost this discipline avoids.
- **Any `qemu-nbd`-dependent sequence must run inside a single Bash tool call.** This sandbox does
  not reliably keep a backgrounded `qemu-nbd -c` process alive between separate tool invocations —
  discovered the hard way in Session 3 (Finding 16) when it silently died mid-write and corrupted a
  BCD file. A `qemu-system-x86_64 ... -daemonize` VM, by contrast, survives fine across many
  separate calls (used throughout Session 3's boot-watch sequences) — the distinction observed so
  far is `-daemonize`'s real double-fork vs. `qemu-nbd`'s own backgrounding, treat as one data point
  worth staying alert to, not a fully-guaranteed rule.
- **Phase gating still applies**: no Phase 3 (service-layer/role-provisioning) work starts until
  Server 2025, Server 2022, *and* Windows 11 have each independently bootstrapped through Phase 2.
  Server 2025 is still the only one attempted so far.

---

## Key facts worth their weight in gold (expensive to re-derive, cheap to just remember)

- Server 2025's `install.wim` index 2 = `Windows Server 2025 SERVERSTANDARD` (Finding 0) — the
  `<NAME>` value used in `Autounattend.xml`'s `/IMAGE/NAME` metadata filter.
- `boot.wim` index 2 = `Microsoft Windows Setup (amd64)` (confirmed via `wimlib-imagex info`, not
  assumed) — same `Installation Type: WindowsPE` as index 1, so the same WinPE-mode BCD boolean
  elements (`26000010`, `26000022`, `260000b0`, all `hex:01` on the OS loader entry, per Finding 11)
  apply to it too.
- `virtio-win-0.1.285.iso`'s driver folders for Server 2025 are named `2k25` (confirmed via `7z l`)
  — `vioscsi/2k25/amd64`, `viostor/2k25/amd64`, `NetKVM/2k25/amd64`.
- **Device model matters and is easy to get backwards**: the *boot medium* (whichever WinPE/Setup
  image is actually booting) must be attached via a non-VirtIO device — AHCI/IDE, e.g.
  `-device ide-hd,bus=ide.0` (q35's built-in ICH9 AHCI controller, no separate controller device
  needed). `virtio-blk-pci` is only for the *target* disk. Getting this backwards self-inflicts the
  exact `INACCESSIBLE_BOOT_DEVICE` this whole project exists to solve (Finding 17).
- Real hardware ID of the virtio-blk-pci target device (confirmed via QMP `query-pci`): vendor
  `0x1AF4`, device `0x1001` — matches `viostor.inf`'s legacy entry exactly.
- `mtools` (`mcopy`/`mmd`/`mdir`) builds and edits FAT floppy images directly, with no `sudo` or
  loop-mount needed at all — much simpler than `mount -o loop`, which needs root.
- `tools/qmp-sendkey.py` and `tools/qmp-type.py` (new this session, alongside the existing
  `tools/qmp-screenshot.py`/`tools/qmp-watch.sh`) drive a QEMU guest's GUI entirely via QMP
  keyboard events — Tab/arrow-key navigation, typing literal text — no mouse, no VNC viewer. Used
  to drive Setup's entire "Install driver to show hardware" dialog by hand this session; likely
  useful again for any future interactive diagnosis.
- To pull a log or any small file out of a running WinPE/Setup session without a network share:
  open a command prompt with `Shift+F10` (`tools/qmp-sendkey.py ... shift-f10`), `copy` the file to
  the attached answer floppy, then read it directly from the host with `mcopy -i
  answer-floppy.img ::filename /host/path`. This is how `setupact.log` got pulled out repeatedly
  this session — much more reliable than screen-scraping a scrolling console window.

---

## Housekeeping note

This directory **is** a git repository (`git log` shows one commit, "Initial commit: Phase 1
architecture + Phase 2 investigation to date") — a stale note claiming otherwise was corrected
during Session 3; don't re-ask this question. As of the end of Session 3, there are real uncommitted
changes sitting in the working tree (`CLAUDE.md`, `PHASE2_ENGINEERING_LOG.md`,
`PHASE2_BOOTSTRAP_ARCHITECTURE.md`, `HANDOFF_FROM_UNATTENDED_INSTALL.md`, `.gitignore`, plus two new
untracked files `tools/qmp-sendkey.py`/`tools/qmp-type.py`) — all Session 3's documentation/tooling
updates, not yet committed. Ask before committing (or squashing into a single commit vs. several) —
don't assume either way, same standard as any other action with lasting effect.
