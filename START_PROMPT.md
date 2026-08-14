This is a resumption prompt, not a fresh kickoff — this project has real history and real
in-progress investigation behind it. Read documents before doing or suggesting anything else, in
this order:

1. **`PHASE2_ENGINEERING_LOG.md` — read this first, especially its final section, "STATUS AND NEXT
   STEPS ON RESUMPTION (Session 6)."** This is the actual current state of the investigation: what's
   solved, what's not, what was tried and failed (with root causes where we found them), and the
   specific next action already agreed on. Don't skip this to save time — it exists precisely so
   nothing in it has to be re-derived, and re-deriving it has already burned full sessions before.
   **Session 6 closed out the Setup.exe pivot entirely** — the recommended direction has reversed
   from every prior session's resumption notes. Read the Session 6 section in full even if you
   remember earlier sessions', don't skim on the assumption nothing changed.
2. `CLAUDE.md` — project goals, architectural principles (no golden image, ever — the eval-media
   expiration reasoning is a hard constraint), tool responsibilities, and the phased development
   plan. Its Phase 2 status line and the "Do not reuse" note under "Relationship to
   `../windows-server-vm-automation/`" both have update markers pointing back at the engineering
   log — read those two spots specifically even if skimming the rest. **The "Do not reuse
   `Microsoft-Windows-Setup`" rule is back in force** after being provisionally relaxed for the
   Setup.exe pivot across Sessions 3-5.
3. `PHASE2_BOOTSTRAP_ARCHITECTURE.md` — the design reasoning behind BCD-SYS and the WinPE
   `bcdboot` fallback. **This is current direction again, not historical context** — the Setup.exe
   pivot that had superseded it is now set aside.
