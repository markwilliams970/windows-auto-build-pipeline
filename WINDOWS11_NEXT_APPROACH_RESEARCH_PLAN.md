# Windows 11 Next Approach: Research Plan

## Status

**Phases 0-3 are complete, and Phase 3.1-3.2 execution have both passed their gates.** Phase 0
confirms the original blocker is still unresolved, as of today. Phase 1 surveyed the strongest
candidate categories and found a real, community-confirmed technique (ISO-level `_noprompt` boot
files). Phase 2 verified that finding against primary sources. Phase 3 turned it into a concrete,
phased design with an explicit pass/fail gate at each step. **Phase 3.1 passed cleanly** (the
`_noprompt` ISO eliminates the boot-prompt race entirely). **Phase 3.2 passed on its second attempt**:
static `bootindex=` alone didn't survive Setup's first reboot (attempt 1, a real, anticipated
failure), but adding a QMP `eject` of the install media right before that reboot fixed it completely
— two separate reboots, zero fallback to the CD-ROM either time, landing on a genuine Windows 11
OOBE screen. **This is the first time in this project's history a Setup.exe-driven Windows 11
install has completed end to end.** **Phase 3.3's first attempt then passed completely cleanly**:
a full `specialize`/`oobeSystem` answer file (adapted from the production template, `e1000` NIC
scope decision), same recipe, reached a real, working Windows 11 desktop with **real authenticated
WinRM confirmed** (`hostname` → `WIN11-P33`, `Get-NetAdapter` → `Intel(R) PRO/1000 MT`, `Status:
Up`) - the exact evidentiary bar Server 2022/2025 met repeatedly, and the bar Findings 8/12/13/14
never once reached on the fully-offline pipeline without a BSOD. **No crash anywhere in the run**,
including through the exact window (WinRM coming up during first-boot servicing) where every prior
Windows 11 attempt on the old pipeline previously failed. **Phase 3.3's second attempt then passed
just as cleanly, on a completely independent fresh disk**: same result in every particular that
matters - no BSOD, real WinRM (`hostname` → `WIN11-P33`, `Get-NetAdapter` → `Intel(R) PRO/1000 MT`,
`Status: Up`), `FirstLogonCommands` confirmed fully executed via a direct marker-file read over
WinRM. **Phase 3.3's third attempt then passed just as cleanly, on a third independent fresh disk
with independent OVMF NVRAM state too**: same result again - no BSOD, real WinRM (`hostname` →
`WIN11-P33`, `Get-NetAdapter` → `Intel(R) PRO/1000 MT`, `Status: Up`), `FirstLogonCommands` marker
confirmed. See `PHASE3_ENGINEERING_LOG.md`'s corresponding entries for the full record. **Three for
three - this project's own 2-3-independent-successes evidentiary bar is now fully met. The
Setup.exe-driven approach is confirmed reliable, not just promising.**

