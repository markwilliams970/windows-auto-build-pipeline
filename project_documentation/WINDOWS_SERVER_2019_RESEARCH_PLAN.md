# Windows Server 2019: Research Plan and Feasibility Assessment

## Status

**Research only — nothing in this document is implemented.** No pipeline code, `services.yaml`,
`image-apply/*.sh`, or `image-apply/lib/common.sh` has been touched. This is a scoping pass to
answer one question: does adding Windows Server 2019 as a fourth target OS look like a low-risk,
"same as Server 2022" addition to the already-production-ready offline-apply pipeline, or does it
carry real open questions that need resolving first? Per `../CLAUDE.md`'s "Research-first discipline"
standard, this was a real multi-angle search pass (Microsoft Learn/Docs, the Microsoft Evaluation
Center, GitHub primary sources for `virtio-win`, Microsoft Q&A threads, community deployment
walkthroughs) — not a single query, and every claim below is marked as either **confirmed** against
a primary source actually checked, or **inferred by analogy** to this project's own proven Server
2022/2025 behavior and not yet independently verified.

**Research Pass 2 (2026-09-02) — this document extended, not replaced.** This is Phase A of a
formal, gated Server 2019 addition project (A: research, B: design + implementation plan with phase
gates, C: design review, D: implementation, E: E2E testing). This pass did real local/host-side
verification (not just web research) now that this project has direct access to its own cached
`virtio-win-0.1.285.iso`, deepened the DCOM/RPC boot-storm research specifically on Reddit/GitHub/
Microsoft Q&A, and re-grounded Finding 6 against this project's own subsequent history — the
Start Menu/DCOM crash investigation continued well past what the first pass had visibility into,
and its actual conclusion changes how Finding 6 should be read. See each finding below for what was
promoted from inferred to confirmed, and the new "Finding 9" for what's genuinely new this pass.

**Phase A: CLOSED, same day (2026-09-02).** Research Pass 2 left exactly one open item: the Server
2019 Evaluation ISO is gated behind a Microsoft registration form, not a scriptable download, so the
WIM edition index (Finding 3) couldn't be directly verified yet. The user completed that form
directly and handed off the resulting ISO; it's now cached in `../iso_cache/`
(`../ISO_CACHE_INVENTORY.md` updated) and the WIM index has been directly verified (index 2 =
`ServerStandardEval`, Server Desktop Experience — see Finding 3, updated in place below). **No
research-phase open questions remain.** Phase B (design + implementation plan) is next.

---

## Research plan (angles actually searched)

Following this project's own "search multiple angles, not one query" convention:

1. **Media availability** — literal search for the current Microsoft Evaluation Center Server 2019
   page, plus a direct fetch of that page's content (not just a search snippet).
2. **Offline imaging mechanism** — "DISM /Apply-Image Windows Server 2019 bcdboot offline
   deployment", looking for any Server-2019-specific deployment quirk distinct from the
   general/OS-agnostic DISM+bcdboot recipe this project already uses.
3. **WIM edition index** — search for community-documented `Dism /Get-WimInfo` output against real
   Server 2019 install media, plus a direct fetch of one such listing.
4. **VirtIO driver support** — search for the `virtio-win` project's `2k19` driver subfolder
   convention, cross-checked against a Proxmox/community deployment guide and a GitHub
   issue-tracker hit for real-world Server 2019 NetKVM behavior.
5. **PCI hardware ID stability** — no independent search needed; this project's own Finding 3A-3
   (`WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`) already establishes this is a QEMU-version behavior,
   not a Windows-version behavior — carried forward as an explicit inference, flagged as such below.
6. **DCOM/RPC "boot storm" race** — direct fetch of the primary Microsoft Q&A thread this project's
   own Finding 3A-5 (`../CLAUDE.md`) already cites for Server 2022, checked specifically for whether it
   (or any other primary source found) implicates Server 2019 too.
7. **Setup.exe involvement** — no new search needed; this project's Server 2022/2025 pipeline never
   invokes Setup.exe at all (pure offline apply), so this is a structural, not empirical, question —
   addressed directly in the findings below.
8. **Unattend.xml specialize-pass behavior** — search for Server-2019-specific
   `\Windows\Panther\unattend.xml` / `FirstLogonCommands` regressions or quirks.

---

## Findings

### 1. Media availability — **confirmed**

Windows Server 2019 evaluation media is still officially published at
[microsoft.com/en-us/evalcenter/evaluate-windows-server-2019](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2019)
(direct fetch performed, not just a search snippet). Datacenter and Standard editions, ISO and VHD
formats, 180-day evaluation period (longer than this project has needed for any single build —
irrelevant to a fresh-apply-every-time pipeline anyway, per `../CLAUDE.md`'s "never cache a previously
applied disk" rule). The page shows **no retirement notice** — it does steer evaluators toward
Server 2022 as the newer option, but the 2019 download itself is live and functional as of this
research pass. This directly updates my own prior assumption going in (that 2019 eval media might
already be pulled, given how old the release is) — it is not pulled.

Not yet done: an actual `curl -sL -o /dev/null -w '%{http_code} %{url_effective}'` verification of
the resolved fwlink and a checksum/`.meta`/`.sha256` sidecar, matching this project's own
`../ISO_CACHE_INVENTORY.md` convention. That's a concrete first step if this project proceeds (see
Recommendations).

