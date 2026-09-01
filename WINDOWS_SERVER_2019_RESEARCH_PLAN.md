# Windows Server 2019: Research Plan and Feasibility Assessment

## Status

**Research only — nothing in this document is implemented.** No pipeline code, `services.yaml`,
`image-apply/*.sh`, or `image-apply/lib/common.sh` has been touched. This is a scoping pass to
answer one question: does adding Windows Server 2019 as a fourth target OS look like a low-risk,
"same as Server 2022" addition to the already-production-ready offline-apply pipeline, or does it
carry real open questions that need resolving first? Per `CLAUDE.md`'s "Research-first discipline"
standard, this was a real multi-angle search pass (Microsoft Learn/Docs, the Microsoft Evaluation
Center, GitHub primary sources for `virtio-win`, Microsoft Q&A threads, community deployment
walkthroughs) — not a single query, and every claim below is marked as either **confirmed** against
a primary source actually checked, or **inferred by analogy** to this project's own proven Server
2022/2025 behavior and not yet independently verified.

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
   own Finding 3A-5 (`CLAUDE.md`) already cites for Server 2022, checked specifically for whether it
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
irrelevant to a fresh-apply-every-time pipeline anyway, per `CLAUDE.md`'s "never cache a previously
applied disk" rule). The page shows **no retirement notice** — it does steer evaluators toward
Server 2022 as the newer option, but the 2019 download itself is live and functional as of this
research pass. This directly updates my own prior assumption going in (that 2019 eval media might
already be pulled, given how old the release is) — it is not pulled.

Not yet done: an actual `curl -sL -o /dev/null -w '%{http_code} %{url_effective}'` verification of
the resolved fwlink and a checksum/`.meta`/`.sha256` sidecar, matching this project's own
`ISO_CACHE_INVENTORY.md` convention. That's a concrete first step if this project proceeds (see
Recommendations).

### 2. Offline WIM apply + bcdboot mechanism — **confirmed, no Server-2019-specific quirk found**

