This is a resumption prompt, not a fresh kickoff — this project has real history and real
in-progress investigation behind it. Read documents before doing or suggesting anything else, in
this order:

1. **`PHASE2_ENGINEERING_LOG.md` — read this first, especially its final section, "STATUS AND NEXT
   STEPS ON RESUMPTION (Session 4)."** This is the actual current state of the investigation: what's
   solved, what's not, what was tried and failed (with root causes where we found them), and the
   specific next action already agreed on. Don't skip this to save time — it exists precisely so
   nothing in it has to be re-derived, and re-deriving it has already burned full sessions before.
   **Session 4 overturned an assumption Session 3's own resumption notes treated as settled** — read
   the Session 4 section in full even if you remember Session 3's, don't skim on the assumption
   nothing changed.
2. `CLAUDE.md` — project goals, architectural principles (no golden image, ever — the eval-media
   expiration reasoning is a hard constraint), tool responsibilities, and the phased development
   plan. Its Phase 2 status line and the "Do not reuse" note under "Relationship to
   `../windows-server-vm-automation/`" both have update markers pointing back at the engineering
   log — read those two spots specifically even if skimming the rest.
3. `PHASE2_BOOTSTRAP_ARCHITECTURE.md` — the design reasoning that led to trying BCD-SYS first. Now
   labeled historical context (it has its own update marker at the top) — BCD-SYS's core claim
   (avoids WinPE entirely) was confirmed true for bootability specifically, but driver injection
   needed WinPE anyway, which changes the calculus. Read for the reasoning, not as current
   direction. **Its fallback path (real `bcdboot` from a self-built WinPE session) may become
   relevant again** if Session 5's one open theory (below) doesn't pan out.
