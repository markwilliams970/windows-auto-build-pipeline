# Phase 2 Engineering Log: First BCD-SYS Experiment (Windows Server 2025)

Status as of this writing: **Phase 2 sub-milestone 1 (make the disk bootable) is confirmed working**
for Windows Server 2025 via BCD-SYS, with zero WinPE boot cycles and zero exposure to the
sibling project's "press any key" UEFI landmine. The disk fails at `INACCESSIBLE_BOOT_DEVICE
(0x7B)` on real boot because the boot-critical VirtIO storage driver isn't registered yet.
Session 2's DISM-in-WinPE and offline-registry attempts at fixing that both failed; **Session 3
picked up the Finding 15 pivot (reuse Setup.exe's own driver-injection mechanism instead of
hand-rolling it) and confirmed its core premise: `boot.wim` index 2, booted as a plain disk,
launches Setup.exe automatically and reaches its real GUI, no landmine of any kind (Finding 18)**.
Session 3 then attached a real target disk and confirmed the viostor driver, hardware ID, and
disk-attachment architecture all work perfectly (Finding 20 — `wmic diskdrive` shows the 40GB
target disk healthy once the driver loads) — but found that autounattend.xml's `DriverPaths`
doesn't automatically feed the specific gate that needs it (Finding 19), with a concrete,
not-yet-attempted fix lined up (Finding 21: `drvload` from our own `startnet.cmd` before Setup
even launches, reusing Finding 12's already-proven technique). See
`PHASE2_BOOTSTRAP_ARCHITECTURE.md` for the design reasoning that predicted the BCD-SYS approach and
`CLAUDE.md` for current phase status.

This log follows the sibling project's engineering-log convention: symptom, diagnosis, root cause,
fix, in the order they were actually hit, including the dead ends.

---

## Setup summary (context for the findings below)

- Target: Windows Server 2025 Evaluation, `iso_cache/2025-26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso`
  (reused from the sibling project's cache, unchanged).
- Disk: fresh 64GB qcow2, GPT layout via `sgdisk` — 100MiB ESP (`ef00`), 16MiB MSR (`0c01`),
  remainder Windows partition (`0700`) — matching Microsoft's own documented manufacturing layout.
- `qemu-nbd` to expose the qcow2 as `/dev/nbd0` for partitioning/formatting/mounting directly from
  this Linux host.
- WIM applied via `wimlib-imagex apply ... 2 <mountpoint>` (index 2 — see Finding 0 below for why
  that index, verified directly rather than assumed).
- Bootability via BCD-SYS (`tools/vendor/BCD-SYS`, vendored via `git clone`), invoked as
  `./bcd-sys.sh <ntfs-mountpoint> -s <esp-mountpoint> -f uefi -v` — see Findings 1-5.
- Boot test: `qemu-system-x86_64`, `q35` machine, `OVMF_CODE_4M.fd`/fresh `OVMF_VARS_4M.fd`
  (Secure Boot deliberately disabled), `virtio-blk-pci` disk, watched via `tools/qmp-screenshot.py`
  (QMP `screendump`) rather than a VNC viewer — no driver injection (Stage 2) performed yet.

---

## Finding 0: Windows Server 2025's WIM image index was never actually verified — only assumed

**Symptom:** `CLAUDE.md`'s "Starting point" section claimed "the iso_cache/ entry, checksum, and
WIM image-name investigation for it already exist in the sibling project and can be reused
directly." This is only true for the ISO cache entry and checksum.

**Diagnosis:** The sibling project's own engineering log (`WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`,
Finding 5's reference table) documents a 4-image WIM index table, but it's explicitly for
**Windows Server 2022** — Server 2025 never got far enough in the old interactive-Setup pipeline
to need or extract this information (blocked at the UEFI boot-key issue before ever reaching image
selection).

**Root cause:** A stale/inaccurate claim in `CLAUDE.md`, not caught until this session actually
needed the real 2025 data.

**Fix:** Extracted directly via `wimlib-imagex info install.wim` against the real 2025 ISO
(`7z e ... sources/install.wim`, ~7.25GB), per the project's own "verify by direct extraction"
standard:

| Index | `<NAME>` | `<EDITIONID>` | Installation Type |
|---|---|---|---|
| 1 | Windows Server 2025 SERVERSTANDARDCORE | ServerStandardEval | Server Core |
| 2 | Windows Server 2025 SERVERSTANDARD | ServerStandardEval | Server (Desktop Experience) |
| 3 | Windows Server 2025 SERVERDATACENTERCORE | ServerDatacenterEval | Server Core |
| 4 | Windows Server 2025 SERVERDATACENTER | ServerDatacenterEval | Server (Desktop Experience) |

Confirmed eval channel via `sources/EI.CFG` (`[Channel]=eval`, `[VL]=0`), same pattern as 2022.
Index 2 (Standard, Desktop Experience) was used for this experiment, matching the sibling
project's own convention for 2022.

**Aside — `wimlib-imagex info` beats the sibling project's old `strings -el | grep EDITIONID`
technique.** Now that `wimlib` is actually installed (it wasn't needed as a Linux-native tool in
the interactive-Setup pipeline), its own `info` subcommand gives complete, structured metadata
directly — no `7z`/`strings` archaeology required. Worth using this going forward for any future
WIM inspection in this project.

---

## Finding 1: BCD-SYS must be invoked with its own script directory as CWD, not the repo root

**Symptom:** `./Linux/bcd-sys.sh --help` run from the BCD-SYS repo root failed with
`cat: ./Resources/help-page.txt: No such file or directory`. Running instead as
`cd BCD-SYS && ./Linux/bcd-sys.sh ...` got further but failed differently:
`./Linux/bcd-sys.sh: line 105: ./winload.sh: No such file or directory`.

**Diagnosis:** `bcd-sys.sh` has an internal `resdir="."` variable. `setup.sh` (BCD-SYS's real
installer) rewrites this via `perl -i -pe` to point at an installed, flattened location
(`/usr/local/share/BCD-SYS`, containing `Resources/`, `Templates/`, and the sibling scripts
`winload.sh`/`recovery.sh`/etc. all side by side) when properly installed. Run uninstalled from a
git clone, `resdir` stays literally `.` — meaning it needs `./Resources/...` **and** `./winload.sh`
to both resolve from the *same* current directory, which only happens if CWD is the `Linux/`
subdirectory itself (where the sibling scripts already live) **and** `Resources`/`Templates`
(siblings of `Linux/` at the repo root, not inside it) are symlinked in. The script actually has
self-healing logic for exactly this (`ln -s ../Resources && ln -s ../Templates`, guarded by
`if [[ ! -d "$resdir/Resources" && ! -d "$resdir/Templates" ]]`) — but that logic only fires
correctly when CWD is already `Linux/`, and it's defined later in the file than the first place
`./winload.sh` gets called, so the CWD has to be right from the start, not fixed up mid-run.

**Root cause:** Vendoring the raw git clone doesn't match either of the two invocation styles
BCD-SYS's own code assumes (installed-via-`setup.sh`, or run with CWD literally inside its own
`Linux/` directory). No bug in BCD-SYS itself for its own intended usage — just a gap between "git
clone it" and "the only two ways it actually expects to be run."

**Fix:** Always invoke as:
```
cd tools/vendor/BCD-SYS/Linux
./bcd-sys.sh <windows-mountpoint> -s <esp-mountpoint> -f uefi -v
```
not `./Linux/bcd-sys.sh ...` from the repo root. The self-healing symlinks (`Linux/Resources`,
`Linux/Templates`) get created automatically on first correct-CWD run and persist for later runs.

---

## Finding 2: `mkntfs` needs explicit geometry or the resulting partition won't be boot-correct

**Symptom:** `mkntfs -Q -F -L Windows /dev/nbd0p3` (no other flags) completed but printed:
```
The partition start sector was not specified for /dev/nbd0p3 and it could not be obtained automatically. It has been set to 0.
...
Windows will not be able to boot from this device.
```

**Diagnosis:** `mkntfs` normally auto-detects partition start sector / sectors-per-track / heads
from the block device's own kernel-exposed geometry to populate the NTFS boot sector's BPB
(BIOS Parameter Block) correctly. `qemu-nbd`-attached partition sub-devices (`/dev/nbd0p3`) don't
expose this the same way a real disk or `/dev/sdaN`-style partition does, so auto-detection came
back empty.

**Root cause:** A real gap in how kernel `nbd` partition devices report geometry via the ioctls
`mkntfs` uses — not a wimlib/BCD-SYS/project-specific bug, but definitely project-specific enough
to bite anyone doing offline NTFS formatting against an nbd-backed device.

**Fix:** Supply the values explicitly. Partition start sector is already known from the `sgdisk`
output that created the layout (in this run, `239616` for the Windows partition); heads/sectors-
per-track use the conventional `255`/`63` LBA-translation defaults nearly universal for
non-CHS-addressed large disks:
```
mkntfs -Q -F -L Windows -p 239616 -H 255 -S 63 /dev/nbd0p3
```
No warning on the reformat, and (confirmed later) the resulting partition booted correctly under
OVMF.

---

## Finding 3: sudo scoping had to be discovered empirically — guessed commands didn't match reality

**Symptom:** The first sudoers drop-in (scoped `NOPASSWD` rules for the disk-prep tooling this
project was expected to need — `qemu-nbd`, `sgdisk`, `mkfs.vfat`/`mkntfs`, `mount`/`umount`,
`modprobe nbd`) covered every command *this project's own scripts* would run directly, but BCD-SYS
itself shells out to several more commands internally that weren't anticipated: `sfdisk -l`
(not `sgdisk -p`, as guessed) to check partition scheme, and later `sfdisk -o Device,UUID -l` (a
different flag shape) inside its `update_device.sh` helper to compute the BCD device locator.

**Diagnosis:** Scoping sudo access *before* actually running the tool meant guessing its internal
implementation rather than observing it. `sfdisk`, not `sgdisk`, turned out to be BCD-SYS's own
tool of choice for reading partition-table metadata — an implementation detail invisible from its
CLI/README alone.

**Root cause:** Reasonable but incomplete upfront scoping; the actual internal command surface of a
third-party tool can only be fully known by reading its source or exercising every code path.

**Fix:** Traced `bcd-sys.sh`'s actual `sudo` call sites directly (`grep -n sudo`) for the exact
invocation shape this project uses (non-virtual source, `-s` syspath, `-f uefi`), rather than
guessing again, and added exactly the two missing rules as they were hit:
```
markw ALL=(root) NOPASSWD: /usr/sbin/sfdisk -l /dev/nbd[0-9]*
markw ALL=(root) NOPASSWD: /usr/sbin/sfdisk -o * -l /dev/nbd[0-9]*
```
Both are read-only listing invocations (`sfdisk` only mutates a partition table when fed a script
on stdin, never in `-l` mode), so widening to cover the `-o <columns>` variant doesn't meaningfully
change the security posture of the original rule. See `tools/sudoers-windows-auto-build-pipeline`
for the full, currently-installed rule set and its scope-note commentary.

**General lesson for this project going forward:** expect any vendored third-party tool's actual
sudo/root footprint to need at least one empirical correction pass beyond what its docs describe.
Scope conservatively up front, then widen narrowly and only in response to a real, traced failure
— never widen speculatively "just in case."

---

## Finding 4: BCD-SYS attempts real UEFI NVRAM writes regardless of `--syspath`, but the scoped-sudo design caught it

**Symptom:** Several `sudo: a terminal is required to read the password` failures during a run,
not attributable to any `sfdisk` call.

**Diagnosis:** BCD-SYS's own `--help` text states firmware/NVRAM interaction is skipped "except
when using the --syspath option." Reading the actual source (`bcd-sys.sh` lines ~705-835)
shows this isn't quite true: `get_wbmoption`/`efibootmgr -c -d ... -L "Windows Boot Manager"` calls
run whenever `command -v efibootmgr` succeeds, independent of `--syspath`. Since `efibootmgr` only
ever talks to the *currently running kernel's own live UEFI firmware* (via `/sys/firmware/efi/efivars`)
— there is no way to target a different, not-yet-booted machine's future firmware — these calls, if
they had succeeded, would have written a real, persistent "Windows Boot Manager" boot entry into
**this development host's own actual UEFI NVRAM**, not the disk image being built.

**Root cause:** `--syspath`'s documented behavior is incomplete for this specific code path. Not a
security bug in BCD-SYS (it's designed for its more common use case: setting up dual-boot on the
same live machine whose firmware it's meant to modify) — just a mismatch with this project's
different use case (preparing a disk image for a VM that doesn't exist yet, on a host whose own
real firmware must never be touched by this process).

**Fix, and why it's a fix rather than a gap:** `efibootmgr` was **deliberately never added** to the
sudoers allowlist. Every one of these calls failed at the `sudo` authentication step — before
`efibootmgr` itself ever ran — because no NOPASSWD rule matched and no interactive terminal was
available to prompt for a password. Confirmed directly (`sudo -n efibootmgr` still requires a
password) that this host's real UEFI boot entries were never touched. The scoped-NOPASSWD design
(deny by default, allow only what's explicitly listed) caught an unintended side effect that a
broader "just make sudo work" grant would not have. **This should remain a permanent exclusion,
not a TODO** — the disk still boots correctly via the `/EFI/BOOT/BOOTX64.efi` default-fallback
path (see Finding 5), which is exactly the path a fresh/blank OVMF VARS file uses anyway, making a
real NVRAM entry unnecessary for this project's purposes regardless.

---

## Finding 5: the actual root cause of the first failed boot — `sfdisk -o Device,UUID` silently failing corrupted the BCD's device locator

**Symptom:** First clean, no-error BCD-SYS run (`Finished configuring UEFI boot files.`, no
reported failures) produced a disk that, on boot, showed Windows Boot Manager's own **Recovery**
screen: *"The Boot Configuration Data file is missing some required information. File: \BCD Error
code: 0xc0000024."* This is a real Windows Boot Manager error screen, not a firmware failure —
`bootmgfw.efi` itself loaded and parsed the BCD far enough to identify a specific content problem.

**Diagnosis, via community research before manual hex debugging** (per this project's
research-first standard): searched BCD-SYS's own GitHub issues for this exact symptom before
reverse-engineering the BCD hive by hand. [Issue #4](https://github.com/jpz4085/BCD-SYS/issues/4)
("BCD Error - Windows Failed to Start") is an extensively-documented thread where the maintainer
traced an identical class of failure to the BCD's `Elements\11000001` ("Application Device")
element containing wrong or missing disk/partition GUIDs, and documented the exact 88-byte format:
a 16-byte partition GUID, a 1-byte scheme identifier (`00`=GPT/`01`=MBR), and a 16-byte disk GUID,
GUIDs stored in mixed-endian order (first 8 bytes little-endian, last 8 bytes big-endian).

Cross-referencing this against **Finding 3**: `update_device.sh` (the helper BCD-SYS uses to
compute this exact element) calls `sudo sfdisk -o Device,UUID -l $disk` to read the real partition
GUID — a call that, at the time of the first "successful" run, did not yet match any sudoers rule
(Finding 3's fix came later) and was failing silently, almost certainly leaving the GUID fields
empty or malformed.

**Root cause:** Confirmed, not just inferred — after applying Finding 3's broadened `sfdisk -o *`
rule and re-running BCD-SYS cleanly, the BCD's device-locator bytes were extracted
(`hivexregedit --export ... 'Objects\{loader-guid}\Elements\11000001'`) and decoded by hand against
the documented format:

```
Element bytes: 7e,04,8a,04,e4,1e,8e,43,b1,fd,94,34,dc,a3,b7,c0 (partition, mixed-endian)
            -> decodes to 048A047E-1EE4-438E-B1FD-9434DCA3B7C0

