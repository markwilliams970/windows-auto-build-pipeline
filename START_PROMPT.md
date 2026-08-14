This is a resumption prompt, not a fresh kickoff — this project has real history and real
in-progress investigation behind it. Read documents before doing or suggesting anything else, in
this order:

1. **`PHASE2_ENGINEERING_LOG.md` — read this first, especially its final section, "STATUS AND NEXT
   STEPS ON RESUMPTION (Session 5)."** This is the actual current state of the investigation: what's
   solved, what's not, what was tried and failed (with root causes where we found them), and the
   specific next action already agreed on. Don't skip this to save time — it exists precisely so
   nothing in it has to be re-derived, and re-deriving it has already burned full sessions before.
   **Session 5 closed out the cheaper of Session 4's two open tracks with a real negative result** —
   read the Session 5 section in full even if you remember Session 4's, don't skim on the assumption
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
   direction. **Its fallback path (real `bcdboot` from a self-built WinPE session) is looking more
   relevant again** now that four independent driver-load-gate fixes have failed inside Setup.exe.
4. `HANDOFF_FROM_UNATTENDED_INSTALL.md` — the original prior-art research (why this project exists,
   what the sibling project already solved vs. couldn't). Still accurate; nothing here has changed.
5. `PREREQUISITES.md` — host tooling this project needs beyond the sibling project. Already
   installed on this host; only relevant again if working from a different machine.

---

## Where things actually stand (updated end of Session 5)

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

**Four independent attempts to get past `EarlyF6DriverInstall`'s gate have now failed, each for a
different, well-evidenced reason — this is a real blocker, not a remaining automation gap:**

1. `Autounattend.xml`'s `DriverPaths` — doesn't feed the gate at all (Session 3, Finding 19).
2. Pre-loading the driver via a real, Microsoft-reference-verified `winpeshl.ini` before Setup
   starts — driver loads successfully (confirmed via `wmic`), but the gate shows anyway.
   `setupact.log` timestamps prove `EarlyF6DriverInstall`'s Execute method starts waiting for
   interactive input in the same second as Setup's own Prepare phase, unconditionally, before any
   user action could possibly matter (Session 4, Finding 24).
3. Manually clicking through the gate (mouse-driven, via a required `usb-tablet` device) — even a
   genuinely clean, error-free install loops right back to `Driver: Starting Wait` forever. No
   timeout (waited 60+ seconds), no hidden "Next" button, and the window's own close control pops a
   "quit Setup entirely" confirmation rather than dismissing just the sub-dialog (Session 4,
   Finding 25).
4. **`$WinPEDriver$`** (Microsoft KB 2686316's documented driver-autoload folder, scanned from
   `C:`/`D:`/`E:`/`X:` with zero `unattend.xml` config) — tested properly in Session 5 (Finding 27).
   Driver files were verified present at the exact documented location, `X:\$WinPEDriver$\viostor\
   2k25\amd64\{viostor.inf,viostor.cat,viostor.sys}` (confirmed via `dir /s` from inside the running
   session, not assumed). **The same empty dialog still appeared, and `setupact.log` shows zero
   `PnPIBS`/`$WinPEDriver$`-related log lines at all** — no evidence Setup ever scanned for the
   folder in this boot configuration. A genuine negative result, not a placement mistake.

**One real, useful side-finding from Session 5, independent of the main question:** `X:` during
this Setup boot flow is **the physical boot-medium NTFS partition itself** (confirmed via `wmic
logicaldisk` — `X:`, `Local Fixed Disk`, `NTFS`, volume label `Windows`), not a separate RAM-loaded
copy of `boot.wim`'s contents as this project had implicitly assumed since Session 4. Also: this
boot configuration has **no `C:` drive at all** — only `D:` (Server 2025 ISO), `E:` (virtio-win
ISO), `X:` (boot medium), `A:` (answer floppy).

**Net effect: there is currently no known path past Setup's disk-configuration step, automated or
manual, and the cheaper of the two remaining research leads is now also ruled out.** Only one
untried thread remains before this project should seriously reconsider the Setup.exe pivot itself.

---

## What to do first this session

1. Confirm you've read the engineering log's Session 5 resumption section in full (including
   Finding 27), then decide, together with whoever you're working with, whether to pursue the one
   remaining thread below or to pivot back to the bootstrap architecture's original fallback.
   **This is a real decision point** — four failed attempts is a meaningful signal, not just bad
   luck, and it's worth checking in before sinking a session into a bigger `Autounattend.xml`
   rewrite on a theory that hasn't been tested yet.
2. **The one remaining thread — the "modern screen" theory (bigger change, still unproven):**
   `EarlyF6DriverInstall` is Windows Setup's legacy "press F6 to load a mass-storage driver"
   mechanism. It may only be reachable because `Autounattend.xml`'s `DiskConfiguration`/
   `ImageInstall` sections drive Setup directly into automated disk configuration, skipping past the
   *modern* interactive "Where do you want to install Windows" screen — which has a different,
   non-legacy "Load driver" link never tested in this project. To test: rebuild `Autounattend.xml`
   to *not* fully automate disk configuration (or omit `DiskConfiguration` entirely), boot, see what
   screen Setup actually shows instead, and test whether *that* screen's driver-load mechanism
   actually lets Setup proceed once satisfied (unlike the legacy F6 dialog, which doesn't).
3. **If that also fails**, the honest conclusion is that the Setup.exe pivot itself needs
   reconsidering against `PHASE2_BOOTSTRAP_ARCHITECTURE.md`'s original fallback: sub-milestone 1
   (making the disk bootable) is already solved a different way — real `bcdboot` run from a
   self-built plain WinPE session (Findings 6/12), which boots clean with **no** driver-load-gate
   exposure at all, because it never invokes Setup.exe. Driver injection would then need solving on
   that path instead — possibly revisiting the `virt-v2v`/hivex approach applied to `boot.wim`
   specifically rather than the main OS disk it failed against in Findings 7-8 (WinPE's own boot
   code path differs from a full NT kernel boot, so the same failure mode may not recur), or the
   DISM COM-hosting failure from Findings 7-13 with newer tooling.
4. **Check what's ephemeral before assuming it's still there.** Everything under `/tmp/` from
   Session 5 is gone. Everything under this project's own `image-apply/output/` persisted:
   - `winpe-boot-index2.qcow2` — **now contains a `\$WinPEDriver$\viostor\2k25\amd64\` folder** at
     its NTFS partition root (Session 5, Finding 27), left in place — harmless, doesn't affect any
     other test. `winpeshl.ini` unchanged from Session 4's reverted-to-stock state
     (`%SYSTEMDRIVE%\setup.exe` only). `Autounattend.xml` still present at both its partition root
     and `\sources\`, unchanged.
   - `win2025-target.qcow2` — still blank/unpartitioned; Setup has never gotten far enough to touch
     it.
   - `answer-floppy.img` — unchanged, still has `Autounattend.xml` + `viostor/2k25/amd64/*`.
   - `OVMF_VARS_setup-test5.fd` — Session 5's fresh OVMF vars copy; same boot command shape as
     Session 4 (`usb-tablet`/`qemu-xhci` included).
   - No VM left running at the end of Session 5 (confirmed via `pgrep` before ending).

---

## Process reminders (still not optional)

- **Research first — search for existing tooling or a documented mechanism before building
  anything new, and do it before proposing the next experiment, not just before writing code.**
  See `CLAUDE.md`'s "Research-first discipline" section. This is exactly how BCD-SYS, the
  `virt-v2v` driver-injection pattern, Microsoft's own "Implicit Answer File Search
  Order"/`winpeshl.ini` reference documentation, and `$WinPEDriver$` were all found and used
  directly instead of guessed at — even though `$WinPEDriver$` itself ultimately didn't pan out
  (Finding 27), it was still the right thing to try first: cheap, well-documented, and its failure
  produced real evidence rather than burning a session on a bigger, unproven rewrite first.
- **Verify before trusting — this discipline directly overturned a settled-looking assumption
  again in Session 5.** Before concluding "$WinPEDriver$ doesn't work," Session 5 verified the
  driver files were actually present at the documented location from inside the running session
  (`dir /s`, not just trusting the host-side copy step) — which is also what surfaced the `X:` =
  physical-partition correction. Don't assume a BCD element ID, a hardware ID, a WIM image index,
  a drive-letter mapping, or a mechanism's behavior — decode a real reference, extract directly, or
  test it.
- **Give periodic status updates during long-running steps** (boot watches, `wimapply`, anything
  that takes more than a couple minutes) — don't go silent until the very end. This is a standing
  preference, not a one-off ask.
- **Work in small, verified steps and document as you go — including dead ends.** Finding 27
  (Session 5) is recorded in exactly the same detail as any success, for the same reason as always:
  re-treading the same ground is the actual cost this discipline avoids.
- **Any `qemu-nbd`-dependent sequence must run inside a single Bash tool call.** This sandbox does
  not reliably keep a backgrounded `qemu-nbd -c` process alive between separate tool invocations
  (Finding 16). A `qemu-system-x86_64 ... -daemonize` VM, by contrast, survives fine across many
  separate calls — the distinction observed so far is `-daemonize`'s real double-fork vs.
  `qemu-nbd`'s own backgrounding, treat as one data point worth staying alert to, not a
  fully-guaranteed rule. Also note: the mount point directory under `/tmp/win-build-mnt/` does not
  reliably survive between separate tool calls either (plain `/tmp` cleanup, not a qemu-nbd issue) —
  `mkdir -p` it fresh inside the same atomic sequence rather than assuming a prior session's
  mountpoint directory still exists.
- **A `usb-tablet` device is required for any mouse-driven UI automation.** Relative PS/2 mouse
  input does not produce visible cursor movement in this WinPE/Setup environment this early in boot
  (confirmed, not just untried) — add
  `-device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0` to any `qemu-system-x86_64`
  invocation that needs `tools/qmp-click.py`.
- **`tools/qmp-type.py` cannot type `&`** (no `CHAR_MAP` entry, confirmed by hitting it directly in
  Session 5) — avoid `2>&1`-style redirection in any command typed via this tool; run separate `dir`
  invocations per target instead, or extend `CHAR_MAP` if this becomes a recurring blocker.
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
  starts (per Microsoft's own reference, fetched directly).
- **`X:` in this Setup boot flow is the physical boot-medium NTFS partition itself**, not a
  separate RAM-disk copy of `boot.wim`'s contents (Session 5, Finding 27 — confirmed via `wmic
  logicaldisk`). Any file placed on the mounted `winpe-boot-index2.qcow2` NTFS partition is directly
  visible as `X:\...` inside the running session. This boot configuration has **no `C:` drive at
  all** — only `D:` (Server 2025 ISO), `E:` (virtio-win ISO), `X:` (boot medium), `A:` (answer
  floppy).
- **`EarlyF6DriverInstall`'s "Install driver to show hardware" gate is unconditional and has no known
  exit via UI interaction, pre-loading, or `$WinPEDriver$`** (Findings 24, 25, 27) — it enters its
  wait state the instant Setup's disk-configuration phase begins, before any driver state is
  checked, loops back to waiting after any driver action (success, failure, or duplicate-install
  error) with no timeout and no hidden "Next" button, and shows no evidence of ever scanning
  `$WinPEDriver$` in `setupact.log`. Don't re-attempt any of these four approaches expecting a
  different result on a retry — the evidence rules them out structurally, not just empirically this
  one time.
- `setupact.log` actually lives at `X:\$WINDOWS.~BT\Sources\Panther\setupact.log` during a live
  Setup session — **not** `X:\Windows\Panther\setupact.log` (doesn't exist yet at this stage; there
  are four different `setupact.log` copies on `X:\`, and this is the one Setup actively writes to).
  `cd /d` into that directory first if typing the literal path via `qmp-type.py` — a `\$` sequence
  typed directly seems to lose the preceding backslash somehow (observed once, not root-caused;
  `cd /d` avoids the issue entirely rather than fighting it).
- `tools/qmp-sendkey.py` and `tools/qmp-type.py` drive a QEMU guest's GUI via QMP keyboard events —
  Tab/arrow-key navigation, typing literal text — no mouse, no VNC viewer. **`qmp-type.py` has no
  `CHAR_MAP` entry for `&`** (hit directly in Session 5) — avoid typing `&`-containing command
  strings (e.g. `2>&1`) through it. Tab navigation also does not reach every control in Setup's
  driver-install dialog (it cycles through textbox → Browse → checkbox → Support → Legal → back to
  textbox, skipping the driver list and the Back/Install buttons entirely) — those need real mouse
  clicks.
- **`tools/qmp-click.py`** — QMP absolute-position mouse clicks (`--double` for double-clicks, used
  for folder-tree navigation in Setup's Browse dialog). Requires a `usb-tablet` device on the VM
  (see Process reminders above) — relative PS/2 mouse movement does not work in this environment at
  all, confirmed via direct calibration, not assumed.
- To pull a log or any small file out of a running WinPE/Setup session without a network share:
  open a command prompt with `Shift+F10` (`tools/qmp-sendkey.py ... shift-f10`), `copy` the file to
  the attached answer floppy, then read it directly from the host with `mcopy -i
  answer-floppy.img ::filename /host/path`. Files redirected via `dir ... > A:\file.txt` come back
  UTF-16-encoded (not the UTF-16LE-with-ASCII-spacing you might expect from older `cmd.exe` —
  decode with Python's `bytes.decode('utf-16-be')` if `utf-16-le`/plain `utf-16` look garbled; check
  both). Still the most reliable way to get real diagnostic detail — much better than screen-scraping
  a scrolling console window.

---

## Housekeeping note

This directory **is** a git repository. Check `git status`/`git log` fresh at the start of this
session rather than trusting any note here about what was committed — this file describes state as
of when it was last edited, not necessarily the true current state. As of Session 5 being written,
`PHASE2_ENGINEERING_LOG.md`, `README.md`, `CLAUDE.md`, and this file have all been updated to
reflect Finding 27 but **not yet committed** — that's expected to happen as a normal end-of-session
commit, not evidence of anything unusual. Still ask before committing *new* changes (or squashing
vs. several commits).

**No VM was left running at the end of Session 5** (confirmed via `pgrep -fa qemu-system-x86_64`
before ending). `winpe-boot-index2.qcow2` carries a harmless `$WinPEDriver$` folder addition (see
above); `win2025-target.qcow2` is still blank.
