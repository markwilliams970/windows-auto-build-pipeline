> **STALE — this entire file is a snapshot frozen at Phase 2/Session 7, before Phase 3 even
> started.** Everything below describes Windows Server 2025 as the only OS with a working
> mechanism and treats the offline specialize/unattend pass as the next open task. Since then:
> Phase 2 finished for all three target OSes, Phase 3 (role provisioning) finished including the
> production pipeline for Server 2022/2025, and Windows 11 — after the offline-apply mechanism hit
> an unresolved BSOD — got its own Setup.exe-driven build path (`image-apply/
> windows11-setup-install.sh`), now production-ready and confirmed via six independent clean
> builds. **Do not use this file to resume work.** Read `CLAUDE.md` (current per-phase status) and
> `PHASE3_ENGINEERING_LOG.md`'s final entries instead — see `README.md`'s own "Resuming work"
> section for the up-to-date reading order. This file is left in place as a real historical
> artifact of how Phase 2 resumption prompts were written at the time, not maintained further.
>
> Original Session 7 content follows, unmodified:

This is a resumption prompt, not a fresh kickoff — this project has real history and real
in-progress investigation behind it. Read documents before doing or suggesting anything else, in
this order:

1. **`PHASE2_ENGINEERING_LOG.md` — read this first, especially its final section, "STATUS AND NEXT
   STEPS ON RESUMPTION (Session 7)."** This is the actual current state of the investigation:
   **Phase 2's core blocker is now solved** — a real Windows Server 2025 disk boots cleanly past
   `INACCESSIBLE_BOOT_DEVICE (0x7B)` to a genuine OOBE screen, using only offline mechanisms.
   Read the Session 7 section (Finding 29) in full — it's the most important finding in the whole
   log, and everything before it (Sessions 3-6, the entire Setup.exe pivot and its abandonment) is
   now historical context for *why* this path was returned to, not the current blocker.
2. `CLAUDE.md` — project goals, architectural principles (no golden image, ever — the eval-media
   expiration reasoning is a hard constraint), tool responsibilities, and the phased development
   plan. Its Phase 2 status line and the "Do not reuse" note under "Relationship to
   `../windows-server-vm-automation/`" both have update markers pointing back at the engineering
   log — read those two spots specifically even if skimming the rest.
3. `PHASE2_BOOTSTRAP_ARCHITECTURE.md` — the design reasoning behind BCD-SYS and the WinPE
   `bcdboot` fallback. **This is exactly the path that just worked** — read it as current, accurate
   design reasoning, not historical context.