Element bytes: 61,40,c4,1e,a6,be,d5,4c,b3,bd,53,4e,cb,c3,c6,ec (disk, mixed-endian)
            -> decodes to 1EC44061-BEA6-4CD5-B3BD-534ECBC3C6EC
```

Both match `sfdisk -o Device,UUID -l /dev/nbd0`'s real output for the Windows partition and disk
**exactly**. Before the sudoers fix, this same extraction would have been reading whatever
`update_device.sh` produced from a failed/empty `sfdisk` call — the concrete, confirmed root cause
of the `0xc0000024` error.

**Fix:** Finding 3's sudoers broadening was the actual fix; this finding is the confirmation that
it fixed *this specific* problem, done by decoding real bytes against a documented format rather
than assuming the fix worked because the script's own exit code looked clean. The BCD-SYS
maintainer's advice from the same issue thread is worth keeping in mind for any future BCD
weirdness: *"should your script check to ensure a proper file was made?"* — BCD-SYS does now (added
after that issue), but this project's own wrapper tooling should eventually add its own
verification step here too rather than trusting a clean exit code alone, given how easy it was for
a silent sub-command failure to produce a "successful"-looking run with a broken artifact.

---

## Finding 6 (confirmation): BCD-SYS is validated end-to-end as this project's bootability mechanism

**After Finding 5's fix**, rebuilt the ESP fresh and re-ran BCD-SYS once cleanly, then booted the
disk under `qemu-system-x86_64` (`q35`, `OVMF_CODE_4M.fd` + fresh `OVMF_VARS_4M.fd`, Secure Boot
disabled, `virtio-blk-pci` disk), watched via `tools/qmp-screenshot.py`:

1. OVMF's own TianoCore splash, then a small loading spinner — **confirmed as Windows Boot
   Manager's own animation, not firmware** — appeared with no boot-key prompt of any kind.
2. Boot proceeded to `INACCESSIBLE_BOOT_DEVICE (0x7B)` — the expected result, since Stage 2
   (offline VirtIO driver injection) has not been attempted yet in this experiment. `winload.efi`
   successfully loaded the kernel and attempted to mount the boot volume; the failure is
   specifically about the storage driver not being registered, not about the boot chain up to that
   point.

**This confirms Phase 2 sub-milestone 1** (`CLAUDE.md`'s "make the disk bootable" success
criterion) **for Windows Server 2025, via BCD-SYS, with zero WinPE boot cycles required** — the
project's single biggest open technical question, resolved. The `PHASE2_BOOTSTRAP_ARCHITECTURE.md`
recommendation to attempt BCD-SYS before the WinPE fallback is now empirically validated, not just
theoretically argued.

---

## Open items carried forward to the next session

1. **Stage 2 (offline VirtIO driver injection via `hivex`, following the `virt-v2v` pattern) is the
   immediate next step** — needed to clear the `0x7B` and reach a real WinRM-reachable boot.
2. **Repeat this entire validated sequence for Windows Server 2022 and Windows 11 Enterprise
   Evaluation** before any Phase 3 work starts, per the explicit phase-gating decision already
   recorded in `CLAUDE.md` and memory — Server 2025 was the first proving ground, not the only
   target that needs to work.
3. **`hivexregedit` is a separate package from `hivexsh`** — `libhivex-bin` provides
   `hivexsh`/`hivexget`/`hivexml` only; `hivexregedit` comes from `libwin-hivex-perl`. Easy to miss
   (already documented in `PREREQUISITES.md`).
4. **BCD-SYS's own preflight needs `fatattr` and `pev`/`readpe` (for `peres`)**, described as
   "optional" in its docs but required in practice for even `--help` to run without erroring
   (already documented in `PREREQUISITES.md`).
5. **Consider adding BCD-SYS artifact verification** (decode/sanity-check the device-locator GUIDs
   automatically) as a wrapper step in this project's own tooling, rather than trusting a clean
   `bcd-sys.sh` exit code alone — Finding 5 showed a "successful" run can still produce a broken
   BCD if an internal sub-command silently fails.
6. **`wimapply` takes ~14-15 minutes wall clock for a Desktop Experience image**, dominated by
   `ntfs-3g` FUSE I/O rather than CPU (only ~4 min combined `user`+`sys` time) — an inherent,
   accepted cost of this architecture (see conversation record; comparable in order of magnitude to
   the old interactive installer's own ~18 minute install time, not a regression).

---

## Session 2: Driver injection deep-dive — two offline attempts, a pivot to WinPE+DISM, a DISM
## architectural dead end, and a promising unexplored path. Paused mid-investigation.

This whole session was spent on Stage 2 (clear the `0x7B`). It went considerably deeper than
expected — documenting all of it in detail, including what didn't work and why, so none of this
has to be re-derived on resumption.

### Finding 7: First offline attempt — `CriticalDeviceDatabase` registration (virt-v2v's own
fallback path) did not clear `0x7B`

**What was done:** Found and read virt-v2v's actual source
(`libguestfs/libguestfs-common`'s `mlcustomize/inject_virtio_win.ml`, function
`add_guestor_to_registry`/`cdb_regedits`) rather than guessing at the registry format. Confirmed via
`query-pci` (QMP) that our virtio-blk-pci device really does present `VEN_1AF4&DEV_1001` (the
legacy/transitional ID), ruling out a hardware-ID mismatch. Built the exact CDB entries
(`ControlSet001\Control\CriticalDeviceDatabase\PCI#VEN_1AF4&DEV_1001&REV_00` and the modern
`&DEV_1042&REV_01` variant, each with `Service`/`ClassGUID`) plus the matching
`ControlSet001\Services\viostor` key (Type=1, Start=0, Group="SCSI miniport", ErrorControl=1,
ImagePath), merged via `hivexregedit --merge`. Rebooted the target disk alone (virtio-blk-pci,
fresh OVMF VARS).

**Result:** Identical `INACCESSIBLE_BOOT_DEVICE (0x7B)`. No error was raised by `hivexregedit`
itself — the merge appeared clean.

**Why this was expected to possibly not work, in hindsight:** virt-v2v's own code only takes the
CDB branch when a `DriverDatabase` node doesn't already exist under `Control` — a check meant to
distinguish "old Windows that never had DriverDatabase" from something else, but which can't
actually distinguish that from "modern Windows whose DriverDatabase just hasn't been populated
yet because it's never booted" (exactly our case). A well-known Windows kernel driver expert
(Maxim S. Shatskih, OSR NTDEV forum) independently confirmed DriverDatabase "replaces" CDB on
modern Windows. This pointed at Finding 8.

### Finding 8: Second offline attempt — added `DriverDatabase` registration on top of CDB — also
did not clear `0x7B`

**What was done:** Extracted the complete `DriverDatabase` registration recipe from the same
virt-v2v source (`ddb_regedits`): `DriverDatabase\DriverInfFiles\guestor.inf` (a placeholder label,
not a real filename — internal bookkeeping only), `DriverDatabase\DeviceIds\PCI\<pciid>` (value
name = the placeholder inf label, `REG_BINARY 01,ff,00,00`), `DriverDatabase\DriverPackages\<label>`
(a specific 48-byte `Version` blob whose middle 16 bytes are literally the SCSIAdapter class GUID
in raw mixed-endian form), plus `Configurations`/`Descriptors` subkeys tying it all together. Built
and merged all of this (both legacy and modern PCI ID variants) on top of the existing CDB entries
and `Tag=0x40` (added per the original 2010 blog post virt-v2v's own code comment cites, which
virt-v2v's own reproduction had omitted).

**Result:** Rebooted — **byte-for-byte identical `0x7B` screen** (confirmed via matching MD5 hash
of the QMP screenshot against the Finding 7 attempt). Whatever's wrong, adding DriverDatabase on
top of CDB didn't change the outcome at all.

**Root cause: never determined.** This is the single biggest open thread from the whole session.
Unlike every other finding in this log, this one has no confirmed diagnosis — there's no
equivalent of a boot-time `dism.log` for a kernel boot failure, so we don't actually know why two
technically-correct-looking (byte-verified against virt-v2v's real production code) registrations
both failed identically. Candidate theories, none confirmed:
- Something else entirely is required beyond what virt-v2v's minimal recipe provides (an unrelated
  OSR forum thread, about a different DriverDatabase problem, mentioned real driver packages also
  have `Strings`/fuller `Descriptors` subkeys that virt-v2v's own minimal reproduction omits —
  never checked against a real, working reference).
- virt-v2v's recipe may only be validated in practice against Windows guests whose
  `DriverDatabase` was already non-empty (i.e., always takes the DDB branch in real usage, never
  actually field-tested via the CDB branch on a modern OS) — meaning **neither** mechanism may
  actually be exercised/proven for a never-booted image, regardless of which one virt-v2v's code
  picks.
- Something unrelated to CDB-vs-DDB entirely (wrong assumption about which `ControlSet00N` matters
  at the point of failure, a completely different boot-critical gate, etc.) — genuinely unknown.

**This is exactly why the session pivoted to trying to get a real, Microsoft-tool-driven answer
(DISM, then kernel debugging) instead of continuing to guess at registry content a third time.**

### Finding 9: Reconsidered whether BCD-SYS (and offline registry hacking generally) was still the
right approach at all, given WinPE now seems unavoidable

Once driver injection looked like it might genuinely need a real Windows/WinPE environment (DISM,
or at minimum a real diagnostic), the question became: if WinPE is unavoidable for *that*, is it
still worth keeping BCD-SYS for bootability specifically, or should the whole pipeline consolidate
on real Microsoft tooling (`bcdboot` + `DISM`) run from one WinPE session? Decision: **yes,
consolidate** — BCD-SYS's core value proposition ("eliminate WinPE entirely") stops being realized
once WinPE is needed anyway for drivers, and official tooling beats a reverse-engineered
approximation once you're paying for a WinPE boot either way. This is *not* a rejection of
BCD-SYS's own correctness (it's still fully validated, see Session 1 above) — it's a "given the
constraint changed, simplify" call. **BCD-SYS is not being deleted or un-recommended** — if the
new architecture below doesn't pan out, BCD-SYS remains a fully proven fallback for bootability
specifically.

### Finding 10: First WinPE boot-medium attempt — copying the ISO's own ramdisk-boot BCD verbatim
failed with `0xc000000f`

**What was done:** Extracted `efi/` + `sources/boot.wim` from the Server 2025 ISO, copied them
onto a plain FAT32-formatted disk (not `media=cdrom`) — i.e., reused Microsoft's own pre-built
`efi/microsoft/boot/bcd` (which correctly boots `boot.wim` as a RAMDISK-mounted OS on the real
install medium) completely as-is.

