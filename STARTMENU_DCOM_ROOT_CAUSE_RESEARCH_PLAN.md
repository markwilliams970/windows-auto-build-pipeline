# Start Menu / DCOM-activation crash: research pass and next-step plan

**Status: ROOT CAUSE CONFIRMED as of 2026-08-24 (see "UPDATE" section at the end of this document).
Remediation not yet implemented — for review before any action is taken.** The investigation steps
below (originally proposed, not yet run) were executed per direct instruction; three were ruled out
and the fourth found and directly confirmed the actual cause. Read the update section first — it
supersedes this document's original "ranked next steps" list.

This document is the direct output of a research-first pass requested after the live Windows Update
experiment (`PHASE3_ENGINEERING_LOG.md`'s "the cheap test" entry, 2026-08-24) refuted Hypothesis 6.
That test proved the crash is not about file content or package-registration data — both are now
confirmed byte-identical to a known-working reference machine (`win2022-dc`) and the crash still
reproduces 100% of the time. The open question restated precisely: **what does a real Setup.exe-
driven install do, on first boot, that this project's offline `wimapply` + Panther `unattend.xml`
approach does not — specifically for the small, fixed family of in-box UWP shell components
(`StartMenuExperienceHost`, `ShellExperienceHost`, `SearchApp`/`CortanaUI`, `InputApp`/CBS) that fail
DCOM activation on every build this project produces?**

A second question this document also answers, raised directly in conversation: **is it time to pivot
Server 2022/2025 to a Setup.exe-driven install, the way Windows 11 was?** Short answer up front:
**no, not yet** — see "Why not pivot to Setup.exe" below. The rest of this document is the narrower
research path instead.

---

## Why not pivot to Setup.exe (recap, for the record)

Windows 11's pivot came only after **two full independent architectures** (fully offline, and Audit
Mode + Sysprep matching Microsoft's own OEM flow) both terminated at an **identical, unconditional,
kernel-level NTFS BSOD** — the machine could not reach a desktop at all, under either approach. That
is a fundamentally different failure class than what Server 2022/2025 has: boot, WinRM, AD DS, IIS,
and SQL Server all work, every time, and have for weeks. Only a specific, small, well-characterized
cluster of desktop-shell UWP components fails — a narrower, more bounded problem, and (per today's
test) one that is getting *more* bounded with each experiment, not less.

There is also a specific, concrete reason to expect a Setup.exe pivot would **not** even work here,
not just be unnecessary: this project's own Phase 2 already tried Setup.exe for Server 2022/2025 and
**abandoned it** after five independent fix attempts (`PHASE2_ENGINEERING_LOG.md` Findings 19, 24,
25, 27, 28) all failed against `EarlyF6DriverInstall` — a fixed, unconditional stage of Setup's own
PE-hosted execution that no answer-file configuration routed around. The mechanism that unblocked
Windows 11's Setup.exe path (`_noprompt`-patched boot media, eliminating the "press any key" UEFI
prompt) solves a *different* problem — a boot-timing race — than `EarlyF6DriverInstall`, which is a
driver-detection gate inside Setup's own execution, unrelated to boot media type. Nothing about the
Windows 11 fix implies it would clear this different, already-hit blocker. Attempting the pivot again
without new evidence that `EarlyF6DriverInstall` is actually avoidable would very plausibly mean
re-opening a closed problem to chase a smaller one.

**Recommendation: exhaust the narrower, cheaper investigation below first.** If it genuinely dead-ends
(not just "hasn't succeeded yet" — actually rules out every plausible runtime-state mechanism), *then*
revisit the Setup.exe question, and if so, scope a fresh `EarlyF6DriverInstall` feasibility check
before committing, rather than assuming the Windows 11 fix transfers.

---

## What's already ruled out (do not re-test)

Per `PHASE3_ENGINEERING_LOG.md`, six real hypotheses are closed with direct evidence:

