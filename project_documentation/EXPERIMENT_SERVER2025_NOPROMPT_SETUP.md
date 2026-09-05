# Experiment: does Windows 11's Setup.exe fix also unblock Windows Server 2025?

**Status: CONFIRMED, 3 independent successes, 2026-09-05 - including with the sibling
project's own virtio driver-injection approach. This is a research spike for the sibling
project (`../windows-server-vm-automation/`), not a change to this project's own production
pipeline.** This project's own Server 2025 support is already done via full offline-apply
(see `CLAUDE.md`'s Phase 2/3 status) and is unaffected by anything here. The scripts and
findings below unblocked the *sibling* project's Packer+autounattend Server 2025 support,
which had been fully blocked since its own Finding 15 - the sibling project is now
implementing this for real via its own careful, research-driven, phased approach (reported
by the user, not tracked in this repo - see "Update" below).

**Reproducibility trail:**
1. This project's own run (below): plain IDE/e1000, no virtio drivers - succeeded, first
   attempt.
2. The sibling project's own independent re-run of this experiment's scripts (`run2`,
   `WIN2025EXP2`) - succeeded, reported by the user; not independently observed by this
   session (no screenshot/log captured here).
3. A further re-run (`WIN2025VIO`, `image-apply/experiments/server2025-noprompt-virtio-setup-experiment.sh`)
   **with the sibling project's own proven virtio-scsi + `DriverPaths` driver injection layered
   in** (not the plain-IDE simplification this experiment used) - also succeeded, reported by
   the user; not independently observed by this session, though the script itself (added to
   this repo alongside this run) includes a live `Get-PnpDevice` check confirming real vioscsi/
   netkvm driver binding, not just a successful boot.

Three-for-three clears this project's own "2-3 independent successes" reproducibility
standard, and the third run specifically closes the "driver injection untested" gap flagged
below when this doc was first written.

---

## The question

The sibling project's Windows Server 2025 support has been blocked since
`WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md`'s Finding 15: Server 2025 media reliably falls
through the "press any key to boot from CD or DVD..." UEFI prompt and drops to PXE/the EFI
shell, every single time - a known, unresolved upstream Packer/QEMU/OVMF issue
(`hashicorp/packer#13342`/`#13514`). Only one fix was tried there: an explicit QEMU boot-order
hint (`qemuargs = [["-boot", "order=d,menu=off"]]`) *inside Packer's own builder* - confirmed
present on the real command line, but made no observable difference.

This project separately solved the identical-looking problem for **Windows 11** media
(`image-apply/windows11-setup-install.sh` + `image-apply/build-iso-noprompt.sh`), via two
changes together:

1. A `_noprompt`-patched install ISO (Microsoft's own, genuinely 15-year-old
   `efisys_noprompt.bin`/`cdboot_noprompt.efi`, which ship on the stock ISO itself - not a
   community hack) - this removes the "press any key" prompt *by construction*, no keystroke
   race to time at all.
2. A hand-built `qemu-system-x86_64` invocation with **no `-boot` override and no
   `bootindex=`** on any device - bypassing Packer's QEMU builder entirely and simply letting
   OVMF's own natural NVRAM boot-device enumeration pick the CD-ROM on the very first boot
   (the only bootable device on a blank disk), then pick the disk's own newly-registered
   "Windows Boot Manager" entry on every reboot after that.

Finding 15 itself already flagged the noprompt technique as "a cheap, low-risk thing to try
before anything more invasive" but noted nobody had tried it for this exact bug, and separately
observed that noprompt "doesn't touch OVMF's EFI-shell-first boot-device ordering" - i.e. it was
an open, unverified question whether removing the prompt alone would be enough, or whether the
deeper cause was OVMF's own boot-device selection.

**This experiment asks directly: does the *combination* (noprompt ISO + hand-built qemu,
not Packer's builder) get Server 2025 past Finding 15's failure, the way it did for Windows 11?**

---

## Method

Two new, deliberately isolated files under `image-apply/experiments/` (kept out of
`build.sh`/`windows-pipeline` entirely - see "Scoping and the CLAUDE.md override" below):

- **`build-iso-noprompt-server2025.sh`** - a Server-2025-targeted sibling of the production,
  Windows-11-only `image-apply/build-iso-noprompt.sh`. Same verified xorriso dual-boot-catalog
  recipe, different source ISO. Before building anything, confirmed by direct `7z l` listing
  (not assumed) that Server 2025's cached ISO
  (`2025-26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso`) does
  ship `efisys_noprompt.bin`/`cdboot_noprompt.efi` at the same paths as Windows 11 media.
- **`server2025-noprompt-setup-experiment.sh`** - a Server-2025-targeted sibling of
  `image-apply/windows11-setup-install.sh`. Identical hand-built-qemu shape (plain
  `ide-cd`/`ide-hd`/`e1000`, no `bootindex=`, QMP socket, graceful `system_powerdown`, the
  `$?`-capture trap fix from CLAUDE.md's own bash-trap standard, USB tablet device per the
  project's standing convention). Deliberately **no virtio drivers** - this pass isolates the
  one variable actually in question (does Setup.exe get past the boot hang at all), not
  driver injection, which Server 2022/2025 already have a completely different, already-proven
  mechanism for in this project's own production pipeline (offline `hivex`).
- **`autounattend-server2025-noprompt-experiment.xml`** - adapted from two already-proven
  sources rather than written from scratch: `image-apply/autounattend-windows11-phase33.xml`'s
  windowsPE structure and FirstLogonCommands (OS-agnostic PowerShell, reused verbatim), plus
  the sibling project's own proven Server 2022
  `packer/answer_files/autounattend.xml.pkrtpl` for the `Microsoft-Windows-Setup`
  `DiskConfiguration`/`ImageInstall` shape (LabConfig TPM/SecureBoot/RAM/CPU bypasses removed -
  not applicable to Server; `ProductKey` omitted, matching that template's own documented
  reason). `/IMAGE/INDEX` = 2, reusing this project's own already-verified value ("Windows
  Server 2025 SERVERSTANDARD", Desktop Experience Eval - `PHASE2_ENGINEERING_LOG.md` Finding 0)
  rather than re-deriving it.

Single QEMU invocation, `-display none`, `-qmp unix:...,server,nowait`, WinRM polled over a
`hostfwd` port from the host via `pywinrm`, exactly matching Windows 11's own confirmation
method (not a screenshot alone - though screenshots were also taken via
`tools/qmp-screenshot.py` at two points for direct visual confirmation).

---

## Result: succeeded, first attempt, no manual intervention

- **~09:24:12** - qemu launched (noprompt ISO + answer-file ISO + blank 40GB target disk, no
  boot overrides).
- **~09:25** (screenshot 1) - already at the real "Windows Server Setup" GUI, "Please wait"
  install-in-progress screen. This alone is the headline result: the sibling project's Server
  2025 attempts **never reached this point at all** under any of Finding 15's four attempts -
  every one fell through to PXE/the EFI shell before Setup.exe ever started.
- **~09:36** (screenshot 2) - a live, real Windows Server 2025 desktop: Server Manager open,
  taskbar populated, a `FirstLogonCommands`-launched "Administrator: Windows PowerShell" window
  visible (the answer file's Order 2/3 network-wait + WinRM-enable steps, matching
  `autounattend-windows11-phase33.xml`'s own proven pattern) - both reboots (post-image-apply,
  post-specialize) already completed by this point.
- **WinRM confirmed**: `hostname` returned `WIN2025EXP`, exactly matching the answer file's
  `<ComputerName>` - not just a screenshot, a real authenticated WinRM session.
- **Graceful shutdown** via QMP `system_powerdown` completed cleanly; qemu exited on its own,
  no forced kill needed.
- **Total wall time, boot to WinRM-confirmed-and-shut-down: ~12-13 minutes** - in the same
  ballpark as Windows 11's own Phase 3.4 confirmations (14-16 minutes), and faster, since this
  run needed no eject step or retry of any kind.

No retries, no manual intervention, no hung boot, no EFI shell fallback observed at any point.

---

## What this answers, and what it doesn't

**Answered**: the noprompt-ISO + hand-built-qemu combination *does* get Windows Server 2025
past whatever Finding 15's failure actually was, on this host, with this exact QEMU/OVMF
version. Finding 15's own open question - whether the deeper cause was OVMF's EFI-shell-first
boot-device ordering, which noprompt alone wouldn't fix - is resolved in the encouraging
direction for this combination, though this experiment doesn't isolate *which* of the two
changes (noprompt vs. bypassing Packer's builder) was actually necessary, only that the
combination works. (Worth noting for whoever picks this up next: Finding 15's own boot-order
hint was tried only *inside* Packer's builder, never as part of a genuinely hand-built
invocation - so it's also possible Packer's own additional default flags/devices were part of
the original problem, not just the missing boot-order control.)

**Answered by the follow-up runs (reported by the user, see "Reproducibility trail" above)**:
- Virtio storage/NIC driver injection - the sibling project's own proven `DriverPaths`-based
  virtio injection (Server 2022's own mechanism) also works cleanly through this noprompt +
  hand-qemu Setup.exe path for Server 2025. This was this doc's biggest open question on first
  writing and is now closed.
- Reproducibility - 3 independent successes total (this project's plain-IDE run, the sibling's
  identical re-run, and the sibling's driver-injection run), clearing this project's own
  "2-3 independent successes" standard.

**Still not answered / explicitly out of scope for this document**:
- AD DS/IIS/SQL Server role provisioning through this path - not attempted here at all.
- Whether this generalizes cleanly into the sibling project's *actual* Packer-based workflow
  end-to-end (a hand-built-qemu Setup.exe step handing off to Packer's own role-provisioning
  phase) - the sibling project's own phased implementation, now underway, is where that gets
  answered; not tracked in this repo.

---

## Recommendation for the sibling project (superseded by "Update" below)

This section is kept as the original record of what was recommended before the sibling
project's own confirmations came in. Steps 1 and 2 are now done (see "Reproducibility trail"
above); step 3 is what the sibling project's own phased implementation is now addressing.

This is real, positive evidence that Finding 15 is worth revisiting with the noprompt+hand-qemu
approach specifically - not a "ship it" result. Suggested next steps, in order:
1. ~~Reproduce this same experiment 1-2 more times to rule out a lucky single run~~ **Done** -
   confirmed twice more by the sibling project.
2. ~~Layer the sibling project's own proven virtio-scsi + `DriverPaths` driver injection back
   in~~ **Done** - confirmed working by the sibling project.
3. Only then consider how to fit a hand-built-qemu step into the sibling's actual Packer-based
   workflow (e.g. a pre-step that does the Setup.exe install this way, handing off to Packer's
   `disk_image=true`/no-ISO mode afterward for role provisioning - the same shape this project's
   own Server 2022/2025 production pipeline already uses via `packer/boot-and-provision.pkr.hcl`)
   - **in progress**, in the sibling project's own repo, via its own careful, research-driven,
   phased approach. Not tracked in this repo; see the sibling project's own engineering log for
   the real trail going forward.

---

## Update (2026-09-05, later the same day)

The user reports the experiment succeeded twice more independently - once as a plain re-run of
this repo's own scripts, and once with the sibling project's own virtio-scsi + `DriverPaths`
driver injection layered in (matching its proven Server 2022 mechanism, not this experiment's
simplified plain-IDE/e1000 scope). Neither follow-up run was independently observed from this
session (no screenshot or log captured here for either) - recorded as reported.

The sibling project is now moving from spike to real implementation of its own Server 2025
Setup.exe support, using a careful, research-driven, phased approach (matching this project's
own "work incrementally, don't build in one shot" standard). That work happens in
`../windows-server-vm-automation/`'s own repo and engineering log, not here - this document's
job is done once the spike that unblocked it is fully recorded, which is now.

---

## Scoping and the CLAUDE.md override

`CLAUDE.md`'s ban on `Microsoft-Windows-Setup` for Server 2022/2025 is written as "absolute, no
exception" for this project's own production pipeline, and that wording is also hard-gated into
`image-apply/build-iso-noprompt.sh` and `image-apply/windows11-setup-install.sh` (both refuse to
run against anything but Windows 11 media). This experiment deliberately overrides that rule, as
an explicit, scoped, user-authorized research spike whose intended beneficiary is the *sibling*
project, not this one:

- Neither hard-gated production script was modified.
- Nothing in `build.sh` or `windows-pipeline` references anything under
  `image-apply/experiments/`.
- This project's own Server 2022/2025 production path (full offline-apply) is unaffected and
  remains the canonical mechanism here.

**By explicit user request, `image-apply/experiments/*.sh` and
`autounattend-server2025-noprompt-experiment.xml` are being kept in the repo** (not deleted as
part of this experiment's own disk-hygiene cleanup) specifically so the sibling project can
reference or copy them. Only the disposable run artifacts (the resulting qcow2 disk, the
extracted-ISO scratch directory, the per-run work directory) are candidates for cleanup, and
only with explicit confirmation first, per this project's own disk-hygiene standard.