**Symptom:** Windows Boot Manager itself loaded fine (**confirming, for the first time in this
project, that a self-built WinPE-style boot medium attached as a plain disk does NOT hit the
"press any key" UEFI landmine** — the project's original central risk, resolved) — but then showed
`Status: 0xc000000f`, `"A required device isn't connected or can't be accessed."`

**Root cause, confirmed by directly decoding the ISO's own BCD** (`hivexregedit --export` +
manual byte decoding, same technique already validated in Finding 5): the OS loader entry's
`device`/`osdevice` elements (`11000001`/`21000001`, element type "ramdisk", not a plain
partition locator) reference a **separate "ramdisk options" object** (`{7619dcc8-...}`, BCD type
`0x30000000`) which itself contains an `RAMDISK_SDIDEVICE` + `RAMDISK_SDIPATH` (`\boot\boot.sdi`)
pair — encoding the *original ISO's own* disk/partition identity. Copying this BCD verbatim onto a
newly-created disk carries over stale device references, the exact same *class* of bug as
Finding 5, just in a structurally different (ramdisk, not plain-partition) BCD element.

**Fix (architectural, not a byte patch):** rather than patch the ramdisk BCD's GUIDs, treat
`boot.wim` as just another Windows NT image and **`wimapply` it to a real NTFS partition**, then
run **BCD-SYS** against it exactly like the main OS disk — completely sidesteps ramdisk-BCD
fragility by reusing the same proven, disk-resident-boot mechanism twice.

### Finding 11: WinPE via `wimapply` + BCD-SYS worked — but needed one extra ingredient: the
"WinPE mode" BCD flags, decoded from a real reference rather than guessed

**What was done:** Partitioned/formatted a second qcow2 (same GPT layout as the main disk: 100M
ESP / 16M MSR / rest NTFS), `wimapply`'d `boot.wim` **index 1** ("Microsoft Windows PE (amd64)") to
the NTFS partition, ran BCD-SYS against it exactly like the main disk (worked cleanly, no errors).

**Problem anticipated in advance:** BCD-SYS has zero awareness of WinPE-specific boot requirements
— confirmed by grepping its source for "winpe" (no matches). A normal Windows boot entry, even a
structurally-correct one, won't make the NT kernel run in "WinPE mode" (session manager launching
`winpeshl.exe`/`startnet.cmd` instead of a normal user logon) without a specific BCD marker.

**How the exact marker was found — empirically, not from memory:** rather than trust an
uncertain recollection of "the WinPE BCD element is `0x16000049`" (which a web search couldn't
confirm confidently either), the ISO's own **real, working** `efi/microsoft/boot/bcd` was decoded
directly (same `hivexregedit --export` + manual byte-format technique as Finding 5/10). The OS
loader entry there (`{7619dcc9-...}`) has three boolean elements all set `true`:
`26000010`, `26000022`, `260000b0`. Not knowing with certainty which *one* is load-bearing, all
three were replicated onto BCD-SYS's newly-created loader entry via a small `hivexregedit --merge`
patch (`Objects\<loader-guid>\Elements\<id>` → `hex:01` for each) — cheap, safe insurance rather
than a guess.

**Also confirmed empirically (not assumed):** BCD-SYS's `winload.sh` hardcodes the OS-loader path
as `\Windows\system32\winload.efi` (verified via `grep`), which does *not* match the path used in
the ISO's own reference BCD (`\windows\system32\boot\winload.efi`). Checked whether this would be a
problem by comparing the two files inside the applied WinPE image directly:
**identical (matching MD5, and actually hard-linked — same inode)**. So BCD-SYS's hardcoded
assumption happens to still work for WinPE without any patch needed. Lucky, but verified, not
assumed.

**Result: WinPE booted successfully.** First real, working, self-built WinPE-as-plain-disk boot in
this entire project. `startnet.cmd` (customized — see Finding 12) ran automatically, confirming
the BCD flags were both necessary and sufficient.

### Finding 12: Within working WinPE — `drvload` and `bcdboot` both work correctly; `DISM` does not

Customized `boot.wim`'s `Windows\System32\startnet.cmd` (mounted read-write via
`wimlib-imagex mountrw` on Linux, edited, recommitted, before ever booting — the whole
customization happens offline, no interactivity needed at boot) to run, unattended:

```
wpeinit
drvload %SystemDrive%\drivers\viostor\viostor.inf
diskpart /s %SystemDrive%\diskpart-assign.txt      (assigns S:=target ESP, W:=target Windows partition)
Dism /Image:W:\ /Add-Driver /Driver:...\viostor.inf [/ForceUnsigned]
bcdboot W:\Windows /s S: /f UEFI
copy the resulting logs to the persistent target disk (W:\), since X:\ is an ephemeral RAM disk
wpeutil shutdown
```

Driver files were baked directly into `boot.wim` itself (under a fixed `\drivers\viostor\` path)
rather than relying on the boot medium's own uncertain drive-letter assignment — referenced in the
script via `%SystemDrive%`, which always resolves correctly to WinPE's own boot volume regardless
of ramdisk-vs-disk-resident boot or drive-letter assignment order.

**Results, per component:**
- `drvload`: **succeeded** — `"DrvLoad: Successfully loaded X:\drivers\viostor\viostor.inf."`
  confirmed on screen.
- `diskpart`: **succeeded** — correctly assigned `S:`/`W:` to the target disk's ESP/Windows
  partitions (`select disk 1` correctly picked the second, virtio-blk-attached disk; disk 0 was
  WinPE's own AHCI-attached boot disk).
- `bcdboot W:\Windows /s S: /f UEFI`: **succeeded, exit 0**, `"Boot files successfully created."`
  Confirmed by direct inspection of the target ESP afterward. **This means the pipeline now has a
  real, Microsoft-tool-built BCD for the main OS disk, not just BCD-SYS's approximation** — this
  part of the new architecture is fully validated and should be kept regardless of how driver
  injection gets resolved.
- `Dism /Image:W:\ /Add-Driver ...` and even the simpler `Dism /Image:W:\ /Get-Drivers`:
  **both failed identically**, `Error: 0x80004002`, `"No such interface supported"`.

### Finding 13: DISM's failure root-caused precisely, via the real `dism.log` (not the console
summary) — an architectural COM-hosting issue, not a driver-content problem

The console-visible error told us almost nothing actionable. Modified `startnet.cmd` to copy
`X:\Windows\Logs\DISM\dism.log` (the real, detailed log — normally lost, since `X:\` is an
ephemeral RAM disk that vanishes at shutdown) to the persistent target disk before shutting down.
The real log showed the precise mechanism:

```
DISM Manager: ... Copying DISM from "W:\Windows\System32\Dism" - CDISMManager::CreateImageSessionFromLocation
DismHostLib: ... Failed to create DismHostManager remote object (hr:0x80004002) - DismCreateObjectInHostFromCLSID
DISM Manager: ... Failed to create Dism Image Session in host. - CDISMManager::LoadRemoteImageSession(hr:0x80004002)
```

**What this reveals:** when servicing an *applied* offline image (a real partition, as opposed to
a mounted WIM), DISM doesn't do the work in-process. It copies DISM's own binaries from the
**target image's own** `W:\Windows\System32\Dism` directory and launches them as a separate
out-of-process COM server (`dismhost.exe`). Activating that COM object is what's failing — this
has nothing to do with our driver, our INF, or our registry content (confirmed further by the
identical failure on the simplest possible read-only operation, `/Get-Drivers`, which doesn't
touch the driver at all).

**Ruled out as the cause, with evidence, not assumption:**
- **Missing DISM provider DLL in plain WinPE (index 1) vs the fuller "Setup" image (index 2):**
  directly compared the full `Windows\System32\Dism\*.dll` file lists between both boot.wim
  indices — **byte-identical sets, zero difference**. Switching to index 2 would not have helped;
  this saved a wasted rebuild cycle.
- **Driver INF/hardware-ID mismatch:** `viostor.inf`'s legacy hardware ID
  (`PCI\VEN_1AF4&DEV_1001&SUBSYS_00021AF4&REV_00`) was checked against our actual device's real
  PCI IDs (via QMP `query-pci`: vendor=0x1AF4, device=0x1001, subsystem-vendor=0x1AF4,
  subsystem=0x0002) and matches **exactly**.
- **Missing embedded signature forcing DISM's signature-verification path to behave oddly:**
  checked the PE Certificate Table directory entry in `viostor.sys` directly (via a small Python
  script parsing the PE header) — a real, non-empty embedded Authenticode signature is present.

**Not yet resolved:** *why* the `dismhost.exe` COM activation itself fails inside this specific
WinPE environment. Plausible but unconfirmed theories floated but not tested: incomplete DCOM/RPC
service initialization in a minimal WinPE session (`services.exe`'s service set in WinPE is
deliberately sparse); some deeper incompatibility specific to DISM's remote-hosting model when
*both* the calling DISM.exe and the hosted `dismhost.exe` are effectively "foreign" to the running
environment (WinPE servicing itself, while pointing at a different OS's own copied DISM binaries).
A relevant, partially-corroborating data point found via research: a Microsoft Q&A thread
describing a near-identical scenario (Windows 11 24H2 via WinPE on QEMU-KVM hitting
`INACCESSIBLE_BOOT_DEVICE`) where `DISM /Add-Driver` against `install.wim` **also failed to
resolve the issue** even when it appeared to run "successfully" — suggesting this general territory
(driver injection into very recent Windows builds via non-ADK-built WinPE) may have broader,
not-fully-solved friction in the community, not just an artifact of our specific setup.

### Finding 14: Found and installed real open-source tooling for Linux-native Windows kernel
debugging — `ntoseye` — as the planned way to get a definitive boot-failure diagnostic

Per the project's research-first discipline, searched for existing tooling before attempting to
write or drive the Windows KD (kernel debugger) wire protocol by hand. Found
**[`dmaivel/ntoseye`](https://github.com/dmaivel/ntoseye)** — "Windows kernel debugger for Linux
hosts running Windows under KVM/QEMU," actively maintained (v0.20.0, dated days before this
session), with a `kd` backend (Windows KD over a serial pipe to QEMU) plus `analyze`
(bugcheck analysis) and `drivers` commands — a precise match for "diagnose why `0x7B` is
happening" without needing WinDbg (Windows-only) at all.

**Installation friction, resolved:** the official installer script
(`curl ... | sh`, a standard `cargo-dist`-style installer, inspected before running) installs a
prebuilt binary, but it's linked against `libpython3.10`, which this host (Ubuntu Noble, ships
3.12) doesn't have and has no apt candidate for. **Rather than install a full Rust toolchain to
rebuild with `--no-default-features` (avoiding the embedded-Python feature) — the documented
alternative — the missing shared library was extracted directly from Ubuntu 22.04 (jammy)'s
official archive** (`http://archive.ubuntu.com/ubuntu/pool/main/p/python3.10/libpython3.10_3.10.12-1~22.04.16_amd64.deb`,
via `dpkg-deb -x`, no system-wide install) and pointed at via `LD_LIBRARY_PATH`. Confirmed working
(`ntoseye --help` runs correctly). Installed to `~/.local/bin/ntoseye` (user-local, no sudo).

**Setup identified (per `ntoseye --kd-instructions`), partially executed:**
- Guest side: `bcdedit /debug on` + `bcdedit /dbgsettings serial debugport:1 baudrate:115200`
  against the target disk's BCD — **attempted via WinPE + real `bcdedit.exe /store <path> ...`**
  (chosen over hand-crafting the debug-related BCD elements via `hivexregedit`, since those
  specific element IDs were not verified against a reference the way the WinPE-mode flags were in
  Finding 11 — same "verify, don't guess a third time" discipline).
- QEMU side: `-chardev socket,id=kd,path=/tmp/ntoseye-kd.sock,server=on,wait=off -serial chardev:kd`
  — not yet added to any actual boot command.