1. Classic (non-WDDM) QXL display driver
2. RPC/DCOM boot-storm race (`ServicesPipeTimeout` fix is in place, RPC/DCOM services are healthy,
   CPU/RAM are idle, and the crash still reproduces on-demand at first activation)
3. AppX provisioning / `ProvisionedPackage` table (win2022-dc has the identical gap and works fine)
4. The deeper StateRepository `Activation`/`Application` table content (byte-identical between both
   machines, down to the `ActivationKey` hash)
5. `Windows.UI.Xaml.dll` patch level (identical `FileVersion` on both machines)
6. Activation state / licensing (`win2022-dc` is also unactivated and unaffected)
7. **(new, today)** RTM-vs-patched binary content — the literal patched, byte-identical-to-`win2022-dc`
   binary still crashes on this project's own build

The remaining gap is specifically **runtime/environment state**, not anything checkable via a file
hash, a registry-adjacent database, or a version string.

---

## Research pass: findings, with sources

Per this project's own research-first standard, multiple real, multi-angle searches were run before
proposing next steps. Findings, ranked by how directly useful each is to the actual open question:

### 1. The crash codes point at a real, recognized AppX/UWP failure class, and the two crashing apps show *different* fault signatures

`SearchApp.exe`'s crash today is `Exception code: 0xc000027b` — **`STATUS_INVALID_VIEW_SIZE`**, a code
specifically associated with Microsoft Store/AppX-delivered app startup failures, not a generic Windows
crash code. Multiple independent community sources (including a real issue filed against Microsoft's
own `WindowsAppSDK` GitHub repo, showing the identical exception code firing inside
`CoreMessagingXP.dll` during app startup — a primary-adjacent source, not just a troubleshooting blog)
converge on the same general cause categories: **incorrect system date/time, AppX registration/cache
corruption, and misconfigured registry or file permissions.**

This is a different exception code than `StartMenuExperienceHost.exe`'s earlier-documented crash
(`0xc0000409`, `STATUS_STACK_BUFFER_OVERRUN`/fail-fast) — worth treating as an open question rather
than assuming both are the identical bug: either two related-but-distinct symptoms of one shared
environmental gap (plausible, since both are AppX/DCOM-activation failures), or evidence the
underlying gap is more foundational to AppX/UWP activation infrastructure than a single specific
component defect. **Not yet re-confirmed which exception code `StartMenuExperienceHost.exe` throws on
today's current build** — the `0xc0000409` figure is from an earlier session, before the binary itself
changed via today's Windows Update test.

