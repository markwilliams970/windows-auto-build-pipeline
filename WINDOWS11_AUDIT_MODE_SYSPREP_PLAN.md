# Windows 11 Architecture Decision: Audit Mode + Sysprep (Option B)

## Status

**Option B chosen. Phases 1 and 2 complete and confirmed — see `PHASE3_ENGINEERING_LOG.md` Session
4, Findings 10-11.** The plan's two biggest unverified assumptions are now both empirically
confirmed true: (1) the offline-drop delivery mechanism triggers real Audit Mode entry (fresh
Windows 11 disk → built-in Administrator account, no OOBE, real Sysprep GUI auto-launched — exact
match to Microsoft's documented behavior), and (2) `Microsoft-Windows-Deployment`/`RunSynchronous`
under the `auditUser` pass automates Sysprep's own invocation with **zero live keystroke driving** -
the VM ran `sysprep /generalize /oobe /shutdown` on its own and powered itself off, with Windows'
own `Sysprep_succeeded.tag` confirming a clean completion. That same test disk carried this
project's normal offline viostor/netkvm driver injection (not a stripped-down disk), so it also
substantively answers Open Question 3 / Phase 3 below - Sysprep did not reject the disk over the
non-standard injection. Phase 4 (write the real `image-apply/audit-mode-sysprep.sh` script) is next.
Treat every claim in Phases 3-5 below as still "verify before trusting" in its fullest sense - Phase
3's remaining open piece is confirming the injected drivers still *function* after the post-Sysprep
`specialize` pass reprocesses them, not just that Sysprep didn't reject them outright.

**Read `PHASE3_ENGINEERING_LOG.md`'s Session 3 (Findings 7-9) before touching anything below** —
this document only makes sense in that context. Short recap: a completely fresh, hands-off Windows
11 build (via this project's own `image-apply/*.sh` scripts) reliably shows an unskippable
interactive OOBE screen and, more seriously, an outright kernel-level BSOD with differing
NTFS-referencing stop codes across independent runs. Bisection conclusively isolated the BSOD's
trigger to Windows *parsing a valid `unattend.xml`* specifically (not the offline file-write that
delivers it — a garbage/invalid file exercising the identical write path is harmless). Server
2022 and Server 2025 show none of this across six independent successful builds each — this is
Windows-11-specific, not a latent risk in the production pipeline already shipped for Server SKUs.

Research into Microsoft's own real OEM manufacturing pipeline
([Deployment and imaging overview](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/deployment-and-imaging-primer?view=windows-11))
found the likely structural cause: every real OEM flow inserts a live **Audit Mode boot + Sysprep**
cycle between offline image preparation and the customer-facing first boot. This project has never
done that — it goes straight from "offline-applied + driver-injected" to what it treats as the
real first boot, for all three OSes. That gap has never mattered for Server 2022/2025 (six clean
runs each) but plausibly explains both Windows 11 symptoms: `install.wim`'s baseline generalized
state is designed for *one* specific flow (apply → boot → real OOBE, exactly once), and this
project's offline `hivex`/`ntfs-3g` edits happen entirely outside anything a real, live Sysprep
pass ever validated.

**Scope: Windows 11 only.** Server 2022/2025 stay on the current, already-proven, fully-offline
architecture unchanged. This would make Windows 11's build recipe a genuinely distinct
implementation branch from the two Server SKUs, not a shared code path with an extra flag.

---

## Executive summary

Insert a new pipeline stage — boot the disk once into **Audit Mode** (a built-in Windows feature
that logs straight into an Administrator desktop without ever showing OOBE), then run **Sysprep**
(`/generalize /oobe /shutdown`) — between `make-bootable.sh` and `apply-unattend.sh`, for Windows
11 only. This re-generalizes the installation through a real, live Windows session before the
disk's actual customer-facing first boot, matching Microsoft's own documented flow exactly instead
of approximating it.

Per Microsoft's own docs, **none of this tooling is gated behind an OEM license** — Audit Mode is
built into every Windows image, and Sysprep is "included in all Windows images." The access
question that matters here isn't licensing, it's mechanism: this project's whole pipeline is built
on never running Setup.exe (CLAUDE.md's own standing rule, and the entire reason this project
exists instead of just fixing the sibling project's interactive-installer approach). Audit Mode is
normally entered either interactively (`Ctrl+Shift+F3` during a live OOBE) or via an unattend
setting that a Setup.exe-driven install consumes. **Whether the offline-drop delivery mechanism
this project already relies on for every other unattend pass (proven working since Session 9 of
`PHASE2_ENGINEERING_LOG.md`) also works for triggering Audit Mode is the single biggest unverified
assumption in this plan**, and the first thing to test before building anything else.

---

## Candidate mechanism for entering Audit Mode without Setup.exe

Real OEM flows document two ways into Audit Mode:

| Mechanism | How it's normally triggered | Applicable here? |
|---|---|---|
| **A. `Ctrl+Shift+F3` during live OOBE** | Manual keystroke during an interactive OOBE session | No — requires a live OOBE session to already be running interactively; this project's whole point is avoiding exactly that kind of live interactive driving, and it doesn't exist before Sysprep has run anyway (chicken-and-egg) |
| **B. `Microsoft-Windows-Deployment`'s `<Reseal><Mode>Audit</Mode></Reseal>`** (unattend component) | Setup.exe consumes it during a live install, or (unverified) the same offline answer-file-search mechanism this project already relies on for every other pass | **Untested but the obvious candidate** — same delivery mechanism (`%WINDIR%\Panther\unattend.xml`, dropped offline) already proven for `specialize`/`oobeSystem` since Session 9. Needs its own from-scratch verification per this project's "verify before trusting" standard, not assumed to carry over just because other passes did. |

No third option was found in this session's research pass; if B doesn't pan out, that's a hard
blocker on Option B as a whole and Option A would need to be revisited.

---

## Proposed pipeline change

Current order (all three OSes, all four scripts): `partition-disk.sh` → `apply-image.sh` →
`make-bootable.sh` → `apply-unattend.sh` → (production) `packer/boot-and-provision.pkr.hcl`'s real
first boot.

**Proposed, Windows 11 only:** insert a new `image-apply/audit-mode-sysprep.sh` between
`make-bootable.sh` and `apply-unattend.sh`:

```
partition-disk.sh → apply-image.sh → make-bootable.sh →
  audit-mode-sysprep.sh   [NEW, windows11 only]
    → offline-drop a minimal, Audit-Mode-triggering unattend.xml (Reseal/Mode=Audit only —
      not the real customer-facing one)
    → boot the disk solo (same virtio-blk-pci device model already used everywhere else in
      this project; not media=cdrom, so none of the "press any key" landmine risk applies —
      confirmed as a non-issue for solo target-disk boots throughout Phase 2)
    → confirm Audit Mode's admin desktop is reached (QMP screendump, same technique used
      throughout this project)
    → trigger sysprep /generalize /oobe /shutdown automatically (mechanism TBD - see
      "Avoiding live keystroke automation" below), not via live keystroke driving
    → confirm the VM powers itself off on its own (sysprep's own /shutdown flag) - poll via
      pgrep, same pattern as every other graceful-shutdown wait in this project
→ apply-unattend.sh   [unchanged mechanism, now drops the REAL final unattend.xml
                        (FirstLogonCommands, OOBE-skip, etc.) after Sysprep has re-generalized
                        the installation, exactly matching Microsoft's own documented sequence]
→ (production) real first boot, now genuinely Sysprep-prepared like a real OEM shipment
```

`apply-unattend.sh` itself needs no changes — it already does exactly the right thing
(`%WINDIR%\Panther\unattend.xml` offline drop); it just needs to run *after* the new step instead
of being the pipeline's last offline touch.

### Avoiding live keystroke automation

CLAUDE.md's own standing engineering preference is against fragile, timing-dependent live
automation where a documented, non-interactive mechanism exists (see its `boot_command`/VNC-keystroke
ban, and the QMP-screendump convention's own framing of interactive driving as a fallback, not a
default). Two candidates, needing their own verification:

1. **`Microsoft-Windows-Deployment`'s `RunSynchronous` commands**, which (per the Unattend
   framework's own documented scope — "the same unattend file can be used to make changes to
   WinPE, an offline image, Sysprep, first boot, audit mode, and the first time a user logs into
   Windows") appear to support exactly this: commands that run automatically during an Audit Mode
   boot, ahead of a final `sysprep` invocation, driven by the same offline-dropped answer file
   already triggering Audit Mode entry in the first place. This is the natural first thing to try —
   it would mean zero live keystroke automation anywhere in this new step, keeping it consistent
   with the rest of this project's architecture.
2. **Fallback only if (1) doesn't work**: a scripted, single QMP `send-key` sequence to open a
   command prompt and run `sysprep /generalize /oobe /shutdown` directly — matches the technique
   already proven working live this session (Finding 7's keyboard-layout-screen workaround), so it's
   a known-viable fallback, not a hypothetical, but should be the second choice, not the first.

**If (2) is ever used, or any future phase needs `tools/qmp-click.py` (mouse clicks, not just
keystrokes)**: see CLAUDE.md's "VM screen inspection" section for the required USB tablet device
flags — this is a project-wide gotcha, not specific to Windows 11 or to this plan, so it's
documented there rather than duplicated here.

---

## Open questions to resolve, in the order they'd actually block progress

1. **Does the offline-drop delivery mechanism trigger Audit Mode at all, in a Setup.exe-free
   pipeline?** The single biggest unknown — test this alone, cheaply, before building anything
   else (see Phase 1 below).
2. **Does `RunSynchronous` (or equivalent) let Sysprep run automatically inside Audit Mode without
   live keystroke driving?** Second-biggest unknown; determines whether this stays fully scripted
   or needs a keystroke-automation fallback.
3. **Does Sysprep's `/generalize` pass tolerate this project's offline `hivex`-injected virtio
   drivers cleanly?** Sysprep is known to fail outright (`"Sysprep was not able to validate your
   Windows installation"`) against certain unexpected driver/app states. Our viostor/netkvm
   `DriverDatabase` registration is a non-standard, non-PnP-driven injection path — genuinely
   untested against Sysprep's own validation logic. Real, testable risk, not hypothetical.
4. **Does the eval-media rearm/expiration constraint interact badly with adding a Sysprep pass?**
   Per `HANDOFF_FROM_UNATTENDED_INSTALL.md`'s own central design constraint, the rearm counter is
   capped at a small number of total uses (typically 3-5) **per original installation, not per
   clone** — and this project's whole "always fresh, never clone" architecture already exists
   because of this limit. Since every build is already fresh and each disk would only ever go
   through Sysprep's `/generalize` once (never repeated against the same installation), this should
   be safe even if `/generalize` itself consumes one rearm attempt — but this has not been
   confirmed, only reasoned about, and belongs in Phase 1's verification pass, not assumed.
5. **Where should the live `pnputil /add-driver` step for netkvm actually run** — inside Audit
   Mode (matching a real OEM's "resolve driver state before generalizing" pattern more closely) or
   stay in `FirstLogonCommands` on the final boot (current behavior, already proven for Server
   SKUs)? Worth deciding deliberately once (1)-(3) are answered, not before.
6. **Wall-clock cost.** This adds one full extra live boot cycle per Windows 11 build (boot to
   Audit Mode, run Sysprep, wait for auto-shutdown) on top of the existing WinPE/`bcdboot` boot and
   the final real boot — three live boots total instead of two. Worth knowing the actual added time
   once Phase 1-2 are working, for realistic build-time expectations.

---

## Phased execution plan

**Phase 1 — DONE, confirmed (`PHASE3_ENGINEERING_LOG.md` Session 4/Finding 10). Verify the core
mechanism, cheaply, before writing any real script.**
Build one fresh Windows 11 disk through the existing `partition-disk.sh`/`apply-image.sh`/
`make-bootable.sh` (unchanged). By hand, offline-drop a minimal unattend.xml containing *only* the
`Microsoft-Windows-Deployment`/`Reseal`/`Audit` setting — nothing else, no `RunSynchronous`, no
driver commands. Boot hands-off, watch via QMP screendump. Success criterion: reaches a real
Administrator desktop with no OOBE screen of any kind (matches Audit Mode's own documented
behavior). Failure here is a hard stop on Option B entirely — reconsider Option A if this doesn't
work.

**Phase 2 — DONE, confirmed (`PHASE3_ENGINEERING_LOG.md` Session 4/Finding 11). Automate Sysprep's
invocation without live keystroke driving.**
`RunSynchronous` under the `auditUser` pass worked on the first attempt - no QMP-keystroke fallback
needed. The VM ran `sysprep /generalize /oobe /shutdown` fully unattended and powered itself off on
its own, confirmed via Windows' own `Sysprep_succeeded.tag` marker in `setupact.log`.

**Phase 3 — substantively answered by the same Session 4/Finding 11 run, one piece still open.
Confirm Sysprep tolerates the offline-injected drivers.**
The Phase 2 test disk was never a stripped-down minimal one - it went through the *full*
`make-bootable.sh` (both viostor and netkvm `DriverDatabase` injection), and Sysprep completed
successfully against it (two non-fatal, generic log errors observed, neither naming `viostor`/
`netkvm` - see Finding 11 for the full detail on why both are almost certainly unrelated to this
project's own injection approach). **Still open**: whether the drivers *function* after the
post-Sysprep `specialize` pass re-processes the disk on its next real boot - Sysprep not rejecting
the disk is necessary but not sufficient evidence of that. Phase 5's end-to-end validation should
confirm this explicitly (real WinRM connectivity depends on the virtio-net driver surviving intact).

**Phase 4 — write the real `image-apply/audit-mode-sysprep.sh` and wire it into the pipeline.**
Once Phases 1-3 confirm the mechanism works, formalize it as a real script (mirroring the existing
`image-apply/*.sh` scripts' structure and conventions — `lib/common.sh` sourcing, `set -euo
pipefail`, the same `qemu-nbd`/`ntfs-3g` offline-drop pattern already used for the trigger
unattend.xml), insert it into `build.sh`'s orchestration for `windows11` specifically (Server
2022/2025 stay unchanged), and decide question 5 (where `pnputil`'s netkvm install actually runs)
based on what Phase 3 revealed.

**Phase 5 — full end-to-end validation, matching the evidentiary bar already set for Server
2022/2025.** Multiple independent, fully fresh Windows 11 builds through the complete revised
pipeline, hands-off, each confirming: no BSOD, no unskippable OOBE screen, real authenticated WinRM
connectivity (`hostname` returns the expected `ComputerName`, `Get-NetAdapter` shows a working
adapter — the same bar Phase 2's own success criterion already uses). Given Findings 7/8 showed
different symptoms on different runs even from an identical recipe, **a single clean run is not
sufficient evidence** — plan for at least 2-3 independent successes before treating this as
production-ready, matching the six-run bar Server 2022/2025 already met.

---

## Risks

- **Phase 1 could simply fail** — the offline-drop mechanism might not extend to Audit Mode entry
  the way it does to `specialize`/`oobeSystem`; this is a real, not-yet-confirmed assumption, not a
  formality. If it fails, Option B is blocked and Option A needs to be revisited from scratch.
- **Sysprep validation failures against non-standard driver injection** (question 3) are a known
  general Sysprep failure class, not a hypothetical concern invented for this project.
- **Added wall-clock time** per Windows 11 build (one more live boot cycle) — acceptable given
  Windows 11 takes no Phase 3 roles and isn't on the same time-sensitivity path as Server builds,
  but worth knowing the real number once measured.
- **This is real new work, not a small patch** — an entire new script, a new unattend.xml variant,
  and a new phase in the pipeline, specific to one OS. Time-box the Phase 1-3 research; if it isn't
  converging within a reasonable number of attempts, that's a legitimate signal to fall back to
  Option A rather than open-ended troubleshooting (per this project's own "avoid rabbit holes"
  standard).

---

## What this plan deliberately does not cover

Root-causing the *exact* NTFS-level mechanism behind Finding 8's BSODs (e.g., whether it's
specifically `$LogFile`/USN-journal inconsistency from `ntfs-3g`'s writes not being byte-compatible
with what a real Windows NTFS session would produce) is out of scope here — per the session's own
conclusion, that investigation is low-priority and doesn't gate this plan. If Phase 5 validates
cleanly, the mechanism no longer needs to be understood in detail; Sysprep is Microsoft's own
correct fix regardless of the precise internals it happens to repair.