### 2. Offline WIM apply + bcdboot mechanism — **confirmed, no Server-2019-specific quirk found**

Multiple independent sources (a Dell KB on offline-servicing a Windows Server image, a VIOware
guide on DISM offline servicing/driver injection, and Deployment Research's "Building the Perfect
Windows Server 2019 Reference Image" walkthrough) describe `DISM /Apply-Image` followed by
`bcdboot` as the standard, version-agnostic mechanism for getting an applied WIM bootable —
identical in shape to what this project already has proven for Server 2022/2025. No source found
describes anything Server-2019-specific about this step; DISM/bcdboot's own behavior here predates
Server 2019 by several releases and postdates it by several more (this matches this project's own
"least brittle" ranking of this layer under ../CLAUDE.md's Version-sensitivity section). **No evidence
found, in either direction, that offline apply is harder on 2019 than 2022** — consistent with this
being the same primitive Microsoft has documented unchanged across Server 2016 through 2025.

### 3. WIM edition index / EDITIONID — **CONFIRMED 2026-09-02: index 2 = ServerStandardEval, Server (Desktop Experience) — exactly matching the "probably index 2" inference, now a citation instead of a guess**

**Resolved.** The user completed Microsoft's registration form directly (see the acquisition-blocker
writeup immediately below, kept for the record) and handed off the resulting ISO, which was cached
into `../iso_cache/2019-17763.3650.221105-1748.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso`
(build 17763.3650, matching the Extended-Support-eligible Server 2019 v1809 release line), with a
`.sha256`/`.meta` sidecar pair added and a new row in `../ISO_CACHE_INVENTORY.md`, matching the existing
convention for every other cached ISO.

This project's own non-negotiable verification recipe (`7z e ... sources/install.wim`, then
`wimlib-imagex info install.wim` — the same technique `PHASE2_ENGINEERING_LOG.md`'s Finding 0 used
for Server 2025, preferred over the older `strings -el | grep EDITIONID` technique) was run directly
against the real extracted `install.wim`, not inferred or pattern-matched:

| Index | `<NAME>` | `<EDITIONID>` | Installation Type |
|---|---|---|---|
| 1 | Windows Server 2019 SERVERSTANDARDCORE | `ServerStandardEval` | Server Core |
| 2 | Windows Server 2019 SERVERSTANDARD | `ServerStandardEval` | **Server (Desktop Experience)** |
| 3 | Windows Server 2019 SERVERDATACENTERCORE | `ServerDatacenterEval` | Server Core |
| 4 | Windows Server 2019 SERVERDATACENTER | `ServerDatacenterEval` | Server (Desktop Experience) |

**Index 2 is the value this project would actually use** (`ServerStandardEval`, Desktop Experience) —
identical index position to Server 2022 and Server 2025's own already-proven `os_wim_index` value,
and the same four-image ordering pattern (Standard Core, Standard Desktop Experience, Datacenter
Core, Datacenter Desktop Experience) both of those OSes use. Two research passes' worth of "probably
index 2, but that's pattern-matching, not a citation" is now closed: this is a direct, primary-source
read of the real cached ISO, exactly matching this project's own "verify before trusting" standard.
**Finding 3 status: CONFIRMED.** The single largest risk flagged in both prior research passes (a
silent wrong-edition apply) no longer applies to Server 2019 specifically, once this value is written
into `image-apply/lib/common.sh` at implementation time.

The extracted `install.wim` scratch file was deleted after verification (4.7 GB, not worth retaining
per this project's own disk-hygiene standard — the cached ISO itself is the durable artifact, the
extraction is reproducible from it in under two minutes on this host).

---

**Original Research Pass 2 write-up below, kept for the record of how the acquisition blocker was
found and resolved — the WIM index question itself is closed, above.**

**Still unverified — and Research Pass 2 found the actual acquisition blocker: Server 2019 evaluation media is not a plain download link like the other three OSes**

