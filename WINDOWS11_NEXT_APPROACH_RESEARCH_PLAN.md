# Windows 11 Next Approach: Research Plan

## Status

**Phase 0 and a targeted Phase 1 pass are both complete.** Phase 0 confirms the original blocker is
still unresolved, as of today. Phase 1 surveyed the strongest candidate categories and found a real,
community-confirmed, primary-source technique (ISO-level `_noprompt` boot files, already present on
stock Windows 11 media) that plausibly — not yet proven for this project specifically — solves the
underlying problem when combined with this project's own existing direct boot-order control.
Categories 4-6 of the original survey (MDT/SCCM/Autopilot mechanism, TPM bypass currency,
cloud-vendor pipelines) were deliberately deferred rather than pursued exhaustively, since the
strongest lead is specific and cheap enough to prototype directly. See Phase 0/1 findings below for
the full detail. **Nothing has been built or tested yet — this is still a research document.**

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

### Phase 3 — design proposal (not started, deferred until Phase 0-2 complete)

Once real, verified working approaches are identified, come back with a concrete design proposal —
explaining the approach, assumptions, and risks before writing any implementation, per `CLAUDE.md`'s
own "Claude Instructions." Not attempted until the research above is actually done.

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

**Phase 0 and a targeted Phase 1 pass are both done.** Both independently point at the same
concrete experiment, now with real community confirmation behind it, not just reasoning from first
principles: build a `_noprompt`-modified Windows 11 ISO (rename the ISO's own already-present
`efisys_noprompt.bin`/`cdboot_noprompt.efi` over the normal boot files, rebuild via `xorriso`) and
drive Setup.exe from a hand-built `qemu-system-x86_64` invocation with explicit `bootindex=`/
`-boot order=` flags for direct UEFI boot-device control — this project's own established pattern,
not Packer's QEMU builder. This sidesteps both known failure modes at once: the keystroke race
(prompt removed entirely) and the Packer-specific boot-order limitation (never in the loop). A real
build-and-boot experiment, not further research — flagged as the recommended next action, not
started yet, pending direction. If it doesn't pan out, Categories 4-6 above remain as the fallback
survey.