Sources:
- [Windows error 0xC000027B, -1073741189](https://windows-hexerror.linestarve.com/0xC000027B)
- [`Exception code: 0xc000027b` caused by ... `CoreMessagingXP.dll` during application startup · Issue #1020 · microsoft/WindowsAppSDK](https://github.com/microsoft/WindowsAppSDK/issues/1020)
- [Fix: 0xc000027b Microsoft Store Crash Exception Code](https://windowsreport.com/0xc000027b/)
- [How to Fix Microsoft Store Apps Crashing With Exception Code 0xc000027b in Windows 11](https://allthings.how/how-to-fix-microsoft-store-apps-crashing-with-exception-code-0xc000027b-in-windows-11/)

### 2. System clock / certificate-validity is a real, documented AppX failure mode — cheap to check, not yet checked

A related, more specific Microsoft error (`0x800B0101`) is directly documented as "certificate not
within its validity period, checked against the current system clock" — a recognized cause of AppX
deployment/activation failures when a machine's clock is wrong at the moment of signature validation.
Community sources repeatedly named "incorrect date and time settings" as a top cause of `0xc000027b`
specifically, alongside the AppX-registration/permissions causes above.

**This project has never explicitly checked guest clock accuracy on a fresh build.** QEMU/KVM guests
normally inherit a roughly-correct RTC from the host, but Windows' interpretation of that RTC as local
vs. UTC time depends on the `RealTimeIsUniversal` registry value, and networked time sync (`w32time`)
only engages once network/service startup has fully settled — plausibly later than these AppX
components' own first activation attempt, on a machine that (per today's investigation) has real but
possibly-delayed internet access. A skew large enough to fail a code-signing certificate check would
need to be more than an hours-scale timezone confusion, so this is not obviously "the" answer, but it
is genuinely unverified and cheap to rule in or out.

Sources:
- [How to make Win 11 sync time on boot | Windows 11 Forum](https://www.elevenforum.com/t/how-to-make-win-11-sync-time-on-boot.12189/)
- [Windows 10 and a PC's real-time clock](https://oofhours.com/2020/10/07/windows-10-and-a-pcs-real-time-clock/)
- (0x800B0101 cert-validity/clock association, surfaced via the AppX/UWP deployment error-code
  research pass; see "Error Codes For Troubleshooting App Installation Issues" — Microsoft Community
  Hub)

### 3. `DISM /Apply-Unattend`'s offline pass does *not* cover what's missing — ruled out, but worth recording why

Directly researched whether this project should be invoking a real, distinct DISM mechanism
(`DISM /Apply-Unattend` against the offline-mounted volume) that it currently skips, in case that
closes the gap. **It does not apply here**: `/Apply-Unattend` only processes the `offlineServicing`
configuration pass (packages, drivers, language packs) — explicitly, per Microsoft's own
documentation, `specialize`/`oobeSystem` pass settings require either real Windows Setup or Sysprep to
process, and are not touched by this DISM verb at all. This project's Panther-drop-of-`unattend.xml`
mechanism is confirmed (by this project's own already-recorded Phase 2 results — `ComputerName`,
`AutoLogon`, `FirstLogonCommands` all firing correctly) to already be triggering real specialize-pass
processing via Windows' own documented `ImageState`-driven first-boot detection, a mechanism that is
real and Microsoft-documented (used by OEM/factory imaging generally, not unique to a Setup.exe boot)
— so "specialize doesn't really run" is not the gap either. **This whole avenue is closed**; recorded
here so it isn't re-investigated from scratch later.

Sources:
- [DISM Unattended Servicing Command-Line Options | Microsoft Learn](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-unattended-servicing-command-line-options?view=windows-11)
- [offlineServicing Configuration Pass | Microsoft Learn](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-7/dd744363(v=ws.10))
- [How Configuration Passes Work | Microsoft Learn](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/how-configuration-passes-work?view=windows-11)

### 4. A specific, credible parallel: "stub packages" and offline-provisioning limitations for Store-model apps

Search surfaced a real, documented distinction between "stub" and "full" AppX packages for some
in-box apps — stub packages ship in base OS media and are meant to be completed via online servicing,
with a documented DISM workaround (`/SkipLicense` + `/StubPackageOption:InstallFull`) for offline
provisioning scenarios. The specific crashing files here are full-size executables (hundreds of KB to
several MB, matching `win2022-dc`'s own sizes) rather than tiny placeholder stubs, so this doesn't
transfer directly — but it's real, corroborating evidence that "offline-provisioned AppX components
missing something a live/online deployment path provides" is a known, recurring class of problem in
the Windows imaging community generally, not a one-off theory specific to this project.

Source:
- [Error 0xc1570117 while installing/updating UWP Apps on win11 24H2 image using DISM - Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/2280498/error-0xc1570117-while-installing-updating-uwp-app)

### 5. Component-Based Servicing "staged vs. resolved" state — no direct primary-source confirmation found, still a live (unconfirmed) hypothesis

Searched specifically for whether install.wim-captured packages can ship in an unresolved/"staged"
CBS state that only a real Setup.exe/TrustedInstaller-driven install resolves, as a candidate
explanation invisible to both file-hash and StateRepository comparisons. **Search came back with only
generic DISM documentation, no specific confirmation or refutation.** Recorded as a genuine negative
result, per this project's own standard ("a negative result is still a result") — not evidence against
the theory, just not yet supported by anything found. This remains open and is the most
architecturally-interesting remaining hypothesis, precisely because it would explain a mechanism
invisible to every comparison already run.

---

## Ranked next steps, cheapest/most-diagnostic first

None of these have been attempted yet. All are read-only or narrowly-scoped checks, not fixes —
appropriate for a single focused session once reviewed.

1. **System clock/time-sync check (cheap, ~5 minutes).** On the next live boot, before touching
   anything else: compare guest time to host time immediately after boot (`w32tm /query /status`,
   `Get-Date` vs. host `date`), and check whether `RealTimeIsUniversal` is set. If clearly off by more
   than a trivial amount, deliberately force a correct time and re-run the live Start Menu test
   (`virsh send-key` + Windows-key press, the now-established method) before the crash would normally
   fire, to see if it changes the outcome.

2. **Re-confirm both crash signatures on the current build, fresh.** Don't rely on the older
   `StartMenuExperienceHost.exe` = `0xc0000409` figure — that binary has since changed (today's
   Windows Update). Trigger both `StartMenuExperienceHost` and `SearchApp` live, capture both current
   `Exception code`/`Fault offset` pairs, and note whether they still differ. If they now match, that's
   a meaningful data point toward "one shared mechanism"; if they still differ, toward "per-app
   activation-path-specific failure."

3. **Permissions/ACL/security-descriptor comparison, offline (no boot needed).** Reuse this session's
   own established zero-boot mechanism (`qemu-nbd` + `ntfs-3g` read-only mount) to diff `icacls`/`Get-
   Acl`-equivalent output (via `hivexsh`/direct NTFS security-descriptor inspection, or a quick live
   WinRM `Get-Acl` pass on both machines if offline inspection proves awkward) for the `SystemApps`
   package folders and the relevant `HKCR`/`HKLM\SOFTWARE\Classes` AppID/CLSID registration keys these
   DCOM servers activate through. A security-descriptor mismatch would be invisible to every check run
   so far (StateRepository content, file hashes) but would directly explain a DCOM activation-time
   permission failure.

4. **Live `DISM /Online /Get-Packages` state comparison.** Boot both machines (or reuse existing
   evidence from `win2022-dc` plus a fresh `win2022prod` boot) and diff full package state/list,
   specifically looking for any package reporting a non-"Installed" state (e.g. "Staged",
   "Superseded", "Pending") on `win2022prod` that reads "Installed" on `win2022-dc` — the most direct
   available test of the CBS staged/resolved hypothesis (Finding 5 above), even without a confirming
   primary source yet.

5. **If 1-4 all come back clean:** treat the narrower investigation as genuinely exhausted, and only
   then revisit whether a Setup.exe pivot is warranted — with a required first step of directly
   testing whether `EarlyF6DriverInstall` still blocks Setup.exe for Server 2022/2025 under this
   project's current tooling, rather than assuming Windows 11's fix transfers.

---

## Assumptions

- `win2022-dc` remains a valid, uncontaminated reference point — its own history (interactive Setup.exe
  install, years of real servicing) is different enough from this project's builds that "it works" is
  meaningful evidence, not coincidence, but it is not a controlled experiment on its own.
- The four implicated packages (`StartMenuExperienceHost`, `ShellExperienceHost`, `SearchApp`/
  `CortanaUI`, `InputApp`/CBS) are assumed to share one root cause given their consistent co-occurrence
  in the DCOM 10010 event pattern — not yet proven; step 2 above is a direct test of this assumption.
- This investigation continues to assume the underlying goal (working Start Menu) is worth pursuing at
  all. That's a separate, still-open question from the earlier conversation (whether this is even
  load-bearing for the project's actual AD/IIS/SQL/Datadog charter) and isn't re-litigated here.

## Risks

- Steps 1-2 require a live boot and the same console-unlock-via-`virsh send-key` choreography used
  today — cheap in wall-clock terms (~10-15 minutes including boot) but not instant.
- Step 3's offline security-descriptor inspection may prove awkward via `hivexsh`/NTFS tooling alone
  (Windows ACLs on NTFS are stored as binary security descriptors, not trivially human-readable via
  `hivex`) — a live `Get-Acl` WinRM pass may end up being the pragmatic fallback even though it costs
  a boot cycle Step 3 was hoping to avoid.
- None of steps 1-4 are guaranteed to find the actual gap — the CBS staged/resolved hypothesis in
  particular has no confirming primary source yet, only architectural plausibility. If all four come
  back clean, the honest outcome is "still unknown," not a confirmed root cause, and the Setup.exe
  question genuinely reopens at that point per step 5.

## Open questions for review

1. Is pursuing a working Start Menu still worth the time budget here, given the project's actual
   AD DS/IIS/SQL Server/Datadog-monitoring charter doesn't structurally require an interactive shell?
   Phase 3A added the SPICE/QXL desktop as a genuine enhancement, not a hard requirement — worth
   explicitly deciding whether this specific bug is still worth chasing versus documenting as a known
   limitation and moving to Phase 4.
2. If pursued: agree on the order above, or reprioritize (e.g. skip straight to step 4's CBS-state
   check if that's judged more likely than the clock-accuracy check).
3. Confirm no objection to another live boot cycle (steps 1-2, and possibly 4) before proceeding —
   same "one QEMU boot at a time" discipline as every other session.

---

## UPDATE (2026-08-24): root cause confirmed. This section supersedes the plan above.

The four steps above were executed in order, per direct instruction to proceed on the
`0xc000027b`/`STATUS_INVALID_VIEW_SIZE` lead. Full evidence trail is in `PHASE3_ENGINEERING_LOG.md`'s
matching entry ("ROOT CAUSE CONFIRMED..."); this section summarizes the outcome and the actual
decision now in front of you.

### Results of the four steps

1. **Clock accuracy — ruled out.** Guest clock matched host time to within a second at first
   reachability, correctly configured as UTC.
2. **Fresh crash-signature re-check — informative.** `StartMenuExperienceHost.exe` now also throws
   `0xc000027b` (it threw `0xc0000409` before the Windows Update test changed the binary);
   `SearchApp.exe` remains consistent at `0xc000027b`. Both apps now converge on the same exception
   class.
3. **CBS staged-package state — ruled out.** The only `Staged` packages on either machine are
   unrelated RAS/VPN components, identical on both — AppX packages aren't even tracked by this
   mechanism.
4. **ACL/security-descriptor check — CONFIRMED, directly, not by inference.**

### The confirmed root cause

`image-apply/apply-image.sh` mounts the target Windows partition with
`mount -t ntfs-3g -o uid=$(id -u),gid=$(id -g)`. Per ntfs-3g's own documentation, `uid=`/`gid=`
**silently disables** the `permissions` option — the one thing that makes ntfs-3g actually read/write
real Windows security descriptors (ACLs, ownership) rather than synthesizing a generic POSIX-style
permission view. `wimlib-imagex apply`, run against this mount without its `--strict-acls` flag (this
project's current, unmodified invocation), never surfaces this as an error — it silently proceeds, and
every file in the image ends up with whatever ntfs-3g's fallback scheme produces instead of its real
WIM-captured security descriptor.

**Proven directly, not just inferred**: re-running `wimlib-imagex apply ... --strict-acls` against a
disposable scratch disk, mounted with this project's exact `uid=`/`gid=` convention, fails immediately
with wimlib's own error: `"Extraction backend does not support security descriptors!"` This is
wimlib self-reporting the exact gap the documentation predicts.

**Live comparison confirms the resulting damage is real, systemic, and matches the crash exactly**:
`C:\`, `C:\Windows\System32`, `C:\Windows\SystemApps`, and the individual crashing packages' own
folders all carry a collapsed `Everyone: FullControl` ACL with no `TrustedInstaller` protection on
every `windows-auto-build-pipeline` build checked, versus proper TrustedInstaller-hardened ACLs on
`win2022-dc` (built via real Setup.exe, which writes through the Windows kernel's own NTFS driver and
never hits this gap). And — the detail that closes the loop on "the cheap test" entry's earlier
mystery — the one file directly rewritten by that Windows Update test (`StartMenuExperienceHost.exe`
itself) now has a **correct** ACL, because Windows Update's TrustedInstaller-driven installer sets it
correctly on write; only the surrounding, untouched folder tree stayed broken. That is exactly why
patching the file's bytes didn't fix the crash.

### What's confirmed vs. what's still open

**Confirmed**: the mechanism (wimlib silently drops security descriptors against this mount), and that
it's systemic and matches every previously-unexplained fact (deterministic, unaffected by file-hash or
registration-data fixes, `win2022-dc` immune by construction).

**Not yet confirmed**: that repairing the ACLs actually fixes the crash. That's a strong, well-fitting
inference (0xc000027b is independently documented as associated with "misconfigured registry or file
permissions"), not a completed end-to-end test.

**A real alternative fix path exists but is unverified**: pointing `wimlib-imagex apply` at the raw
partition device directly (`/dev/nbd0p3`, not the FUSE-mounted directory) invokes a genuinely
different internal code path — wimlib's own built-in direct-NTFS-volume writer, bypassing the kernel
FUSE mount (and its `uid=`/`gid=` limitation) entirely. This was reached and confirmed to take a
different route (distinct log output: `"Applying image 2 ... to NTFS volume /dev/nbd0p3"`), but failed
on `Permission denied` — this mode needs to open the raw block device directly, which needs root, and
this project's own `tools/sudoers-windows-auto-build-pipeline` deliberately excludes `wimlib-imagex`
from passwordless root (its own header comment explains the FUSE-mount approach was chosen
specifically to avoid wimapply ever needing root — a real, reasonable tradeoff at the time, now
understood to be the actual cause of this bug). **Whether this mode produces correct ACLs when
actually given root was never observed** — the test errored before writing anything.

### Decision needed: two real remediation paths, neither implemented

1. **Switch `apply-image.sh` to wimlib's native direct-NTFS-volume apply mode** (target the raw
   partition device, not a FUSE-mounted directory). Architecturally the more correct fix — restores
   the WIM's own real captured security descriptors rather than approximating them. Requires:
   - Granting `wimlib-imagex` scoped, reviewed `sudo` access in
     `tools/sudoers-windows-auto-build-pipeline` (currently deliberately absent) — a real, visible
     security-posture change for this project, not a trivial edit.
   - Confirming the resulting ACLs are actually correct once run as root (untested).
   - Checking whether this mode changes anything else about the apply (timing, the `--wimboot`/
     `--unix-data` flag interactions, whether `sgdisk`/`mkntfs`'s existing partition layout is
     compatible with wimlib opening the partition directly while nothing else has it mounted).
2. **A targeted, scoped post-apply ACL fixup** (e.g. `icacls`, applied via `FirstLogonCommands` or an
   offline step, to a known-good reference ACL captured from `win2022-dc` — only for the specific
   paths implicated, not a system-wide reset). Lower architectural purity, but avoids the sudo/root
   question entirely. **Explicitly not the same as `secedit /configure /cfg defltbase.inf`** — research
   during this pass found Microsoft's own documentation states that mechanism is unsupported and can
   destabilize the OS for exactly this "restore the Setup-established security baseline" purpose,
   because Setup's real baseline is `defltbase.inf` *plus* installation-time state that has "no
   supported process to replay." A scoped, narrow `icacls` fix on just the implicated paths sidesteps
   that specific unsupported territory, but is a narrower, more manual fix than path 1 and would need
   its own reference-ACL capture and verification.

Neither path has been attempted. This is the actual decision point for when you're back — which path
to pursue (or whether to scope a quick empirical test of path 1 first, given how close this session
got to actually running it), and whether the sudo/permissions-scope tradeoff in path 1 is worth taking
now that its cost (this exact bug) is fully understood.
