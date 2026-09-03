# Phase 4 Tools Installer — Research and Design Plan

Status: **Phases A–E all complete as of 2026-09-03.** `tools.yaml`, `scripts/install-tools.ps1`,
and `image-apply/install-tools.sh` are real, committed, and confirmed end-to-end against a real
Server 2022 build — see "Phase D: Implementation" and "Phase E: Testing" at the bottom of this
document for the full trail (two real bugs found and fixed, full CRUD + idempotency confirmed for
all six tools including the Datadog Agent's version-convergence path). This document still carries
its original Phase A/B research and design content unchanged above — read it first for the *why*
behind the design before jumping to the bottom sections for the *what happened when it was built and
tested*.

---

## Phase A: Research

### A.1 — Package-manager mechanism: what to build the installer on top of

Three real candidates were researched beyond the Chocolatey mention already in `../CLAUDE.md`'s
original Phase 4 sketch: **winget**, **Chocolatey** (re-examined, not just carried over), and
**PSAppDeployToolkit (PSADT)**. None of the three is adopted wholesale; the reasoning for each:

| Option | Finding | Verdict |
|---|---|---|
| **winget** | Built into Windows Server 2025 (delivered via Windows Update as part of App Installer) but **not reliably present on Server 2019 or Server 2022** without a manual sideload workaround — confirmed via multiple independent sources, not just one blog. This project's four target OSes need one mechanism that behaves identically everywhere (`tools.yaml` "has no OS-exclusivity concept" per `../CLAUDE.md`); winget would need a bootstrapping workaround on 3 of 4 OSes just to be present, which defeats using it as *the* mechanism. Its offline/pinning story is also weaker than Chocolatey's — full offline mirroring needs third-party tooling, not a first-class winget feature. | **Rejected** — inconsistent OS coverage across this project's own target matrix, the same category of problem `../CLAUDE.md` already flags for `services.yaml`'s OS-exclusivity gap. |
| **Chocolatey** | Re-confirmed, not just re-asserted: Chocolatey's own ecosystem guidance still states the public community repository's reliability "cannot be guaranteed" for production/organizational use and recommends an internalized or private/proxy repo for repeatable builds — i.e., Chocolatey's own maintainers recommend the same pinned-local-cache pattern this project's `ISO_CACHE_DIR` convention already implements by hand. Adopting Chocolatey as-is would add a new bootstrap dependency (Chocolatey itself needs installing on the guest, needing live internet access from inside the guest at exactly the right unattended moment) — a "hidden dependency" this project's own standards already warn against. | **Rejected**, same conclusion as the original `../CLAUDE.md` sketch, now with the public-repo caveat independently re-confirmed rather than just carried forward. |
| **PSAppDeployToolkit (PSADT)** | A real, actively-maintained, widely-used enterprise deployment framework — not a guess, not abandoned (v4.1.0 is current, code-signed PowerShell module, importable standalone with no SCCM/Intune dependency). Its idempotent-detection pattern is genuinely worth adopting: PSADT's own community guidance is explicit that **`Win32_Product` WMI queries must not be used for detection** — querying it silently triggers a Windows Installer *reconfigure* of every MSI-installed application on the machine, a real, documented side effect, not a style preference. PSADT's `Get-InstalledApplication`/`Test-RegistryValue` instead scan the registry Uninstall keys directly. However, PSADT's actual bulk (banner UI, user-deferral prompts, "close running applications" interaction, restart-handling UX, `Deploy-Application.ps1`-per-app template scaffolding) is built for **interactive enterprise desktop deployment via SCCM/Intune** — none of that applies to this project's headless, fully unattended, single-VM lab builds. | **Not adopted wholesale** (would violate this project's own "avoid overly complex frameworks" standard for a 6-tool unattended pipeline) — **but its registry-based idempotent-detection pattern is adopted directly** as the detection mechanism below, and its "never use `Win32_Product`" finding is treated as a hard constraint on this design. |

**Net decision**: no third-party package manager. Extend this project's own already-proven
delivery-ISO pattern (already used for `spice-guest-tools-latest.exe` and `virtio-win-*.iso` in
`image-apply/inject-virtio-spice.sh`) to the six Phase 4 tools, and run each vendor's own documented
silent-install flags directly — this is the "thin adapter, not a new mechanism" tier of
`../CLAUDE.md`'s own decision tree under "Deciding what to build vs. what to adopt," and it's the same
tier this project has already used successfully for every binary dependency so far.

**Revised 2026-09-03, mid-Phase-D, at the user's explicit direction: these six tools are NOT
pinned/checksummed into `../iso_cache/` the way the OS ISOs and `virtio-win`/`spice-guest-tools`
are.** The user's own observation is correct and overrides A.6/B.6 below as originally written:
general-purpose desktop tools churn far faster than Windows Server evaluation media, and
`../CLAUDE.md`'s "Version-sensitivity and brittleness" standard already treats a stale pinned binary as
a real, previously-observed risk (the Windows 11 fwlink drift documented in `../ISO_CACHE_INVENTORY.md`)
— applying that same pin-and-hope-it-stays-current model to six fast-moving tools would just
relocate the drift problem, not solve it. The one exception is the Datadog Agent, whose version can
plausibly affect monitoring-integration test comparability build-to-build — for that one tool only,
version selection is a deliberate, explicit knob in `tools.yaml` (`datadog.agent_version`), not a
cached/checksummed file.

**What did NOT change**: downloading happens on the **Linux host**, not from inside the guest.
Guest-side download was considered and explicitly rejected — it reintroduces the identical
"hidden dependency" (live internet access from inside the guest at exactly the right unattended
moment) that got Chocolatey rejected in A.1 above. The six installers are still fetched host-side
and delivered via the same mounted-ISO mechanism as everything else in this pipeline (A.2); only the
*pinning* was dropped, not the *no-guest-network* principle. See the revised A.3/B.2/B.4/B.6 below.

### A.2 — Delivery mechanism: verified against the actual codebase, not assumed

`../CLAUDE.md`'s own original Phase 4 sketch described delivery as "a mounted ISO or WinRM copy" —
ambiguous. Checked directly against `image-apply/inject-virtio-spice.sh` (lines 110–118): the
**established, working pattern is a small delivery ISO built with `mkisofs`, attached to the QEMU
VM as an extra CD-ROM `-drive ...,media=cdrom`**, explicitly **not** WinRM file transfer. The
script's own comment: *"Small delivery ISO for spice-guest-tools, matching this project's existing
pattern of delivering files to a guest via a mounted ISO rather than WinRM file transfer."*

This matters for the installer design in two concrete ways:

1. The tools' installer binaries (and `tools.yaml`, and `install-tools.ps1` itself) get staged onto
   one delivery ISO, mounted as a CD-ROM, not copied over WinRM.
2. WinRM is still used, but only to **invoke** `powershell -File <mounted-drive>:\install-tools.ps1
   ...` — a short command line, not an inlined script. This sidesteps
   `inject-virtio-spice.sh`'s own hard-won `assert_winrm_ps_budget` constraint (WinRS's ~7800-char
   safe ceiling on an inlined `-encodedcommand` payload) entirely, since the actual script body
   never crosses the wire as a command-line argument — it's read from the mounted ISO by the guest
   itself.

### A.3 — Per-tool fetch mechanism and silent-install/uninstall flags

**Revised 2026-09-03**: every URL below was checked with a real HTTP request during this research
pass (`curl`, not a search-result summary) — five of six resolve to a "current version" dynamically
at fetch time (no version number hardcoded anywhere in this project's own files); the sixth
(Datadog Agent) resolves a version read from `tools.yaml` at fetch time. `install-tools.sh` re-runs
this resolution **fresh on every invocation** — there is no cached "last known version" anywhere.

| Tool | How the current installer is found (host-side, verified live) | Installer type | Silent install | Silent uninstall | Detection |
|---|---|---|---|---|---|
| 7-Zip | Resolve SourceForge's `.../projects/sevenzip/files/latest/download` redirect, parse the version token from the resolved filename (e.g. `7z2601`), fetch `https://www.7-zip.org/a/7z<ver>-x64.msi` | MSI | `msiexec /i 7zip.msi /qn /norestart` | `msiexec /x {ProductCode} /qn /norestart` | `DisplayName` matches `7-Zip*` |
| PuTTY | Fetch `https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html`, extract the `w64/putty-64bit-*-installer.msi` href (resolves to the `the.earth.li` mirror) | MSI | `msiexec /i putty.msi /quiet /norestart` | `msiexec /x {ProductCode} /qn /norestart` | `DisplayName` matches `PuTTY*` |
| WinSCP | Resolve SourceForge's `.../projects/winscp/files/latest/download` redirect directly (no parsing needed — it's already the final signed download URL) | **Inno Setup** (no official MSI) | `winscp.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS` | registry `UninstallString` (`unins000.exe`) + `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` | `DisplayName` matches `WinSCP*` |
| Notepad++ | GitHub API `repos/notepad-plus-plus/notepad-plus-plus/releases/latest`, find the asset named `npp.*.Installer.x64.msi` (not `.sig`), use its `browser_download_url` — **MSI confirmed to exist as of 8.9.8** (Notepad++ only started shipping an official MSI at 8.8.8; the original plan's NSIS-only assumption is now out of date) | MSI | `msiexec /i notepadplusplus.msi /qn /norestart` | `msiexec /x {ProductCode} /qn /norestart` | `DisplayName` matches `Notepad++*` |
| Google Chrome | Fixed, permanent Google-hosted URL: `https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi` — confirmed live, always serves current stable (Chrome Enterprise, deliberately not the consumer updater-based installer) | MSI | `msiexec /i chrome.msi /qn /norestart NOGOOGLEUPDATEPING=1` | `msiexec /x {ProductCode} /qn /norestart` | `DisplayName` = `Google Chrome` |
| Datadog Agent | `https://windows-agent.datadoghq.com/ddagent-cli-<agent_version>.msi`, where `<agent_version>` comes from `tools.yaml`'s `datadog.agent_version` — URL pattern confirmed against Datadog's own official Chef cookbook source (`chef-datadog`'s `recipes/_install-windows.rb`/`attributes/default.rb`, not a guess), then live-verified against two real published versions (7.83.0, 7.82.0) | MSI | `msiexec /i datadog-agent.msi /qn /norestart APIKEY=<key> SITE=<site> TAGS="<csv>" REBOOT=ReallySuppress` — property names confirmed against `docs.datadoghq.com/agent/supported_platforms/windows/` | `msiexec /x {ProductCode} /qn /norestart REBOOT=ReallySuppress` | `DisplayName` = `Datadog Agent` |

Only WinSCP is non-MSI now (Notepad++'s MSI availability, confirmed live, removes what was
originally going to be a second NSIS branch) — `Install-Tool`/`Uninstall-Tool` need 2 code paths
(msi, inno), not 3.

**MSI upgrade-in-place**: for the five MSI-based tools, re-running `msiexec /i <newer>.msi /qn`
against an already-installed product with the same `UpgradeCode` triggers the MSI engine's own
major/minor-upgrade sequencing automatically — no separate "update" verb is needed. WinSCP's Inno
Setup installer is also self-replacing when re-run against an existing install (standard Inno Setup
behavior, not vendor-confirmed line-by-line — flagged as an assumption below).

### A.4 — Idempotent-detection pattern (adopted from PSADT, reimplemented locally)

Scan `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` and
`HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*` for a `DisplayName` match
(all six tools install system-wide/all-users, so `HKCU` paths aren't needed). Read `DisplayVersion`
and `UninstallString` from the matching key. **Never use `Win32_Product`** — confirmed real side
effect (silent MSI reconfigure of every installed product on query), not a style preference.

---

## Phase B: Design

### B.1 — `tools.yaml`

Mirrors `services.yaml`'s own established shape exactly (flat list under one key, plain-regex
parseable, no YAML module dependency — `run-services.ps1`'s own header comment explains why: *"a
plain regex parser"* is enough and avoids a `powershell-yaml`-module dependency that would need
internet access on the guest to install). A tool listed under `tools:` gets installed; nothing is
implicitly uninstalled by omission (same semantics as `services.yaml`'s roles — declarative-install,
not declarative-diff). Explicit removal is a separate, deliberate action (`-Mode Uninstall`, see
B.3), not driven by editing this file, to avoid a config edit accidentally uninstalling something on
a rebuild.

```yaml
tools:
  - 7zip
  - putty
  - winscp
  - chrome
  - notepadplusplus
  - datadog-agent      # requires DD_API_KEY env var at build time - see "Secret handling" (B.5).
                        # Comment this line out (like services.yaml's own commented-out roles) to
                        # build without it, no other change needed.

# Consulted only if datadog-agent is listed above. Real config (not secret) - safe to commit.
# agent_version is the ONE deliberate version pin in this whole file - see the A.1 revision note
# above for why the Agent is treated differently from the other five (floating-latest) tools.
datadog:
  agent_version: "7.83.0"
  site: datadoghq.com
  tags:
    - "env:lab"
    - "project:windows-auto-build-pipeline"
```

Applies uniformly to all four target OSes — no per-OS exclusion list, matching `../CLAUDE.md`'s own
Phase 4 assumption #2.

### B.2 — Per-tool installer spec table (mechanics, not user config — lives in code, not `tools.yaml`)

Split across the two sides of the delivery boundary, each with its own small table (same
"config table, no per-OS branching in the scripts" pattern as `image-apply/lib/common.sh`):

- **Host side** (`image-apply/install-tools.sh`): a `resolve_<tool>()` bash function per tool,
  implementing the A.3 fetch mechanism, each setting `$DL_URL` (and `$DL_VERSION` where knowable) —
  fresh HTTP calls every invocation, no cached "last known version." After a successful download,
  each file is copied into the staging directory under a **normalized, fixed filename** (`7zip.msi`,
  `putty.msi`, `winscp.exe`, `notepadplusplus.msi`, `chrome.msi`, `datadog-agent.msi`) — this is what
  actually goes on the delivery ISO, so the PowerShell side never needs to glob-match an
  unpredictable upstream filename (`7z2601-x64.msi` this week, something else next month). The real
  resolved version/URL for each tool is written to a `manifest.txt` on the same ISO purely for
  in-build logging/audit — not git-tracked, not compared against anything.
- **Guest side** (`scripts/install-tools.ps1`): a `$ToolSpecs` hashtable (6 entries, small enough
  that a separate file isn't warranted) keyed by the same normalized filenames — `Type`
  (`msi`|`inno`), `InstallArgs`, `UninstallArgsAppend`, `DetectDisplayNamePattern`. No `PinnedVersion`
  field except for `datadog-agent`, whose expected version comes from `tools.yaml`'s
  `datadog.agent_version` at runtime, not a hardcoded table value — see B.3's idempotency split.

### B.3 — `scripts/install-tools.ps1` (the orchestrator + CRUD engine)

```
param(
    [string]$ToolsYamlPath = "D:\tools.yaml",       # D: = the mounted delivery ISO, matching
    [string]$ToolsDir      = "D:\",                 # inject-virtio-spice.sh's own drive-letter-
    [ValidateSet("Install","Uninstall","Status")]    # discovery pattern (never hardcode a letter -
    [string]$Mode = "Install",                       # see that script's own driveLetter lookup)
    [string]$ApiKey = $env:DD_API_KEY
)
```

Functions (CRUD mapped as: Create/Update → `Install-Tool`, Read → `Get-ToolStatus`, Delete →
`Uninstall-Tool`):

- `Get-ToolStatus($spec)` — the A.4 registry scan; returns `{Present, DisplayVersion,
  UninstallString}` or `$null`.
- `Install-Tool($name, $spec)` — idempotent, but the check differs by tool now that only
  `datadog-agent` carries a pinned version (B.1's revision):
  - **The five floating-latest tools**: skip with a logged reason if `Get-ToolStatus` shows
    **any** version already present — re-running `install-tools.ps1` against an already-tooled VM
    is a no-op for these, it never force-upgrades just because a newer upstream version might exist
    (that would defeat the "run once per real build" model and make re-running the fast-iteration
    harness non-idempotent in a surprising way).
  - **`datadog-agent`**: skip only if `Get-ToolStatus.DisplayVersion` **exactly matches**
    `tools.yaml`'s `datadog.agent_version`; a present-but-different version triggers a real
    reinstall (relying on the A.3 MSI upgrade-in-place behavior) to bring it to the pinned version —
    this is the one tool where "idempotent" means "converge to the declared version," not just
    "installed at all."
  
  Either way: runs the installer per its `Type` branch (msi/inno) when not skipped, then re-checks
  status and throws if the post-install scan still doesn't find it (fail loud, matching
  `run-services.ps1`'s own `throw`-on-failure convention). `datadog-agent` is the one tool needing
  extra args (`-ApiKey`, plus `$Site`/`$Tags`/`$AgentVersion` parsed from `tools.yaml`'s `datadog:`
  block) — passed as explicit MSI properties appended to `InstallArgs` only for that one entry, not
  a generic mechanism every tool carries.
- `Uninstall-Tool($name, $spec)` — idempotent: calls `Get-ToolStatus` first; **skips with a logged
  reason** if already absent; otherwise runs `$status.UninstallString` + the type-specific silent
  flags from B.2.
- `Get-ToolStatus` alone, run for all six regardless of `tools.yaml` content, is what `-Mode Status`
  reports — useful standalone for `tests/` later (Phase 4's own validation bar) without needing a
  full install run first.

Orchestrator loop: same shape as `run-services.ps1` (parse `tools.yaml`'s flat list with the same
regex approach, loop, `try`/`catch` per tool collecting failures into an array, `throw` once at the
end summarizing any that failed) — not reinvented, copied structurally from the proven role
orchestrator.

**Logging**: `Write-Host` only, captured via the WinRM call's stdout — same as `run-services.ps1`,
no separate transcript file. No new logging mechanism introduced.

### B.4 — `image-apply/install-tools.sh` (new build-pipeline stage)

Structurally mirrors `image-apply/inject-virtio-spice.sh` (same QMP-graceful-shutdown helpers,
same `winrm_ps`/`assert_winrm_ps_budget` helpers, same single-boot-cycle pattern), scoped down to
what this stage actually needs. **Revised 2026-09-03**: unlike `inject-virtio-spice.sh`'s
`spice-tools.iso` (built once and reused across invocations for the same `RUN_ID`, since
`spice-guest-tools-latest.exe` is a static cached file), this stage's delivery ISO is rebuilt fresh
on **every** invocation, because "latest" is only meaningful at the moment of fetch — reusing a
previously-built ISO would silently defeat the entire point of this design change.

1. Fail loud, before starting QEMU, if `tools.yaml` lists `datadog-agent` and `$DD_API_KEY` is
   empty (Phase C decision #3).
2. Resolve and download all six current installers **host-side** (A.3's `resolve_<tool>()`
   functions — real network calls to SourceForge/chiark/GitHub/Google/Datadog from the Linux host,
   never from inside the guest), staging each under its normalized filename (B.2) plus a
   `manifest.txt` recording what was actually fetched this run, under
   `image-apply/output/tools-install-work/<RUN_ID>/staging/`.
3. Build the delivery ISO (`mkisofs`) from that staging directory — installers, `manifest.txt`,
   `tools.yaml` (the path given to `build.sh`, or the repo default), and `scripts/install-tools.ps1`
   itself.
4. Boot `$TARGET_QCOW2` once (OVMF/UEFI, virtio-scsi/virtio-net matching the disk's already-injected
   drivers from Phase 3A — this stage runs **after** `inject-virtio-spice.sh` in the pipeline, so
   the disk already boots on virtio-scsi/QXL by this point) with the delivery ISO attached as an
   extra CD-ROM `-drive`.
5. `wait_for_winrm`, then discover the delivery ISO's drive letter the same way
   `inject-virtio-spice.sh` discovers `virtiocd`'s letter (`Get-Volume`/`Get-Volume -FileSystemLabel`
   matching a known volume label, e.g. `TOOLSCD` — never hardcode `D:`).
6. `winrm_ps "powershell -File <letter>:\install-tools.ps1 -ApiKey '$DD_API_KEY' ..."` — short
   command line, well under the WinRS budget (see A.2).
7. `qmp_graceful_shutdown`, matching this project's own standing convention
   ([[feedback_graceful_qmp_shutdown_not_quit]] — never a hard QMP `quit` on a disk meant to be
   reused).

**Secret handling**: `$DD_API_KEY` is read from the host environment (matching the existing
`ADMIN_PASSWORD`-with-default convention used throughout `image-apply/*.sh`), threaded only into
the WinRM invocation's command-line argument at the moment `install-tools.ps1` actually runs — never
written into `tools.yaml`, never baked into the delivery ISO. This matches `../CLAUDE.md`'s original
Phase 4 secret-handling note, now grounded in confirmed real MSI property names (`APIKEY`, `SITE`,
`TAGS`) rather than assumed ones. The known, honestly-stated limitation from that note stands
unchanged: the key is transiently visible in the guest's process list while `msiexec` runs — a real,
narrow exposure window inherent to MSI silent installs generally, not something this design can
fully eliminate.

### B.5 — `build.sh` wiring

Runs **after** `inject-virtio-spice.sh` in every branch (Server 2019/2022/2025 *and* Windows 11 —
Phase 4 has no OS exclusivity, unlike Phase 3's roles), against the same already-provisioned,
already-SPICE-injected artifact:

```
log "[Phase 4] install-tools.sh (see PHASE4_TOOLS_INSTALLER_PLAN.md)"
"${REPO_ROOT}/image-apply/install-tools.sh" "$OS" "$PROVISIONED_QCOW2" "${TOOLS_YAML_PATH:-tools.yaml}"
```

Rationale for running last: Phase 3A's own desktop (SPICE/QXL) is what makes these six tools useful
in the first place (`../CLAUDE.md`: *"A desktop a human might actually sit at benefits from having
7-Zip/Chrome/Notepad++/PuTTY/WinSCP on it"*) — installing them before the display stack exists would
work but has no ordering benefit, while installing after guarantees the tools land on the final,
fully-configured artifact `register-vm.sh` will actually define a domain from.

### B.6 — `../ISO_CACHE_INVENTORY.md`: deliberately NOT touched

**Revised 2026-09-03, superseding the original plan.** None of the six tools are added to
`../iso_cache/` or `../ISO_CACHE_INVENTORY.md` — that file's whole purpose is a durable record of
*pinned* binaries (its own header: *"what was cached, when, and from where"*), and these six are now
explicitly not pinned. Caching them there would misrepresent them as version-stable the way the OS
ISOs/`virtio-win`/`spice-guest-tools` genuinely are. The per-build `manifest.txt` (B.4) is this
design's equivalent record — scoped to one build's own output directory, not git-tracked, which is
the correct scope for a value that's expected to differ build-to-build.

---

## Assumptions

1. All six installers' documented silent flags behave as described above — verified against
   multiple independent sources per tool, and (as of the 2026-09-03 revision) the fetch mechanism
   for all six was additionally confirmed with real, live HTTP requests during this research pass,
   not just search-result summaries. Still **not independently re-verified against a real install
   run** the way `../CLAUDE.md`'s "verify before trusting" standard ultimately wants — that's Phase E.
2. WinSCP's Inno Setup installer is self-upgrading when re-run against an existing install of an
   older version — standard Inno Setup behavior, not vendor-confirmed line-by-line. If false, the
   fallback is trivial (uninstall-then-install) but changes `Install-Tool`'s WinSCP branch slightly.
3. `tools.yaml` applies uniformly to all four OSes with no per-OS exclusions — carried over from
   `../CLAUDE.md`'s own Phase 4 assumption #2, unchanged by this research pass.
4. The delivery-ISO drive-letter discovery pattern (`Get-Volume` by label) that
   `inject-virtio-spice.sh` already uses for `virtiocd`/`spicecd` generalizes cleanly to a third ISO
   label (`TOOLSCD`) attached in the same boot session — no reason to expect otherwise, but unverified
   until Phase D.
5. **New (2026-09-03)**: the five "resolve current version" mechanisms (a SourceForge redirect for
   two tools, an HTML-scrape for one, a GitHub API call for one, a fixed permanent URL for one) each
   keep behaving the way they were observed to behave during this research pass. This is a
   qualitatively different assumption than version-pinning's own risk (below) — it's not "the
   installer's flags might change," it's "the mechanism used to *find* the installer might change
   shape" (e.g. SourceForge changes its redirect behavior, GitHub's asset-naming convention shifts,
   chiark's `latest.html` markup changes). Host-side `resolve_<tool>()` failures are the visible
   symptom if this happens — see Risk 1.

## Risks

1. **A vendor's "find the current version" mechanism can change shape**, not just the version
   number — new risk introduced by dropping pinning (Assumption 5). Unlike a silent-install-flag
   change (which fails at `msiexec` time, guest-side, mid-boot-cycle), a broken resolver fails
   host-side, before any QEMU boot even starts, which is actually a better failure mode (fast, cheap,
   no wasted boot cycle) — but it does mean this design trades "stale-but-working" (the pinning
   approach's failure mode) for "occasionally broken until someone fixes the resolver" (this design's
   failure mode). Acceptable for six general-purpose desktop tools per the user's own explicit
   direction; would not be an acceptable trade for boot-critical OS media, which is exactly why
   `../CLAUDE.md`'s existing pinned-ISO convention is untouched by this change.
2. **Datadog API key process-list exposure** during the MSI's own execution window — inherent to
   MSI-property-based secret passing, already flagged in `../CLAUDE.md`'s original Phase 4 note,
   unchanged by this design.
3. **A build's exact tool versions are no longer reproducible after the fact** for the five
   floating-latest tools (by design, per the user's direction) — `manifest.txt` (B.4) records what
   was actually fetched for a given build's own debugging, but there's no way to deliberately
   reconstruct "the same build" later the way a pinned OS ISO allows. Accepted tradeoff for
   general-purpose desktop tools; `datadog-agent` is the deliberate exception (B.1).
4. **This is a sixth boot cycle** added to an already-multi-boot-cycle pipeline (Packer's own
   provision+restart, then `inject-virtio-spice.sh`'s two more, now this stage's one more) — Finding
   3A-5 already documents a real Server 2022 RPC/DCOM "boot storm" race triggered by exactly this
   project's own multi-boot-cycle pattern, fixed via `ServicesPipeTimeout`. Worth watching for
   recurrence during Phase E testing, though the existing fix (`make-bootable.sh`'s offline registry
   change, applied before the *first* boot) should already cover it regardless of how many
   additional boot cycles come later.

## Phase C review — decisions (resolved 2026-09-03)

1. **7-Zip installer format: MSI**, as recommended — CRUD uniformity with PuTTY/Chrome/Datadog wins
   over the `.exe`/NSIS alternative. B.2's table stands unchanged.
2. **`install-tools.sh` is its own dedicated stage script**, as recommended — mirrors
   `inject-virtio-spice.sh`'s two-script pattern (B.4 stands unchanged). `../CLAUDE.md`'s original
   Phase 4 open question #1 is resolved in favor of this option.
3. **Missing `$DD_API_KEY` fails loud before boot**, as recommended — `install-tools.sh` checks
   `$DD_API_KEY` is non-empty up front (when `datadog-agent` is listed in `tools.yaml`) and exits
   with an error before ever starting QEMU, matching `partition-disk.sh`'s own prerequisite-check
   convention. To be added explicitly to B.4's step list at implementation time.
4. Six-tool list and `tools.yaml` schema (B.1): no objection raised: treated as confirmed as
   written.

**Phase C is closed. Phase D (implementation) may begin.**

---

## Phase D: Implementation

Real, committed files, transcribed directly from this document's Phase B design rather than
reconstructed from memory — same standard this project's other phases hold themselves to:

- **`tools.yaml`** (repo root) — the six-tool flat list plus the `datadog:` block, exactly as B.1
  specifies.
- **`scripts/install-tools.ps1`** — the guest-side CRUD engine: `Read-ToolsYaml` (plain
  section-tracking parser, no YAML module), `Get-ToolStatus` (registry Uninstall-key scan, never
  `Win32_Product`), `Install-Tool`/`Uninstall-Tool` (idempotent per B.3's two-tier rule), and the
  `run-services.ps1`-shaped orchestrator loop.
- **`image-apply/install-tools.sh`** — the host-side stage: the six `resolve_<tool>()` functions
  (A.3), the fail-loud-before-boot `$DD_API_KEY` check (Phase C decision #3), delivery-ISO staging,
  and the QEMU boot/WinRM/graceful-shutdown sequence.
- **`build.sh`** — wired in after `inject-virtio-spice.sh` in both the Windows 11 branch and the
  Server 2019/2022/2025 branch, per B.5.

**Two real bugs found and fixed during Phase D/E, not hypothetical:**

1. **PCI topology mismatch, `install-tools.sh` only.** The script's first QEMU invocation used
   implicit/default bus placement for the virtio-scsi controller (`-device
   virtio-scsi-pci,id=scsi0`) instead of replicating `inject-virtio-spice.sh` Stage 2's exact
   explicit `pcie-root-port` placement (`addr=0x6,chassis=1,port=1`) — the same disk that had just
   booted cleanly twice under `inject-virtio-spice.sh` failed to boot under this new topology,
   landing on WinRE/Setup's shared "Choose your keyboard layout" screen instead of a real desktop
   (confirmed via a live QMP screendump, `tools/qmp-screenshot.py`-equivalent, taken while the
   stuck qemu process was still up). This is exactly the risk Finding 3A-3
   (`WINDOWS11_VIRTIO_SPICE_DRIVERS_PLAN.md`) already documented — PCI topology, not just drive
   presence, affects which hardware ID a virtio-scsi-pci controller negotiates, and a mismatch
   from what's registered in the guest's `DriverDatabase` breaks the boot. Fixed by matching Stage
   2's topology exactly, not guessing. `inject-virtio-spice.sh` itself needed no change — it
   already had this right.
2. **Exit-code-swallowing in QEMU cleanup traps, three scripts.** `install-tools.sh`'s own
   `cleanup()` trap ended its hard-kill fallback with `kill -9 ... || true` as its last command —
   under bash's EXIT-trap semantics, that made the *trap's* exit status (always 0) become the
   *whole script's* exit status, silently turning the real WinRM-timeout failure above into a
   reported success (`build.sh` exit code 0). Fixed by capturing `$?` at the top of the trap and
   re-asserting it via an explicit `exit "$exit_code"` at the end. The same latent pattern was then
   found and fixed in `inject-virtio-spice.sh`'s `cleanup_stage1`/`cleanup_stage2` and
   `windows11-setup-install.sh`'s `cleanup` — both had carried the identical bug all along, just
   dormant, because every completed real run on record for either script had its graceful shutdown
   succeed before ever reaching the hard-kill fallback line. All three fixes are the same
   capture-then-reassert pattern, applied consistently.

## Phase E: Testing

**Full CRUD + idempotency confirmed end-to-end against a real Server 2022 build, 2026-09-03.**
Evidentiary bar matches this project's other phases: real WinRM-verified guest state, not just "the
script exited 0."

**Setup**: `build.sh server2022` run through the full production pipeline (partition → apply →
bootable → unattend → Packer/IIS role provisioning → `inject-virtio-spice.sh`, both stages clean)
using a scratch test `tools.yaml` (5 tools, `datadog-agent` omitted — no real API key available for
this session) to isolate the new Phase 4 mechanism from the already-proven Phase 3 role layer. Host
fetch resolved real current versions live during the run: 7-Zip 2601, PuTTY 0.85, WinSCP 6.5.6,
Chrome (Google's permanent latest-stable URL), Notepad++ 8.9.8 — all five downloaded and staged
successfully on the first attempt; the boot failure and fix above happened on `install-tools.sh`'s
own first QEMU invocation, not the host-side fetch.

**Five floating-latest tools, full CRUD + idempotency** (against the same disk, sequential runs,
each a fresh boot cycle):

| Operation | Result |
|---|---|
| Create (fresh install) | All 5 fetched, installed, registry-verified: 7-Zip 26.01.00.0, PuTTY 0.85.0.0, WinSCP 6.5.6, Chrome 152.0.7977.76, Notepad++ 8.9.8 |
| Read (`-Mode Status`) | All 5 correctly `PRESENT` with exact versions; `datadog-agent` (not yet installed) correctly `ABSENT` |
| Idempotent re-Create | Re-running Install skipped all 5 as already-present (`already present (version X) - skipping`), no reinstall attempted |
| Delete (`-Mode Uninstall`) | All 5 uninstalled cleanly and registry-verified absent — including WinSCP's Inno Setup branch, proving both installer-type code paths (`msi`/`inno`), not just MSI |
| Idempotent re-Delete | Re-running Uninstall against the now-clean system skipped all 5 as already-absent (`already absent - nothing to do`) |

**Datadog Agent, full CRUD including its unique version-convergence path** (a dummy 32-character
API key, `DD_API_KEY`, used deliberately — this exercises the installer mechanism and the real
`APIKEY`/`SITE`/`TAGS` MSI properties, not a real Datadog account or real telemetry):

| Step | Result |
|---|---|
| Create (`agent_version: "7.82.0"`) | `[datadog-agent] installed: version 7.82.0.0` |
| Read | `[datadog-agent] PRESENT version=7.82.0.0` |
| Update (`tools.yaml` changed to `agent_version: "7.83.0"`, re-run Install) | `[datadog-agent] present at 7.82.0.0, pinned version is 7.83.0 - reinstalling to converge` → `[datadog-agent] installed: version 7.83.0.0` — the one idempotency branch (B.3's "converge to declared version" rule) not exercised by the five floating tools above, now confirmed |
| Delete | `[datadog-agent] uninstalling (was version 7.83.0.0)` → `[datadog-agent] uninstalled` |

Every one of the above runs shut down gracefully and exited with the correct status (confirmed
directly meaningful once the exit-code bug above was fixed — before that fix, a real failure had
already been observed to silently report success). The test disk
(`packer/output/server2022-20260903-101620/`) was left in a clean, all-six-tools-uninstalled state
at the end of testing.

**Not yet exercised**: Server 2019/2025 and Windows 11 (only Server 2022 was tested — the other
three OSes share the identical `install-tools.sh`/`install-tools.ps1` code path with no OS branching
in Phase 4 itself, so this is a lower-risk gap than Phase 2/3's own per-OS verification needed to be,
but it is still an honest gap, not implicitly covered). A real (non-dummy) Datadog API key was also
never used, so actual Agent connectivity/telemetry was never confirmed — only the installer
mechanism itself.