Multiple independent sources (a Dell KB on offline-servicing a Windows Server image, a VIOware
guide on DISM offline servicing/driver injection, and Deployment Research's "Building the Perfect
Windows Server 2019 Reference Image" walkthrough) describe `DISM /Apply-Image` followed by
`bcdboot` as the standard, version-agnostic mechanism for getting an applied WIM bootable —
identical in shape to what this project already has proven for Server 2022/2025. No source found
describes anything Server-2019-specific about this step; DISM/bcdboot's own behavior here predates
Server 2019 by several releases and postdates it by several more (this matches this project's own
"least brittle" ranking of this layer under CLAUDE.md's Version-sensitivity section). **No evidence
found, in either direction, that offline apply is harder on 2019 than 2022** — consistent with this
being the same primitive Microsoft has documented unchanged across Server 2016 through 2025.

### 3. WIM edition index / EDITIONID — **inferred only, explicitly unverified**

This project's own convention (never assume an index; verify via `7z x` + `strings -el ... | grep
EDITIONID` against the real cached ISO) **cannot be executed yet** — Server 2019 media is not
present in `../iso_cache/` (confirmed by direct listing: only `2022-SERVER_EVAL...`,
`2025-...SERVER_EVAL...`, `win11ent-...`, `virtio-win-0.1.285.iso`, and `spice-guest-tools-latest.exe`
are cached; `ISO_CACHE_INVENTORY.md`'s own table lists the same four ISO/EXE sources with no Server
2019 entry).

Community evidence found for context only, not as a substitute for direct verification: a
GitHub-hosted `Dism /Get-WimInfo` listing against a real Server 2019 (build 17763.437) `install.wim`
states index 4 is "Windows Server 2019 Datacenter (Desktop Experience)" — but the fetched excerpt
did not surface the full index table, so the **Standard Edition (Desktop Experience) index — the one
this project would actually want, matching its existing `server2022`/`server2025` choice of
`ServerStandardEval`/index 2 — was not confirmed** from this source. Standard Server media
historically orders Server Core before Desktop Experience within each edition tier (Core, then
Desktop Experience, repeated per SKU: Standard Core, Standard Desktop Experience, Datacenter Core,
Datacenter Desktop Experience), which would put Standard Desktop Experience at index 2 — matching
this project's own already-proven Server 2022/2025 value — but **this is pattern-matching against
this project's own prior results, not a citation**, and must not be trusted without the direct
`7z`/`strings` check this project's own standard requires before it's used in `lib/common.sh`.

### 4. VirtIO driver subfolder (`2k19`) — **confirmed to exist as a convention, not yet verified against the specific pinned version this project caches**

A Snel.com Server-2019-specific VirtIO install guide and a Proxmox community guide both confirm the
`virtio-win` driver package ships a `2k19` subfolder (`vioscsi\2k19\amd64`, `NetKVM\2k19\amd64`,
`Balloon\2k19\amd64`), parallel to this project's already-used `2k22`/`2k25`/`w11` subfolders. A
Fedora People directory search also surfaced a `2k19/amd64` path for an older `virtio-win` release
(0.1.171) confirming the subfolder naming has existed across multiple package versions, not just a
recent one. **However**, a direct fetch of the actual directory listing for the specific version
this project already has cached (`virtio-win-0.1.285.iso`, per `ISO_CACHE_INVENTORY.md`) returned an
"Access Denied" (bot-protection page) rather than a listing — so **the presence of `2k19` in the
exact pinned ISO this project would use has not been independently confirmed**, only inferred from
the driver package's well-established general convention across versions. This is a five-minute,
host-side check (`7z l virtio-win-0.1.285.iso | grep -i 2k19`), not a real research gap — flagged
here rather than glossed over per this project's own "verify before trusting" standard.

One relevant real-world data point, not a blocker: a `virtio-win` GitHub issue reports a NetKVM
driver failure on Server 2019 — but the reporting environment is **Bhyve**, not QEMU/KVM, and the
issue is unresolved/inconclusive rather than a documented general Server-2019 regression. Not
evidence against this project's own QEMU/KVM-based approach.

### 5. PCI hardware ID stability — **inferred, not independently tested for 2019**

`CLAUDE.md`'s own Finding 3A-3 already establishes that `virtio-scsi-pci` PCI hardware ID
negotiation (`VEN_1AF4&DEV_1048` modern vs. `DEV_1004` legacy/transitional) is a function of **QEMU
version and device topology** (bare controller vs. drive-attached), not Windows version — this was
explicitly generalized in CLAUDE.md's "Version-sensitivity and brittleness" section as a QEMU-side
risk. No new research was needed or found to contradict this; it should carry forward unchanged to
Server 2019 on the same host QEMU version this project already uses for 2022/2025/Windows 11.
**Not yet empirically confirmed for 2019 specifically** — the honest status is "no reason to expect
it to differ," not "verified."

### 6. DCOM/RPC "boot storm" race (`ServicesPipeTimeout`) — **inconclusive, real open question**

The exact primary source `CLAUDE.md`'s Finding 3A-5 already cites
([learn.microsoft.com/.../5836440](https://learn.microsoft.com/en-us/answers/questions/5836440/intermittent-failure-of-start-menu-search-function))
was re-fetched directly for this research pass. **The thread's title, its own framing, and every
quoted diagnostic statement in it are scoped explicitly to Windows Server 2022** — "This is a known
architectural bottleneck in Windows Server 2022, particularly in virtualized environments," and "In
Windows Server 2022, both the Start Menu (`StartMenuExperienceHost.exe`) and Windows Search
(`SearchHost.exe`) are built on this modern architecture." **Windows Server 2019 is not mentioned
anywhere in the thread**, in either direction.

This is a genuinely ambiguous result, not a clean "does/doesn't apply" answer:

- Server 2019 (build 17763, based on the Windows 10 1809 codebase) **does** already ship
  `StartMenuExperienceHost.exe` as its Start Menu host process (that XAML-based shell architecture
  was introduced in 1809, predating Server 2022) — so the same *class* of DCOM-registration-timeout
  race is structurally plausible on 2019 too, not obviously excluded by OS version.
  This is straightforward inference, not asserted by any source found.
- On the other hand, no primary source found reports the specific symptom triad (Start Menu +
  Search + IIS failing after restart) on Server 2019 specifically, despite Server 2019 having been
  in wide production use for years longer than Server 2022 has — which is at least weak evidence
  the failure mode is less prevalent there, whether because the underlying timing changed, the
  service dependency graph changed, or simply less deployment overlap with this project's own
  unusually aggressive multi-boot-cycle build pattern (Finding 3A-5's own stated root cause: "boot
  storm" from several already-automated boot/shutdown cycles on a cold-cache disk, which is a
  pattern specific to *this project's build process*, not a generic 2022 usage pattern either).

**This is the single most load-bearing open question in this research pass** — see Recommendations
and Open Questions below.

### 7. Setup.exe / `EarlyF6DriverInstall` — **not applicable, by design**

Server 2022/2025's production pipeline never invokes Setup.exe at all — this project's entire
Server-2022/2025 track is pure offline apply (`wimlib` + `bcdboot`/WinPE + offline `hivex` +
offline unattend drop), per the standing "no `Microsoft-Windows-Setup`" rule for Server SKUs in
`CLAUDE.md`. Server 2019 would use the identical mechanism, so this gate is **structurally
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

---

## Comparison table

| Dimension | Server 2019 (proposed) | Server 2022 / 2025 (proven) | Windows 11 (proven) |
|---|---|---|---|
| Install mechanism | Offline apply (`wimlib`+`bcdboot`), same as 2022/2025 — no evidence otherwise | Offline apply, production-confirmed | Setup.exe-driven (`_noprompt` ISO), production-confirmed — genuinely different mechanism, for a documented reason (offline-only path hits a hard BSOD) |
| Setup.exe involved? | No (by design, same rule as 2022/2025) | No | Yes, required |
| WIM index verified? | **No — not yet checked; media not cached** | Yes, index 2 for both, directly verified via `7z`/`strings` | Yes, index 1, directly verified |
| VirtIO driver subfolder | `2k19` — confirmed to exist as a `virtio-win` convention; **not yet confirmed present in the specific pinned `virtio-win-0.1.285.iso`** | `2k22`/`2k25` — confirmed present in pinned ISO | `w11` — confirmed present in pinned ISO |
| PCI hardware ID risk | Inferred same as 2022/2025 (QEMU-version-dependent, not Windows-version-dependent) — not independently tested | Confirmed via Finding 3A-3, generalizes across Server SKUs | Confirmed via Finding 3A-3 |
| DCOM "boot storm" risk | **Unknown — primary source found is scoped only to Server 2022; plausible by architecture (same `StartMenuExperienceHost.exe` shell since 1809) but not confirmed present or absent** | Confirmed present, fixed via `ServicesPipeTimeout=120000` in `make-bootable.sh` | Not evaluated (no roles/services layer applies to Windows 11; Phase 3A's driver work never reported this symptom there) |
| Media availability | Confirmed live, 180-day eval, Standard+Datacenter, ISO/VHD | Confirmed live and cached | Confirmed live and cached, though the fwlink has already drifted to a newer 25H2 build than what's cached (per `ISO_CACHE_INVENTORY.md`'s own caution) |
| Unattend.xml specialize pass | No regression found; expected to work identically | Confirmed working (Finding 41/42) | Confirmed working (own Setup.exe-driven answer file) |

---

## Technical recommendations (if this project proceeds)

Ordered as a dependency chain, mirroring how Server 2022 was actually brought up (Phase 2 Sessions
12-13):

1. **Cache the ISO.** Download Server 2019 Evaluation (Standard + Datacenter, ISO) from the
   Evaluation Center link confirmed live above, verify the resolved fwlink and checksum, add a
   `.meta`/`.sha256` sidecar pair, and add a row to `ISO_CACHE_INVENTORY.md` — matching the existing
   convention exactly (nothing new to design here).
2. **Verify the WIM edition index directly**, per this project's own non-negotiable standard: `7z x`
   the ISO, `strings -el ... | grep EDITIONID` against `install.wim`, confirm which index is
   `ServerStandardEval` (Desktop Experience) before writing anything into
   `image-apply/lib/common.sh`'s `os_wim_index()`. Do not carry forward the "probably index 2"
   inference above into code without this check — it is pattern-matching, not a citation.
3. **Confirm the `2k19` driver subfolder is present and complete in the already-cached
   `virtio-win-0.1.285.iso`** (`7z l virtio-win-0.1.285.iso | grep -i 2k19`), including that
   `viostor.inf`/`vioscsi.inf`/`netkvm.inf` all reference the same PCI hardware IDs this project's
   existing `tools/gen-viostor-ddb-reg.py` presets already use — if so, adding a `server2019` case to
   that script's existing per-OS preset table should be a small, low-risk change (same shape as the
   2022→2025 generalization that required "zero tooling changes" in Session 12).
4. **Add `server2019` to `image-apply/lib/common.sh`'s per-OS tables** (`os_win_iso`,
   `os_wim_index`, driver subfolder, disk size, default computer name), following the exact pattern
   already used for the other three OSes — no new mechanism needed.
5. **Decide on `ServicesPipeTimeout` proactively vs. reactively.** Given Finding 6's ambiguity, the
   lower-risk choice is almost certainly to **apply the same `ServicesPipeTimeout=120000` offline
   registry merge to Server 2019 preemptively** (identical mechanism already in `make-bootable.sh`
   for 2022/2025, OS-unconditional there already) rather than wait to see if the symptom reproduces —
   the fix is cheap, has already been proven safe on two other Server SKUs, and this project's own
   build pattern (multiple automated boot/shutdown cycles before the first *interactive* boot) is
   the actual trigger condition per Finding 3A-5, independent of which Server SKU is involved. This
   is a recommendation, not a decision — flagged explicitly in Open Questions below since it
   preemptively changes a registry value based on inference rather than confirmed 2019-specific
   evidence.
6. **Run the existing production pipeline unmodified** (`build.sh server2019`, once wired) and apply
   this project's own 2-3-independent-successes evidentiary bar before calling it production-ready,
   exactly as done for Server 2022/2025/Windows 11.
7. **Decide the `services.yaml`/`run-services.ps1` profile question**: AD DS/IIS/SQL Server are
   already proven on Server 2022/2025 — Server 2019 supports all three roles natively (this is not
   in question; it's the same Windows Server role infrastructure), so no new scripting work is
   expected there, only confirming the two-profile guard (`ad-ds` alone vs. `iis`/`sql-server`
   together) doesn't need an OS-specific carve-out for 2019.

## Feasibility assessment

**Verdict: low-to-moderate risk, most likely a "should just work, same as Server 2022" addition —
but not a zero-question one, and it should not be assumed clean without at least resolving Finding
6 (the DCOM boot-storm applicability) and Recommendation #2 (direct WIM index verification) first.**

Every layer this project has already identified as "least brittle" (`wimlib` WIM apply, `bcdboot`,
offline `hivex` driver registration, the unattend/specialize pass) is confirmed by public
documentation and community precedent to behave identically on Server 2019 as on Server 2022/2025 —
no source found suggests any of these steps is harder, different, or riskier on 2019. Server 2019
predates Server 2022, not follows it, so in one sense this project would be moving *backward* in
Windows Server generations rather than forward into new territory — the offline-apply mechanism
this project built was proven first on 2025 (the newest, least-tested target at the time) and
generalized to 2022 with zero tooling changes; 2019 is architecturally closer to 2022 than 2025 is
to 2022, if anything a slightly easier target, not harder.

The two real open items — WIM index (Recommendation #2) and the DCOM boot-storm race's actual
applicability (Finding 6) — are both cheap to resolve empirically (a few hours of hands-on
verification once media is cached, not a research problem) rather than architecturally uncertain.
Compare to Server 2022's own actual bring-up (Session 12): described in `PHASE3_ENGINEERING_LOG.md`
as requiring **zero changes to any of the reusable tooling**, only OS-specific input values. Server
2019's bring-up, if the two open items above resolve the way this research infers they will, should
land in the same category — a low-effort configuration addition, not new engineering. **Rough effort
estimate: comparable to or slightly less than Server 2022's own Session 12 bring-up** (that session
covered ISO download/verification, WIM index confirmation, and a full end-to-end build/WinRM
confirmation cycle in a single session) — realistically one focused session for the offline-apply
track, plus a second short session to confirm the three provisioning roles if not already exercised
against 2019 specifically.

---

## Open questions / assumptions / risks

**Open questions (need a decision or an empirical test, not answerable by more research):**

1. Does the DCOM/RPC "boot storm" race (Finding 6) actually reproduce on Server 2019 under this
   project's own multi-boot-cycle build pattern? No primary source confirms or excludes it. Options:
   (a) apply `ServicesPipeTimeout=120000` preemptively regardless (Recommendation #5, lower risk,
   unconfirmed necessity), or (b) build first without the fix and only add it if the symptom
   actually appears (matches how it was originally *discovered* on 2022 — reactively, not
   preemptively — but re-exposes this project to a repeat of the same debugging session already
   spent once on 2022).
2. Is the "probably index 2" WIM index inference (Finding 3) actually correct for Server 2019
   Standard (Desktop Experience)? Unverified — must be checked directly per Recommendation #2 before
   any code is written, not assumed from the partial community listing found.
3. Is `2k19` actually present, complete, and hardware-ID-consistent with this project's existing
   `gen-viostor-ddb-reg.py` presets inside the *specific* already-cached `virtio-win-0.1.285.iso`
   (not just "the virtio-win project generally ships a 2k19 folder")? Unverified due to the
   Access-Denied result on the direct fetch attempt — a five-minute local `7z l` check, not a
   research gap.

**Assumptions carried into the Feasibility verdict above, stated explicitly per `CLAUDE.md`'s own
"identify assumptions" instruction:**

- That this project's host QEMU version and virtio-win driver version remain unchanged between now
  and a Server 2019 bring-up attempt (if either changes, Finding 5's inference about PCI hardware ID
  stability would need re-checking, per CLAUDE.md's own "Version-sensitivity" standard).
- That Server 2019's AD DS/IIS/SQL Server role provisioning via the existing `scripts/*.ps1` needs
  no OS-specific changes — reasonable (these are long-stable Windows Server role features, not new
  in 2022), but not independently exercised as part of this research pass, which focused on the
  offline-apply mechanism rather than re-verifying the already-proven-elsewhere provisioning layer.

**Risks:**

- The single largest risk is a **silent WIM index mismatch** (Recommendation #2 skipped or
  mis-verified) — `wimapply` would apply the wrong edition with no error at apply time, per
  `CLAUDE.md`'s own "Version-sensitivity and brittleness" standard. This is a process risk (someone
  skips the verification step under time pressure), not a technical unknown — the verification
  recipe itself is already proven and cheap.
- A secondary risk is treating Finding 6 as resolved in either direction without an actual empirical
  boot test — the honest state of the evidence is "plausible either way," and this document should
  not be read as recommending Server 2019 is DCOM-race-free just because the one primary source
  found didn't mention it.