4. `HANDOFF_FROM_UNATTENDED_INSTALL.md` — the original prior-art research (why this project exists,
   what the sibling project already solved vs. couldn't). Still accurate; nothing here has changed.
5. `PREREQUISITES.md` — host tooling this project needs beyond the sibling project. Already
   installed on this host; only relevant again if working from a different machine.

---

## Where things actually stand (updated end of Session 7)

**Phase 2's core technical blocker — offline virtio driver injection clearing
`INACCESSIBLE_BOOT_DEVICE (0x7B)` without any interactive Setup.exe involvement — is solved.**

The full working sequence, confirmed end-to-end this session:
1. A target disk with `install.wim` already applied (`win2025-test.qcow2`, reused from Session 2).
2. Boot a **plain, non-Setup WinPE medium** (`boot.wim` index 1, not index 2 — Setup.exe is not
   involved anywhere in this path) with the target disk attached via `virtio-blk-pci`.
3. Inside WinPE: `drvload X:\drivers\viostor\viostor.inf` (the target disk is **not visible at
   all** to WinPE before this — `diskpart list disk` shows only WinPE's own boot disk until the
   driver loads, then immediately shows both).
4. `diskpart` to assign drive letters to the target's ESP (`S:`) and Windows partition (`W:`).
5. **Real `bcdboot W:\Windows /s S: /f UEFI`** — a genuine Microsoft-tool-built BCD, not BCD-SYS's
   approximation (BCD-SYS remains a fully valid alternative for this step; this session used real
   `bcdboot` specifically to eliminate it as a confound versus Session 2's original failed attempt).
6. Copy `viostor.sys` to the target's `Windows\System32\drivers\viostor.sys`.
7. Shut down WinPE cleanly.
8. **Offline, from the Linux host**: `hivexregedit --merge` a corrected `.reg` file
   (`tools/gen-viostor-ddb-reg.py`) into the target's `SYSTEM` hive, registering `viostor` in
   `DriverDatabase` — the actual fix; see below for what was wrong before.
9. Boot the target disk **alone** (no WinPE, no floppy, no Setup.exe) — clean progression through
   TianoCore → Windows boot animation → "Getting ready" → a real Windows Server 2025 OOBE screen.

**The root cause of Session 2's original failure (Findings 7-8), found by reading `virt-v2v`'s
actual source instead of working from a prior summary:** `DriverDatabase` lives at the **SYSTEM
hive root**, a direct sibling of `ControlSet001` — not nested under `ControlSet001\Control` as a
reasonable-looking (but wrong) assumption would suggest, and as Finding 8's own prose description
suggests it was placed (written immediately after CDB paths that correctly use that prefix).
Registering under the wrong parent key is a **silent no-op** — `hivexregedit` raises no error, and
Windows never sees the registration — which matches Finding 8's "byte-for-byte identical 0x7B, no
error" symptom exactly. Confirmed empirically (not just inferred from source) via `hivexsh` against
a real applied image: `DriverDatabase` is a direct child of the hive root, already populated with
real `DeviceIds`/`DriverFiles`/`DriverInfFiles`/`DriverPackages` content from `wimapply` time.

**Still solved, unchanged from before:** making an offline-applied disk boot at all under UEFI/OVMF
(BCD-SYS or real `bcdboot`, both confirmed multiple times now), and the driver/hardware match
itself (`viostor` correctly matches the real `virtio-blk-pci` hardware ID).

**Abandoned this project, now historical context:** the Setup.exe pivot (Finding 15, Sessions 3-5) —
five independent attempts to get past Setup.exe's own `EarlyF6DriverInstall` gate all failed
(Findings 19, 24, 25, 27, 28), leading Session 6 to recommend returning to the plain-WinPE path
above, which then worked. The "do not reuse `autounattend.xml`'s `Microsoft-Windows-Setup`
component" rule is back in force. No need to revisit this pivot's detail unless something about the
current working path breaks and Setup.exe starts looking attractive again — treat it as closed.

---

## What to do first this session

1. Confirm you've read the engineering log's Session 7 section (Finding 29) in full, then decide
   with whoever you're working with which of the recommended next steps to prioritize:
2. **Re-verify end-to-end on a completely fresh disk.** Session 7's success reused
   `win2025-test.qcow2`, a disk originally built in Session 2, before some of this project's
   current conventions were as settled. The fix is verified against Microsoft/`virt-v2v`-documented
   registry semantics, not against any disk-specific quirk, so it should generalize — but this
   hasn't actually been confirmed on a disk partitioned + `wimapply`'d from scratch this session.
   Do this before building anything else on top.
3. **Build the offline specialize/unattend pass** (`CLAUDE.md`'s Build step 6): drop a
   `\Windows\Panther\unattend.xml` onto the offline-mounted image before first boot (computer name,
   WinRM enablement). The sibling project's own `autounattend.xml` `specialize`/`oobeSystem` content
   is a proven starting point for the actual *settings* — but the *delivery mechanism* here is
   different: offline file placement onto the mounted image, not Setup.exe consuming it during
   install. This is what turns "boots to OOBE" into Phase 2's actual success criterion (a real,
   unattended WinRM connection).
4. **Consider formalizing this into real `image-apply/` scripts.** `image-apply/` is still empty of
   actual implementation — everything through Session 7 has been ad hoc Bash run directly per
   session, appropriate for the R&D phase this has been. Now that the core mechanism is proven
   end-to-end, scripting it (`partition-disk.sh`, `apply-image.sh`, `make-bootable.sh`, per
   `CLAUDE.md`'s repository sketch) may be due — but this is a real decision point, not a default
   next action. Per `CLAUDE.md`'s Claude Instructions, explain the design and check in before
   generating significant implementation code.
5. **Once WinRM-reachable for Server 2025**, repeat for Server 2022 and Windows 11 Enterprise
   Evaluation — Phase 3 does not start until all three OSes are independently proven, per the
   explicit phase-gating rule.
6. **Check what's ephemeral before assuming it's still there.** Everything under `/tmp/` from
   Session 7 is gone (including the intermediate `.reg` file — regenerate with
   `tools/gen-viostor-ddb-reg.py`, confirmed to reproduce byte-identical output). Everything under
   `image-apply/output/` persisted — see the persistent-state list below.

---

## Process reminders (still not optional)

- **Research first — read the actual primary source, not a summary of it, including your own
  project's prior summary of it.** This is the single biggest lesson from Session 7: Finding 7/8's
  original summary of `virt-v2v`'s recipe was detailed and looked complete, but was subtly wrong in
  a way that silently broke everything, and nobody caught it across two full sessions because
  nobody re-read the actual `.ml` source file until Session 7 did. When a research-derived
  technique doesn't work and the failure has no clear error message, re-verify the *transcription*
  against the primary source before concluding the *technique* is broken.
- **Verify before trusting — caught real problems twice this session.** (1) Checking `hivexsh`
  directly against a real hive confirmed `DriverDatabase`'s actual parent, rather than trusting
  either the old summary or a fresh-but-unverified reading of the OCaml source. (2) Inspecting a
  reused WinPE medium's actual `startnet.cmd` before trusting it (`cat`, not assumption) caught that
  it carried Finding 14's leftover debug script, not Finding 12's drvload/bcdboot script — would
  have produced a confusing, silent failure (`diskpart` unable to find the target disk) if not
  caught. Always inspect what a reused artifact actually contains before relying on it.
- **Give periodic status updates during long-running steps** (boot watches, `wimapply`, anything
  that takes more than a couple minutes) — don't go silent until the very end. This is a standing
  preference, not a one-off ask.
- **Work in small, verified steps and document as you go.** Finding 29 (Session 7) is recorded in
  the same detail as every dead end before it, for the same reason as always.
- **Any `qemu-nbd`-dependent sequence must run inside a single Bash tool call.** This sandbox does
  not reliably keep a backgrounded `qemu-nbd -c` process alive between separate tool invocations
  (Finding 16). A `qemu-system-x86_64 ... -daemonize` VM, by contrast, survives fine across many
  separate calls. The mount point directory under `/tmp/win-build-mnt/` does not reliably survive
  between separate tool calls either — `mkdir -p` it fresh inside the same atomic sequence.
- **Always start from a fresh `OVMF_VARS_4M.fd` copy per distinct boot target.** Reusing a vars file
  across unrelated qcow2s carries over stale NVRAM boot entries — hit this directly in Session 7
  (a stale `Boot0008` pointed at a completely different disk's ESP until a fresh vars file fixed
  it). Cheap to avoid, confusing to debug if not.
- **`hivexregedit --merge` needs every intermediate registry key declared explicitly** — unlike real
  `regedit.exe`, it will not auto-create more than one missing level of nesting per `[...]` section
  in one jump; it dies with "cannot create ... since parent ... does not exist" instead. Declare
  empty parent-key sections before any deeply-nested child key (see
  `tools/gen-viostor-ddb-reg.py` for the pattern).
- **Plain WinPE cannot see a virtio-blk-pci disk without `drvload`ing viostor first.** Confirmed
  directly this session (Finding 14's own unconfirmed Session-2 suspicion). Any WinPE script
  touching a virtio-blk target must `drvload` before any `diskpart`/disk-enumeration step,
  unconditionally.
- **`tools/qmp-type.py` cannot type `%`, `|`, or `&`** (no `CHAR_MAP` entries) — avoid
  environment-variable references (`%SystemDrive%`), pipes, or `2>&1`-style redirection in any
  command typed through it. Use literal drive letters (`X:`, `W:`) instead of
  `%SystemDrive%`/`%SystemRoot%`, and avoid combining stdout/stderr redirection with `&`.
- **Phase gating still applies**: no Phase 3 (service-layer/role-provisioning) work starts until
  Server 2025, Server 2022, *and* Windows 11 have each independently bootstrapped through Phase 2.

---

## Key facts worth their weight in gold (expensive to re-derive, cheap to just remember)

- **`DriverDatabase` lives at the SYSTEM hive root, a sibling of `ControlSet001`** — not nested
  under `ControlSet001\Control`. Get this wrong and `hivexregedit` succeeds with zero errors while
  silently doing nothing. This is Session 7's single most important correction.
- The full, correct offline driver-registration recipe is transcribed directly from `virt-v2v`'s
  real source (`libguestfs/libguestfs-common`, `mlcustomize/inject_virtio_win.ml`) into
  `tools/gen-viostor-ddb-reg.py` — regenerate rather than hand-write if this needs adjusting for a
  different driver (e.g. `vioscsi`) or OS.
- `win2025-test.qcow2` (in `image-apply/output/`) is a 64GB disk with `install.wim` applied
  (Session 2) that Session 7 confirmed boots to OOBE with the corrected driver registration and a
  real `bcdboot`-built BCD. A real, working, non-trivial-to-rebuild reference asset.
- `winpe-boot-index1-work.qcow2` — working copy of the plain WinPE medium (no Setup.exe),
  `startnet.cmd` reverted to bare `wpeinit` in Session 7. Use this one going forward, not the
  `.bak`, which remains untouched as the original safety copy.
- Server 2025's `install.wim` index 2 = `Windows Server 2025 SERVERSTANDARD` (Finding 0).
  `boot.wim` index 1 = plain WinPE (no Setup.exe) — the medium to build on. `boot.wim` index 2 =
  `Microsoft Windows Setup (amd64)`, the medium the abandoned pivot used.
- `virtio-win-0.1.285.iso`'s driver folders for Server 2025 are named `2k25` (confirmed via `7z l`)
  — `vioscsi/2k25/amd64`, `viostor/2k25/amd64`, `NetKVM/2k25/amd64`.
- **Device model matters and is easy to get backwards**: the *boot medium* must be attached via a
  non-VirtIO device — AHCI/IDE, e.g. `-device ide-hd,bus=ide.0`. `virtio-blk-pci` is only for the
  *target* disk. Getting this backwards self-inflicts the exact `INACCESSIBLE_BOOT_DEVICE` this
  whole project exists to solve (Finding 17).
- Real hardware ID of the virtio-blk-pci target device (confirmed via QMP `query-pci`): vendor
  `0x1AF4`, device `0x1001` — matches `viostor.inf`'s legacy entry exactly. Both the legacy
  (`DEV_1001`) and modern (`DEV_1042`) PCI IDs are registered by `gen-viostor-ddb-reg.py`.
  `mtools` (`mcopy`/`mmd`/`mdir`) builds and edits FAT floppy images directly, with no `sudo` or
  loop-mount needed at all.
- To pull a log or any small file out of a running WinPE session without a network share: open a
  command prompt with `Shift+F10` (`tools/qmp-sendkey.py ... shift-f10`), `copy` the file to the
  attached answer floppy, then read it directly from the host with `mcopy -i answer-floppy.img
  ::filename /host/path`. Files redirected via `dir ... > A:\file.txt` come back UTF-16-encoded —
  decode with Python's `bytes.decode('utf-16-be')` if `utf-16-le`/plain `utf-16` look garbled.
- **`tools/qmp-click.py`** — QMP absolute-position mouse clicks. Requires a `usb-tablet` device on
  the VM. Not needed for the current WinPE-based path (interactive `Shift+F10` + keyboard typing is
  sufficient), but kept for reference.

---

## Housekeeping note

This directory **is** a git repository. Check `git status`/`git log` fresh at the start of this
session rather than trusting any note here about what was committed — this file describes state as
of when it was last edited, not necessarily the true current state. As of Session 7 being written,
`PHASE2_ENGINEERING_LOG.md`, `README.md`, `CLAUDE.md`, this file, and the new
`tools/gen-viostor-ddb-reg.py` have all been added/updated to reflect Finding 29, and are expected
to be committed as a normal end-of-session commit. Still ask before committing *new* changes (or
squashing vs. several commits).

**No VM was left running at the end of Session 7** (confirmed via `pgrep -fa qemu-system-x86_64`
before ending). `win2025-test.qcow2` now carries a working fix (real `bcdboot`-built BCD +
corrected driver registration) and boots to OOBE — treat it as a valuable reference asset, not
disposable scratch state, even though a fresh-disk re-verification is still recommended before
relying on it as the actual build output.