This project's own convention (never assume an index; verify via `7z x` + `strings -el ... | grep
EDITIONID` against the real cached ISO) **still cannot be executed** — but Research Pass 2 found
*why* this is a real, non-trivial gap to close, not just "hasn't been gotten around to yet."

**New finding: Server 2019's evaluation download is gated behind a Microsoft lead-generation
registration form (name/email/company), unlike Server 2022, Server 2025, Windows 11, or
`virtio-win`.** Confirmed directly, not inferred: fetching the Evaluation Center page's own
`winserver19-iso-dlintent`-tagged link
(`https://go.microsoft.com/fwlink/p/?linkid=2195685&clcid=0x409&culture=en-us&country=us`) resolves
(HTTP 301) to `https://info.microsoft.com/ww-landing-windows-server-2019.html` — a **lead-gen
landing page with a registration form**, not a downloadable ISO. This is corroborated by
independent community sources found via search (Microsoft Q&A: "To download Windows Server 2019,
you need to register first, then download and install"). This is a genuine procedural difference
from every other source in `../ISO_CACHE_INVENTORY.md`: the 2022/2025/Windows 11/`virtio-win` fwlinks
all resolve directly to a downloadable file with a real `curl`-checkable HTTP 200, no human
interaction required (confirmed by that file's own "Re-download links, verified live" table).
Server 2019 does not currently offer that path.

**This pass deliberately did not attempt to complete that registration form** — doing so would
require submitting a real or fabricated identity (name/email/company) to Microsoft, which is not
something a research task should do without the user's explicit involvement and real information.
**This remains a genuine, unresolved acquisition blocker**, not glossed over: getting the Server
2019 ISO into `../iso_cache/` requires either (a) the user completing Microsoft's registration form
themselves in a browser and handing off the resulting direct download link, or (b) a project
decision about whether a non-Microsoft-first-party mirror (e.g. Internet Archive hosts several
uploads of Server 2019 v1809 media, surfaced during this pass's search) is an acceptable substitute
source — which would be a real departure from this project's established "official
Evaluation Center source" convention for every other OS and needs an explicit decision, not a
silent substitution. See Recommendations and Open Questions below — this is now a concrete
precondition for Recommendation #1/#2, not just "download it, like the others."

**Community evidence for the index value itself, still not primary-source-confirmed**: Pass 1's
GitHub-hosted `Dism /Get-WimInfo` excerpt (real Server 2019 build 17763.437 `install.wim`, index 4 =
"Windows Server 2019 Datacenter (Desktop Experience)") was re-confirmed as genuine this pass (the
source file's only relevant line is literally `#We're using index 4 for Windows Server 2019
Datacenter (Desktop Experience)` — accurate as far as it goes, but still doesn't show the full
table). A general web search this pass surfaced an AI-generated summary claiming the full
1/2/3/4 = Standard Core/Standard Desktop Experience/Datacenter Core/Datacenter Desktop Experience
ordering — **this was deliberately NOT accepted as confirmation**: attempts to trace it to an
actual verbatim primary source (a real Gist, a Thomas Maurer walkthrough's own screenshot, a
Deployment Research walkthrough) each independently failed to surface real command output backing
the claim, and one forum thread that might have (`forums.mydigitallife.net`) returned HTTP 403.
Per this project's own explicit standard ("verify the primary source; don't trust a search summary
... this project already caught one stale/wrong claim this way"), **the Standard Desktop Experience
index is still unverified, "probably index 2" remains pattern-matching, not a citation** — Pass 2
tried harder to close this and could not, honestly reported rather than upgraded on thin evidence.

### 4. VirtIO driver subfolder (`2k19`) — **CONFIRMED directly, Research Pass 2 (2026-09-02): byte-identical to `2k22`, not just "present"**

Research Pass 1 found `2k19` referenced as a general `virtio-win` packaging convention but couldn't
check this project's own pinned ISO (web fetch hit an Access-Denied bot wall). Research Pass 2 did
the direct, local, host-side check instead — no network needed, the file is already cached:

```
7z l ../iso_cache/virtio-win-0.1.285.iso | grep -i 2k19
```

**Confirmed present**: `Balloon/2k19/amd64/`, `NetKVM/2k19/amd64/`, `vioscsi/2k19/amd64/`,
`viostor/2k19/amd64/` all exist in the exact pinned ISO, with the full expected file set in each
(`.inf`/`.sys`/`.cat`/`.pdb`, plus `netkvmco.exe`/`netkvmp.exe` for NetKVM — the same
`netkvmp.exe` dependency Phase 3 Session 1/2 found `pnputil` needs but offline `DriverDatabase`
registration alone doesn't provide, already present here too).

**Went further than "present" — extracted and diffed the actual driver content against `2k22`**:

- `diff` of `vioscsi.inf`, `netkvm.inf`, and `viostor.inf` between `2k19` and `2k22`: **zero
  differences, byte-for-byte identical text**, hardware IDs included.
- `sha256sum` of the actual driver binaries (`netkvm.sys`, `netkvmp.exe`, `vioscsi.sys`,
  `viostor.sys`) between `2k19` and `2k22`: **identical hashes on every file**:
  ```
  netkvm.sys:  e5dbfefb...e56  (2k19 == 2k22)
  netkvmp.exe: 9b07ee1b...2e7  (2k19 == 2k22)
  vioscsi.sys: 573419a1...3c4  (2k19 == 2k22)
  viostor.sys: 7802ea9a...326  (2k19 == 2k22)
  ```

This isn't "the driver package has a 2k19 folder that probably works the same way" anymore — it's
**the literal same compiled binaries and INF text**, just packaged under a different per-OS
subfolder path. Whatever this project already knows to be true about `2k22`'s driver behavior
(hardware IDs, `DriverDatabase` registration recipe, `pnputil` dependency on `netkvmp.exe`)
transfers to `2k19` as a hash-verified fact, not an inference. **Finding 4 status: CONFIRMED.**

One relevant real-world data point, not a blocker (carried over from Pass 1, still accurate): a
`virtio-win` GitHub issue reports a NetKVM driver failure on Server 2019 — but the reporting
environment is **Bhyve**, not QEMU/KVM, and the issue is unresolved/inconclusive rather than a
documented general Server-2019 regression. Not evidence against this project's own QEMU/KVM-based
approach.

### 5. PCI hardware ID stability — **substantially strengthened, Research Pass 2; still not independently boot-tested for 2019**

`../CLAUDE.md`'s own Finding 3A-3 already establishes that `virtio-scsi-pci` PCI hardware ID
negotiation (`VEN_1AF4&DEV_1048` modern vs. `DEV_1004` legacy/transitional) is a function of **QEMU
version and device topology** (bare controller vs. drive-attached), not Windows version — this was
explicitly generalized in `../CLAUDE.md`'s "Version-sensitivity and brittleness" section as a QEMU-side
risk, independent of which guest OS is involved.

Finding 4's byte-for-byte confirmation above directly extracted the exact `PCI\VEN_1AF4&DEV_...`
hardware ID lines from `2k19`'s own INF files:

```
vioscsi (2k19): PCI\VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00 (legacy), PCI\VEN_1AF4&DEV_1048&SUBSYS_11001AF4&REV_01 (modern)
netkvm  (2k19): PCI\VEN_1AF4&DEV_1000&SUBSYS_00011AF4&REV_00 (legacy), PCI\VEN_1AF4&DEV_1041&SUBSYS_11001AF4&REV_01 (modern)
viostor (2k19): PCI\VEN_1AF4&DEV_1001&SUBSYS_00021AF4&REV_00 (legacy), PCI\VEN_1AF4&DEV_1042&SUBSYS_11001AF4&REV_01 (modern)
```

These match `tools/gen-viostor-ddb-reg.py`'s existing `viostor`/`netkvm` presets
(`legacy_pciid="VEN_1AF4&DEV_1001&REV_00"`/`"VEN_1AF4&DEV_1000&REV_00"`,
`modern_pciid="VEN_1AF4&DEV_1042&REV_01"`/`"VEN_1AF4&DEV_1041&REV_01"`) **exactly** — confirmed by
direct read of the script, not by memory of what 2022/2025 used. Since Finding 4 already proved the
`2k19` INF is textually identical to `2k22`'s, this was expected, but it's now a direct read of the
actual hardware IDs Server 2019 would use, not an assumption carried over from 2022/2025.

**What this does and doesn't close**: the *driver-side* half of this question (does the driver
package itself reference the same hardware IDs) is now fully confirmed, hash-verified. The
*QEMU-negotiation* half (does a real virtio-scsi-pci controller on this host's actual QEMU version
actually present `DEV_1004`/`DEV_1048` to a Server 2019 guest at boot, the way Finding 3A-3 proved
for Server 2022/2025/Windows 11) has no OS-side variable that could make it differ — negotiation
happens in QEMU/host firmware, before the guest OS is even loaded — but has not been independently
exercised by an actual Server 2019 boot. **Status: strengthened from "inferred" to "driver-side
confirmed, QEMU-negotiation side not yet boot-tested" — a smaller, more specific residual gap than
Pass 1 could state.**

### 6. DCOM/RPC "boot storm" race (`ServicesPipeTimeout`) — **substantially re-framed, Research Pass 2: the mitigation is already unconditional in the shared pipeline, and the underlying crash this project actually chased turned out to have a different root cause entirely**

**Important correction to Pass 1's own framing, found by reading this project's own subsequent
history (`STARTMENU_DCOM_ROOT_CAUSE_RESEARCH_PLAN.md`, dated 2026-08-24, one day after the
`ServicesPipeTimeout` fix Pass 1 was evaluating) rather than new web research.** Pass 1 treated
"does the DCOM boot-storm race reproduce on Server 2019" as the open question, and treated applying
`ServicesPipeTimeout=120000` as an optional, preemptive-vs-reactive *decision* Server 2019's
bring-up would need to make (Recommendation #5 / Open Question #1). Both premises need updating:

**1. The fix is not optional or per-OS — it's already unconditional in `make-bootable.sh`.** Read
directly: `make-bootable.sh` merges the `ServicesPipeTimeout=120000` registry value into the
`SYSTEM` hive for every OS that runs through it, with no OS branching around the change (confirmed
by direct grep — the merge call has no `case`/`if` gating it by `$OS`). Since Server 2019's own
bring-up (per Recommendation #4) would run through this exact same shared script unmodified, **the
fix would already apply to Server 2019 automatically, the day `server2019` is added to
`lib/common.sh` — no separate decision, code change, or "preemptive vs. reactive" tradeoff is
actually available to make.** Recommendation #5 and Open Question #1 as originally written describe
a decision that doesn't exist; see the Recommendations/Open Questions sections below for the
corrected framing.

**2. The crash this project actually spent the most effort chasing was NOT caused by the DCOM
boot-storm race — `ServicesPipeTimeout` was applied, confirmed effective at its own job, and the
Start Menu/`SearchApp` crash persisted anyway.** `STARTMENU_DCOM_ROOT_CAUSE_RESEARCH_PLAN.md`
records this directly: with the `ServicesPipeTimeout` fix already in place, "RPC/DCOM services are
healthy" (no more DCOM 10010 timeout events) — and the crash still reproduced on-demand, 100% of
the time. The investigation that followed found the *real* cause: `image-apply/apply-image.sh`'s
former FUSE-mounted (`ntfs-3g uid=/gid=`) `wimlib-imagex apply` silently dropped every file's real
NTFS security descriptor (ACLs), collapsing `TrustedInstaller`-protected system folders to
`Everyone: FullControl` — a completely different, unrelated bug that happened to produce a
similar-looking shell-crash symptom. This was directly proven (`--strict-acls` reproducing wimlib's
own `"Extraction backend does not support security descriptors!"` error against the same mount) and
then fixed by switching `apply-image.sh` to wimlib's native NTFS-volume apply mode — confirmed via
clean, unbroken E2E builds for both Server 2022 and Server 2025 on 2026-08-25/26 (`PHASE3_ENGINEERING_LOG.md`).

**What this means for Server 2019, concretely:**
- The bug that actually caused visible shell/Start-Menu crashes on every prior build is fixed at
  the shared `apply-image.sh` level, which Server 2019 inherits automatically — this is genuinely
  good news, and removes a source of risk Pass 1 didn't know to account for.
- The DCOM/RPC boot-storm race itself — the thing `ServicesPipeTimeout` actually targets — is
  real and Microsoft-documented (the primary source `../CLAUDE.md`'s Finding 3A-5 cites,
  [learn.microsoft.com/.../5836440](https://learn.microsoft.com/en-us/answers/questions/5836440/intermittent-failure-of-start-menu-search-function),
  re-checked again this pass: still scoped explicitly to "Windows Server 2022" in every quoted
  diagnostic statement, Server 2019 still not mentioned in either direction). Whether this specific
  race would actually reproduce on Server 2019 under this project's build pattern remains
  genuinely untested — but it no longer matters for the "should Server 2019 get the fix"
  question, since the fix is already unconditionally in the pipeline it would use.

**Deepened community/Reddit/GitHub search this pass — real effort, still a negative result, but a
usefully specific one:**
- Searched Microsoft Q&A, Reddit-adjacent indexes, and general web search for
  `ServicesPipeTimeout`/DCOM-10010/`StartMenuExperienceHost` combined with "Windows Server 2019"
  specifically. Found several **real** Server 2019 Start Menu failure reports (e.g. a Microsoft
  Q&A thread titled "Start Button is not working in Windows Server 2019") — but every one found
  points to a **different** mechanism (AppX package/registration corruption via
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Notifications`, per-user-profile corruption,
  RDS-specific new-user provisioning issues), not the first-boot RPC-endpoint-mapper-timeout/boot-storm
  chain the Microsoft Q&A 5836440 thread describes for 2022. None of these Server-2019-specific
  reports mention `ServicesPipeTimeout`, DCOM Event 10010, or a "boot storm"/heavy-I/O framing at
  all.
- Checked a real, actively-maintained community project as a negative control:
  [`ruzickap/packer-templates`](https://github.com/ruzickap/packer-templates) builds Windows Server
  2016/2019/2022 (among others) via Packer + QEMU/KVM + libvirt + VirtIO, a close architectural
  match to this project's own environment. Its `Autounattend.xml` for **both** Server 2019 and
  Server 2022 has an empty `FirstLogonCommands` block — **no `ServicesPipeTimeout` workaround for
  either OS**, and a GitHub issue-search across that repo for `ServicesPipeTimeout`/DCOM/10010/
  "start menu" returned zero results. This is corroborating (not proving) evidence for a specific,
  useful reframing: the "boot storm" trigger condition the Microsoft Q&A thread describes may be
  more specific to *this project's own unusually aggressive multi-boot-cycle build pattern*
  (several automated boot/shutdown cycles before the first interactive boot — Packer's
  provision+restart, then `inject-virtio-spice.sh`'s own two more) than to Server 2022 as an OS in
  general, since a comparable community project building the same OS via the same core technology
  stack apparently never needed this workaround. If that reframing is right, it argues *for*
  keeping the fix (cheap, unconditional, no reason to remove it) rather than for expecting it to be
  Server-2019-relevant in some special way — it's pipeline-pattern-relevant, and Server 2019 would
  run the identical pipeline pattern.

**Status: no longer "the single most load-bearing open question."** The practical question
(does Server 2019 get the mitigation) is resolved by architecture, not by new evidence about
Server 2019 specifically. The only genuinely open sub-question left is intellectual curiosity, not
a blocker: whether the underlying RPC/DCOM race itself would ever manifest on Server 2019 under
this build pattern — untestable without a real build, and not gating, since the mitigation is
already present either way.

### 7. Setup.exe / `EarlyF6DriverInstall` — **not applicable, by design**

Server 2022/2025's production pipeline never invokes Setup.exe at all — this project's entire
Server-2022/2025 track is pure offline apply (`wimlib` + `bcdboot`/WinPE + offline `hivex` +
offline unattend drop), per the standing "no `Microsoft-Windows-Setup`" rule for Server SKUs in
`../CLAUDE.md`. Server 2019 would use the identical mechanism, so this gate is **structurally
irrelevant** to a Server 2019 addition — no research finding changes this; it's a property of which
pipeline this project would run 2019 through, not of 2019 itself. (Contrast with Windows 11, where
Setup.exe involvement is load-bearing precisely because the offline-only path hit a hard,
unresolved BSOD there — that finding does not transfer to Server SKUs, which have never needed
Setup.exe in this project.)

### 8. Unattend.xml specialize pass — **no Server-2019-specific regression found**

General search for `FirstLogonCommands`/`AutoLogon`/Panther-directory behavviour turned up only
generic, OS-agnostic guidance and generic troubleshooting threads (e.g., `FirstLogonCommands` now
executing asynchronously rather than serially — a documented Windows Setup behavior generally, not
version-specific) — no source found describes Server 2019 behaving differently from Server
2022/2025 for the offline `\Windows\Panther\unattend.xml` drop this project already uses. This
matches the expectation that specialize-pass/OOBE processing is core Windows Setup component
behavior that has been stable across Server 2016 through 2025, consistent with this project's own
"least brittle" ranking of the underlying imaging primitives.

### 9. Support lifecycle — **confirmed, no near-term deprecation risk**

Windows Server 2019 remains in **Extended Support until January 9, 2029** (mainstream support
ended January 9, 2024) — confirmed via Microsoft's own support-lifecycle page
([support.microsoft.com](https://support.microsoft.com/en-us/topic/support-for-windows-server-2019-will-end-in-january-2029-adfc192e-7e65-496e-adef-ba4b517f7271)).
Over two years out from this research pass's date. This doesn't change the feasibility verdict, but
it's worth having checked explicitly rather than assuming — a project adding a 2018-era OS as a new
target should have a real answer for "is this about to be pulled," not just "the eval page loads
today."

---

## Comparison table

| Dimension | Server 2019 (proposed) | Server 2022 / 2025 (proven) | Windows 11 (proven) |
|---|---|---|---|
| Install mechanism | Offline apply (`wimlib`+`bcdboot`), same as 2022/2025 — no evidence otherwise | Offline apply, production-confirmed | Setup.exe-driven (`_noprompt` ISO), production-confirmed — genuinely different mechanism, for a documented reason (offline-only path hits a hard BSOD) |
| Setup.exe involved? | No (by design, same rule as 2022/2025) | No | Yes, required |
| ACL/security-descriptor fix (`apply-image.sh` native NTFS apply) | Inherited automatically, unconditional in the shared script — no OS-specific work needed | Confirmed fixed, clean E2E builds 2026-08-25/26 | Inherited automatically (not exercised by Windows 11's own separate Setup.exe path, but not needed there either) |
| WIM index verified? | **Yes — CONFIRMED 2026-09-02, index 2 = `ServerStandardEval`, Server (Desktop Experience), via direct `wimlib-imagex info` against the real cached ISO** | Yes, index 2 for both, directly verified via `7z`/`strings` | Yes, index 1, directly verified |
| VirtIO driver subfolder | `2k19` — **CONFIRMED present in the pinned `virtio-win-0.1.285.iso`, byte-identical (`sha256sum`-verified) to `2k22`'s driver binaries and INF text** | `2k22`/`2k25` — confirmed present in pinned ISO | `w11` — confirmed present in pinned ISO |
| PCI hardware ID risk | Driver-side hardware IDs confirmed identical to 2k22 (hash-verified INF read); QEMU-negotiation side not independently boot-tested | Confirmed via Finding 3A-3, generalizes across Server SKUs | Confirmed via Finding 3A-3 |
| DCOM "boot storm" mitigation | **Moot as an open question — `ServicesPipeTimeout=120000` is unconditional in `make-bootable.sh`, which Server 2019 would run through unmodified; applies automatically, no decision needed** | Present, applied unconditionally; the crash this project actually chased was later found to be a separate ACL bug, now fixed at the `apply-image.sh` level | Not evaluated (no roles/services layer applies to Windows 11) |
| Media availability | **RESOLVED — gated behind a Microsoft registration form (name/email/company), unlike the other three sources, which resolve directly with no human interaction; the user completed the form directly and the ISO is now cached (`../iso_cache/2019-17763.3650.221105-1748...iso`, `../ISO_CACHE_INVENTORY.md` updated). No longer blocking.** | Confirmed live and cached, direct fwlink | Confirmed live and cached, though the fwlink has already drifted to a newer 25H2 build than what's cached (per `../ISO_CACHE_INVENTORY.md`'s own caution) |
| Support lifecycle | Extended Support until 2029-01-09 — confirmed, no near-term deprecation risk | Actively supported | Actively supported |
| Unattend.xml specialize pass | No regression found; expected to work identically | Confirmed working (Finding 41/42) | Confirmed working (own Setup.exe-driven answer file) |

---

## Technical recommendations (if this project proceeds)

Ordered as a dependency chain, mirroring how Server 2022 was actually brought up (Phase 2 Sessions
12-13):

1. ~~Resolve the ISO acquisition blocker first.~~ **DONE 2026-09-02.** The user completed Microsoft's
   registration form directly and handed off the resulting ISO; no non-Microsoft mirror was needed.
2. ~~Cache the ISO.~~ **DONE 2026-09-02.** Cached as
   `../iso_cache/2019-17763.3650.221105-1748.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso`,
   checksum computed fresh (no prior sidecar to verify against), `.meta`/`.sha256` sidecars written,
   `../ISO_CACHE_INVENTORY.md` updated with a row matching the existing convention (with an explicit
   note that this source has no scriptable re-download link, unlike the other four).
3. ~~Verify the WIM edition index directly.~~ **DONE 2026-09-02, see Finding 3 above.** Index 2 =
   `ServerStandardEval`, Server (Desktop Experience) — confirmed via `wimlib-imagex info` against the
   real extracted `install.wim`, matching the "probably index 2" inference exactly. This value is
   ready to write into `image-apply/lib/common.sh`'s `os_wim_index()` at implementation time.
4. **Add `server2019` to `image-apply/lib/common.sh`'s per-OS tables** (`os_win_iso`,
   `os_wim_index`, driver subfolder `2k19`, disk size, default computer name), following the exact
   pattern already used for the other three OSes — no new mechanism needed. The `2k19` driver
   subfolder itself needs no further verification before this step — Research Pass 2 already
   hash-confirmed it's present and byte-identical to `2k22`'s.
5. **No `ServicesPipeTimeout` decision is actually needed.** Research Pass 2 found this fix is
   already unconditional in `make-bootable.sh` (no OS branching around it) — Server 2019 inherits it
   automatically the moment `server2019` exists in `lib/common.sh`. What Pass 1 framed as
   Recommendation #5 (a preemptive-vs-reactive tradeoff) doesn't describe an actual decision point;
   removed as a to-do, kept here only so the correction is visible against Pass 1's original text.
6. **Run the existing production pipeline unmodified** (`build.sh server2019`, once wired) and apply
   this project's own 2-3-independent-successes evidentiary bar before calling it production-ready,
   exactly as done for Server 2022/2025/Windows 11.
7. **Decide the `services.yaml`/`run-services.ps1` profile question**: AD DS/IIS/SQL Server are
   already proven on Server 2022/2025 — Server 2019 supports all three roles natively (this is not
   in question; it's the same Windows Server role infrastructure), so no new scripting work is
   expected there, only confirming the two-profile guard (`ad-ds` alone vs. `iis`/`sql-server`
   together) doesn't need an OS-specific carve-out for 2019.

## Feasibility assessment

**Verdict, updated after the ISO acquisition/verification closed out (2026-09-02): low risk, all the
way down to implementation. Every open research question from Pass 1 and Pass 2 is now resolved.**

**What got better across both passes and the final verification:**
- The virtio driver question (Finding 4/5) is hash-confirmed, not inferred — as close to zero
  residual risk as this project's own "verify before trusting" standard can produce short of an
  actual boot test.
- The DCOM boot-storm question (Finding 6), previously called "the single most load-bearing open
  question," turns out to already be resolved by architecture (the fix is unconditional in the
  shared script) — and the crash this project actually spent real effort chasing had an unrelated
  root cause (ACL/security-descriptor loss in the old FUSE-mounted `apply-image.sh`) that's since
  been found and fixed at the shared-script level, which Server 2019 inherits automatically.
- **The ISO acquisition blocker is resolved and the WIM edition index is confirmed** (Finding 3,
  above) — index 2, exactly matching the "probably index 2" inference both research passes were
  unwilling to accept as a citation. This was the single largest remaining risk (a silent
  wrong-edition apply) and it's now closed by direct primary-source verification, not analogy.

**No open research items remain.** Everything from here is implementation work (Phase B/D), not
further research — see Recommendations #4-7 below.

Every layer this project has already identified as "least brittle" (`wimlib` WIM apply, `bcdboot`,
offline `hivex` driver registration, the unattend/specialize pass, and now the ACL-preserving native
NTFS apply mode too) is confirmed by public documentation, community precedent, and — for the driver
layer — this project's own direct hash verification, to behave identically on Server 2019 as on
Server 2022/2025. Server 2019 predates Server 2022, not follows it, so in one sense this project
would be moving *backward* in Windows Server generations rather than forward into new territory —
the offline-apply mechanism this project built was proven first on 2025 (the newest, least-tested
target at the time) and generalized to 2022 with zero tooling changes; 2019 is architecturally closer
to 2022 than 2025 is to 2022, if anything a slightly easier target technically — and no longer gated
on anything research-shaped.

Compare to Server 2022's own actual bring-up (Session 12): described in `PHASE3_ENGINEERING_LOG.md`
as requiring **zero changes to any of the reusable tooling**, only OS-specific input values. Server
2019's bring-up should land in the same category — a low-effort configuration addition, not new
engineering. **Rough effort estimate: comparable to or slightly less than Server 2022's own Session
12 bring-up** (that session covered ISO download/verification, WIM index confirmation, and a full
end-to-end build/WinRM confirmation cycle in a single session, and this project's own equivalent
verification work for Server 2019 is already done as of this entry) — realistically one focused
session for the offline-apply track (Phase D, wiring `lib/common.sh` + a real `build.sh server2019`
run), plus a second short session to confirm the three provisioning roles.

---

## Open questions / assumptions / risks

**Open questions (need a decision or an empirical test, not answerable by more research) — all
research-phase open questions from both passes are now closed:**

1. ~~Who acquires the Server 2019 ISO, and how?~~ **Closed 2026-09-02** — the user completed
   Microsoft's registration form directly; no non-Microsoft mirror was needed. Kept here, struck
   through, for the record of how it was resolved.
2. ~~Is the "probably index 2" WIM index inference (Finding 3) actually correct for Server 2019
   Standard (Desktop Experience)?~~ **Closed 2026-09-02, confirmed yes** — direct `wimlib-imagex info`
   verification against the real cached ISO (Finding 3, above). No longer open.
3. ~~Does the DCOM/RPC "boot storm" race actually reproduce on Server 2019?~~ **Closed as a
   blocking question by Research Pass 2** — not because the underlying race was confirmed or
   excluded for 2019 (it still wasn't), but because the mitigation (`ServicesPipeTimeout=120000`) is
   unconditional in `make-bootable.sh` regardless of which Server SKU runs through it. Whether the
   race itself would reproduce on 2019 remains genuinely unknown and is no longer answerable by
   research (only by a real build) — but it no longer gates anything, since the fix is already
   present either way. Kept here, struck through, so a future reader doesn't wonder why it
   disappeared rather than assuming it was never asked.
4. ~~Is `2k19` present and hardware-ID-consistent with `gen-viostor-ddb-reg.py`'s presets?~~
   **Closed, confirmed yes** — Research Pass 2's direct `7z l` + `diff` + `sha256sum` check (Finding
   4/5). No longer open.

**Assumptions carried into the Feasibility verdict above, stated explicitly per `../CLAUDE.md`'s own
"identify assumptions" instruction:**

- That this project's host QEMU version and virtio-win driver version remain unchanged between now
  and a Server 2019 bring-up attempt. Research Pass 2 strengthens the driver-package half of this
  (now hash-verified identical to `2k22`'s), but the QEMU-side PCI negotiation behavior itself is
  still an assumption carried from Finding 3A-3, not independently re-tested this pass.
- That Server 2019's AD DS/IIS/SQL Server role provisioning via the existing `scripts/*.ps1` needs
  no OS-specific changes — reasonable (these are long-stable Windows Server role features, not new
  in 2022), but not independently exercised as part of either research pass, which focused on the
  offline-apply mechanism rather than re-verifying the already-proven-elsewhere provisioning layer.
- ~~That a non-Microsoft-first-party mirror of Server 2019 media carries the same provenance/checksum
  trust this project's own `../ISO_CACHE_INVENTORY.md` convention otherwise guarantees.~~ **Moot** — the
  user acquired the ISO directly from Microsoft's own Evaluation Center, so no mirror-trust question
  actually arose.

**Risks:**

- ~~The single largest risk was a silent WIM index mismatch.~~ **Resolved** — Finding 3's direct
  verification confirms index 2 = `ServerStandardEval` (Desktop Experience), so the value that will
  go into `image-apply/lib/common.sh` is a citation, not an inference.
- A process risk around the ISO acquisition step remains true as a standing fact, even though it's
  resolved for this specific ISO: because Server 2019's media requires a human-facing form rather
  than a scriptable download, it's the one source in this project's cache that can't be re-acquired
  unattended by a future session without a person involved again. Worth remembering if the cached
  file is ever lost and needs re-downloading — not a blocker now that it's cached, but not a
  "just re-run the script" situation either.
- The DCOM boot-storm risk from Pass 1 is downgraded, not eliminated: this document should still not
  be read as confirming Server 2019 is immune to the underlying RPC/DCOM race described in the
  Microsoft Q&A source — only that whether it is or isn't no longer matters for this project's own
  build, since the mitigation is unconditionally present regardless.