**Phase 3.4 is done.** Formalized into real production scripts
(`image-apply/build-iso-noprompt.sh`, `image-apply/windows11-setup-install.sh`, new
`tools/qmp-eject.py`/`tools/qmp-pixel.py` helpers), `build.sh` wired to route `windows11` through the
new script with no Packer handoff. The first automated version used a QMP-scripted eject at a
calibrated timing window (mirroring Phase 3.2/3.3's own hand-run recipe) - real testing surfaced two
genuine problems: an ISO-naming bug in the calibration convenience script, and a real "Windows 11
installation has failed" error from an eject that landed too early relative to the actual proven-safe
point. Both were fixed, but a sharper design concern (the pixel-sample "safety net" can't actually
distinguish 10% complete from 90% - the whole mechanism was really just one guessed timeout dressed
up to look more robust) led to testing a fundamentally different approach instead of continuing to
patch the timing guess: **dropping the static `bootindex=` override entirely and letting OVMF's own
NVRAM boot order decide disk-vs-CD-ROM selection, with no eject at all.** Confirmed working
independently four times total (two hand-run tests plus two runs of the final production script,
including direct TianoCore boot-log capture of `Boot0009 "Windows Boot Manager"` on both reboots) -
this eliminates the entire eject-timing problem area, not just improves it.
`calibrate-eject-timing.sh` is retired (kept as historical record, same treatment as
`audit-mode-sysprep.sh` - nothing left to calibrate once there's no eject step). See
`PHASE3_ENGINEERING_LOG.md`'s Phase 3.4 entries for the complete trail.

**Phase 3.5 is done.** Two independent fresh builds through the finished `windows11-setup-install.sh`
(default settings, no manual intervention), both clean: `hostname` -> `WIN11P35A`/`WIN11P35B`
confirmed via real WinRM, graceful shutdown, clean qemu exit, no errors or warnings. Combined with
Phase 3.4's own four independent NVRAM-boot-order confirmations, this gives the Setup.exe-driven
Windows 11 path the same production-readiness standing Server 2022/2025 already have. See
`PHASE3_ENGINEERING_LOG.md`'s Phase 3.5 entry for the full record. Remaining open items, deliberately
deferred rather than overlooked: the virtio-driver question (Phase 3.2/3.3's own `e1000`/plain-IDE
scope decision) and Phase 4 (Datadog Agent integration, not started for any of the three OSes).

**Read `PHASE3_ENGINEERING_LOG.md`'s "HARD STOP" section (end of Session 4) before anything
below.** Short recap: this project tried two architectural options for building Windows 11
entirely offline (no Setup.exe, no live boot before the customer-facing one) — staying fully
offline (Option A) and inserting a live Audit Mode + Sysprep cycle (Option B) — and both terminate
at the identical kernel-level NTFS BSOD during Windows 11's real first boot. A full audit ruled
out this project's own code, host environment, and input media as the cause. Multi-angle research
found no community precedent for the exact combination. Rather than deriving a third
from-first-principles option, the direction now is: research how Windows 11 unattended builds are
*actually, successfully* done elsewhere, and design the next pipeline around what's proven to
work — not around another guess.

---

## The one question to resolve first, before anything else

This project's entire "never run Setup.exe" rule (`CLAUDE.md`'s "Relationship to
`../windows-server-vm-automation/`" section) exists because of one specific, cited upstream bug:
the sibling project's Setup.exe-driven install of Windows Server 2025/Windows 11 media hit a
"press any key to boot from CD" VNC-keystroke timing race that turned out to be a known, open,
unresolved issue in Packer's own QEMU builder plugin —
[hashicorp/packer#13342](https://github.com/hashicorp/packer/issues/13342) and
[#13514](https://github.com/hashicorp/packer/issues/13514) (`HANDOFF_FROM_UNATTENDED_INSTALL.md`
lines 88-89, confirmed via primary-source search at the time, not re-derived from memory here).

**If that issue has since been fixed, patched around, or has a documented community workaround,
the entire space of well-documented, Setup.exe-based unattended Windows 11 deployment techniques —
which is the overwhelming majority of everything that exists publicly — becomes viable again for
Windows 11 specifically.** This is a single, cheap, high-leverage check that could completely
reframe every later phase of this research, so it has to happen first, not get folded into a
broader survey later.

**This does not touch Server 2022/2025.** Those stay on the current, fully-offline, Setup.exe-free
architecture regardless of what Phase 0 finds — they're already proven, production-ready, and
untouched by any of this. This research is scoped to Windows 11 only.

---

## Research phases

### Phase 0 — re-check the original blocker (do this first, before anything else)

Directly re-verify the status of `hashicorp/packer#13342`/`#13514`: still open? Closed with a fix?
A documented workaround in the comments? Check the Packer QEMU builder plugin's own changelog/
release notes since the sibling project's own attempt for anything relevant, even if the issue
itself is still nominally open (a workaround doesn't require the upstream issue to be closed).

**Why this gates everything else**: if Setup.exe is viable again (even with a workaround, not
necessarily a clean fix), Phase 1's search space is completely different — it opens up the large
body of mature, actively-maintained Windows deployment tooling this project has deliberately
avoided so far. If it's still genuinely blocked, Phase 1 stays scoped to Setup.exe-free approaches
(a much smaller, more specialized space) or approaches that avoid Packer's own QEMU builder
specifically (e.g., `virt-install`/libvirt-native tooling, which is a different codebase and may
not share the same bug).

#### Phase 0 result: still unresolved, confirmed today, plus a genuinely promising lead

**The sibling project's own `WINDOWS_SERVER_UNATTENDED_THRU_PHASE2.md` already had a "re-research
update" dated 2026-08-14 — eight days before this check — that answers most of this directly**, a
local primary source cheaper and more detailed than re-deriving the same search from scratch:

- `hashicorp/packer#13342` — closed 2025-03-29, but only by the 30-day stale-bot; no maintainer
  response or fix was ever posted. Not a real resolution.
- `hashicorp/packer#13514` — still open. Fresh "still broken" comments as recently as 2026-05-27.
  Spot-checked directly today (2026-08-22): still open, no newer activity, no maintainer response,
  no confirmed fix.
- [HashiCorp Discuss #76406](https://discuss.hashicorp.com/t/qemu-windows-unable-to-boot-in-uefi-mode/76406) —
  still accumulating "same problem" reports as recently as 2026-08-06. Spot-checked directly today:
  no newer replies, the `fs1:\bootmgr.efi` manual-shell workaround still fails for everyone who's
  tried it, no confirmed fix in the thread.
- `packer-plugin-qemu` releases through v1.1.6 (2026-07-16, the latest as of the sibling project's
  check) — changelogs reviewed directly there, nothing touches `-boot`, boot order, or EFI/El
  Torito handling.
- `eb4x/packer-qemu-win11` (suggested in the Discuss thread as a possible fix) — checked directly:
  it's a Windows 11 TPM/secure-boot config example (`efi_firmware_code`/`vtpm`/`q35`), not a fix
  for this specific boot-order/EFI-shell bug, and doesn't address Server 2025 at all.

**Confirmed: still genuinely blocked, as of today, not just as of the sibling project's last
check.** Per the gating logic above, Phase 1 stays scoped away from Packer's own QEMU builder for
the install phase specifically.

**One genuinely promising, not-yet-tried angle surfaced in that same update, worth carrying
directly into Phase 1**: swapping an ISO's `efi/microsoft/boot/{cdboot.efi,efisys.bin}` for their
ADK-provided `_noprompt` counterparts removes the "press any key to boot" prompt *entirely* — no
keystroke to race at all, rather than trying to time one better. The sibling project's own log
describes this as "mature, known-good... confirmed again recently in a '[SOLVED]' Proxmox thread
for **Windows 11** specifically" — but flags it as unverified against the *deeper* bug (OVMF's
EFI-shell-first boot-device ordering), since removing the prompt doesn't necessarily fix boot-order
selection on its own.

**Why this project may be structurally better positioned to test this than the sibling project
was**: the sibling's own diagnosis of the deeper bug is explicitly a *Packer* limitation — "Packer
currently lacks the capability to alter [UEFI boot order]" (Finding 15) — not a fundamental
QEMU/OVMF one. This project's own `image-apply/*.sh` scripts already build raw
`qemu-system-x86_64` invocations directly for every stage (not through Packer's QEMU builder at
all), with full, direct, already-proven control over boot device ordering via explicit
`bootindex=` device flags (`make-bootable.sh`'s own WinPE-vs-target ordering, Finding 5's fix, is
exactly this mechanism). **A Setup.exe-based install driven by a hand-built `qemu-system-x86_64`
invocation, using the `_noprompt` boot files to eliminate the keystroke race and explicit
`bootindex=`/`-boot order=` flags to control UEFI boot-device selection directly, has never been
tried by either project** — it sidesteps the specific Packer limitation the sibling project's whole
investigation is blocked on, using a capability this project already has in daily use elsewhere.
This is the strongest lead so far and a natural first thing to prototype cheaply in Phase 1, before
a wider tooling survey.

### Phase 1 — survey how unattended Windows 11 builds are actually, successfully done

Once Phase 0 sets the actual scope, survey real, working, documented approaches. Candidate
categories, each a genuinely different angle (not redundant searches of the same thing):

1. **Community Packer Windows templates** — e.g. `StefanScherer/packer-windows`,
   `boxcutter/windows`, `gusztavvargadr/packer-windows`. Do any support Windows 11 client SKU
   specifically (not just Server)? Are they actively maintained (recent commits/releases, not
   abandoned)? What's their actual boot/answer-file delivery mechanism, and does it differ from
   what the sibling project already tried?
2. **Large-scale open-source Windows image pipelines** — GitHub's own
   [`actions/runner-images`](https://github.com/actions/runner-images) repository builds fresh
   Windows images on a regular, public cadence. Worth checking whether Windows 11 client is among
   their build targets and, if so, what mechanism they use — this is about as close to a
   "battle-tested at scale" primary source as this space has.
3. **`virt-install`/libvirt-native unattended Windows install guides** — a genuinely different
   tool than Packer's QEMU builder, so may not share the same upstream bug even if Setup.exe stays
   in the loop. Real community precedent exists for this pattern; worth checking currency and
   Windows-11-specific applicability, not just that it exists in principle.
4. **Microsoft's own enterprise deployment tooling (MDT/SCCM/Autopilot)** — typically
   interactive-console/GUI-oriented rather than headless-CI-friendly, so not necessarily directly
   reusable as tooling, but worth understanding the actual *mechanism* they use to get past
   Setup.exe's own boot-timing and hardware-compatibility gates (TPM/Secure Boot in particular) —
   that mechanism might transfer even if the tool itself doesn't.
5. **Windows 11's TPM 2.0/Secure Boot Setup.exe gate specifically** — this project's own
   Setup.exe-free approach sidesteps this gate entirely (confirmed empirically,
   `PHASE2_ENGINEERING_LOG.md` Session 13/Finding 43). If Setup.exe comes back into play at all,
   this becomes a real, necessary capability again, not a solved problem — but it's also a
   well-precedented one in the community (registry bypass keys, e.g. `LabConfig`/
   `BypassTPMCheck`, well-documented for exactly this eval/lab scenario). Worth surveying current,
   still-working guidance rather than assuming old bypass keys still function on current builds.
6. **Cloud-vendor Windows 11 image pipelines** (Azure VM Image Builder, AWS-side Windows AMI
   tooling) — lower priority, likely less directly applicable to a local KVM/QEMU host, but a
   cheap check for any genuinely public technique worth knowing about.

#### Phase 1 findings

**Category 1 — community Packer Windows templates.** Checked three, each directly (not just from
search snippets):
- **`rgl/windows-vagrant`** — the strongest-looking candidate at first glance: actively maintained
  (536 commits), explicit Windows 11/2022/2025 templates (the exact OS set both projects target),
  Packer's QEMU/libvirt builder. Fetched its actual `windows-11-24h2-uefi.pkr.hcl` boot
  configuration directly: `boot_wait = "1s"`, `boot_command` is ten repetitions of `<up><wait>` —
  **the same fundamental timed-keystroke race both projects already know is unreliable for this
  media**, not a different or fixed mechanism. No custom `-boot`/`bootindex` handling, no ISO
  modification. Its own maintainer may or may not have this specific combination working reliably;
  nothing in the template itself demonstrates a fix, so treat this as "another instance of the
  known-fragile approach," not a solved reference.
- **`proactivelabs/packer-windows`** — low signal: only 5 commits, no visible maintenance
  cadence, no documentation of the boot-order/prompt issue at all. Not a credible reference either
  way.
- **`eb4x/packer-qemu-win11`** — the repo the sibling project's own log already checked and found
  to be a TPM/secure-boot config example, not a boot-order fix. Re-confirmed directly: still true,
  and its README doesn't document its actual boot-prompt-handling mechanism at all (6 commits,
  low activity). Not a resolved lead.

**Category 2 — `actions/runner-images`.** Confirmed directly: builds Windows Server 2022/2025 (and
Ubuntu) via Packer on Azure — **does not build Windows 11 client SKU at all.** Not directly
applicable, though it does further corroborate that Packer-based Server 20XX builds are a mature,
well-trodden path (consistent with this project's own Server 2022/2025 experience) — the gap really
does look concentrated on Windows 11 client specifically.

**Category 3 — `virt-install`/libvirt-native approaches.** Checked `adityasugandhi/winvm-lab`
(virt-install-based Windows 11 install, not Packer). Genuinely useful: its documentation explicitly
names the same class of problem — "the default `<boot dev='hd'/>` ordering ignores attached CD-ROM
and UEFI can't find bootable media" — with a real fix: `<boot dev='cdrom'/>` listed **before** the
hard disk entry in the libvirt domain XML. This is a legitimate, well-established libvirt mechanism,
distinct from Packer's own more limited config surface — but the specific repo demonstrating it has
only 3 commits, no releases, reads as a personal lab project rather than a battle-tested reference.
The *technique* (direct domain-XML boot-device ordering) is credible on its own merits as a known
libvirt feature; this specific implementation isn't strong enough to lean on as proof by itself.

**The strongest finding of Phase 1 — a real, community-confirmed, primary-source success, found via
a targeted follow-up rather than the general survey**: a Proxmox forum thread, ["\[SOLVED\] Fully
Unattended Windows 11 Installation - Avoid Press any key to boot from CD or
DVD"](https://forum.proxmox.com/threads/fully-unattended-windows-11-installation-avoid-press-any-key-to-boot-from-cd-or-dvd.162252/),
gives the exact, complete procedure and includes an explicit, unambiguous confirmation from the
original poster after applying it: *"That's it! Works perfectly. Thank you very much!"* Proxmox
runs QEMU/KVM/OVMF under the hood — the same virtualization stack this project already uses, not a
different hypervisor's mechanism that might not transfer.

**Correction to the sibling project's own note, worth carrying forward precisely**: the sibling
log described this as needing ADK-provided `_noprompt` files. Per this thread, that's not quite
right and the real mechanism is simpler than that implies — **`efisys_noprompt.bin` and
`cdboot_noprompt.efi` already ship on the stock Microsoft Windows 11 ISO itself**, at
`efi/microsoft/boot/`, sitting right alongside the normal `efisys.bin`/`cdboot.efi`. No separate
ADK download or `MakeWinPEMedia.cmd` run is required just for this — the fix is: delete the normal
files, rename the `_noprompt` files to take their place, and rebuild the ISO (the thread includes a
worked example using `xorriso` to remount/repack it with correct El Torito boot-sector handling).

**Necessary caveat, stated as honestly as the source allows**: the fetch of this thread found no
discussion of UEFI boot-device *ordering* separately from the keystroke prompt itself — it isn't
established from this source alone whether the deeper OVMF EFI-shell-first-boot-device bug (Finding
15 in the sibling log, the one attributed specifically to a Packer limitation) would still bite even
with the prompt removed. Two things support optimism here without fully closing the gap: (1) this
poster was using Proxmox directly, which — like this project's own hand-built `qemu-system-x86_64`
invocations — has direct, first-class boot-device-order control unavailable to Packer's own QEMU
builder abstraction, so their success is at least consistent with "prompt removal + direct boot-order
control together are sufficient," matching this plan's own leading hypothesis from Phase 0; and (2)
no comment in the thread reports the deeper bug recurring after the fix, which would be a natural
thing to mention if it had. This is real, credible, primary-source evidence *for* the leading
hypothesis, not yet a full, independent proof of it — the actual test is still to build and boot it
here.

**Categories 4-6 (MDT/SCCM/Autopilot mechanism, TPM/Secure-Boot bypass currency, cloud-vendor
pipelines) were not yet surveyed** — the noprompt-ISO finding is strong enough, and specific enough
to this project's own tooling, that it's worth prototyping directly before spending more research
time on lower-priority categories that were always going to matter less than a confirmed working
technique. Worth returning to only if the noprompt-ISO prototype doesn't pan out.

### Phase 2 — primary-source verification of whatever Phase 1 finds

For any actively-maintained, credible candidate, read the actual source/config directly — not a
summary of it — to understand the *exact* mechanism, matching this project's own "verify before
trusting" standard. Specifically worth checking for each real candidate: does it actually handle
Windows 11 client SKU (not just assumed from Server support), and does it avoid or actually solve
the sibling project's specific boot-timing race, or does it just get lucky with different timing
the way this project's own Session 13 arguably did?

#### Phase 2 findings — verifying the `_noprompt` finding against primary sources, not just the
#### Proxmox thread's own retelling

Phase 1's Proxmox-thread finding was itself a secondary source (a forum post describing a
technique, however credibly confirmed by its own participants). Verified it three further ways,
each against something more authoritative than the thread itself:

1. **Checked our own actual install media directly, not a description of media.** `7z l` against
   this project's own cached ISOs confirms `cdboot.efi`, `cdboot_noprompt.efi`, `efisys.bin`, and
   `efisys_noprompt.bin` all genuinely exist at `efi/microsoft/boot/` on **all three of this
   project's target OSes' media** — Windows 11 Enterprise Evaluation, Windows Server 2025, and
   Windows Server 2022 (`cdboot.efi`/`cdboot_noprompt.efi` differ slightly in byte size between
   builds, confirming they're genuinely distinct compiled binaries specific to each build, not
   placeholder duplicates). This is the strongest form of verification available - not "a forum
   says this is on the ISO," but "our own actual build input has been checked directly and the
   claim holds."
2. **This means the technique isn't Windows-11-specific at all** - it's a general Windows
   installation-media feature present across every OS this project targets. Worth noting even
   though Server 2022/2025 don't need it (their offline pipeline is already proven) - it's
   corroborating evidence this is a real, general-purpose Windows Setup mechanism, not a
   Windows-11-specific workaround that happens to exist by coincidence.
3. **Traced the mechanism back further than the Proxmox thread, to actual Microsoft
   documentation**, not just community description of it. A genuine Microsoft Support KB article
   (["Boot failed" error... Windows 7/Server 2008 R2 UEFI installation
   media](https://support.microsoft.com/en-us/topic/-boot-failed-error-message-when-you-start-a-uefi-enabled-computer-from-the-installation-dvd-of-a-64-bit-version-of-windows-7-or-windows-server-2008-r2-package-2-a19c6273-bd5a-a684-3c4f-f479b5f0522d),
   fetched and read directly, lists `Cdboot_noprompt.efi`/`Efisys_noprompt.bin` in its own hotfix
   file table (version `6.1.7600.20754`, dated **13-Jul-2010**) as files to be copied into place
   during hotfix integration. This confirms these aren't a community reverse-engineering discovery
   or an accidental artifact — they're a genuine, official Microsoft mechanism that's been present
   and stable on Windows installation media for **over fifteen years**, from Windows 7 through
   Windows 11/Server 2025 (confirmed directly, point 1 above). The KB itself doesn't explain the
   *purpose* of the noprompt variant in so many words, but the naming is self-documenting and
   matches every independent community source's consistent description exactly.
4. **Got the literal rebuild procedure, not a paraphrase of it**, since the actual `xorriso`
   command matters if this is ever really built:
   ```
   xorriso -as mkisofs \
     -iso-level 3 \
     -volid "WINSETUP" \
     -eltorito-boot boot/etfsboot.com \
       -eltorito-catalog boot/boot.cat \
       -no-emul-boot \
       -boot-load-size 8 \
       -boot-info-table \
     -eltorito-alt-boot \
       -e efi/microsoft/boot/efisys.bin \
       -no-emul-boot \
     -isohybrid-gpt-basdat \
     -o "output_path.iso" \
     "extracted_content_directory"
   ```
   (after deleting the original `efisys.bin`/`cdboot.efi` and renaming the `_noprompt` variants
   into their place). This is the standard, widely-documented dual-boot-catalog pattern for
   rebuilding a Windows ISO (BIOS via `boot/etfsboot.com`, UEFI via `efi/microsoft/boot/
   efisys.bin`) — recognizable as the same general recipe used across many independent "how to
   build a custom Windows ISO" guides, not a fragile one-off invented for this specific thread.
5. **One real, practical caveat surfaced and worth carrying into Phase 3's design, not dropped**:
   a thread participant mentioned needing to handle CD-ROM re-attachment/ejection across Setup's
   own multi-phase reboot (Windows Setup reboots partway through installation; if the ISO is still
   attached and preferred at boot time, it can re-enter Setup instead of continuing the installed
   system) — described only vaguely ("cloning VM state after first phase"), not as a solved,
   documented technique. This project already has the tooling to handle this cleanly and
   deliberately (QMP-based device control, already used throughout this project's own conventions,
   or explicit `bootindex=` favoring the hard disk after the first reboot) rather than needing to
   adopt the thread's own vague workaround — but it's a real design point for Phase 3, not
   something the noprompt-ISO fix alone resolves.

**Net assessment**: the `_noprompt` mechanism itself is now about as well-verified as research
alone can make it — confirmed on this project's own actual media, traced to genuine 15-year-old
Microsoft documentation, with a concrete, standard rebuild procedure in hand. What remains
unverified (and can only be verified by actually building it, not further research) is whether
combining it with this project's own direct `bootindex=` control genuinely avoids the *deeper*
OVMF boot-device-ordering bug the way the Phase 0/1 hypothesis proposes — the Proxmox thread is
consistent with that being true but doesn't isolate it as its own confirmed variable.

### Phase 3 — design proposal

**Status: written, not yet executed.** Nothing below has been built or tested — this is the design
proposal itself, per `CLAUDE.md`'s own "Claude Instructions" (explain the approach, assumptions,
and risks before writing implementation). Structured as a phased execution plan with an explicit
pass/fail gate at each step, mirroring `WINDOWS11_AUDIT_MODE_SYSPREP_PLAN.md`'s own proven format —
each phase is cheap, isolates one specific question, and a failure at any gate is a real, named
stopping point, not something to push through.

#### Approach summary

Bring Setup.exe back into play, **for Windows 11 only** — Server 2022/2025 stay exactly as they
are, fully offline, unchanged. Combine the two verified findings from Phases 0-2:

1. A `_noprompt`-patched Windows 11 ISO (swap `efisys.bin`→`efisys_noprompt.bin`,
   `cdboot.efi`→`cdboot_noprompt.efi`, rebuild via the verified `xorriso` recipe) — eliminates the
   "press any key" keystroke race entirely, provably (there's no prompt left to race against), not
   statistically (better timing).
2. A hand-built `qemu-system-x86_64` invocation with explicit `bootindex=` device ordering — this
   project's own already-proven pattern (`make-bootable.sh`'s WinPE-vs-target ordering, Finding 5)
   — instead of Packer's QEMU builder, whose own documented limitation ("Packer currently lacks the
   capability to alter [UEFI boot order]") is the specific thing both this project's and the
   sibling project's prior investigations were actually blocked on.

This does **not** mean adopting Packer's QEMU builder for the install phase, or reusing the sibling
project's own `autounattend.xml`/`boot_command` machinery — it means driving Setup.exe the same way
this project already drives WinPE and Audit Mode: a real answer file, a real `qemu-system-x86_64`
invocation this project controls directly, and QMP for observation, none of it routed through
Packer until (if at all) a later, post-install stage.

#### Standing-rule conflict — flagged explicitly, not silently reversed

`CLAUDE.md`'s own "Relationship to `../windows-server-vm-automation/`" section has a standing rule:
*"Do not reuse `Microsoft-Windows-Setup`... `boot_command`/VNC keystroke injection remain correctly
banned regardless."* This proposal necessarily revisits that rule for Windows 11 specifically. Two
things distinguish this from what the rule was actually written to prevent, worth stating plainly
rather than asserting the rule doesn't apply:

- The rule's own reasoning was about *keystroke-timing-dependent* driving of an interactive
  prompt — exactly what this proposal's `_noprompt` ISO eliminates by construction, not works
  around by better timing. No `boot_command`, no VNC keystrokes, no race to lose.
- `EarlyF6DriverInstall`'s own gate (this project's original, unrelated reason for abandoning
  Setup.exe entirely in Sessions 3-6, per `CLAUDE.md`'s "RECONSIDERATION CLOSED" note) was hit
  under a *different* boot medium (a self-built `boot.wim` index 2 attached as a plain disk, not
  the real installation ISO) and a different failure mode entirely (a driver-installation gate
  firing unconditionally partway through Setup, not a boot-time prompt). Whether that specific gate
  still applies when driving the real, unmodified (except for the boot-file swap) installation ISO
  through its normal `windowsPE` pass is **not yet known** and is exactly what Phase 3 below tests
  before anything else.

**This is a real decision for the user, not something to default into.** The plan below is written
so each phase can be individually approved, and the whole thing can stop at any failed gate without
having reversed the standing rule for nothing.

#### Phased execution plan

**Phase 3.1 — PASSED. Prove the `_noprompt` ISO alone eliminates the keystroke race, hands-off, in
isolation.**
Build the patched ISO via the verified `xorriso` recipe. Boot it **hands-off, zero keystrokes sent,
not even a fallback keypress script** — CD-ROM only, no target disk needed yet, keep this phase
minimal. Hand-built `qemu-system-x86_64`, OVMF, watched via `tools/qmp-screenshot.py`/
`qmp-watch.sh`, matching this project's own established observation convention throughout.
- **Gate to pass**: reaches a real, interactive Windows Setup UI screen (language/region selection
  or later) with zero keystrokes sent and no "press any key"/EFI-shell/PXE fallback ever appearing.
- **Gate fails if**: it still drops to EFI shell/PXE/timeout even with no prompt to race against.
  This would mean the deeper OVMF issue is independent of the keystroke race entirely — a **hard
  stop** on this whole approach; return to the research phase (Categories 4-6, deferred above) or
  reconsider Setup.exe-free options again.
- **Actual result (see `PHASE3_ENGINEERING_LOG.md` for the full record)**: passed cleanly.
  `BdsDxe` loaded the DVD-ROM boot entry directly, no EFI Shell/PXE fallback at all, straight to a
  real, settled "Windows 11 Setup" language-selection screen in ~20 seconds, zero keystrokes sent.
  The rebuilt ISO was verified correct beforehand (`7z l` + `md5sum` against the `_noprompt` source
  files), not assumed. Persisted at `image-apply/output/iso-noprompt/win11-noprompt.iso` for reuse
  in Phase 3.2, since the rebuild itself is now confirmed correct.

**Phase 3.2 — PASSED (on attempt 2). Prove explicit `bootindex=` control correctly re-selects the
target hard disk across Setup's own mid-install reboot(s), not just the initial CD-ROM boot.**
Add a real target disk alongside the patched ISO (a blank `partition-disk.sh`-created disk, or even
fully blank — Setup.exe partitions it itself). Same hands-off approach, but now let Setup's own
`windowsPE` pass actually run an install (a real answer file needed here — see 3.3 for its full
content, but a minimal one is enough for this phase's own question). Watch across every reboot
boundary via QMP screenshots.
- **Gate to pass**: every reboot correctly resumes into the installed system on the hard disk (or
  continues Setup's own next phase), never falling back into the ISO/EFI shell/PXE.
- **Gate fails if**: the CD-ROM's continued presence causes Setup to re-enter from the ISO after a
  reboot, or boot device selection is otherwise ambiguous. **Not necessarily a hard stop** — Phase
  2's own research already flagged this as a real, solvable engineering problem (this project's
  existing QMP device-control conventions, or a scripted `bootindex=` flip between phases, are real
  candidate fixes) — but it's real work to close, not assumed away, and worth confirming a fix
  actually works before Phase 3.3 builds on top of it.
- **Actual result (see `PHASE3_ENGINEERING_LOG.md` for the full record)**: attempt 1 hit exactly
  this failure mode - static `bootindex=` alone doesn't survive the first reboot, Windows Setup's
  own "looks like you booted from installation media" dialog confirmed it. Attempt 2 fixed it with
  a QMP `eject` on both CD-ROM devices right before the reboot, confirmed via `query-block`. Result:
  **two separate reboots, zero fallback to the CD-ROM either time**, landing on a real, genuine
  Windows 11 OOBE screen ("Is this the right country or region?") - the first time in this project's
  history a Setup.exe-driven Windows 11 install has completed end to end. The eject trigger used
  visual/screenshot judgment this session, not yet a scriptable signal - real open item for Phase
  3.4's formalization (candidates: a generous fixed timeout, a cheap fixed-pixel color-sample check,
  or dropping the static `bootindex=` override entirely in favor of OVMF's own NVRAM-driven boot
  order once Windows registers its own Boot Manager entry - untested).

**Phase 3.3 — PASSED, all 3 of 3 attempts. Deliver a real, complete answer file through Setup.exe
and confirm a genuinely working, WinRM-reachable result — the project's own established success bar,
not a new one. Evidentiary bar met; proceed to Phase 3.4.**
Build a real answer file covering the passes Setup.exe actually processes (`windowsPE` for
disk/image selection — new territory, not needed by this project's offline-apply path — plus
`specialize`/`oobeSystem`, adapting this project's existing `unattend-windows11.xml` content where
it already applies). Run a genuinely fresh, hands-off, end-to-end build: ISO patch → hand-built
`qemu-system-x86_64` boot → unattended Setup.exe install → real first boot → WinRM check.
- **Gate to pass**: real, authenticated WinRM connectivity (`hostname` returns the expected
  `ComputerName`, `Get-NetAdapter` shows a working adapter) — the exact bar every other successful
  build in this project has met — **and, critically, no BSOD, no unskippable OOBE hang** — the
  actual problem this entire effort exists to solve, not a secondary concern.
- **Given this project's own hard-earned lesson from the Option A/B saga (a single success is not
  sufficient evidence)**: this gate requires **at least 2-3 independent successful runs**, matching
  the same evidentiary bar Server 2022/2025 and Option B's own mechanical pieces were held to, not
  a lighter bar just because this is a new approach.
- **Gate fails if**: the same BSOD/OOBE-hang signature recurs even once across these attempts, or a
  new failure mode appears. Either way, this is the point to stop and reassess rather than
  patching around a recurrence — this project has already spent significant effort learning not to
  do that.

**Phase 3.4 — DONE. Formalize into real scripts, only after Phase 3.3's repeated success.**
Wrote the production tooling: `image-apply/build-iso-noprompt.sh`, `image-apply/
windows11-setup-install.sh`, new `tools/qmp-eject.py`/`tools/qmp-pixel.py` helpers, `build.sh` wired
to route `windows11` through the new script with no Packer handoff (decided deliberately — Windows
11 has no Phase 3 roles to provision, and the script confirms first boot itself; Server 2022/2025's
own Packer path is untouched). The offline-apply scripts (`partition-disk.sh` etc.) stay in place,
just no longer called for `windows11` — not deleted, per this project's standard. Along the way, real
testing found and fixed two genuine bugs (a calibration-script ISO-naming bug, and a real install
failure from an eject-timing default that was too early), then found something bigger: the entire
eject-timing mechanism was unnecessary — dropping the static `bootindex=` override and relying on
OVMF's own NVRAM boot order works cleanly and was confirmed independently four times, including two
full runs of the final production script with zero manual intervention. `calibrate-eject-timing.sh`
is retired (historical record only). See `PHASE3_ENGINEERING_LOG.md`'s Phase 3.4 entries for the
complete trail.

**Phase 3.5 — DONE. Full validation, matching this project's own evidentiary bar.**
Two independent, fully fresh, hands-off builds through the finished `windows11-setup-install.sh` -
both clean (`hostname` confirmed via real WinRM, graceful shutdown, no errors/warnings), no manual
intervention. Combined with Phase 3.4's own four independent confirmations of the underlying
mechanism, Windows 11 now has the same "production-ready" status Server 2022/2025 already have. See
`PHASE3_ENGINEERING_LOG.md`'s Phase 3.5 entry for the full record.

#### Key assumptions (stated so they can be checked, not just held)

- The `_noprompt` mechanism behaves identically for Windows 11 client media as the Proxmox thread
  observed for whatever media that poster used (not independently confirmed — Phase 3.1 is exactly
  this check, against *our own* cached Windows 11 ISO specifically).
- `EarlyF6DriverInstall`'s gate (Sessions 3-6's original blocker) doesn't refire under this
  different boot-medium/delivery shape. Untested; Phase 3.1-3.2 will surface this quickly if wrong.
- Windows 11's TPM 2.0/Secure Boot hardware-compatibility check (enforced by Setup.exe itself, per
  `PHASE2_ENGINEERING_LOG.md` Finding 43) will need to be satisfied or bypassed once Setup.exe is
  back in the loop — this project's offline-apply path never had to deal with it at all. A
  well-precedented, lab-appropriate bypass exists (`LabConfig`/`BypassTPMCheck` registry keys,
  Phase 1's Category 5) but hasn't been verified current for this project's own OVMF/QEMU
  configuration. Needs a real check, not an assumption, likely surfacing naturally in Phase 3.2-3.3.

#### Key risks

- **Reintroducing Setup.exe reintroduces its own historically-fragile territory** — this is
  precisely the mechanism this project was built to avoid, for real, documented reasons (Sessions
  3-6's `EarlyF6DriverInstall` dead end). The phased gates above exist specifically to catch this
  early and cheaply (Phase 3.1-3.2) before investing in the fuller Phase 3.3 build.
- **The deeper OVMF boot-order bug may not be purely a Packer limitation** — Phase 0/1's own
  research found this stated as the sibling project's diagnosis, not independently proven. Phase
  3.2 is the actual test of this, not an assumption carried in from research.
- **Wall-clock cost**: each phase is a real disk build, similar cost to the Sysprep-cycle testing
  this project already did extensively this session (tens of minutes per attempt). Time-box
  investigation per this project's own standing principle — a hard stop and return to Categories
  4-6 (or further reconsideration) is a legitimate outcome, not a failure of the plan.

#### Open questions carried forward from Phases 0-2

- Does Setup.exe coming back for Windows 11 make it a genuinely separate implementation track
  within this project, or should it converge toward looking more like the sibling project's own
  approach instead? Real architecture-boundary question — worth revisiting once Phase 3.3 actually
  succeeds (or doesn't), not decided in the abstract now.
- Does Packer re-enter the pipeline at all for Windows 11 post-install, or does the hand-built
  `qemu-system-x86_64` approach cover the whole lifecycle the way `image-apply/*.sh` already does
  for the offline path? Deferred to Phase 3.4.

---

## Explicitly out of scope for this research pass

- Server 2022/2025's own pipeline — unaffected, not being reconsidered.
- Re-deriving a fully-offline, Setup.exe-free variant from scratch — already hard-stopped; Phase
  0-1 may still turn up Setup.exe-free approaches worth knowing about, but the point is to find
  what's *proven to work elsewhere*, not to retry this project's own already-falsified approach a
  third time.
- Any implementation work. This is a research pass only.

---

## Open questions this plan deliberately leaves unresolved until research happens

- Does Setup.exe need to come back into play for Windows 11 specifically, given the original
  reason it was banned may be Packer-QEMU-builder-specific rather than a fundamental Windows
  11/QEMU incompatibility?
- If Setup.exe does come back for Windows 11, does that make Windows 11 a genuinely separate
  implementation track within this project (as Option B briefly was), or does it mean Windows 11's
  build process converges toward looking more like the *sibling* project's own approach instead?
  A real architecture-boundary question, not something to decide unilaterally once research
  results are in.

---

## Next step

**Research (Phases 0-2) and design (Phase 3) are both done.** The next step is real, not more
documentation: execute **Phase 3.1** — build the `_noprompt`-patched Windows 11 ISO and confirm,
hands-off, that it eliminates the keystroke race in isolation. This is the first gate in Phase 3's
own phased plan above; each subsequent phase is gated on the one before it passing, with named
stopping points on failure rather than an assumption that the whole approach will work end to end.
Not started yet, pending direction. If Phase 3.1 fails, Categories 4-6 above remain as the fallback
survey.