- **Not yet confirmed working**: the WinPE session that was supposed to run `bcdedit` completed
  (VM shut down cleanly, matching the expected `wpeutil shutdown` at the end of the script) but the
  expected output log (`W:\bcdedit-log.txt`) was **not found** on the target disk afterward. This
  was the last thing investigated before pausing — root cause not yet determined. Candidate
  causes, unexamined: the `diskpart` assignment may not have completed the same way in this run
  (no driver files were loaded this time via `drvload`, since none were needed — but the *script
  itself* also didn't call `drvload` at all before `diskpart`, which shouldn't matter since
  `diskpart`/`bcdedit` don't need the viostor driver to see the target's *own* virtio-blk device...
  except **WinPE itself still needs `viostor` loaded to see the target disk at all**, and this
  particular script iteration never called `drvload`! That's the most likely explanation — worth
  checking first on resumption, before any other theory.

### Finding 15: The strategic pivot — reconsidering whether hand-rolling driver injection is the
right approach at all, versus reusing Setup.exe's own already-proven mechanism

After Finding 13/14, the user asked directly whether this whole approach (DISM-in-WinPE, or
offline registry hacking) might be too deep/complex a rabbit hole for the project's actual goals,
and whether there was a simpler path being missed. On reflection: **yes, there is one, and it
follows directly from what this session already proved.**

**The insight:** this entire project exists because the sibling project's *interactive Setup.exe*,
booted from `media=cdrom` install media, hits the "press any key" UEFI landmine on Server
2025/Windows 11 media. This session **proved** (Finding 10 → 11) that a self-built WinPE/Setup
boot medium, attached as a **plain disk** rather than `media=cdrom`, does **not** hit that landmine
at all — Windows Boot Manager loads cleanly every time this was tried. That finding was framed
during this session as "the central open question for *bootability*, resolved" — but it applies
equally to `boot.wim` **index 2** ("Microsoft Windows Setup"), not just index 1 (plain WinPE). The
landmine was never a Setup.exe-specific problem; it was a CD-ROM-boot-time firmware interaction
problem, and this project has already found the fix for that specific problem, just applied it so
far only to plain WinPE.

**The proposed hybrid architecture** (not yet attempted):
1. Build the boot medium exactly per the now-proven recipe (`wimapply` `boot.wim`, this time
   **index 2** instead of index 1, + BCD-SYS + the same three WinPE-mode BCD flags from Finding 11
   — Setup.exe's own image is *also* a WinPE-mode image, same requirement applies) — attached as a
   plain disk, never `media=cdrom`.
2. Attach `install.wim` (and the rest of the real install source) as a **secondary**, non-boot
   device — the landmine is specifically about *firmware boot-device selection*, not about an
   already-booted OS reading a second disk, so this should be unaffected by it (**untested
   assumption, flagged as such**).
3. Reuse the sibling project's **already-validated-for-Server-2022** `autounattend.xml` content
   near-verbatim: `Microsoft-Windows-PnpCustomizationsWinPE`'s `DriverPaths` (viostor/vioscsi +
   NetKVM), computer name, WinRM-enabling `FirstLogonCommands` — the exact mechanism CLAUDE.md
   currently says **not** to reuse ("do not reuse: anything related to ... autounattend.xml's
   `Microsoft-Windows-Setup` component"), a restriction written when Setup.exe looked permanently
   off the table. **That restriction needs a deliberate, explicit revisit** given this new
   information — not a silent reversal.
4. Rather than rely on Setup's own autodetection of `autounattend.xml` from removable media (what
   the sibling project did, tuned for a CD-ROM-delivered answer file), invoke Setup explicitly from
   our own `startnet.cmd`: `setup.exe /unattend:<path>` — more robust than autodetection, and we
   already have scripting control proven out (Finding 12).
5. Let Setup.exe do everything it already knows how to do — partitioning, image apply, driver
   staging via its own well-tested `DriverPaths` mechanism, BCD creation — instead of continuing to
   hand-roll each piece (DISM, hivex) ourselves.

**Why this is promising:** it reuses the vast majority of a pipeline that's *already proven
working* (the sibling project's Server 2022 success), changes only *how the boot medium is
attached* (which is precisely the thing this session already solved), and sidesteps the DISM
COM-hosting dead end and the twice-failed offline-registry approach entirely, rather than
continuing to debug either.

**Explicitly not yet tested, flagged as assumptions for the next session:**
- Does `boot.wim` index 2 booted this way actually launch Setup.exe automatically without hitting
  some *different* Setup-specific landmine? (Only index 1 was actually booted this session.)
- Does Setup, invoked via `setup.exe /unattend:<path>` from our own script, behave the same way as
  when autodetecting an answer file from removable media the way the sibling project used it?
- Is a secondary (non-boot) attached `install.wim` source actually unaffected by the original
  landmine, as reasoned above? (Reasoned from first principles, not empirically confirmed.)
- Does the sibling's `DriverPaths` mechanism, previously validated only against Server 2022, also
  work unmodified for Server 2025/Windows 11 once the boot problem itself is out of the way?
  (Never testable in the sibling project, since it never got past the boot landmine for those two
  OSes.)

---

## STATUS AND NEXT STEPS ON RESUMPTION

**Where things stand:**
- Phase 2 sub-milestone 1 (bootability): **solved**, twice over — BCD-SYS (Session 1) and real
  `bcdboot` via WinPE (Session 2, Finding 12) both independently produce a correctly-booting BCD.
  Either is usable; `bcdboot` via WinPE is now the recommended path if the Finding 15 pivot is
  pursued, since that WinPE session is needed anyway.
- Phase 2 sub-milestone driver injection: **not yet solved**. Two offline-registry attempts and
  one DISM-via-WinPE attempt all failed, for three different (one undiagnosed, one ruled out by
  elimination, one precisely root-caused) reasons.
- **Recommended next step, in order:**
  1. Read this log's Finding 15 in full, decide whether to pursue the Setup.exe hybrid pivot (the
     user was leaning toward yes when the session paused, but had not given final go-ahead).
  2. If pursuing it: build the index-2 boot medium (same recipe as Finding 11, different WIM
     index), get the sibling project's `autounattend.xml` + `DriverPaths` templates
     (`../windows-server-vm-automation/packer/answer_files/autounattend.xml.pkrtpl`) adapted for
     explicit `setup.exe /unattend:` invocation, and test end to end.
  3. If it does *not* pan out: fall back to either (a) resuming the kernel-debugging thread
     (Finding 14 — first fix the missing-`drvload` theory for why `bcdedit-log.txt` didn't appear,
     then actually attach `ntoseye` and capture a real `analyze`/`drivers` diagnostic for the
     `0x7B`), or (b) a third offline-registry attempt informed by whatever the debugger reveals.

**Ephemeral state that will NOT survive to a new session — must be redone from scratch:**
- All of `/tmp/claude-*/scratchpad/winpe-build/`, `/tmp/boot-wim-mnt*/`, extracted driver files,
  and the `/tmp/libpython-extract/` libpython3.10 workaround — all under `/tmp`, gone on reboot/new
  session. Re-extract `efi/`/`boot.wim` from the cached ISO, re-extract viostor/NetKVM from
  `virtio-win-0.1.285.iso`, and redo the `libpython3.10` extraction (URL is in Finding 14 above) if
  `ntoseye` is needed again.
- `ntoseye` itself **is** persisted (`~/.local/bin/ntoseye`, outside `/tmp`) — no need to
  reinstall, just re-extract the `libpython3.10` `LD_LIBRARY_PATH` dependency.

**Persistent state that DOES survive (under `image-apply/output/`, not `/tmp`):**
- `win2025-test.qcow2` — the main target disk. Current state: `install.wim` index 2 applied,
  **real `bcdboot`-created BCD** (from Finding 12, superseding the earlier BCD-SYS one), driver
  registry entries **reverted to clean** (Finding 8's revert), still fails `0x7B`.
- `winpe-boot.qcow2` — the WinPE boot medium disk. Current state: `boot.wim` **index 1** applied
  (plain WinPE, not Setup), most recent `startnet.cmd` on it is the **`bcdedit`-debug-flag-setup**
  version (Finding 14), not the DISM/bcdboot version — will need rebuilding for index 2 if pursuing
  Finding 15's pivot, or fixing (add back `drvload`) if continuing the kernel-debugging thread.
- `tools/vendor/BCD-SYS` — vendored, working, unchanged.

**Key technical facts worth their weight in gold (expensive to re-derive, cheap to just remember):**
- WinPE-mode BCD boolean elements: `26000010`, `26000022`, `260000b0` (all `hex:01` on the OS
  loader entry) — required for `boot.wim` (any index) to actually run in WinPE mode after BCD-SYS
  builds an otherwise-normal boot entry for it.
- Real hardware ID of our virtio-blk-pci device (confirmed via QMP `query-pci`): vendor `0x1AF4`,
  device `0x1001`, subsystem-vendor `0x1AF4`, subsystem `0x0002` — matches `viostor.inf`'s legacy
  entry (`PCI\VEN_1AF4&DEV_1001&SUBSYS_00021AF4&REV_00`) exactly.
- DISM offline-servicing of an *applied* (non-mounted-WIM) image always launches an out-of-process
  `dismhost.exe` copied from the *target's own* `Windows\System32\Dism` — this is architectural,
  not configurable, and is where our DISM attempts died (`0x80004002`,
  `DismCreateObjectInHostFromCLSID`).
- `ntoseye` (`github.com/dmaivel/ntoseye`) is the tool for Linux-native Windows kernel debugging
  over serial KD — actively maintained, real `analyze`/`drivers` commands, exactly suited to this
  project's needs if the debugging thread is resumed.

---

## Session 3: Setup.exe pivot (Finding 15) — assumption 1 confirmed. Setup.exe boots and reaches
## its real GUI from a plain-disk `boot.wim` index 2 medium, no landmine. Two operational gotchas
## hit and resolved along the way.

Picked up Finding 15's pivot directly: rebuild the WinPE-style boot medium against `boot.wim`
**index 2** ("Microsoft Windows Setup") instead of index 1, using the exact same proven recipe
(`wimapply` → BCD-SYS → patch the three WinPE-mode BCD booleans), then boot it and see whether
Setup.exe launches cleanly.

### Finding 16: this sandbox's Bash tool does not let backgrounded/daemonized child processes
survive between separate tool calls — `qemu-nbd -c` (which forks and detaches) can silently die
between one call and the next

**Symptom:** `qemu-nbd -c /dev/nbd0 <file>` succeeded, and partitioning/formatting/`wimapply`/
BCD-SYS all worked correctly across several subsequent (separate) tool invocations against that
same nbd device — then a later `hivexregedit --merge` against the BCD file on the mounted ESP
failed mid-commit with `Input/output error`, leaving the BCD file **truncated to 0 bytes**.
`dmesg` showed real block-layer I/O errors against `/dev/nbd0`/`nbd0p1` (both WRITE, from the
failed commit, and READ, from later commands trying to use the now-dead device), and `ps aux`
showed **no `qemu-nbd` process running at all** — the server side of the nbd connection was gone,
leaving the kernel client device attached to nothing. `dmesg -T` also showed a ~3-minute window
where "OOM killer disabled" then "OOM killer enabled" bracketed the failure, consistent with a
per-tool-call cgroup/session teardown reaping a detached background process rather than an actual
out-of-memory event.

**Diagnosis:** this is not a hivex/vfat compatibility bug (the initial suspicion) — it's that
`qemu-nbd`'s normal daemonizing behavior (fork, detach, keep serving the nbd device) cannot be
relied upon to survive past the end of the Bash tool call that started it, in this specific
sandboxed environment. It happened to survive several calls by luck (nothing needed the device in
between) before finally being reaped mid-operation.

**Fix:** do every step that depends on a given `qemu-nbd` attachment — attach, partition, format,
mount, `wimapply`, BCD-SYS, patch, unmount, detach — inside **one single Bash tool invocation**,
never split across separate calls. Confirmed working end-to-end once restructured this way.
**Standing rule for the rest of this project**: never assume a backgrounded `qemu-nbd -c` survives
between tool calls; a long-running `qemu-system-x86_64 ... -daemonize` VM, by contrast, *did*
survive across many separate calls in this same session (used for the whole boot-watch sequence
below) — the distinction observed so far is `-daemonize`'s real double-fork vs. `qemu-nbd`'s own
backgrounding, not backgrounding in general, but treat this as one data point, not a fully
root-caused guarantee.

### Finding 17: self-inflicted `INACCESSIBLE_BOOT_DEVICE (0x7B)` on the boot medium itself — caused
by attaching it via `virtio-blk-pci` instead of the AHCI device Finding 12 actually used

**Symptom:** first boot attempt of the freshly-built index-2 medium reached Windows Boot Manager
cleanly (no landmine), then hit `INACCESSIBLE_BOOT_DEVICE (0x7B)` on itself — the same stop code
this project already has for the *main OS disk's* still-unsolved driver-injection problem, which
briefly looked like a new, Setup-specific landmine.

**Root cause:** re-reading Finding 12 closely before treating this as a real finding
(`CLAUDE.md`'s "verify before trusting" standard) showed the discrepancy immediately: Finding 12's
working WinPE test had **the WinPE boot medium itself on `disk 0`, AHCI-attached** — only the
*separate target* main OS disk was `virtio-blk-pci` (`disk 1`). This session's `qemu-system-x86_64`
invocation attached the boot medium itself via `-device virtio-blk-pci`, which needs a boot-critical
storage driver that was never registered for it (same class of problem as the main disk, just now
self-inflicted on the wrong disk). Not a new Setup.exe-specific UEFI/boot landmine at all — a
device-model mistake in this session's own test command.

**Fix:** rebuilt the boot command with the medium attached via `-device ide-hd,drive=disk0,bus=ide.0`
(q35's built-in ICH9 AHCI controller, no explicit `-device ich9-ahci` needed), matching Finding 12
exactly. Booted clean on retry.

### Finding 18 (the actual pivot result): `boot.wim` index 2, booted as a plain AHCI disk, launches
Setup.exe automatically and reaches its real graphical Setup UI — Finding 15's assumption 1
confirmed

With the device-model bug fixed, the rebuilt medium (WIM index verified directly via
`wimlib-imagex info boot.wim` as `Index 2, Name: Microsoft Windows Setup (amd64)` before use, not
assumed) booted to a real **"Windows Server Setup"** window within seconds of Windows Boot Manager
handing off — watched via `tools/qmp-screenshot.py`/`qmp-watch.sh`, no VNC viewer. No UEFI
boot-key prompt, no CD-ROM-landmine-class failure of any kind, confirming this applies to
`boot.wim` index 2 exactly as it did to index 1 in Finding 10→11.

**Unexpected, not yet explained:** Setup reached the disk-selection page (showing "Install driver
to show hardware" because no target disk was attached in this test — expected, since none was
attached) within the first ~5 seconds of the watch starting, with **no simulated keyboard/mouse
input sent at all**. This implies Setup auto-skipped the language-select, "Install now", license,
and edition-selection screens entirely on its own, most likely because this eval WIM has only one
language and one edition to choose from — plausible but **not confirmed**, flagged here rather than
asserted as fact. Worth understanding properly once autounattend.xml is in the mix (an explicit
unattend answers these same screens regardless, so this may never need root-causing further, but
noting it in case a future session sees different behavior on Server 2022/Windows 11 media that
does carry multiple editions).

**What this confirms:** the core premise of Finding 15's pivot — that the "press any key" UEFI
landmine is CD-ROM-boot-specific, not Setup.exe-specific, and that a self-built plain-disk boot
medium can run real Setup.exe — is no longer a reasoned assumption, it's an observed result.

**Explicitly still unconfirmed** (unchanged from Finding 15's list, not yet attempted this
session):
- Whether a secondary, non-boot-attached `install.wim`/install source is reachable and usable by
  Setup from this configuration.
- Whether the sibling project's `DriverPaths` mechanism, invoked this way, actually resolves the
  virtio-blk target disk and lets Setup proceed past disk selection.
- Whether `setup.exe /unattend:<path>` explicit invocation (vs. relying on autodetection) is even
  necessary given how much Setup already appears to auto-resolve on its own — worth testing
  autodetection first now that it looks like the interactive screens mostly don't need answering
  for this specific eval media.

**Artifacts from this session so far:** `image-apply/output/winpe-boot-index2.qcow2` (index-2 boot
medium, BCD-SYS-built + WinPE-mode-flagged, confirmed booting) and
`image-apply/output/winpe-boot-index1.qcow2.bak` (safety copy of the previous, still-working
index-1 WinPE medium, made before this session's rebuild, in case the kernel-debugging fallback is
needed later).

### Finding 19: autounattend.xml's `DriverPaths` (`Microsoft-Windows-PnpCustomizationsWinPE`) does
not feed the specific gate that shows "Install driver to show hardware" — confirmed via direct
`setupact.log` evidence, not assumption, after two placement variants and real community research

**Setup:** attached a fresh 40GB target disk (`image-apply/output/win2025-target.qcow2`) via
`virtio-blk-pci` (matching this project's already-established device-model convention), plus the
cached Server 2025 ISO and `virtio-win-0.1.285.iso` as secondary, non-boot `media=cdrom` CD-ROMs —
confirming Finding 15's "secondary attached source is unaffected by the CD-ROM boot landmine"
assumption in passing (both attached and read cleanly with no issue). Built a concrete
`Autounattend.xml` (resolved from the sibling project's `autounattend.xml.pkrtpl`: `<NAME>` =
`Windows Server 2025 SERVERSTANDARD` per Finding 0, virtio driver dir = `2k25`, confirmed present on
the cached virtio-win ISO by direct `7z l` listing rather than assumed).

**Attempt 1 — placed at `X:\Autounattend.xml` and `X:\sources\Autounattend.xml`** (the boot
medium's own partition, matching what looked like search-order entries 6/8 in Microsoft's own
["Implicit Answer File Search Order"](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-automation-overview)
table): Setup.exe reached "Install driver to show hardware" with an empty list, no target disk
visible. Direct log inspection (pulled out via `copy ... A:\`, since `findstr` doesn't exist in
this minimal WinPE and there's no scrollback capture) showed `UnattendSearchExplicitPath: Found
usable unattend file for pass [windowsPE] at [X:\autounattend.xml]` — **the answer file WAS found**,
ruling out the first-guessed "X: isn't a valid search location" theory.

**Attempt 2 — added a floppy (`image-apply/output/answer-floppy.img`, built via `mtools`
`mcopy`/`mmd`, no `sudo`/loop-mount needed) with `Autounattend.xml` at its root**, matching
Microsoft's own documented example and a real proven community template
([jakobadam/packer-qemu-templates](https://github.com/jakobadam/packer-qemu-templates/blob/master/windows/floppy/windows-2012-R2-standard/Autounattend.xml))
that puts driver files on the *same* floppy as the answer file. Same empty-list result. Then
copied `viostor`'s 4 files directly onto the floppy alongside the XML (matching that same
community template's convention exactly) and pointed `DriverPaths` at `A:\viostor\2k25\amd64` —
still no change.

**Root cause, confirmed via `setupact.log`, not inferred:** `UnattendDriverInstall`'s **Prepare**
method runs every time (`UnattendDriverInstall: Entering/Leaving Prepare Method`), but its
**Execute** method never appears anywhere in the log before Setup reaches and blocks on
`EarlyF6DriverInstall`'s own gate (`EarlyF6DriverInstall: Entering Execute Method` →
`Driver: Starting Wait`, with nothing in between). `EarlyF6DriverInstall` is Setup's legacy
"press F6 to load a third-party mass-storage driver" mechanism (the name is a direct callback to
that Windows XP/2003-era feature) — a **different, separate action from the modern
`DriverPaths`/`UnattendDriverInstall` mechanism**, and in this flow it runs first and blocks
disk enumeration before `UnattendDriverInstall` ever gets a chance to execute. Two rounds of
targeted web research (the exact symptom, then the mechanism itself) turned up real, relevant
threads but no primary source definitively documenting this specific execution-order interaction —
recorded as a genuine gap in public documentation, not a search shortcut skipped.

### Finding 20: manually loading the same driver via the "Browse" UI succeeds completely — the
target disk becomes fully visible (confirmed via `wmic diskdrive`), proving the driver/hardware
pairing itself is entirely sound and the gap is specifically in *automated* delivery to this gate

Drove the entire "Install driver to show hardware" dialog via `tools/qmp-sendkey.py` (Tab/arrow-key
navigation, no mouse needed) rather than fighting the automation further: Browse → selected
`A:\viostor\2k25\amd64` → Setup itself listed **"Red Hat VirtIO SCSI controller"** matched from
`viostor.inf` → Install. `setupact.log` confirmed `Driver: Install successfully completed.` on the
first attempt (an accidental *second* click produced the `0x80070103`/`ERROR_NO_MORE_ITEMS`
"Error installing driver" message actually seen on screen — a harmless side effect of re-installing
an already-loaded driver, not a real failure; worth remembering so this exact message doesn't get
mistaken for a real error again).

**Decisively confirmed via direct inspection, not the Setup UI** (which stayed on the same page —
its own "Back" button was disabled and it doesn't auto-refresh after a driver install; not yet
investigated further since the next finding makes it moot): opened a command prompt (`Shift+F10`)
and ran `wmic diskdrive get caption,size,status`:
```
Caption                          Size          Status
QEMU HARDDISK                    2146798080    OK
Red Hat VirtIO SCSI Disk Device  42944186880   OK
```
The 40GB target disk is fully visible and healthy. **This proves, empirically, that every piece of
this project's driver-injection puzzle already works** — the real hardware ID, the driver file,
the boot-medium architecture, the secondary-disk attachment — the only unsolved piece is
*automating* the load rather than clicking through it by hand.

### Finding 21 (recommendation, not yet attempted): reuse Finding 12's already-proven `drvload`
technique instead of fighting `EarlyF6DriverInstall`/`DriverPaths` automation

Finding 12 already proved, in this same project, that running `drvload X:\drivers\viostor\viostor.inf`
from our **own** `startnet.cmd` — *before* ever launching `setup.exe` — successfully loads a boot-
critical VirtIO driver into a running WinPE session. That technique was used there to let WinPE see
the *target* disk for `diskpart`/`bcdboot` purposes; the same technique, applied one step earlier
(before Setup even starts, rather than after WinPE boots for a different purpose), should mean the
virtio-blk-pci target disk is *already* visible the moment Setup performs its own first disk
enumeration — never triggering `EarlyF6DriverInstall`'s gate, and its interactive-only "Install
driver to show hardware" page, at all. This sidesteps the undocumented execution-order gap in
Finding 19 entirely rather than continuing to search for a way to make `DriverPaths` feed it
automatically. **Not yet attempted** — the concrete next step for this pivot.

**New tooling from this session**, promoted to `tools/` (same "thin wrapper around an existing
protocol" pattern as `qmp-screenshot.py`): `tools/qmp-sendkey.py` (QMP `human-monitor-command
sendkey`, for driving dialogs via Tab/arrow-key/Enter with no mouse or VNC viewer needed) and
`tools/qmp-type.py` (types literal ASCII strings the same way, for running diagnostic commands in
a Shift+F10 command prompt). Both were essential to reaching Findings 19-20's conclusions and are
now permanent, reusable project tooling, not one-off scratch scripts.

---

## Session 4

### Finding 22: `winpe-boot-index2.qcow2` has no `winpeshl.ini` at all — `startnet.cmd`'s presence
does not mean it actually runs before `setup.exe` launches

Before implementing Finding 21 as written, mounted the index-2 medium's NTFS partition directly
(same technique as always: `qemu-nbd` + mount, single Bash call) to check what's actually in
`startnet.cmd`/`winpeshl.ini` rather than assume, per this project's own "verify before trusting"
standard. Found:

- `Windows\System32\startnet.cmd` exists and contains only `wpeinit` — but a full-volume
  `find -iname winpeshl.ini` turned up **zero results**. No such file exists anywhere on the image.
- `Windows\System32\winpeshl.log` shows `winpeshl.exe` launching `WallpaperHost.exe`, then
  attempting `X:\$Windows.~BT\sources\setup.exe` (fails, doesn't exist), then succeeding on
  `X:\setup.exe` — with **no log entry for `startnet.cmd` or `wpeinit` ever running**, on any of the
  four prior boot attempts recorded in that log.
- The `SYSTEM` hive's `\Setup\CmdLine` = `winpeshl.exe` (checked via `hivexregedit --export`),
  confirming `smss.exe` launches `winpeshl.exe` directly (the classic GUI-setup-phase mechanism) —
  and with no `winpeshl.ini` present, it falls back to a built-in default app list, not the
  `startnet.cmd`/`wpeinit` convention that custom WinPE builds (`copype`) normally rely on.

**Conclusion:** this is genuine, unmodified Setup media (only `Autounattend.xml` added), and it
likely never executes `startnet.cmd` in this boot path at all. Finding 21's plan (edit
`startnet.cmd`, expect it to run before `setup.exe`) rested on an assumption the evidence
contradicts.

### Finding 23: creating `winpeshl.ini` ourselves, verified against Microsoft's own reference,
successfully makes `drvload` run before `setup.exe` — the driver loads correctly, but this does
**not** avoid the "Install driver to show hardware" gate (see Finding 24 for why)

Fetched the actual [Winpeshl.ini reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpeshlini-reference-launching-an-app-when-winpe-starts)
directly (not just a search summary) to confirm syntax rather than guess: `[LaunchApps]` entries
run strictly sequentially, each waited-on before the next starts; one app per line; comma-separated
argument string. Wrote `Windows\System32\winpeshl.ini`:

```
[LaunchApps]
%SYSTEMROOT%\System32\drvload.exe, A:\viostor\2k25\amd64\viostor.inf
%SYSTEMDRIVE%\setup.exe
```

Booted (boot medium on `ide.0`, target disk `win2025-target.qcow2` on `virtio-blk-pci`, Server 2025
ISO + `virtio-win-0.1.285.iso` as secondary `media=cdrom`, answer floppy — same shape as every prior
session's test). Confirmed via `Shift+F10` + `wmic diskdrive get caption,size,status` that the
**target disk is fully visible and healthy before Setup's UI even finishes rendering** —
`drvload` from `winpeshl.ini` works exactly as documented:

```
Caption                          Size          Status
QEMU HARDDISK                    2146798080    OK
Red Hat VirtIO SCSI Disk Device  42944186880   OK
```

**But Setup's UI still showed "Install driver to show hardware" with an empty list anyway.** This
is the actual, more important finding — see Finding 24.

### Finding 24: `EarlyF6DriverInstall` enters its wait state unconditionally and immediately at
Setup start — confirmed via `setupact.log` timestamps, not inferred — so no amount of pre-loading
a driver before `setup.exe` launches can avoid this gate

Pulled `setupact.log` from `X:\$WINDOWS.~BT\Sources\Panther\setupact.log` (note: **not**
`X:\Windows\Panther\setupact.log`, which doesn't exist in this WinPE session — there are four
different `setupact.log` copies on `X:\`, and this is the one Setup is actively writing to) via the
established `Shift+F10` → `copy` → floppy → `mcopy` technique. The timestamps are decisive:

```
15:58:00  EarlyF6DriverInstall: Entering Execute Method
15:58:00  Driver: Starting Wait
16:00:21  Driver: Scan requested          <- ~2.5 minutes later, first manual interaction
```

`EarlyF6DriverInstall`'s Execute method starts waiting for interactive input in the **very same
second** as Setup's Prepare phase — before any user action, and after `drvload` (from Finding 23)
had already loaded the driver and made the disk visible. This proves the gate is not conditioned on
disk/driver visibility at all; it is a hardcoded, unconditional wait for interactive input the
moment this WinPE-based Setup flow reaches disk configuration. Finding 21 (and Finding 23's cleaner
version of it) **cannot** work — there's nothing to pre-load around, because the gate doesn't check
what's already loaded.

### Finding 25: manual click-through (Finding 20's technique) reproduced with mouse clicks instead
of keyboard, including a genuinely clean install with zero errors — and `setupact.log` proves the
dialog loops back to waiting even after real success. No exit from this dialog was found via UI
interaction alone.

**Relative (PS/2) mouse input does not work this early in this WinPE/Setup environment.** QMP
`input-send-event` with `type: rel` accepts events with no error, but the guest's on-screen cursor
never moves — confirmed by direct calibration (a 300/300 relative move produced zero visible
movement across two separate attempts). `type: abs` events fail outright with `"Input handler not
found for event type abs"` unless a USB tablet device is attached. **Fix:** hot-launch (well,
cold-relaunch — QEMU has no hot-add path for a new PCI controller here) the VM with
`-device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0` added. With that, absolute-position
clicks work correctly and reliably. Promoted the click helper to `tools/qmp-click.py` (supports
`--double` for double-clicks, used for tree-view folder expansion in the driver Browse dialog).

Two runs, both driven entirely by mouse clicks (Browse → double-click through
`A:\viostor\2k25\amd64` in the folder tree → select the matched driver row → Install):

1. **With the driver already loaded via `winpeshl.ini`** (Finding 23's state): clicking Install
   reproduced Finding 20's known-harmless `0x80070103` "already installed" error exactly.
2. **A genuinely clean run** (reverted `winpeshl.ini` back to just `%SYSTEMDRIVE%\setup.exe`,
   rebooted fresh, confirmed the driver list was empty beforehand): clicking Install produced
   **no error at all**. `setupact.log` confirms a real, clean success:
   ```
   16:17:39  Driver: Succeeded in loading driver from path [A:\viostor\2k25\amd64\viostor.inf].
   16:17:39  Driver: Install successfully completed.
   16:17:39  Driver: Starting Wait          <- loops right back to waiting anyway
   ```

**This is decisive, not just "not yet found a way past it": success, failure, and "already loaded"
all lead to the identical `Driver: Starting Wait` state.** Waited 60+ seconds after the clean
success with no auto-advance (ruling out a timeout/grace-period mechanism). Tried maximizing the
window in case a "Next" affordance was hidden below the fold — no change, no new controls appear.
Tried the window's own close (`X`) button specifically to check whether it dismisses just this
sub-dialog: it does not — it raises "Are you sure you want to quit?" and clicking Yes would abort
all of Setup, confirming this is the main wizard window, not a dismissible modal with a hidden
escape hatch.

**Net result: there is no known way to get this Setup.exe-driven flow past the disk-configuration
step once `EarlyF6DriverInstall`'s dialog appears, whether reached automatically (Finding 24) or
resolved manually via full mouse-driven UI automation (this finding).** This is a real, currently
unresolved blocker for the Setup.exe pivot as a whole, not just an automation nicety — worse than
Session 3's "Status" summary assumed, since Session 3 left off believing Finding 20's manual
click-through was a complete, if manual, workaround (its own words: "not yet investigated further
since the next finding makes it moot" — Finding 21 was expected to make the whole question moot,
and it didn't).

**One real, not-yet-tested theory for why**, worth checking before concluding the whole pivot is
dead: `EarlyF6DriverInstall` is explicitly named after Windows' legacy "press F6 to load a
third-party mass-storage driver" mechanism. It's possible this legacy code path only triggers
because `Autounattend.xml`'s `DiskConfiguration`/`ImageInstall` sections drive Setup straight into
automated disk configuration, skipping past the *modern* interactive "Where do you want to install
Windows" screen entirely — which has its own, different, non-legacy "Load driver" link. If Setup
were allowed to reach that modern screen instead (e.g. by not fully specifying `DiskConfiguration`
in the answer file, accepting a manual/scripted partition-selection step), the modern driver-load
mechanism there might not have the same dead-end behavior. **Not yet attempted** — a materially
bigger change to test (rebuilding how much of the disk-configuration phase the answer file drives)
than anything tried so far, deferred to the next session pending a decision on direction.

### Finding 26: real, multi-angle web research (done properly this time, per the project's own
"research first" standard, after being steered back to it) turned up a documented, much cheaper
mechanism to try before the modern-screen theory — `$WinPEDriver$` — plus corroborating community
prior art confirming the *general shape* of the real fix is "register the driver in the image
before Setup starts," not "load it live via any runtime mechanism"

After Finding 25 concluded with a speculative theory, a proper multi-angle search (the literal
symptom, then the capability — "has anyone solved unattended virtio driver injection for Windows
Setup without hitting this exact wall" — rather than jumping straight to designing a new experiment)
turned up two genuinely useful, verified-at-the-primary-source results:

**1. `$WinPEDriver$` — a documented, decades-old, still-current Setup.exe feature (Microsoft KB
2686316, fetched and quoted directly, not taken from a search summary), architecturally distinct
from both `drvload` and `DriverPaths`.** Setup.exe automatically scans four fixed locations for a
folder literally named `$WinPEDriver$`, and recursively loads any `.INF` files found there into the
driver store — no `unattend.xml` configuration needed at all. The KB's own `setupact.log` excerpt
(quoted verbatim, and matching this project's own log format exactly):
```
PnPIBS: Checking for pre-configured driver paths ...
PnPIBS: Checking for pre-configured driver directory C:$WinPEDriver$.
PnPIBS: Checking for pre-configured driver directory D:$WinPEDriver$.
PnPIBS: Checking for pre-configured driver directory E:$WinPEDriver$.
PnPIBS: Checking for pre-configured driver directory X:$WinPEDriver$.
```
**Note the checked drive letters: `C:`, `D:`, `E:`, `X:` — not `A:`.** Our answer floppy is `A:`, so
`$WinPEDriver$` placed there would never be found; it needs to live on `X:` (the boot medium
itself, which this project already fully controls offline via the existing `qemu-nbd`-mount
routine — no registry hacking, no DISM, just a plain file copy into
`X:\$WinPEDriver$\viostor\2k25\amd64\`) or on `D:`/`E:` (the Server 2025 ISO / virtio-win ISO
themselves, not writable without rebuilding the ISO). The KB itself documents this as **item 4** in
its own list of five distinct driver-inclusion methods — explicitly separate from `drvload` (item 2:
"Doesn't propagate the driver to the installed OS") and from `unattend.xml`'s `DriverPaths` (item
5, the mechanism Finding 19 already showed doesn't reach `EarlyF6DriverInstall` at all) — and its
own wording ("Setup.exe will attempt to load all drivers in the `$WinPEDriver$` directory into
memory, **and also will schedule them for injection into the installing OS**") suggests deeper
integration with Setup's own driver bookkeeping than a bare runtime PnP load. **Not yet tested** —
this is the cheapest, best-documented next experiment: no `winpeshl.ini` change, no
`Autounattend.xml` rewrite, just copy 4 files into the boot medium's own `X:\$WinPEDriver$\` and
boot exactly as before.

**2. Corroborating (not directly reusable) prior art: the Proxmox community's standard fix for this**
**exact problem is DISM-slipstreaming the driver into *both* `boot.wim` and `install.wim` offline,
before ever booting Setup** (confirmed via a real GitHub tool,
[`zer0coolx/proxmox-windows-slipstream-virtio-drivers`](https://github.com/zer0coolx/proxmox-windows-slipstream-virtio-drivers),
fetched and inspected directly) — `dism /Add-Driver /image:<mount> /driver:<inf> /Recurse
/ForceUnsigned` run against *both* WIMs from a real Windows+ADK host. This confirms the general
shape of the real, working fix in the wider community is "the driver must be present in `boot.wim`'s
own driver store at WinPE-boot time," not "loaded afterward by any means" — consistent with
`$WinPEDriver$` being the right kind of fix, and inconsistent with anything this project has tried
so far (`drvload`, `DriverPaths`) ever having been likely to work. **Not directly usable as-is**:
it requires a real Windows host with ADK, conflicting with this project's Linux-only offline-prep
constraint — Findings 7-8's hivex-based `CriticalDeviceDatabase`/`DriverDatabase` registry attempts
were a Linux-only attempt at the same underlying goal (register a driver into an image's own driver
database) and failed for unknown reasons on the *main OS disk*; whether the same technique would
behave differently applied to `boot.wim` specifically (a different boot code path than a full NT
kernel boot) is unknown and not planned to be re-attempted while `$WinPEDriver$` remains untested
and much cheaper to try first.

A related, third, low-confidence, **not verified** community folklore data point surfaced in the
same research pass and worth a mention only because it's nearly free to try if `$WinPEDriver$`
doesn't pan out: several forum threads (manual troubleshooting, not automated-deployment context)
mention that clicking **Cancel** on the "Install driver to show hardware" dialog and restarting the
partition-selection step (rather than clicking Install/Back) sometimes lets Setup re-enumerate and
proceed. Nothing in this project's own `setupact.log` evidence supports or contradicts this — a
"Cancel" button was never identified/tried in Findings 20/25 (only Browse/Install/Back/the window's
own close control were tried). Cheap to test if `$WinPEDriver$` fails, but not a priority given how
thin the sourcing is.

---

## STATUS AND NEXT STEPS ON RESUMPTION (Session 3)

**Where things stand:** the Setup.exe pivot (Finding 15) is now substantially de-risked. Every
individual mechanical piece is confirmed working: `boot.wim` index 2 boots clean with no landmine
(Finding 18), the real viostor driver correctly matches the real virtio-blk-pci hardware ID and
successfully brings up the 40GB target disk (Finding 20). The only remaining gap is automation:
autounattend.xml's `DriverPaths` doesn't feed the specific `EarlyF6DriverInstall` gate that shows
"Install driver to show hardware" (Finding 19) — manual Browse works, automated DriverPaths doesn't.

**Recommended next step:** implement Finding 21 — customize `winpe-boot-index2.qcow2`'s own
`Windows\System32\startnet.cmd` (mount the NTFS partition directly, same technique used for
`Autounattend.xml` placement this session, no need to re-mount the WIM) to run
`drvload A:\viostor\2k25\amd64\viostor.inf` (or bake the driver files into the boot medium itself
under a fixed path, matching Finding 12's `%SystemDrive%\drivers\viostor\` convention, to avoid
depending on the floppy still being attached at exactly the right moment) **before** the stock
`winpeshl.ini` launches `setup.exe`. If the target disk is already visible the moment Setup starts,
`EarlyF6DriverInstall`'s gate should never trigger at all. Test end-to-end with the same
`Autounattend.xml` already built this session (still valid, no changes needed) plus the target
disk + Server 2025 ISO + virtio-win ISO already attached the same way.

**If that works:** the disk should partition/format/apply `install.wim`/create its own BCD
entirely via Setup itself, per the answer file's `DiskConfiguration`/`ImageInstall` sections —
watch for it reaching `oobeSystem`'s `FirstLogonCommands` (WinRM enablement) and then attempt a
real WinRM connection, which is Phase 2's actual success criterion.

**If `drvload` alone isn't enough** (e.g. if Setup re-runs its own disk enumeration in a way that
doesn't pick up a driver loaded before it started): fall back to actually attempting the
`setup.exe /unattend:<path>` explicit-invocation approach from `startnet.cmd` (Finding 15's
original step 4) instead of relying on stock `winpeshl.ini` autodetection — not yet tried, since
autodetection has worked fine for the answer file itself throughout this session (Finding 19).

**Persistent state that DOES survive** (under `image-apply/output/`, not `/tmp`):
- `winpe-boot-index2.qcow2` — the working index-2 (Setup) boot medium. Current state: stock,
  unmodified `startnet.cmd`/`winpeshl.ini` (launches `setup.exe` automatically on its own);
  `Autounattend.xml` present at both its partition root and `\sources\`. **Needs its
  `startnet.cmd` customized per the recommended next step above** — not yet done.
- `winpe-boot-index1.qcow2.bak` — safety copy of the previous, still-working index-1 WinPE medium
  (Findings 11-12), kept in case the kernel-debugging fallback thread is ever resumed instead.
- `win2025-target.qcow2` — fresh 40GB blank target disk, virtio-blk-pci, never yet actually
  partitioned by Setup (Setup's own `DiskConfiguration`/`WillWipeDisk` will handle that once the
  driver-load gate is cleared).
- `answer-floppy.img` — floppy with `Autounattend.xml` + `viostor/2k25/amd64/*` at its root,
  confirmed working for both answer-file autodetection and (manually) driver loading.

**Ephemeral state that will NOT survive to a new session:** everything under `/tmp/`, including
the extracted `boot.wim`/`virtio-extract` scratch files and the `qmp-sendkey.py`/`qmp-type.py`
scratchpad originals (their permanent copies are now in `tools/`, so no need to re-extract those
specifically — just the ISO content, which is a cheap `7z e` away).

**Key facts worth remembering:**
- Server 2025's `install.wim` index 2 = `Windows Server 2025 SERVERSTANDARD` (Finding 0).
- virtio-win-0.1.285.iso's driver folders for Server 2025 are named `2k25` (confirmed via `7z l`,
  not assumed) — `vioscsi/2k25/amd64`, `viostor/2k25/amd64`, `NetKVM/2k25/amd64`.
- The boot medium (whatever WinPE/Setup image is actually booting) must be attached via a
  non-virtio device (AHCI/IDE, e.g. `-device ide-hd,bus=ide.0`) — **never** `virtio-blk-pci` for
  the boot medium itself, or it self-inflicts the exact same `INACCESSIBLE_BOOT_DEVICE` this whole
  pivot exists to solve (Finding 17). `virtio-blk-pci` is only for the *target* disk.
- Any `qemu-nbd`-dependent sequence (attach/partition/format/mount/patch/detach) must run inside a
  **single** Bash tool call in this sandbox — backgrounded `qemu-nbd` processes do not reliably
  survive between separate tool invocations (Finding 16). A `qemu-system-x86_64 ... -daemonize`
  VM, by contrast, survives fine across many separate calls (used throughout this session's
  boot-watch sequences).
- `mtools` (`mcopy`/`mmd`/`mdir`) builds/edits FAT floppy images without `sudo`/loop-mount at all —
  simpler than the `mount -o loop` approach that needs root.

---

## STATUS AND NEXT STEPS ON RESUMPTION (Session 4)

**Where things stand: worse than Session 3 believed, in one specific, important way.** Session 3's
own status section (above) treated Finding 20's manual click-through as a complete, if manual,
fallback, and treated Finding 21 (pre-load the driver before `setup.exe` starts) as very likely to
remove the need for it entirely. Session 4 implemented Finding 21 properly (Finding 23: a real,
Microsoft-reference-verified `winpeshl.ini`, not a `startnet.cmd` edit that Finding 22 showed
probably never even runs) and it **did** successfully load the driver before Setup started — but
`EarlyF6DriverInstall`'s gate showed anyway, and `setupact.log` timestamps prove it's unconditional
(Finding 24). Worse: Finding 25 shows the manual click-through itself — the fallback Session 3 was
relying on — doesn't actually lead anywhere either. A **genuinely clean, error-free** Install click
was tested for the first time this session (Session 3 only ever saw either a real success followed
immediately by an accidental duplicate-click error, or nothing further), and `setupact.log` proves
even that loops back to `Driver: Starting Wait` forever. No hidden "Next" button, no timeout, and
the window's close button quits all of Setup rather than dismissing just this sub-dialog.

**Net effect: the Setup.exe pivot (Finding 15) does not currently have any known path past
disk configuration, whether automated or manual.** This is the single most important thing to
internalize before resuming — do not re-attempt Finding 21/23's pre-load approach again believing
it might work with a small tweak; the evidence in Finding 24 is timestamp-based proof, not
inference, that it fundamentally cannot.

**Two open threads now, not one — try the cheaper, better-documented one first.** Finding 25 closed
with a speculative theory (the "modern screen" idea, below); proper multi-angle research afterward
(Finding 26) turned up a real, primary-source-documented mechanism that's cheaper to test and more
likely to work. Recommended order:

1. **`$WinPEDriver$` (Finding 26 — try this first).** Mount `winpe-boot-index2.qcow2` (existing
   `qemu-nbd` routine, single Bash call as always), create `X:\$WinPEDriver$\viostor\2k25\amd64\`,
   copy in the 4 viostor driver files (already known-good, same files used throughout this project).
   **No `winpeshl.ini` change, no `Autounattend.xml` change.** Boot exactly as every prior test this
   session. Watch `setupact.log` for `PnPIBS: Checking for pre-configured driver directory
   X:$WinPEDriver$.` and whatever follows it — if the driver gets picked up this way and
   `EarlyF6DriverInstall` never shows (or shows and immediately proceeds), this is a real, much
   smaller permanent fix than either alternative. If it doesn't help, the `setupact.log` evidence of
   *why* (does the scan even find the folder? does it load the driver but still hit the same gate?)
   is itself valuable and should be recorded before moving to option 2.
2. **The "modern screen" theory (Finding 25's original idea).** `EarlyF6DriverInstall` may only be
   reachable because `Autounattend.xml`'s `DiskConfiguration`/`ImageInstall` sections drive Setup
   directly into automated disk configuration, bypassing the *modern* interactive "Where do you want
   to install Windows" screen — which has a different, non-legacy "Load driver" link never tested in
   this project. Testing this means rebuilding the answer file to *not* fully automate disk
   configuration (or omit `DiskConfiguration` entirely) and seeing what screen Setup shows instead,
   then testing whether **that** screen's driver-load mechanism actually lets Setup proceed. A
   materially bigger change than option 1, and still just a theory — try it second.

**If neither works**, the honest conclusion is that the Setup.exe pivot itself (not just its
automation) needs reconsidering against the two-tier bootstrap plan's original fallback path
(`PHASE2_BOOTSTRAP_ARCHITECTURE.md`), which this pivot was chosen over — possibly combined with
revisiting Findings 7-8's hivex-based driver-database registration technique applied to `boot.wim`
specifically rather than the main OS disk (untested; a different boot code path, per Finding 26).

**Persistent state that DOES survive** (under `image-apply/output/`, not `/tmp`):
- `winpe-boot-index2.qcow2` — **currently reverted back to stock** (`winpeshl.ini` present but
  containing only `%SYSTEMDRIVE%\setup.exe`, no `drvload` line) after Session 4's clean-install
  test. `Autounattend.xml` still present at both its partition root and `\sources\`, unchanged and
  still valid.
- `win2025-target.qcow2` — still blank/unpartitioned; Setup has never gotten far enough to touch it.
- `answer-floppy.img` — unchanged, still has `Autounattend.xml` + `viostor/2k25/amd64/*`.
- `OVMF_VARS_setup-test4.fd` — this session's OVMF vars copy, paired with a boot command that now
  also needs `-device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0` (see Finding 25) for
  mouse automation to work at all — earlier sessions' boot commands (AHCI boot medium + virtio-blk
  target + secondary CD-ROMs + floppy) are otherwise unchanged and still correct.
- A VM from this session may still be running (`qmp-setup-test4.sock`) depending on whether it was
  left up at session end — check `pgrep -fa qemu-system-x86_64` before assuming either way.

**New permanent tooling:** `tools/qmp-click.py` (promoted from this session's scratchpad) — QMP
absolute-position mouse clicks, supports `--double`. Requires the `usb-tablet` device above; a
plain PS/2 relative mouse does not produce any visible cursor movement in this environment (tried
and confirmed not to work, not just "not attempted" — see Finding 25).

**Process note confirmed again this session:** the "verify before trusting" discipline directly
paid off twice — Finding 22 (checking what's actually in `winpeshl.ini`/`startnet.cmd` before
editing, rather than assuming Finding 21's premise) and Finding 24 (pulling real `setupact.log`
timestamps instead of guessing why the dialog wouldn't advance) both overturned an assumption the
previous session's writeup had treated as settled.

---

## Session 5

### Finding 27: `$WinPEDriver$` (Finding 26's cheapest, best-documented lead) tested and ruled out
— files verifiably present at the documented location, but Setup's `EarlyF6DriverInstall` shows
the exact same empty "Install driver to show hardware" dialog anyway, with zero evidence in
`setupact.log` that any `$WinPEDriver$` scan was even attempted

**Setup:** mounted `winpe-boot-index2.qcow2`'s NTFS partition directly (`qemu-nbd` + mount, same
technique as Finding 22/23), copied the same known-good `viostor` driver files (already used
throughout this project, sourced from `answer-floppy.img`'s existing copy) into
`\$WinPEDriver$\viostor\2k25\amd64\` at the partition root. No `winpeshl.ini` change, no
`Autounattend.xml` change — confirmed `winpeshl.ini` was still stock (`%SYSTEMDRIVE%\setup.exe`
only) before booting, matching Session 4's end state exactly.

**Result 1 — the dialog still appears, unchanged.** Booted with the exact same device shape as
every prior session (boot medium on `ide.0`, target disk on `virtio-blk-pci`, Server 2025 ISO +
`virtio-win-0.1.285.iso` as secondary `media=cdrom`, answer floppy). Screenshot at ~45s shows
"Install driver to show hardware" with an empty driver list — pixel-identical in substance to
Finding 20/23/25's dialog.

**Result 2 — `setupact.log` shows no `$WinPEDriver$` scan at all.** Pulled the live log via the
established `Shift+F10` → `copy X:\$WINDOWS.~BT\Sources\Panther\setupact.log A:\...` → `mcopy`
technique (Finding 21's path, confirmed still correct). `grep`-ing the full log for `PnPIBS`,
`WinPEDriver`, `checking for`, or `pre-configured` (the KB's own documented log-line vocabulary)
returns **zero matches**. The only driver-related lines present are the same ones Finding 24 saw:
`SetupManager: Drivers Path: []` (empty — this reflects `Autounattend.xml`'s `DriverPaths`, a
different mechanism per Finding 26, not `$WinPEDriver$`), then `EarlyF6DriverInstall: Entering
Prepare Method` → `Leaving Prepare Method` → (a few lines of unrelated setup activity) →
`EarlyF6DriverInstall: Entering Execute Method` → `Driver: Starting Wait`, one second later. No
`$WinPEDriver$`-related log line appears anywhere before, during, or after this sequence.

**Result 3 — the files are genuinely present and correctly placed, not a placement mistake.**
Before concluding "doesn't work," verified the premise itself rather than trusting the copy step:
rebooted, `Shift+F10`, and ran `wmic logicaldisk get caption,volumename,description,filesystem`.
This surfaced an important, previously-wrong assumption of this project's own: **`X:` in this
Setup boot session is not a RAM-loaded copy of `boot.wim`'s contents distinct from the physical
boot medium — `X:` *is* the physical NTFS partition itself** (`wmic` confirms: `X:`, `Local Fixed
Disk`, `NTFS`, volume label `Windows` — the same partition `qemu-nbd`-mounted throughout this
project to edit `Autounattend.xml`/`winpeshl.ini`). There is no `C:` at all in this boot
configuration (only `D:` = Server 2025 ISO, `E:` = virtio-win ISO, `X:` = the boot medium,
`A:` = answer floppy) — meaning our copy to the partition root landed exactly on `X:`, one of the
KB's four documented scan locations, not on an unlettered or wrong volume. `dir "X:\$WinPEDriver$"
/s` (redirected to the floppy, pulled off and decoded as UTF-16) confirms all three driver files
present at the exact documented depth: `X:\$WinPEDriver$\viostor\2k25\amd64\{viostor.inf,
viostor.cat, viostor.sys}`, `3 File(s) 80,324 bytes`.

**Diagnosis:** the driver-placement side of Finding 26's plan was executed correctly and is not
the reason this didn't work. Either (a) `$WinPEDriver$` is not honored by this specific Setup
build (`10.0.26100.32230`, Windows Server 2025) in this boot configuration, despite KB 2686316
describing it as a current mechanism, or (b) the scan happens at a point in the boot sequence this
project hasn't captured (e.g. only from true `media=cdrom` boot, not a `wimapply`'d plain-disk
medium — plausible, since this project deliberately never boots the medium as `media=cdrom` and
KB 2686316's own examples assume a real burned/mounted installation disc), or (c) the scan
requires the folder to exist at boot-media-creation time in a way `wimapply` + direct NTFS-partition
file copy doesn't reproduce (e.g. a manifest/catalog built into `boot.wim` at Microsoft's own build
time, not something addable after the fact by dropping files onto the applied partition). This
project has no way to distinguish (a)/(b)/(c) further without a real optical/`media=cdrom` boot
test or deeper reverse-engineering of `PnPIBS`'s actual scan trigger — not pursued this session,
since Finding 26's second, costlier thread (the "modern screen" theory) was already next in line
regardless of which of these is true.

**Root cause:** not fully determined — a genuine negative result, not a mistake in this project's
own execution. Recorded per this project's "document findings as you go" standard rather than
treated as wasted effort: this closes out Finding 26's cheaper thread cleanly, with real evidence
(not just "didn't get to it"), and the `X:` discovery (Result 3) is independently useful — it
corrects a wrong mental model (`X:` as a RAM-disk copy) this project had held implicitly since
Finding 22, without ever stating it explicitly or testing it.

**Not yet tried, only because Finding 26 already ranked it second and more expensive:** placing
`$WinPEDriver$` on the Server 2025 ISO itself (`D:`) or the virtio-win ISO (`E:`) instead of the
boot medium (`X:`) — would require rebuilding one of those ISOs (not a bare file copy, unlike the
boot medium which this project already mounts read-write routinely), so it's a materially bigger
change than what was just tested and not clearly more likely to succeed given `X:` was already a
documented, valid location per the KB. Not recommended as the next step over Finding 26's own
option 2 below.

---

## STATUS AND NEXT STEPS ON RESUMPTION (Session 5)

**Where things stand:** both items in Finding 26's priority-ordered list have now been tried.
`$WinPEDriver$` (the cheaper one) is ruled out empirically (Finding 27) — not "not attempted," a
real negative result with `setupact.log` evidence. The Setup.exe pivot (Finding 15) still has no
known automated or manual path past `EarlyF6DriverInstall`'s disk-configuration gate, unchanged
from Session 4's conclusion.

**Recommended next step — Finding 26's option 2, the "modern screen" theory:** rebuild
`Autounattend.xml` to *not* fully automate `DiskConfiguration`/`ImageInstall` (or omit
`DiskConfiguration` entirely) and observe what screen Setup shows instead of jumping straight into
`EarlyF6DriverInstall`. The working theory is that full unattend-driven disk configuration is what
routes Setup into the *legacy* driver-load gate tested exhaustively across Findings 19-25 and 27,
and that the normal interactive "Where do you want to install Windows" screen has a materially
different, non-legacy "Load driver" link never yet tested in this project. This is a bigger change
than Finding 27's (an `Autounattend.xml` rewrite, not a file copy) and still just a theory, not a
confirmed mechanism, per Finding 26's own original framing — treat it as an experiment, not an
assumed fix.

**If option 2 also fails:** per Finding 26's own fallback framing, the honest conclusion is that
the Setup.exe pivot itself (not just its automation) needs reconsidering against the two-tier
bootstrap plan's original fallback path (`PHASE2_BOOTSTRAP_ARCHITECTURE.md`) — i.e., going back to
sub-milestone 1's already-solved, boots-clean-with-zero-driver-problems plain WinPE +
`bcdboot`-from-WinPE path (Findings 6/12), and solving driver injection there via the offline
`hivex` registry technique (Findings 7-8) reapplied to a target disk that's already been made
bootable a different way — rather than continuing to chase driver-load gates inside Setup.exe's
own UI, which has now failed four independent ways (`DriverPaths` unattend config, pre-loaded
`drvload`, manual UI click-through, and `$WinPEDriver$`).

**Persistent state that DOES survive** (under `image-apply/output/`, not `/tmp`):
- `winpe-boot-index2.qcow2` — **now contains a `\$WinPEDriver$\viostor\2k25\amd64\` folder at its
  NTFS partition root**, added this session (Finding 27), left in place (harmless, doesn't affect
  any other test). `winpeshl.ini` unchanged from Session 4's reverted-to-stock state
  (`%SYSTEMDRIVE%\setup.exe` only). `Autounattend.xml` still present and unchanged at both its
  partition root and `\sources\`.
- `win2025-target.qcow2` — still blank/unpartitioned; Setup has never gotten far enough to touch it.
- `answer-floppy.img` — unchanged, still has `Autounattend.xml` + `viostor/2k25/amd64/*`. (This
  session's diagnostic `.txt` log dumps written to it during testing were not preserved — copied to
  the host and deleted from the floppy's working copy is unnecessary since the floppy image itself
  wasn't modified by this session's `mcopy`/`dir >` runs beyond what earlier sessions already left;
  no action needed here.)
- `OVMF_VARS_setup-test5.fd` — this session's fresh OVMF vars copy (from `OVMF_VARS_4M.fd`,
  Secure Boot disabled), boot command otherwise identical to Session 4's (`usb-tablet`/`qemu-xhci`
  included even though this session's testing was log/CLI-driven, not mouse-driven).
- No VM left running this session (confirmed via `pgrep` before ending).

**Key correction to internalize before resuming:** `X:` during this Setup boot flow is **the
physical boot-medium NTFS partition itself**, not a separate RAM-disk copy of `boot.wim`'s
contents. Any future file placed on the mounted `winpe-boot-index2.qcow2` NTFS partition is
directly visible as `X:\...` inside the running session — useful to know for any future
`Autounattend.xml`/driver-placement experiment, not just this one. Also worth remembering: this
boot configuration has **no `C:` drive at all** — only `D:` (Server 2025 ISO), `E:` (virtio-win
ISO), `X:` (boot medium), `A:` (answer floppy).

### Finding 28: the "modern screen" theory (Finding 26's second, costlier lead) tested and ruled
out too — `EarlyF6DriverInstall` fires at identical timestamps whether `DiskConfiguration`/
`InstallTo` are present in the answer file or not, proving the gate isn't routed by disk-config
automation at all

**Setup:** built a variant `Autounattend.xml` identical to the working one except with the entire
`<DiskConfiguration>` element and `<ImageInstall>/<OSImage>/<InstallTo>` removed (keeping
`<InstallFrom>`'s image-name metadata, `<UserData>`, and every later-pass setting unchanged), per
Microsoft's documented behavior that omitting these lets Setup show the interactive "Where do you
want to install Windows" screen instead of driving straight into automated partitioning. The
theory being tested: that screen's non-legacy "Load driver" link might not be gated the same way
`EarlyF6DriverInstall`'s legacy dialog is.

**First attempt — confound caught before drawing any conclusion.** Swapped this variant onto
`winpe-boot-index2.qcow2`'s `Autounattend.xml` (both partition root and `\sources\`) and booted.
The dialog was pixel-identical to every prior test — but `setupact.log`'s own
`UnattendSearchExplicitPath` lines showed **three** "usable" answer files found for pass
`windowsPE`: `A:\autounattend.xml` (the answer floppy — still the *old*, unmodified version, never
touched by this edit), `X:\Sources\autounattend.xml`, and `X:\autounattend.xml` (both edited).
Per this project's own "verify before trusting" standard, this was caught as a real confound
rather than accepted as a negative result — the floppy's old copy could plausibly have been the
one actually applied, silently invalidating the test.

**Second attempt — confound removed, result confirmed clean.** Overwrote `A:\autounattend.xml` on
the floppy with the same variant (`mcopy -o`, no `qemu-nbd` needed for FAT media) so all three
locations Setup finds agree, then rebooted. **Identical dialog again.** `setupact.log` this time
shows the exact same sequence and timing as every prior test, down to the second:
`EarlyF6DriverInstall: Entering Prepare Method` → `Leaving Prepare Method` → (`UnattendDriverInstall`
and `LateF6DriverInstall`'s own Prepare/Leave pairs, unrelated) → `EarlyF6DriverInstall: Entering
Execute Method` → `Driver: Starting Wait`, one second later — matching Finding 24's original
timestamps pattern and Finding 27's repeat of it almost exactly, despite `DiskConfiguration` and
`InstallTo` being completely absent from every answer file Setup could find this time.

**Diagnosis:** `EarlyF6DriverInstall` is not conditionally reached based on whether the answer file
automates disk configuration — its Prepare/Execute sequence runs as a fixed stage of Setup's
PE-hosted execution, immediately after `SetupCore` registers the various F6/driver-related actions
and well before `ImageInstall`/`DiskConfiguration` processing would even begin. Whatever screen
Setup would eventually show for interactive disk selection, it doesn't get there until *after* this
gate — meaning there is no way to reach a "different, modern" driver-load mechanism by skipping
disk-configuration automation, because the same legacy gate sits in front of both paths
unconditionally.

**Root cause:** the original theory's premise (that `DiskConfiguration` automation is what routes
Setup toward the legacy F6 dialog) is false. `EarlyF6DriverInstall` is simply an earlier,
unavoidable phase of Setup's own boot sequence, not a fork in a decision tree the answer file
controls.

**Net effect: both threads in Finding 26's priority list are now ruled out** (Finding 27:
`$WinPEDriver$`; this finding: the modern-screen theory), on top of Findings 19/24/25's three
earlier failed approaches. Five independent approaches have now failed against the same gate. Per
Finding 26's own fallback framing, the honest conclusion is that **the Setup.exe pivot itself
(Finding 15) should be set aside** in favor of the bootstrap architecture's already-solved
alternative: sub-milestone 1 is proven working via real `bcdboot` run from a plain, self-built
WinPE session (Findings 6/12) — a path that never invokes Setup.exe at all, and therefore never
hits this gate — with driver injection needing to be solved on *that* path instead (most likely
revisiting the offline `hivex` registry technique from Findings 7-8, applied to a disk made
bootable via `bcdboot` rather than the main OS disk it was originally tried against).

**Cleanup performed before ending the session:** both `winpe-boot-index2.qcow2`'s `Autounattend.xml`
copies (partition root and `\sources\`) and the answer floppy's copy were reverted to the original,
working version (with `DiskConfiguration`/`InstallTo` intact) via the same backup-then-restore
technique, confirmed via `grep -c DiskConfiguration` returning 2 on both restored files. No VM left
running (confirmed via `pgrep`).

---

## STATUS AND NEXT STEPS ON RESUMPTION (Session 6)

**Where things stand:** every lead Finding 26 identified has now been tried and failed, on top of
the three approaches Session 4 already ruled out. Five independent attempts to get past
`EarlyF6DriverInstall` have failed: `DriverPaths` (Finding 19), pre-loaded `drvload` (Finding 24),
manual UI click-through (Finding 25), `$WinPEDriver$` (Finding 27), and disabling disk-configuration
automation entirely (Finding 28, this session). The evidence across all five is consistent and
timestamp-based, not circumstantial — this is not a "try one more variation" situation.

**Recommended next step: set aside the Setup.exe pivot (Finding 15) and return to the bootstrap
architecture's original, already-validated path.** `PHASE2_BOOTSTRAP_ARCHITECTURE.md`'s
sub-milestone 1 is solved two independent ways that don't involve Setup.exe at all — BCD-SYS
(zero boots) and real `bcdboot` run from a self-built plain WinPE session (`boot.wim` index 1, not
index 2). Neither path ever reaches `EarlyF6DriverInstall`, because neither ever runs Setup.exe.
The remaining problem reduces to: get the virtio storage driver registered into the *offline,
already-applied* Windows image's own driver database, so that when the disk (made bootable via
BCD-SYS or WinPE `bcdboot`) boots for real, the kernel already knows about the viostor device
before `INACCESSIBLE_BOOT_DEVICE` would otherwise occur. This is exactly the original Stage 2
problem from before the Setup.exe pivot began (see "Open items carried forward" after Finding 6),
last attempted via offline `hivex` registry edits (Findings 7-8) and a `DISM`-via-WinPE approach
(root-caused to a COM-hosting failure, Findings 9-13) — both worth revisiting with what this
project has learned since, rather than assumed still-broken:
- The `hivex` `CriticalDeviceDatabase`/`DriverDatabase` registry-injection attempt (Findings 7-8)
  failed for reasons never fully root-caused. It was tried against the *main OS disk* specifically;
  worth first double-checking whether that attempt's failure mode was specific to something about
  the main-OS-disk boot path (full NT kernel boot, different driver-loading code than WinPE) before
  assuming the technique itself is unsound.
- The `DISM`-via-WinPE attempt's COM-hosting failure (Findings 9-13) may be worth revisiting given
  this project's much more mature QMP-based tooling now (`qmp-click.py`, `qmp-type.py`,
  `qmp-sendkey.py`) for driving whatever interactive recovery might be needed, if any.
- `virt-v2v`'s own production-proven offline driver-injection pattern (the original prior-art
  research behind the `hivex` approach) is still the best-documented reference for how this is
  supposed to work — re-reading its actual source for the specific registry keys/values it writes,
  rather than working from this project's own possibly-incomplete reconstruction of the pattern in
  Findings 7-8, is a reasonable first step before any new experiment.

**Persistent state that DOES survive** (under `image-apply/output/`, not `/tmp`):
- `winpe-boot-index2.qcow2` — `Autounattend.xml` (both locations) reverted to the original, working
  version this session; the `\$WinPEDriver$\viostor\2k25\amd64\` folder added in Finding 27 is
  still present (harmless, inert now that this pivot is being set aside). `winpeshl.ini` still in
  Session 4's reverted-to-stock state.
- `winpe-boot-index1.qcow2.bak` — the plain WinPE medium (no Setup.exe), the one this project should
  actually build on going forward per the recommendation above. Confirmed working for `bcdboot` in
  Findings 6/12 — re-verify it still boots cleanly before relying on it, since it hasn't been
  touched since Session 2/3.
- `win2025-target.qcow2` — still blank/unpartitioned.
- `answer-floppy.img` — `Autounattend.xml` reverted to the original this session; driver files and
  historical log dumps from prior sessions still present, harmless.
- No VM left running at the end of Session 6 (confirmed via `pgrep`).

**New fact worth remembering:** Setup's implicit answer-file search checks **multiple locations
and treats more than one as "usable" for the same pass** (`setupact.log`'s
`UnattendSearchExplicitPath` lines) — in this project's boot configuration, that means the answer
floppy (`A:`), the boot medium's `\sources\` folder, and the boot medium's own root are **all**
candidates, and editing only one is not sufficient to guarantee a test reflects the intended
change. Any future `Autounattend.xml` experiment must update **all** locations Setup can find one
(or remove the file from the ones not being tested) before trusting a "nothing changed" result.
