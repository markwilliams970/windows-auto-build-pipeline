# `image-apply/experiments/` - research spikes, not production

Everything in this directory is a **one-off research spike**, kept for reference, not part of
this project's production pipeline. Nothing here is called by `build.sh`, `windows-pipeline`,
or any other production script - `grep -rn "experiments/" --include=*.sh --include=*.hcl` from
the repo root outside this directory should turn up nothing, and should stay that way.

## Why this directory exists at all

`CLAUDE.md` bans using `Microsoft-Windows-Setup` (interactive Windows Setup.exe, driven by an
`autounattend.xml`) for Windows Server 2022/2025 in this project, "absolute, no exception" -
this project's own production Server 2022/2025 path is full offline image application
(`wimlib`/`bcdboot`/offline `hivex`), never a booted installer. That ban is correct and
unchanged for this project's own pipeline; nothing here weakens it, and the two scripts it
actually gates (`image-apply/build-iso-noprompt.sh`, `image-apply/windows11-setup-install.sh`,
both Windows-11-only) were never modified for this work.

The files in this directory exist for a different, explicitly scoped purpose: they were a
research spike, run with the user's explicit authorization to override that rule for this one
purpose, whose intended beneficiary is the **sibling project**
(`../windows-server-vm-automation/`), which *does* use Setup.exe/autounattend.xml as its normal
mechanism (proven for Server 2022) but was fully blocked on Server 2025 by a known, unresolved
upstream Packer/QEMU/OVMF UEFI boot issue (that project's own
`WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`, Finding 15).

## What's here and what it proved

Two experiment lines, run in sequence - the second only after the first was already proven, to
isolate variables one at a time rather than changing everything at once:

**Line 1 - does Setup.exe get past the boot hang at all?** (plain IDE/e1000, zero driver
injection, deliberately - Windows' own inbox drivers need no injection at all)
- `build-iso-noprompt-server2025.sh` - builds a Server-2025-targeted, `_noprompt`-patched
  install ISO (same technique as this project's own `image-apply/build-iso-noprompt.sh`, kept
  separate rather than parameterizing that script, so its Windows-11-only gate stays literal
  and unambiguous).
- `server2025-noprompt-setup-experiment.sh` - the hand-built `qemu-system-x86_64` invocation
  (no Packer, no `bootindex=`/`-boot` override) that drives an unattended Setup.exe install
  against the noprompt ISO, plain `ide-hd`/`e1000` devices.
- `autounattend-server2025-noprompt-experiment.xml` - the answer file that install uses,
  adapted from this project's own proven Windows 11 template and the sibling project's own
  proven Server 2022 template.
- Succeeded twice independently (`WIN2025EXP`, `WIN2025EXP2`).

**Line 2 - does it still work with the sibling project's actual production device model** (a
virtio-scsi target disk + virtio-net NIC, needing real driver injection, not Windows' inbox
drivers)?
- `build-unattend-drivers-iso-server2025-virtio.sh` - builds the combined answer-file +
  virtio-driver CD (vioscsi/viostor/NetKVM's "2k25" subfolder, extracted from the cached
  virtio-win ISO), matching the sibling project's own `build.sh` extraction recipe exactly.
- `server2025-noprompt-virtio-setup-experiment.sh` - the same hand-built-qemu shape as line 1,
  but with `virtio-scsi-pci`/`scsi-hd` and `virtio-net-pci` devices instead of IDE/e1000, plus a
  live post-install check (`Get-PnpDevice -Class SCSIAdapter,Net`) confirming the real vioscsi/
  netkvm drivers bound, not a silent fallback to something else.
- `autounattend-server2025-noprompt-virtio-experiment.xml` - the answer file's `DriverPaths`
  content (both the `windowsPE`-pass and `NonWinPE`-pass copies, plus the `FirstLogonCommands`
  `pnputil` fallback) is transcribed directly from the sibling project's own proven
  `packer/answer_files/autounattend.xml.pkrtpl` - not reinvented.
- Succeeded once (`WIN2025VIO`), with real virtio driver binding confirmed live, not just a
  successful boot.

**Result: confirmed, 3 independent successes total (2026-09-05)** across both lines - the
noprompt+hand-qemu technique itself, and the sibling project's actual virtio device model and
driver-injection mechanism layered on top of it. Full method, timeline, and evidence:
`project_documentation/EXPERIMENT_SERVER2025_NOPROMPT_SETUP.md`.

## What to actually do with these files

**Read them and the findings doc above before reusing anything.** They're kept specifically so
the sibling project can reference or copy them while building its own real, phased Server 2025
Setup.exe support - not because they're meant to run again inside this repo. If you're in this
repo and reaching for these files to actually build something, stop and re-check
`CLAUDE.md`'s ban first; if you're in the sibling repo adapting these, you're using them for
their intended purpose.

Any host-side run artifacts these scripts produce go under `image-apply/output/experiments/`
(git-ignored, same as the rest of `image-apply/output/`) and are disposable - safe to delete at
any time and cheap to regenerate by re-running the scripts.