4. `HANDOFF_FROM_UNATTENDED_INSTALL.md` — the original prior-art research (why this project exists,
   what the sibling project already solved vs. couldn't). Still accurate; nothing here has changed.
5. `PREREQUISITES.md` — host tooling this project needs beyond the sibling project. Already
   installed on this host; only relevant again if working from a different machine.

---

## Where things actually stand (updated end of Session 6)

**Still solved:** making an offline-applied Windows Server 2025 disk boot at all, via UEFI/OVMF,
with zero exposure to the sibling project's "press any key" landmine — confirmed two independent
ways, **neither of which involves Setup.exe**: BCD-SYS (zero boots required) and real `bcdboot` run
from a self-built plain WinPE session (`boot.wim` index 1). A third method, `boot.wim` index 2
("Microsoft Windows Setup") booting clean as a plain disk, is also confirmed to work for
*bootability* — but see below for why this path is now being abandoned anyway.

**Still solved, empirically:** the driver/hardware/disk chain itself. A real 40GB target disk via
`virtio-blk-pci`, loaded with the real `viostor` driver, comes up fully healthy via `wmic
diskdrive`, confirmed multiple ways. The driver file and hardware ID match are not in question —
only *how* to get the driver registered before the disk's first real boot remains open.

**The Setup.exe pivot (Finding 15) is being set aside. Five independent attempts to get past
`EarlyF6DriverInstall`'s "Install driver to show hardware" gate have now failed, each for a
different, well-evidenced reason:**

1. `Autounattend.xml`'s `DriverPaths` — doesn't feed the gate at all (Finding 19).
2. Pre-loading the driver via a real, Microsoft-reference-verified `winpeshl.ini` before Setup
   starts — driver loads successfully (confirmed via `wmic`), but the gate shows anyway.
   `setupact.log` timestamps prove the gate's Execute method starts waiting for interactive input
   in the same second as Setup's own Prepare phase, unconditionally (Finding 24).
3. Manually clicking through the gate (mouse-driven, via a required `usb-tablet` device) — even a
   genuinely clean, error-free install loops right back to `Driver: Starting Wait` forever. No
   timeout, no hidden "Next" button (Finding 25).
4. `$WinPEDriver$` (Microsoft KB 2686316's documented driver-autoload folder) — driver files
   verified present at the exact documented location (`X:\$WinPEDriver$\...`), yet the same empty
   dialog appeared and `setupact.log` shows zero evidence Setup ever scanned for the folder
   (Finding 27).
5. **Disabling `DiskConfiguration`/`InstallTo` automation** to test whether Setup would reach a
   different, modern driver-load screen instead of the legacy gate (the "modern screen" theory) —
   **ruled out this session (Finding 28).** After catching and fixing a real confound (Setup's
   implicit answer-file search checks multiple locations — the answer floppy, the boot medium's
   `\sources\`, and its root — and treats more than one as "usable"; the first test's edit only
   reached two of three, so the floppy's unmodified copy may have won), a clean re-test with all
   three locations agreeing produced `setupact.log` timestamps **identical** to every prior test.
   This proves `EarlyF6DriverInstall` is a fixed, unconditional stage of Setup's own PE-hosted
   execution — not something the answer file's disk-configuration choices route around.

**Net effect: there is no known path past Setup's disk-configuration step, in any of five
independently-motivated ways tried, and the theory that a bigger `Autounattend.xml` rewrite might
find one is now also closed.** This is a firm conclusion, not a remaining gap — internalize this
before considering any further Setup.exe-based experiment.

---

## What to do first this session

1. Confirm you've read the engineering log's Session 6 resumption section in full, then start
   planning the return to the bootstrap architecture's original path — this is a real pivot back,
   not a small continuation, so it's worth re-grounding in `PHASE2_BOOTSTRAP_ARCHITECTURE.md`
   before writing any code.
2. **The problem now reverts to its original Stage 2 form** (see the engineering log's "Open items
   carried forward to the next session," right after Finding 6, from before the Setup.exe pivot
   ever began): register the virtio storage driver into the offline-applied Windows image's own
   driver database, so that when the disk — made bootable via BCD-SYS or real `bcdboot` from a
   **plain, non-Setup** WinPE session (`boot.wim` index 1, already proven working in Findings 6/12)
   — boots for real, the kernel already knows about the viostor device and `INACCESSIBLE_BOOT_DEVICE`
   never occurs. Two hand-rolled attempts at this were made and shelved before the Setup.exe pivot
   started chasing an easier-looking path instead — worth revisiting with what this project has
   learned since, not assumed still equally broken:
   - **Offline `hivex` registry edits following `virt-v2v`'s recipe** (original Findings 7-8) —
     failed for reasons never fully root-caused, against the *main OS disk* specifically. Worth
     first checking whether that failure was specific to something about the main-OS-disk boot path
     (a full NT kernel boot) before assuming the technique itself is unsound — re-reading
     `virt-v2v`'s actual source for the exact registry keys/values it writes (rather than working
     from this project's own possibly-incomplete reconstruction) is a reasonable first step.
   - **A `DISM`-via-WinPE attempt** (original Findings 9-13) — root-caused to an out-of-process COM
     hosting failure. This project's QMP-based tooling (`qmp-click.py`, `qmp-type.py`,
     `qmp-sendkey.py`) is much more mature now than when this was first tried; may be worth another
     look if the `hivex` route doesn't pan out.
3. **Re-verify `winpe-boot-index1.qcow2.bak`** (the plain, non-Setup WinPE medium `bcdboot` was
   proven against in Findings 6/12) still boots cleanly before building on it — it hasn't been
   touched since Session 2/3, and this project's own "verify before trusting" standard applies here
   too.
4. **Check what's ephemeral before assuming it's still there.** Everything under `/tmp/` from
   Session 6 is gone. Everything under this project's own `image-apply/output/` persisted:
   - `winpe-boot-index2.qcow2` — `Autounattend.xml` (both partition-root and `\sources\` copies)
     reverted to the original, working version this session, after two experiments swapped in a
     modified variant. The `\$WinPEDriver$\viostor\2k25\amd64\` folder added in Finding 27 is still
     present at its partition root — harmless, inert now that this pivot is set aside; leave it or
     clean it up, doesn't matter. `winpeshl.ini` still in Session 4's reverted-to-stock state.
     **This qcow2 is no longer the medium to build on going forward** — see point 3 above.
   - `winpe-boot-index1.qcow2.bak` — the plain WinPE medium (no Setup.exe) this project should
     actually build on now. Not touched since Session 2/3; re-verify before relying on it.
   - `win2025-target.qcow2` — still blank/unpartitioned.
   - `answer-floppy.img` — `Autounattend.xml` reverted to the original this session too (it's also
     one of the locations Setup's implicit search checks — see the "new fact" note below).
   - No VM left running at the end of Session 6 (confirmed via `pgrep` before ending).

---

## Process reminders (still not optional)

- **Research first — search for existing tooling or a documented mechanism before building
  anything new, and do it before proposing the next experiment, not just before writing code.**
  See `CLAUDE.md`'s "Research-first discipline" section. This is exactly how BCD-SYS, the
  `virt-v2v` driver-injection pattern, and `$WinPEDriver$` were all found and used directly instead
  of guessed at — even the leads that ultimately didn't pan out (`$WinPEDriver$`, the modern-screen
  theory) were still right to try first: cheap relative to a bigger rewrite, well-documented or
  clearly falsifiable, and their failures produced real evidence rather than burning a session on
  an unproven bigger change first.
- **Verify before trusting — this discipline caught a real confound in Session 6 itself.** The
  first "modern screen" test looked like a clean negative result until checking `setupact.log`'s
  own `UnattendSearchExplicitPath` lines revealed the answer floppy's *old*, unedited
  `Autounattend.xml` was still one of three "usable" files Setup could have used — a confound that
  would have produced a false negative if not caught. Don't trust a "nothing changed" result from
  an answer-file experiment without confirming every location Setup's implicit search can find one.
- **Give periodic status updates during long-running steps** (boot watches, `wimapply`, anything
  that takes more than a couple minutes) — don't go silent until the very end. This is a standing
  preference, not a one-off ask.
- **Work in small, verified steps and document as you go — including dead ends, and especially
  including a whole pivot turning out not to pan out.** Findings 15-28 (the entire Setup.exe pivot,
  across Sessions 3-6) are recorded in exactly the same detail as any success, for the same reason
  as always: re-treading the same ground is the actual cost this discipline avoids, and the next
  session (or a different investigator entirely) should be able to see exactly why this pivot was
  abandoned without re-running any of these five experiments.
- **Any `qemu-nbd`-dependent sequence must run inside a single Bash tool call.** This sandbox does
  not reliably keep a backgrounded `qemu-nbd -c` process alive between separate tool invocations
  (Finding 16). A `qemu-system-x86_64 ... -daemonize` VM, by contrast, survives fine across many
  separate calls. Also note: the mount point directory under `/tmp/win-build-mnt/` does not
  reliably survive between separate tool calls either (plain `/tmp` cleanup, not a qemu-nbd issue) —
  `mkdir -p` it fresh inside the same atomic sequence rather than assuming a prior session's
  mountpoint directory still exists.
- **A `usb-tablet` device is required for any mouse-driven UI automation** (relative PS/2 mouse
  input does not produce visible cursor movement this early in boot, confirmed) — likely less
  relevant going forward since the WinPE `bcdboot` path doesn't need Setup's GUI at all, but keep in
  mind if any interactive debugging is needed.
- **`tools/qmp-type.py` cannot type `&`** (no `CHAR_MAP` entry) — avoid `2>&1`-style redirection in
  any command typed via this tool; run separate commands per target instead.
- **Phase gating still applies**: no Phase 3 (service-layer/role-provisioning) work starts until
  Server 2025, Server 2022, *and* Windows 11 have each independently bootstrapped through Phase 2.
  Server 2025 is still the only one attempted so far, and Phase 2 itself is not yet working end to
  end even for Server 2025.

---

## Key facts worth their weight in gold (expensive to re-derive, cheap to just remember)

- Server 2025's `install.wim` index 2 = `Windows Server 2025 SERVERSTANDARD` (Finding 0) — the
  `<NAME>` value used in `Autounattend.xml`'s `/IMAGE/NAME` metadata filter, still relevant if
  driver injection ends up needing an unattend pass of any kind.
- `boot.wim` index 1 = plain WinPE (no Setup.exe) — **the medium to build on now.** `boot.wim`
  index 2 = `Microsoft Windows Setup (amd64)`, the medium the now-abandoned pivot used. Both share
  the same WinPE-mode BCD boolean elements (`26000010`, `26000022`, `260000b0`, all `hex:01` on the
  OS loader entry, per Finding 11).
- `virtio-win-0.1.285.iso`'s driver folders for Server 2025 are named `2k25` (confirmed via `7z l`)
  — `vioscsi/2k25/amd64`, `viostor/2k25/amd64`, `NetKVM/2k25/amd64`.
- **Device model matters and is easy to get backwards**: the *boot medium* (whichever WinPE image
  is actually booting) must be attached via a non-VirtIO device — AHCI/IDE, e.g.
  `-device ide-hd,bus=ide.0` (q35's built-in ICH9 AHCI controller, no separate controller device
  needed). `virtio-blk-pci` is only for the *target* disk. Getting this backwards self-inflicts the
  exact `INACCESSIBLE_BOOT_DEVICE` this whole project exists to solve (Finding 17).
- Real hardware ID of the virtio-blk-pci target device (confirmed via QMP `query-pci`): vendor
  `0x1AF4`, device `0x1001` — matches `viostor.inf`'s legacy entry exactly.
- `mtools` (`mcopy`/`mmd`/`mdir`) builds and edits FAT floppy images directly, with no `sudo` or
  loop-mount needed at all — much simpler than `mount -o loop`, which needs root. `mcopy -o` (or
  `-n`) overwrites a file already on the image in place.
- **`X:` during a booted WinPE/Setup session is the physical boot-medium NTFS partition itself**,
  not a separate RAM-disk copy of `boot.wim`'s contents (Finding 27 — confirmed via `wmic
  logicaldisk`). Any file placed on the mounted qcow2's NTFS partition is directly visible as
  `X:\...` inside the running session.
- **Windows Setup's implicit answer-file search checks multiple locations and can treat more than
  one as "usable" for the same pass simultaneously** (`setupact.log`'s `UnattendSearchExplicitPath`
  lines) — in this project's boot configuration: the answer floppy (`A:`), the boot medium's
  `\sources\` folder, and the boot medium's own root. Editing only one is not sufficient to trust a
  test reflects the intended change (Finding 28) — update all locations, or remove the file from
  the ones not under test.
- **`EarlyF6DriverInstall`'s "Install driver to show hardware" gate is a fixed, unconditional stage
  of Setup.exe's own PE-hosted execution** (Findings 24, 25, 27, 28) — it fires at identical timing
  regardless of driver pre-loading, `$WinPEDriver$`, or whether disk configuration is automated in
  the answer file. This is why the pivot is being abandoned; don't re-attempt any Setup.exe-based
  workaround expecting a different result without new information not already covered above.
- `setupact.log` actually lives at `X:\$WINDOWS.~BT\Sources\Panther\setupact.log` during a live
  Setup session — **not** `X:\Windows\Panther\setupact.log` (doesn't exist yet at this stage).
  `cd /d` into that directory first if typing the literal path via `qmp-type.py` — a `\$` sequence
  typed directly seems to lose the preceding backslash somehow (observed once, not root-caused).
- To pull a log or any small file out of a running WinPE session without a network share: open a
  command prompt with `Shift+F10` (`tools/qmp-sendkey.py ... shift-f10`), `copy` the file to the
  attached answer floppy, then read it directly from the host with `mcopy -i answer-floppy.img
  ::filename /host/path`. Files redirected via `dir ... > A:\file.txt` come back UTF-16-encoded —
  decode with Python's `bytes.decode('utf-16-be')` if `utf-16-le`/plain `utf-16` look garbled; check
  both. Still the most reliable way to get real diagnostic detail.
- **`tools/qmp-click.py`** — QMP absolute-position mouse clicks (`--double` for double-clicks).
  Requires a `usb-tablet` device on the VM — relative PS/2 mouse movement does not work in this
  environment at all. Likely less needed going forward (see Process reminders above).

---

## Housekeeping note

This directory **is** a git repository. Check `git status`/`git log` fresh at the start of this
session rather than trusting any note here about what was committed — this file describes state as
of when it was last edited, not necessarily the true current state. As of Session 6 being written,
`PHASE2_ENGINEERING_LOG.md`, `README.md`, `CLAUDE.md`, and this file have all been updated to
reflect Findings 27-28 and the pivot reversal, and are expected to be committed as a normal
end-of-session commit. Still ask before committing *new* changes (or squashing vs. several
commits).

**No VM was left running at the end of Session 6** (confirmed via `pgrep -fa qemu-system-x86_64`
before ending). `winpe-boot-index2.qcow2`'s `Autounattend.xml` and the answer floppy's copy were
both reverted to their original, working versions; `win2025-target.qcow2` is still blank.