4. `HANDOFF_FROM_UNATTENDED_INSTALL.md` — the original prior-art research (why this project exists,
   what the sibling project already solved vs. couldn't). Still accurate; nothing here has changed.
5. `PREREQUISITES.md` — host tooling this project needs beyond the sibling project. Already
   installed on this host; only relevant again if working from a different machine.

---

## Where things actually stand (updated end of Session 4)

**Still solved:** making an offline-applied Windows Server 2025 disk boot at all, via UEFI/OVMF,
with zero exposure to the sibling project's "press any key" landmine — confirmed for **both**
`boot.wim` index 1 (plain WinPE) and index 2 ("Microsoft Windows Setup"), each attached as a plain
disk (never `media=cdrom`). Setup.exe launches automatically and reaches its real graphical UI with
no landmine of any kind.

**Still solved, empirically:** the driver/hardware/disk chain itself. A real 40GB target disk via
`virtio-blk-pci`, loaded with the real `viostor` driver (either manually through Setup's "Install
driver to show hardware" dialog, or automatically via a custom `winpeshl.ini` before Setup even
starts), comes up fully healthy via `wmic diskdrive`. The driver file, the hardware ID match, and
the disk-attachment architecture are all proven sound, repeatedly, multiple ways.

**What Session 3 believed was "just automation" turned out to be a real, currently-unresolved
blocker.** Session 3 left off believing: (a) `DriverPaths` doesn't auto-feed `EarlyF6DriverInstall`'s
gate, but (b) manually clicking through it (Finding 20) was a working fallback, and (c) pre-loading
the driver before Setup starts (Finding 21, not yet attempted) would very likely remove the need for
the gate entirely. Session 4 tested both remaining pieces properly:

- **Pre-loading via a real, Microsoft-reference-verified `winpeshl.ini`** (not the `startnet.cmd`
  edit Finding 21 originally proposed — Session 4 found `startnet.cmd` most likely never even runs
  in this boot flow, see Finding 22) **does** load the driver before Setup starts, confirmed via
  `wmic`. **The gate still shows anyway.** `setupact.log` timestamps prove
  `EarlyF6DriverInstall`'s Execute method starts waiting for interactive input in the same second as
  Setup's own Prepare phase — unconditionally, before any user action could possibly matter. See
  Finding 24. Pre-loading cannot work around this; it isn't a timing/race issue.
- **Manually clicking through the gate** (now mouse-driven — see the tooling note below — matching
  Finding 20's original keyboard-driven click-through) was repeated with a **genuinely clean,
  error-free** install for the first time (Session 3 only ever saw a real success immediately
  followed by an accidental duplicate-click error). `setupact.log` proves that even a clean success
  loops right back to `Driver: Starting Wait`, forever. No timeout (waited 60+ seconds), no hidden
  "Next" button (tried maximizing the window), and the window's own close button pops "Are you sure
  you want to quit?" rather than dismissing just this sub-dialog. See Finding 25.

**Net effect: there is currently no known path past Setup's disk-configuration step, automated or
manual.** This is a real setback, not a small remaining gap — internalize this before re-attempting
anything that looks like "just pre-load the driver a bit differently" or "just click through it more
carefully." The evidence is timestamp-based proof from `setupact.log`, not inference.

---

## What to do first this session

1. Confirm you've read the engineering log's Session 4 resumption section in full, then decide,
   together with whoever you're working with, whether to pursue the one open theory below or step
   back to reconsider architecture — **this is a real decision point, not a "just try the next
   thing" continuation.** Don't silently start rebuilding `Autounattend.xml` without checking in
   first; Session 4 already spent a full session on what looked like a small remaining gap turning
   into a real blocker, and this next step is a bigger change than anything tried so far.
2. **The one real open thread, not yet attempted:** `EarlyF6DriverInstall` is Windows Setup's legacy
   "press F6 to load a mass-storage driver" mechanism. It may only be reachable because
   `Autounattend.xml`'s `DiskConfiguration`/`ImageInstall` sections drive Setup directly into
   automated disk configuration, skipping past the *modern* interactive "Where do you want to install
   Windows" screen — which has a different, non-legacy "Load driver" link never tested in this
   project. To test this: rebuild `Autounattend.xml` to *not* fully automate disk configuration (or
   omit `DiskConfiguration` entirely), boot, see what screen Setup actually shows instead, and test
   whether *that* screen's driver-load mechanism actually lets Setup proceed once satisfied (unlike
   the legacy F6 dialog, which doesn't). If this also dead-ends, the honest conclusion is that the
   Setup.exe pivot itself needs reconsidering against `PHASE2_BOOTSTRAP_ARCHITECTURE.md`'s original
   fallback (real `bcdboot` from a self-built WinPE session, driver injection handled some other way
   — possibly revisiting the `virt-v2v`/hivex approach with fresh eyes, or the DISM COM-hosting
   failure from Findings 7-13 with the newer `ntoseye` kernel-debugging tooling now available).
3. **Check what's ephemeral before assuming it's still there.** Everything under `/tmp/` from
   Session 4 is gone (extracted logs, scratchpad copies of `qmp-click.py`/`qmp-dblclick.py` — the
   *permanent* copy of `qmp-click.py` is in `tools/`, already there, no need to re-extract).
   Everything under this project's own `image-apply/output/` persisted:
   - `winpe-boot-index2.qcow2` — **currently reverted to stock** (`winpeshl.ini` present, containing
     only `%SYSTEMDRIVE%\setup.exe`, no `drvload` line) after Session 4's clean-install test.
     `Autounattend.xml` still present at both its partition root and `\sources\`, unchanged.
   - `win2025-target.qcow2` — still blank/unpartitioned; Setup has never gotten far enough to touch
     it.
   - `answer-floppy.img` — unchanged, still has `Autounattend.xml` + `viostor/2k25/amd64/*`.
   - A VM from Session 4 may still be running (`qmp-setup-test4.sock`) — check
     `pgrep -fa qemu-system-x86_64` before assuming either way; if still up, its target disk is still
     blank and its boot medium's `winpeshl.ini` is in the stock/reverted state described above.

---

## Process reminders (still not optional)

- **Research first — search for existing tooling or a documented mechanism before building
  anything new.** See `CLAUDE.md`'s "Research-first discipline" section. This is exactly how
  BCD-SYS, the `virt-v2v` driver-injection pattern, and Microsoft's own "Implicit Answer File Search
  Order"/`winpeshl.ini` reference documentation were all found and used directly instead of guessed
  at.
- **Verify before trusting — this discipline directly overturned a settled-looking assumption
  twice in Session 4 alone.** Checking what was actually in `winpeshl.ini`/`startnet.cmd` before
  editing (rather than trusting Finding 21's premise) and pulling real `setupact.log` timestamps
  (rather than guessing why a dialog wouldn't advance) both revealed the previous session's
  optimism was wrong. Don't assume a BCD element ID, a hardware ID, a WIM image index, or a
  mechanism's behavior — decode a real reference, extract directly, or test it.
- **Give periodic status updates during long-running steps** (boot watches, `wimapply`, anything
  that takes more than a couple minutes) — don't go silent until the very end. This is a standing
  preference, not a one-off ask.
- **Work in small, verified steps and document as you go — including dead ends, and including when
  a previous session's optimism turns out to be wrong.** Findings 22-25 (Session 4) are recorded in
  exactly the same detail as any success, for the same reason as always: re-treading the same
  ground is the actual cost this discipline avoids. If Session 3's status section had tested a
  genuinely clean Install click and waited 60 seconds, this gap would have been caught a session
  earlier.
- **Any `qemu-nbd`-dependent sequence must run inside a single Bash tool call.** This sandbox does
  not reliably keep a backgrounded `qemu-nbd -c` process alive between separate tool invocations
  (Finding 16). A `qemu-system-x86_64 ... -daemonize` VM, by contrast, survives fine across many
  separate calls — the distinction observed so far is `-daemonize`'s real double-fork vs.
  `qemu-nbd`'s own backgrounding, treat as one data point worth staying alert to, not a
  fully-guaranteed rule. Also note: the mount point directory under `/tmp/win-build-mnt/` does not
  reliably survive between separate tool calls either (plain `/tmp` cleanup, not a qemu-nbd issue) —
  `mkdir -p` it fresh inside the same atomic sequence rather than assuming a prior session's
  mountpoint directory still exists.
- **A `usb-tablet` device is now required for any mouse-driven UI automation.** Relative PS/2 mouse
  input does not produce visible cursor movement in this WinPE/Setup environment this early in boot
  (confirmed, not just untried) — add
  `-device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0` to any `qemu-system-x86_64`
  invocation that needs `tools/qmp-click.py`.
- **Phase gating still applies**: no Phase 3 (service-layer/role-provisioning) work starts until
  Server 2025, Server 2022, *and* Windows 11 have each independently bootstrapped through Phase 2.
  Server 2025 is still the only one attempted so far, and Phase 2 itself is not yet working end to
  end even for Server 2025.

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
- **There is no `winpeshl.ini` on the stock Setup boot.wim at all** (confirmed via full-volume
  `find`) — `winpeshl.exe` falls back to a built-in default app list (`WallpaperHost.exe`, then
  `X:\$Windows.~BT\sources\setup.exe`, then `X:\setup.exe`), and `startnet.cmd`'s presence does
  **not** mean it runs in this boot flow (no evidence it ever does — see Finding 22). To control
  launch order deterministically, write your own `Windows\System32\winpeshl.ini` — verified syntax:
  `[LaunchApps]` entries run strictly sequentially, one app per line, each waited-on before the next
  starts (per Microsoft's own reference, fetched directly in Session 4, not just a search summary).
- **`EarlyF6DriverInstall`'s "Install driver to show hardware" gate is unconditional and has no known
  exit via UI interaction alone** (Findings 24-25) — it enters its wait state the instant Setup's
  disk-configuration phase begins, before any driver state is checked, and loops back to waiting
  after any driver action (success, failure, or duplicate-install error) with no timeout and no
  hidden "Next" button. Don't re-attempt "pre-load the driver a bit earlier/differently" expecting a
  different result — the timestamps rule this out structurally, not just empirically this one time.
- `setupact.log` actually lives at `X:\$WINDOWS.~BT\Sources\Panther\setupact.log` during a live
  Setup session — **not** `X:\Windows\Panther\setupact.log` (doesn't exist yet at this stage; there
  are four different `setupact.log` copies on `X:\`, and this is the one Setup actively writes to).
  `cd /d` into that directory first if typing the literal path via `qmp-type.py` — a `\$` sequence
  typed directly seems to lose the preceding backslash somehow (observed once, not root-caused;
  `cd /d` avoids the issue entirely rather than fighting it).
- `tools/qmp-sendkey.py` and `tools/qmp-type.py` drive a QEMU guest's GUI via QMP keyboard events —
  Tab/arrow-key navigation, typing literal text — no mouse, no VNC viewer. Still useful for
  keyboard-only interaction (opening `Shift+F10` command prompts, typing commands), but **Tab
  navigation does not reach every control** in Setup's driver-install dialog (it cycles through
  textbox → Browse → checkbox → Support → Legal → back to textbox, skipping the driver list and the
  Back/Install buttons entirely) — those need real mouse clicks.
- **New this session: `tools/qmp-click.py`** — QMP absolute-position mouse clicks (`--double` for
  double-clicks, used for folder-tree navigation in Setup's Browse dialog). Requires a `usb-tablet`
  device on the VM (see Process reminders above) — relative PS/2 mouse movement does not work in
  this environment at all, confirmed via direct calibration, not assumed.
- To pull a log or any small file out of a running WinPE/Setup session without a network share:
  open a command prompt with `Shift+F10` (`tools/qmp-sendkey.py ... shift-f10`), `copy` the file to
  the attached answer floppy, then read it directly from the host with `mcopy -i
  answer-floppy.img ::filename /host/path`. Still the most reliable way to get real diagnostic
  detail — much better than screen-scraping a scrolling console window.

---

## Housekeeping note

This directory **is** a git repository. Recent commits (as of end of Session 3) include
"Session 3: Setup.exe pivot confirmed working end-to-end, minus one automation gap" and "Add README
summarizing project status ahead of a pause in work" — both already committed, working tree was
clean at the start of Session 4. Session 4 has since modified `CLAUDE.md`, `PHASE2_ENGINEERING_LOG.md`,
and `START_PROMPT.md` (this file), plus added `tools/qmp-click.py` — none of this is committed yet
as of the end of Session 4. Ask before committing (or squashing into a single commit vs. several) —
don't assume either way, same standard as any other action with lasting effect. Given Session 3's
commit message ("...working end-to-end, minus one automation gap") turned out to be more optimistic
than Session 4's findings support, consider whether the new commit message should be explicit about
the walked-back status rather than reading as straightforward progress.
