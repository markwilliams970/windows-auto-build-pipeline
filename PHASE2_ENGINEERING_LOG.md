# Phase 2 Engineering Log: First BCD-SYS Experiment (Windows Server 2025)

Status as of this writing (session paused mid-investigation, resuming later — see **"STATUS AND
NEXT STEPS ON RESUMPTION"** at the bottom of this document for the current state and the
recommended next move): **Phase 2 sub-milestone 1 (make the disk bootable) is confirmed working**
for Windows Server 2025 via BCD-SYS, with zero WinPE boot cycles and zero exposure to the
sibling project's "press any key" UEFI landmine. The disk fails at `INACCESSIBLE_BOOT_DEVICE
(0x7B)` on real boot because the boot-critical VirtIO storage driver isn't registered yet — Stage 2
(driver injection) turned into a much deeper investigation than expected, is not yet resolved, and
a promising architectural pivot was identified but not yet attempted. See
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
