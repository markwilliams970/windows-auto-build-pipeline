# Handoff: from unattend.xml-driven Setup to offline DISM image application

This project exists because its sibling, `../windows-server-vm-automation/`, hit a wall that
turned out to be a known, currently-unresolved upstream issue rather than something fixable by
more configuration tuning. This document is the detailed record of what was tried there, what
was learned, and why this project takes a fundamentally different approach to getting Windows
onto a disk. Read this before writing any code here — it exists so you don't have to re-derive
any of this from scratch, and so you don't accidentally re-attempt things that were already
tried and shelved.

If you want the full blow-by-blow (every finding, every command, every screenshot description),
the sibling repo's own engineering logs have it:
- `../windows-server-vm-automation/WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md` (Server 2022 — works;
  Server 2025 — blocked, see its Finding 15)
- `../windows-server-vm-automation/WINDOWS11_UNATTENDED.md` (Windows 11 — blocked, Findings W1-W3)

This document is the condensed, decision-focused version of both.

**Note on current status (added later, do not let it undermine the analysis below - the analysis
is still exactly why this project's offline-apply approach exists and remains correct for Server
2022/2025):** the offline-apply approach this document motivates was pursued for Windows 11 too,
but that specific pathway later hit its own hard stop (a first-boot BSOD, root-caused to neither
this project's code nor environment - see `PHASE3_ENGINEERING_LOG.md`'s "HARD STOP" section).
Windows 11 was eventually unblocked by a *different* mechanism than either this document or the
sibling project's own blocked `boot_command` approach describes: a `_noprompt`-patched ISO plus a
hand-built `qemu-system-x86_64` invocation (not Packer-managed, so the `boot_command`/keystroke-race
problem this document describes doesn't apply to it at all) - see
`WINDOWS11_NEXT_APPROACH_RESEARCH_PLAN.md` and `PHASE3_ENGINEERING_LOG.md`'s Phase 3.4/3.5 entries.
Server 2022/2025 still use exactly the offline-apply approach this document describes, unchanged.

---

## What the sibling project is, and why it exists

`windows-server-vm-automation` builds a disposable, reproducible Windows lab environment
(Windows Server, and eventually Windows 11 client machines) on KVM/libvirt, for Datadog Agent
integration testing — simulating realistic enterprise and regulated-cloud (FedRAMP/GovCloud-style)
customer environments. The explicit, stated design goal there (and here) is **not** a golden
image: every build starts from a clean install source and produces one disposable,
already-specialized disk, every time. That's a hard requirement carried forward into this
project too — see "Why not just build a golden image and clone it" below for exactly why that
matters more than it might first appear.

Three target operating systems were in scope: Windows Server 2022, Windows Server 2025, and
Windows 11 (Enterprise Evaluation edition, chosen over Home/Pro to better simulate a realistic
enterprise machine and to avoid Home edition's much harder-to-automate Microsoft Account/OOBE
requirements).

## What worked: Windows Server 2022

Packer + QEMU/KVM, booting the real Windows Server 2022 evaluation ISO, with an
`autounattend.xml` (delivered via a second generated CD-ROM alongside the install media) driving
a fully unattended interactive Setup — UEFI firmware, `boot_command` spamming `<spacebar>` over
VNC to catch the install media's own "Press any key to boot from CD or DVD..." prompt, then
`FirstLogonCommands` enabling WinRM for Packer's own provisioner phase. This is fully working,
confirmed end-to-end, no manual intervention required. Three post-install role-provisioning
scripts (IIS, AD DS, SQL Server 2022 Developer Edition) are also implemented and independently
verified against this baseline, dispatched by a `services.yaml`-driven orchestrator
(`scripts/run-services.ps1`).

**This is the part of the old project that's still perfectly good and directly reusable here —
see "What to carry forward" below.** The problem was never the post-install provisioning layer;
it was specifically the *installation* mechanism for two of the three target OSes.

## What didn't work: Windows Server 2025 and Windows 11

The exact same `boot_command`/VNC-keystroke mechanism that works reliably for Server 2022 — across
many builds, in the same session — **reliably failed** for both Server 2025 and Windows 11
Enterprise Evaluation media. Not intermittently: every single attempt, across multiple different
fix strategies, fell through the "press any key" prompt to a dead end (PXE fallthrough with no
DHCP server to answer it, and eventually the OVMF UEFI Interactive Shell once PXE itself gave up).

Things tried, all shelved as ineffective (do not re-attempt without genuinely new evidence):

- Widening the keystroke window in both directions (starting sooner, running longer — from
  `boot_wait=2s`/25 presses over ~25s, to `boot_wait=1s`/60 presses over ~60s).
- An explicit QEMU boot-order hint (`qemuargs = [["-boot", "order=d,menu=off"]]`), confirmed via
  live `ps aux` inspection to actually be present in the running qemu invocation, additive and not
  colliding with Packer's own generated `-drive`/`-device` arguments.
- A different keystroke entirely (`<enter>` instead of `<spacebar>`), following a working
  reference project (see below).
- Fully manually constructing every `-drive` via `qemuargs` (bypassing Packer's own native
  `iso_url`/`efi_firmware_*`/`cd_files` fields entirely) to get deterministic control over device
  ordering, on the theory that Packer's own auto-generated ordering might be the actual culprit.

That last one, while it didn't solve the core problem, **did** surface one genuine, confirmed bug
along the way, worth knowing regardless of which install mechanism this project ends up using:
when constructing `-drive media=cdrom,...` manually via `qemuargs` with no explicit `index=`,
QEMU/OVMF's own bus assignment can be ambiguous enough that BDS never enumerates the device as a
boot candidate at all (`BdsDxe: No bootable option or device was found` — a firmware-level
"nothing to boot" error, not the interactive prompt). Adding `index=0`/`index=1` fixed this
specific symptom cleanly. This is a real, useful fact about QEMU/OVMF in general, independent of
everything else in this document — see the Arch Linux forum thread
(bbs.archlinux.org/viewtopic.php?id=212268, "\[solved\]") that root-caused it originally.

Checked against the community before assuming a local/host-specific bug (worth doing early in any
future investigation too — this saved real time): this is a **known, currently open, unresolved
issue** affecting other people independently, not something specific to this host or this
project's configuration:
- [hashicorp/packer#13342](https://github.com/hashicorp/packer/issues/13342) and
  [#13514](https://github.com/hashicorp/packer/issues/13514), "Windows 2025 Server ISO Boot
  Loop" — open, no maintainer fix.
- [HashiCorp Discuss: "QEMU - Windows unable to boot in UEFI mode"](https://discuss.hashicorp.com/t/qemu-windows-unable-to-boot-in-uefi-mode/76406) —
  a user hit the identical symptom (drops to EFI Shell, ISO content on `FS1:` instead of `FS0:`).
  Community diagnosis: "in UEFI, the EFI shell is first in the boot order, and Packer currently
  lacks the capability to alter this for UEFI boots." A suggested workaround was tried by that
  user too, and also failed.
- A related Proxmox forum thread describes a *different* Server 2025 problem (installer freezing
  at partition selection due to stricter `SanPolicy` disk-offline defaults with virtio storage) —
  not the same symptom, but independent corroboration that Server 2025 media is broadly pickier
  about boot/disk setup across multiple QEMU-based hypervisors, not just this one setup.

**The working reference used for the qemuargs rewrite attempt**, in case it's useful for anything
else: [github.com/eb4x/packer-qemu-win11](https://github.com/eb4x/packer-qemu-win11). Its
approach (full manual qemuargs, `vtpm`/`tpm_device_type` native Packer fields for TPM, `floppy_content`
for just the answer file instead of `cd_files`, raw virtio-win.iso mounted directly rather than a
curated driver subset) informed the rewrite here, though ultimately even matching it closely
didn't resolve the core boot-timing issue for this project's exact setup.

**Best current theory, not proven:** the failure is tied to *Windows media vintage* rather than
Server-vs-client OS family specifically — Windows 11 (build 26200) and Server 2025 (build 26100+)
are both much newer media builds than Server 2022, and both fail identically while Server 2022
never has. Nobody in the community threads found above has produced hard evidence of *why* —
only that it happens. The most promising unexplored diagnostic (never actually executed, only
scoped) was direct QMP-based screendumping of the VM every ~250-500ms right after boot, to see
exactly what's on screen and when, rather than continuing to guess at keystroke/timing parameters
blindly.

## Why offline DISM image application instead of continuing to fight this

The realization that reframed the whole approach: **hyperscalers (AWS/GCP/Azure) don't solve this
problem at instance-launch time at all.** When you launch a Windows VM on any of them, you're not
booting a raw ISO with an interactive Setup wizard — you're booting an already-installed,
already-generalized disk image that was built once, upstream, via a controlled offline imaging
pipeline (conceptually: partition a disk, apply a WIM image directly to it with `DISM
/Apply-Image` or equivalent, make it bootable with `bcdboot`, done — Setup.exe's interactive GUI
and its "press any key" boot stub are never involved at all). The "specialize" work you'd
recognize (hostname, network, admin password) then happens via a lightweight first-boot agent, not
via unattend.xml driving a live installer.

This project adopts that *mechanism* (offline image application) without adopting the
hyperscalers' *golden-image-and-clone* model — see the next section for exactly why that
distinction matters and isn't optional.

### Why not just build a golden image and clone it (the eval-media expiration problem)

This was explicitly raised and needs to stay a hard constraint on this project's design, not just
a one-time consideration: **Windows evaluation media has a built-in, time-limited activation
countdown, and it does not reset when you clone the disk.** The countdown is baked into the
image's own activation/SLC (Software Licensing) state at the moment of install — clone a disk that
was activated on day 0, boot the clone on day 100, and it reports having only the *original*
remaining time left, not a fresh countdown. `sysprep /generalize` + `slmgr /rearm` can buy a few
more ~180-day windows, but the rearm counter itself is *also* part of the state that gets cloned,
and it's capped at a small number of total uses (typically 3-5, depending on the Windows version)
for the *entire lifetime of that original installation* — not per clone. A golden-image-and-clone
model against eval media would therefore eventually produce clones that are born already expired,
with no way to reset it short of rebuilding from a fresh ISO again — at which point you've gained
nothing over just doing a fresh install every time in the first place.

**The fix for this project is straightforward and was the whole point of separating "mechanism"
from "model" above: apply the WIM offline, fresh, on every single build.** Never cache or reuse a
previously-applied disk as a starting point for new builds. This preserves the sibling project's
"always fresh, no golden image" design goal completely (each build's eval clock genuinely starts
at zero, every time) while still avoiding the flaky interactive-installer boot entirely. If this
project ever needs actual image caching/snapshotting for *iteration speed* during development
(the sibling project's `dev/` harness does exactly this, for testing role-provisioning scripts
quickly — see "What to carry forward" below), that's a different, already-solved problem
(COW overlays refreshed from a known-fresh baseline for *dev testing only*, explicitly not part of
the real build workflow) and doesn't reintroduce the expiration risk as long as the *real* build
path always applies the WIM fresh.

If this project ever moves to genuine volume-licensed/KMS-activated Windows media instead of eval
media, this particular constraint goes away (KMS activation is a periodic-network-reachability
model, not a hard baked-in countdown) — but that's a separate, bigger decision (real licensing,
possibly a local KMS host inside the lab) that hasn't been made and shouldn't be assumed.

## What to carry forward from the sibling project

These are independent of *how* Windows gets onto the disk, and should be reusable close to as-is:

- **`../iso_cache/` and its currency-check convention.** Version-keyed ISO filenames, `.sha256`
  sidecars (standard `sha256sum` format), `.meta` sidecars recording source URL + an upstream
  freshness fingerprint (ETag, or a resolved versioned filename), checked via a cheap `curl -I`
  before deciding to re-download. Already has Server 2022, Server 2025, and Windows 11 Enterprise
  Eval ISOs cached with this convention. The cache directory itself now lives one level above both
  repos (`../iso_cache/`, relative to either repo root), shared between this project and the
  sibling rather than duplicated per-repo — no copying/symlinking needed, just resolve it the same
  way the sibling project's `build.sh`/`build-windows11.sh` do: default to
  `${REPO_ROOT}/../iso_cache`, overridable via the `ISO_CACHE_DIR` environment variable.
- **The role-provisioning layer entirely — these are drop-in reusable, verbatim, no changes
  needed.** They only assume a booted VM with WinRM reachable and two specific files already
  uploaded to it; nothing in any of them depends on *how* Windows got installed. All live at
  `../windows-server-vm-automation/scripts/`:

  | File | What it does | Notes for this project |
  |---|---|---|
  | `run-services.ps1` | Orchestrator. Reads `C:\Windows\Temp\services.yaml`, parses the flat `- role` list with a plain regex (no YAML module dependency), and for each role runs `C:\Windows\Temp\scripts\install-<role>.ps1` if present, else warns and skips. Throws (non-zero exit) if any role's script fails, so a broken build fails the Packer build loudly. | Takes params `-ServicesYamlPath` (default `C:\Windows\Temp\services.yaml`), `-ScriptsDir` (default `C:\Windows\Temp\scripts`), `-DomainName` (default `corp.example.internal`). Whatever Packer template invokes this needs to (a) upload `services.yaml` to that exact path, (b) upload the whole `scripts/` directory to that exact path, (c) pass `-DomainName` sourced from a Packer variable if `ad-ds` will ever be used. Also contains one hardcoded exception: role name `ad-ds` maps to script `install-ad.ps1`, not the naive `install-ad-ds.ps1` the plain convention would imply — matches ../CLAUDE.md's repo-structure naming. |
  | `install-iis.ps1` | Installs IIS, verifies the default site returns HTTP 200 before returning. Branches on `(Get-ComputerInfo).OsProductType`: `Install-WindowsFeature`/`Get-WindowsFeature` (Server-only cmdlets) if `"Server"`, else `Enable-WindowsOptionalFeature -FeatureName IIS-WebServerRole -All` (client SKUs — Server cmdlets don't exist there at all). | Confirmed working against Server 2022 only — the client branch was written for Windows 11 but never actually exercised, since Windows 11 never booted far enough to reach the provisioning phase. Superseded by explicit project direction rather than ever tested: ../CLAUDE.md's own scope note states AD DS/IIS/SQL Server are Server-20XX-specific, not applicable to Windows 11 at all — this client branch stays permanently unexercised by design, not as an open TODO. |
  | `install-ad.ps1` | Promotes to the first DC of a new AD forest + DNS, via `Install-ADDSForest -DomainName $env:AD_DOMAIN_NAME ... -NoRebootOnCompletion`. Server-only; do not select for a Windows 11 build (see Open Issue below). | Reads `$env:AD_DOMAIN_NAME`, set by `run-services.ps1` from its own `-DomainName` param — see that row above. Deliberately does **not** reboot itself (`-NoRebootOnCompletion`): the reboot is expected to happen via a separate `provisioner "windows-restart"` step in whatever Packer template calls this, run immediately after `run-services.ps1` and before `verify-post-reboot.ps1` (next row) — this three-step provisioner sequence (`run-services.ps1` → `windows-restart` → `verify-post-reboot.ps1`) needs to be replicated exactly in this project's own Packer template, unconditionally, the same way the sibling project's does (Packer can't conditionally include a provisioner based on whether `ad-ds` was actually selected). Leaves a marker file `C:\Windows\Temp\.ad-ds-installed` on success. |
  | `verify-post-reboot.ps1` | Always invoked (same reasoning as the `windows-restart` step above — unconditional). No-ops immediately if `install-ad.ps1`'s marker file isn't present. Otherwise checks `NTDS`/`DNS` services are running and `Get-ADDomain` succeeds. | Only makes sense to run *after* the reboot step, since AD DS/DNS aren't up until then — must stay last in the provisioner sequence. |
  | `install-sql-server.ps1` | Downloads and silently installs SQL Server 2022 Developer Edition (Mixed Mode auth, SQL Server Agent enabled), verifies via a real `SELECT 1` over a SQL login. Server-only; do not select for a Windows 11 build. | Self-contained — downloads its own installer media at provisioning time, no Packer-side wiring beyond the standard `services.yaml`/`scripts/` upload. Two non-obvious fixes are baked in and worth knowing about if this script is ever touched: `/UPDATEENABLED=False` is *required* whenever `/Q` is used (otherwise setup tries to reach Windows Update and fails in an isolated lab network), and account-name values containing spaces (`"NT AUTHORITY\NETWORK SERVICE"`) need their own embedded quotes when passed through `Start-Process -ArgumentList`, which does not auto-quote array elements containing spaces. |

  **Open issue carried over from the sibling project, unresolved there too**: `run-services.ps1`
  only skips a role when its script file is missing from `scripts/` — it has no OS-awareness of
  its own. Since `install-ad.ps1` and `install-sql-server.ps1` both exist (for the Server builds),
  nothing currently stops someone from listing `ad-ds` or `sql-server` in a Windows 11 build's
  `services.yaml` and having those scripts actually attempt to run against a client SKU (and
  almost certainly fail). Worth fixing with an OS-awareness check (matching the pattern
  `install-iis.ps1` already uses) before this project's Windows 11 track needs `services.yaml` to
  be trustworthy on its own, rather than relying on a human to just not do that.
- **The `dev/` fast-iteration harness pattern**: a frozen baseline disk + Packer's own
  `disk_image = true` / `use_backing_file = true` (copy-on-write overlay, only changed blocks
  stored, `skip_compaction` auto-forced) to test role-provisioning changes in a few minutes
  instead of a full rebuild. Once this project has *any* way of producing a bootable,
  freshly-applied Windows disk, the exact same pattern applies for iterating on the
  provisioning-script side of things — and likely becomes the mechanism for the "boot the
  already-applied disk and run provisioners" phase of the real build too (see next section).
- **The general discipline established the hard way this session**: verify download URLs with a
  real `curl -I` before trusting them (not just search-result summaries); verify WIM
  edition/image names by direct extraction (`7z e .../install.wim` + `strings -el ... | grep
  EDITIONID`) before assuming a `/IMAGE/NAME` value is correct; check the community for a known
  issue before assuming a novel bug; `kill -9` (not plain `kill`) if you need Packer's disk
  artifact to survive a cancelled build for forensics, since Packer's normal SIGTERM handling
  deletes its own output directory on cancel.

## What does *not* carry forward, and what this project needs to build instead

- The entire `boot_command`/VNC-keystroke-injection mechanism, and the whole idea of booting the
  install ISO as a live interactive OS at all. Gone.
- `autounattend.xml`'s `windowsPE`-pass `Microsoft-Windows-Setup` component (disk partitioning +
  `/IMAGE/NAME` selection) — that's Setup.exe's own job, and Setup.exe is no longer in the
  picture. Disk partitioning becomes this project's own explicit responsibility (`diskpart`/
  `sgdisk`/`parted`, done directly, not declaratively via unattend).
- The `specialize`/`oobeSystem` unattend passes (computer name, WinRM enablement,
  `FirstLogonCommands`) may still be *conceptually* useful — Windows still needs an unattend file
  of some kind applied to the offline image before first boot to handle specialization without a
  human at the keyboard — but how exactly that gets injected into an offline-applied image (versus
  Setup.exe consuming it from removable media during a live install) is one of this project's
  first real design questions. `DISM /Apply-Unattend` (applying an unattend answer file to an
  offline, mounted Windows image, no boot required) is the likely mechanism — needs verification.

## Prior art / community research (done before designing anything here — same discipline as the sibling project)

We are not the first to want this. Before scoping the building blocks below, the actual procedure
was checked directly against Microsoft's own documentation and multiple independent real-world
deployment writeups, for all three target OSes specifically — not assumed to transfer from one to
the others. Sources quoted directly, not just search-summarized, wherever a claim mattered.

**The canonical recipe is Microsoft's own, and it is not what we first assumed.** Microsoft's
official OEM/manufacturing documentation
([Capture and Apply Windows using a WIM file](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/capture-and-apply-windows-using-a-single-wim?view=windows-11),
applicable to both Windows 10 and 11 per its own version metadata) gives the exact sequence:
`diskpart` (scripted partitioning) → `DISM /Apply-Image` → **`bcdboot W:\Windows /s S:`** — and
critically, **this is run from within a live WinPE boot, not the full interactive Setup GUI.**
`bcdboot` is a real Windows tool that does two things: copies boot files from the applied image's
own `Windows\Boot\` directory to the System (EFI) partition, and constructs/populates the BCD
store. **This reframes "make the disk bootable" from "reimplement bcdboot's internal BCD schema
from scratch on Linux" (hard, fragile, poorly documented internals) to "boot a minimal WinPE
environment once and run the real Microsoft tool" — a much better-supported plan.**

Microsoft's Note on that same page is directly relevant to our newer targets: *"To configure for
boot with Windows UEFI 2023 CA, you may use the `/bootex` option with the `bcdboot` command"* — a
reference to the Secure Boot certificate rotation from CVE-2023-24932. Worth using `/bootex`
explicitly for Server 2025/Windows 11 given their more recent build dates, even though it isn't
confirmed strictly required.

**This exact mechanism was then confirmed working in practice, independently, for all three
target OSes specifically:**

- **Windows Server 2022**: a real deployment walkthrough
  ([virtualizationhowto.com](https://www.virtualizationhowto.com/2021/09/windows-server-2022-install-with-mdt/))
  confirms MDT (an orchestration layer around exactly this WinPE + DISM + bcdboot mechanism)
  successfully builds and deploys Server 2022 via a normal WIM-apply task sequence. (One search
  result claimed MDT "doesn't support ... Windows Server 2022" — checking the actual source showed
  this was wrong/stale; disregard it. Lesson reinforced: verify a specific claim against its
  primary source before trusting a search-engine summary, especially when it contradicts other
  results in the same search.)
- **Windows 11 (24H2)**: a detailed reference-image build guide
  ([deploymentresearch.com](https://www.deploymentresearch.com/building-a-windows-11-24h2-reference-image-using-microsoft-deployment-toolkit-mdt/))
  confirms the same WinPE + DISM + bcdboot mechanism works for Windows 11, and states explicitly:
  **"there is no technical requirement... TPM"** when building/imaging in a VM this way. This
  matters directly for us: TPM/Secure Boot enforcement lives in Setup.exe's own interactive
  installer compatibility gate, not in DISM/bcdboot — meaning the swtpm/Secure-Boot-OVMF wiring the
  sibling project built for its (shelved) Windows 11 attempt is likely only needed for the
  *eventual running instance* (realism, and so Windows itself doesn't nag about unsupported
  hardware at every boot), not for the image-application step itself. Worth confirming this
  distinction empirically once this project reaches that point, rather than assuming the two are
  equivalent.
- **Windows Server 2025**: a real deployment guide
  ([dispersednet.com](https://www.dispersednet.com/disaster-recovery/module3/windows-deployment-preparation-guide.php))
  quotes the actual commands against a Server 2025 WIM: `Dism /Capture-Image
  /ImageFile:D:\Images\Windows-Server-2025-Reference.wim ...` and `Dism /Apply-Image
  /ImageFile:D:\Images\Windows-Server-2025-Reference.wim /Index:1 /ApplyDir:W:\`, confirming the
  mechanism works unchanged. One real caveat, correctly scoped: *"The traditional WDS model that
  relies on installation-media `boot.wim` for end-to-end deployment is not supported for Windows
  Server releases after Windows Server 2022."* This is about WDS's own legacy PXE-network-boot
  workflow specifically (serving the *original install media's* `boot.wim` directly via WDS) — it
  does not affect us, since this project was never planning to use WDS's PXE path at all (we're
  applying the WIM offline from this Linux host directly, then booting a *self-built* minimal WinPE
  just once to run `bcdboot`, not network-booting through WDS). Don't let this caveat cause
  confusion later — it sounds alarming out of context but isn't actually about the mechanism we're using.

**On MDT itself**: one source claims Microsoft Deployment Toolkit was retired in 2026. This wasn't
independently verified in depth, and it doesn't matter much either way for this project — we were
never planning to depend on MDT-the-product, only on the underlying WinPE + DISM + bcdboot
mechanism it orchestrates, which we'll script ourselves. Worth knowing MDT itself may not be a
long-term-supported reference to keep citing, though.

## Technical building blocks (updated with the above research — one open question remains, not several)

**Update — see `PHASE2_BOOTSTRAP_ARCHITECTURE.md`:** a second research pass (looking specifically
for existing open source tooling before building anything) found an actively-maintained tool,
**BCD-SYS**, that performs step 3's BCD-construction and boot-file-copy work entirely from the
Linux host, with no boot of any kind involved — not even WinPE. That document lays out the full
comparison and rationale; the short version is that BCD-SYS should be attempted *first*, and
everything below in this section (the WinPE + real `bcdboot` mechanism) is retained as the
documented, Microsoft-sourced **fallback** if BCD-SYS's output doesn't produce a disk that boots
cleanly. Nothing below is stale or wrong — it's still the right plan if the new first attempt
doesn't pan out — but it is no longer the first thing to try.

High-level shape of the intended pipeline. Steps 1, 2, 4, and 5 are now considered well-understood
(confirmed mechanism, just needs implementing and testing against our specific setup). Step 3 is
the one place real investigation is still needed — but it now has a confirmed, recommended
approach rather than being wide open.

1. **Partition the target disk directly**, without booting anything. `qemu-nbd` (already used once
   in the sibling project, for read-only forensic mounting of a qcow2 — see that project's
   engineering log's "Practical Operating Notes") to expose the qcow2 as a `/dev/nbdN` block
   device, then `sgdisk`/`parted` to create the same GPT layout the unattend-driven builds used
   (EFI System Partition, MSR, primary NTFS), `mkfs.vfat`/`mkfs.ntfs` (via `ntfs-3g`/
   `ntfsprogs`) to format them.
2. **Apply the WIM image to the primary partition.** `wimlib` (`wimapply`/`wimlib-imagex apply`) is
   the open-source, Linux-native tool for this — extract the correct image index (matching the
   `<NAME>`/`<EDITIONID>` values already confirmed for each ISO in the sibling project's engineering
   logs) directly onto the mounted NTFS partition. No Windows environment needed for this step at
   all, and per the research above, no TPM/Secure Boot device wiring needed for this step either.
3. **Make the disk bootable — now a two-tier plan, see `PHASE2_BOOTSTRAP_ARCHITECTURE.md`.**
   **First attempt: BCD-SYS**, run directly against the wimapply'd partition from the Linux host,
   no boot required at all. **Fallback, if that doesn't produce a disk that boots cleanly:** boot a
   minimal, self-built WinPE environment under QEMU just long enough to run the real `bcdboot
   W:\Windows /s S: /bootex` once, then never boot that WinPE environment again. The fallback is
   the confirmed, Microsoft-documented mechanism (not a guess), and sidesteps reimplementing BCD's
   internal schema from scratch. Genuinely open sub-questions for the fallback path, in priority
   order:
   - **Does WinPE's own boot suffer from the same "press any key" landmine that blocks the full
     installer?** Never tested. If a *self-built* minimal WinPE boot medium (constructed by this
     project, not reusing the original install ISO's more complex boot catalog) avoids the issue —
     plausible, since the "press any key" ceremony is specifically an optical-media (CD/DVD) boot
     convention (the point is "don't accidentally reinstall from media left in the drive," a
     concern that doesn't apply to a plain disk-image boot device) — then attaching the WinPE
     image as a regular virtio-blk/virtio-scsi *disk* rather than `media=cdrom` may avoid the
     landmine entirely, independent of any of the keystroke-timing fixes already tried and
     shelved in the sibling project. This is the single most promising unverified idea from this
     research pass and should be the very first experiment.
   - How to actually construct a minimal, purpose-built WinPE boot medium from this Linux host —
     extracting `boot.wim` + the necessary EFI boot files from the install ISO is well-trodden
     (see the wimlib-based "bootable USB creation" community guides found during this research,
     e.g. the gists referenced in earlier research notes) but those are aimed at recreating full
     *installer* media, not a minimal "boot straight to a script that runs `bcdboot`" environment —
     adapting one for our narrower purpose (custom `startnet.cmd`-equivalent, matching how
     Microsoft's own ADK `copype`/`MakeWinPEMedia` tooling supports custom WinPE startup scripts)
     is the remaining design work here, not the underlying feasibility.
   - Fallback if WinPE boot turns out to hit the same landmine: community tooling search for
     "apply Windows WIM from Linux and make it boot" more specifically (`virt-builder`/
     `libguestfs`'s Windows customization hooks weren't checked in this research pass and may
     already solve part of this) before resorting to manually constructing a BCD store from
     scratch (`hivex`/`hivexregedit` from libguestfs can create/edit Windows registry hives — the
     BCD store is itself just a registry hive — but this is the highest-effort, most fragile
     option and shouldn't be attempted until the two options above are genuinely dead ends).
4. **Apply an unattend/specialize step to the offline image before first real boot** —
   `DISM /Apply-Unattend` against the mounted offline image is the documented mechanism for this;
   needs verification that it covers everything the old `specialize`/`oobeSystem` unattend passes
   did (computer name, WinRM enablement, `FirstLogonCommands`-equivalent for driver installation
   and role provisioning).
5. **Boot the resulting disk and hand off to the existing role-provisioning layer unchanged.**
   Once the disk is genuinely bootable and specialized, this is exactly the sibling project's
   `dev/role-test.pkr.hcl` pattern: Packer with `disk_image = true`, WinRM communicator, the same
   `services.yaml` → `run-services.ps1` → `install-<role>.ps1` flow, unmodified.

Virtio drivers need to be injected into the offline image before first boot too (same requirement
as the unattend-driven approach — boot-critical storage driver, plus the NIC driver for the
eventual WinRM connection). **Update — see `PHASE2_BOOTSTRAP_ARCHITECTURE.md`:** the recommended
mechanism is now offline `hivex`/`hivexregedit` registry injection (the same pattern `virt-v2v` uses
in production for VMware/Hyper-V→KVM conversions), not `DISM /Add-Driver` — that DISM-based
approach only made sense when the plan required a WinPE/Windows environment somewhere in the loop,
which is no longer the first-choice design.

Step 3's WinPE-boot-medium sub-question is the real first milestone for this project: get *any*
Windows disk, built via offline WIM application from this Linux host, to boot at all under
QEMU/OVMF — before worrying about unattend/specialize or role provisioning, which are
comparatively well-understood at this point given both the sibling project's existing work and the
research above.

## Starting point

Windows Server 2025 first, per explicit direction — it's evaluation media in the same eval-channel
pattern already well-understood (see the sibling project's Finding 5 for how eval-channel edition
selection actually works, which still applies here for choosing the right WIM image index), and
the `../iso_cache/` entry, checksum, and WIM image-name investigation for it already exist (the
cache directory is now shared directly with the sibling project rather than needing to be copied
over).
