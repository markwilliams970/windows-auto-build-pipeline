# Phase 5 Engineering Log: Lifecycle Automation - the `windows-pipeline` CLI

Status as of this writing: **Phase 5 is done.** What started as CLAUDE.md's own three-line Phase 5
scope ("build workflow, verification workflow, destroy workflow") became something larger by
explicit user direction partway through: consolidating `build.sh`, `register-vm.sh`, and two
genuinely new workflows (`verify`, `destroy`) into one installable Python CLI, `windows-pipeline`,
with real state tracking and a host/guest identity split that didn't exist before. `build.sh` and
`register-vm.sh` are retired - see this log's own E5 section for why that was safe, and git history
for the scripts themselves. See `../CLAUDE.md`'s own Phase 5 section for the current, rolled-up
status; treat this file as the chronological record behind that summary, matching every other
phase's own log in this project.

This log follows the same convention as `PHASE2_ENGINEERING_LOG.md`/`PHASE3_ENGINEERING_LOG.md`:
symptom, diagnosis, root cause, fix, in the order things actually happened, dead ends included.

---

## Reframing: from "add two scripts" to "one CLI" (design discussion)

The original ask was narrow: add `verify` and `destroy` alongside the existing `build.sh`/
`register-vm.sh`. The user redirected this before any code was written, for a concrete reason: the
NetBIOS computer name baked into each OS (`WIN2022PROD`, fixed per OS in `image-apply/lib/common.sh`)
works fine as a *guest-side* identity, but is a bad *host-side* identity — every rebuild of the same
OS produces the identical name, so `register-vm.sh` could only ever have one `win2022prod` domain
registered at a time, forcing an undefine-and-redefine dance on every re-registration and making
`virsh list --all` useless for telling builds apart. The fix: decouple them. A new, host-side-unique
identifier (`<netbios-lowercase>-<timestamp>-<uuid8>`, e.g. `win2022prod-20260904-1314-a1b2c3d4`) is
generated once at `create` time and reused everywhere on the host side (qcow2 basename, Packer
`build_id`, NVRAM filename, and eventually the libvirt domain name itself) — this is really just
finishing something `build.sh` had already half-built (its own `BUILD_ID`, `<os>-<timestamp>`, existed
purely to stop concurrent builds of the same OS from colliding on a shared path). The guest's own
`ComputerName` is untouched by any of this.

This, in turn, needed somewhere to actually track the mapping between a host ID and everything that
belongs to it (its qcow2 path, its OS, whether it's been registered, etc.) — state that didn't exist
anywhere before. `../windows11-lab` was named explicitly as a reference for the *mechanics* of
building this (argparse subcommands, a pip-installable console script, atomic JSON state writes via
temp-file-then-`os.replace`) — **not** for its own `ImageGraph`/`NodeManifest` data model, which
tracks an immutable qcow2 layer lineage because that project supports cloning from golden images.
This project deliberately never does that (`../CLAUDE.md`'s "Ephemeral Infrastructure, Still"
principle — every build applies the WIM fresh), so the state design here is flat by construction:
one JSON record per host ID, holding only its *current* state, overwritten in place as it moves
through its lifecycle. No history, no graph. Confirmed explicitly with the user mid-design
("Please understand that I was pointing to windows11-lab for the command syntax and structure, not
the graph theory") after a first design pass had already gotten this right.

## Research: prior art for "destroy" and "verify"

Consistent with this project's own research-first standard, both new workflows were researched
before any design was committed to:

- **Libvirt "destroy" conventions**: `vagrant-libvirt`'s actual `destroy_domain.rb` source (read
  directly, not summarized) gave a proven sequence — delete snapshots, remove managed-save state,
  undefine the domain (with an explicit `--nvram`/`--keep-nvram` flag), then delete backing storage.
  `terraform-provider-libvirt`'s own issue tracker confirmed two of these steps aren't optional
  niceties but hard libvirt failure modes: `virsh undefine` on a UEFI/NVRAM domain fails outright
  without an explicit nvram flag, and fails outright if the domain still has snapshots. A third
  finding — libvirt does not release a domain's dynamic DHCP lease on undefine, and current `virsh`
  has no command to force one either (`net-dhcp-leases` is list-only, checked directly against this
  host's own libvirt 10.0.0, not assumed from documentation) — was accepted as a known, deliberate
  gap rather than a reason to request broader sudo access for what's ultimately a cosmetic issue (the
  lease expires on its own).
- **Verification frameworks**: Goss, Testinfra, and Chef InSpec were all evaluated and explicitly
  **not** adopted. All three turned out to be DSL wrappers over the same WinRM+PowerShell/WMI checks
  this project's own scripts already perform by hand — adopting one would add a real runtime
  dependency for no functional gain, exactly the "hidden dependency" trap this project's own
  standards warn against. What was adopted from the research instead was *convention*, not tooling: a
  consistent per-check result shape (name/passed/detail) so results aggregate the way a framework's
  own report would, without needing the framework.
- **Disk/artifact retention conventions**: a genuine negative result — no established "keep N most
  recent" pattern exists for qcow2/libvirt pipelines specifically, and Packer's own artifact handling
  is per-build, not cross-build retention. Left as bespoke, consistent with this project's existing
  manual, confirm-before-delete disk-hygiene discipline (`../CLAUDE.md`'s Engineering Standards).
- **A close full-lifecycle analog**: none found. No GitHub project combining offline WIM application
  with a libvirt destroy/lifecycle workflow turned up — consistent with this project's own established
  pattern of finding strong prior art for individual *primitives* (`bcdboot`, `hivex` driver
  injection, BCD-SYS) but never for the whole pipeline shape at once. Phase 5's actual lifecycle
  commands are original engineering, informed by the primitives above, not adapted from an existing
  tool.

## Design

- **Identity**: `<netbios-lowercase>-<timestamp>-<uuid8>`, generated once by `create`, reused as the
  qcow2 basename, Packer `build_id`, NVRAM filename, and libvirt domain name.
- **State store**: one JSON file per host ID (`HostRecord`/`StateStore`), atomic writes modeled on
  `windows11-lab`'s own `ManifestStore` mechanics, deliberately without any of its graph/layer
  concepts — see the reframing section above.
- **Command surface**: `create`, `list`, `register-vm`, `start`, `stop`, `verify`, `destroy`.
- **Package**: Python + `argparse`, `src/windows_pipeline/`, a `pyproject.toml` console-script entry
  point — structured like `windows11-lab` mechanically, not its graph model (see above). The package's
  own code stays a thin orchestration layer: every actual heavy-lifting operation (partitioning,
  `wimlib` apply, `bcdboot`, Packer, driver injection, tool install) is invoked as a subprocess against
  the existing, already-proven `image-apply/*.sh` scripts, never reimplemented in Python.
- **Locked decisions from discussion, before implementation started**: `destroy` defaults to keeping
  the disk (`--purge-disk` opts in, since a real build can take 15-50+ minutes to reproduce);
  `create` and `register-vm` stay separate commands (building a disk doesn't have to mean
  immediately committing it to a persistent, host-visible domain); `build.sh`/`register-vm.sh` are
  retired outright once the CLI is proven equivalent, not kept around as deprecated wrappers.

---

## E1: `create`, `list`, the state store

Ports `build.sh`'s body unchanged underneath — every actual script invocation
(`partition-disk.sh`/`apply-image.sh`/`make-bootable.sh`/`apply-unattend.sh`/Packer/
`inject-virtio-spice.sh`/`install-tools.sh`/`windows11-setup-install.sh`) is identical to what
`build.sh` already ran. The only new logic is host-ID generation up front and a state record
tracking `creating -> built|failed`.

### Real bug: `pywinrm` silently unresolvable under an activated venv

**Symptom.** Three consecutive `windows-pipeline create server2022` runs (invoked the natural way,
`source .venv/bin/activate && windows-pipeline create server2022`) failed identically at
`inject-virtio-spice.sh`'s Stage 1 WinRM wait — always timing out, first at the script's default
600s, then again at an experimentally-raised 1800s. Manual, direct invocations of the *exact same
script* against the *exact same disk* that had just timed out succeeded within seconds, every time.

**Diagnostic trail, including the wrong turns (kept here honestly, per this project's own "document
dead ends too" convention).** Several real hypotheses were formed, tested with real evidence, and
disproven in turn before the actual cause was found:

- *First-time PnP hardware enumeration is slow.* Disproven directly: a disk whose Stage 1 verify-boot
  hardware topology was genuinely new (never before booted) came up in 30 seconds via the real CLI on
  a later attempt — a true "first encounter" that was fast, not slow.
- *NLA/network-profile classification lag.* A real, plausible-looking lead — `Microsoft-Windows-WinRM`
  Event 10149 ("service is not listening for WS-Management requests") recurred across the whole
  stuck window. Disproven directly by reading the guest's own `NetworkProfile/Operational` event log:
  the network was already classified `Private` within 18 seconds of boot, many minutes before the
  10149 events stopped recurring.
- *Windows Defender's first-run scan.* Disproven directly: `Get-MpComputerStatus` showed
  `QuickScanAge`/`FullScanAge` both at their "never run" sentinel value.

Real evidence was gathered throughout via QMP screenshots (confirming the guest was fully booted to
a live, interactive Server Manager desktop the *entire* stuck window, never hung) and direct guest-side
Event Log/Task Scheduler archaeology over WinRM once a diagnostic boot happened to succeed — a
genuinely useful investigative technique that, this time, was aimed at the wrong layer.

**Actual root cause**, found by comparing the script's own `winrm_ps()` call against an ad hoc
equivalent, live, side by side: `source .venv/bin/activate` prepends `.venv/bin` to `PATH` for the
*entire process tree*, including every subprocess `create.py` spawns via `subprocess.run()`.
`inject-virtio-spice.sh`'s own `winrm_ps()` function calls a bare `python3` for its WinRM-readiness
checks — under the activated `windows-pipeline` venv, that resolved to `.venv/bin/python3`, which had
no `pywinrm` installed (the new package's `pyproject.toml` originally declared zero dependencies, on
the reasoning that it only orchestrates existing scripts and needs nothing itself). Every retry
crashed instantly on `import winrm`, and the wait loop's own `winrm_ps 'hostname' >/dev/null 2>&1`
redirect silently swallowed the traceback — indistinguishable, from the log, from a genuinely slow or
hung WinRM/Windows problem, for the entire investigation above.

**First fix attempt, reverted.** Stripped the active venv's `bin` directory back out of `PATH` before
invoking any subprocess, routing calls to the system `python3` instead. Rejected by the user on sight:
this silently reintroduces exactly the kind of implicit, undeclared dependency this project's own
standards warn against (the venv should be self-contained, not routed around), and a change to how
subprocess environments are constructed isn't a call to make unilaterally.

**Real fix**: declared `pywinrm` as a proper dependency of the `windows-pipeline` package itself
(`pyproject.toml`'s `dependencies`), so an activated venv's own `python3` has it installed directly —
no PATH manipulation, no routing around anything. Verified two ways: `.venv/bin/python3 -c "import
winrm"` succeeds under activation, and the literal code path each script uses (`Session.run_cmd`/
`run_ps`) was exercised under activation and confirmed to reach the real network layer
(`ConnectionError` against an unreachable address) rather than failing on import.

**Full dependency audit**, performed afterward at explicit user request ("I don't want to run into a
6 reboot failure again. Triple check."): every `python3` invocation across every script `create`
shells out to, every `tools/*.py` script, and `windows_pipeline`'s own package code, checked
import-by-import. Confirmed the *only* third-party import anywhere in the whole invoked surface is
`winrm` itself, and confirmed `pywinrm`'s own transitive dependency tree (`requests`,
`requests-ntlm`, `xmltodict`, plus their own further deps) is fully present and resolves correctly.

**Validated** end-to-end with a full, clean `windows-pipeline create server2022` run, venv activated
(matching real-world usage): offline apply → Packer/IIS → `inject-virtio-spice.sh` Stage 1/2 (both
confirmed instantly, matching every previously-proven-good manual run) → `install-tools.sh` (all six
tools installed with real, live-resolved versions, Datadog Agent included via a dummy API key for
testing purposes).

## E2: `register-vm`, `start`, `stop`

Ports `register-vm.sh`'s device model and precondition check unchanged. One real simplification
falls out directly of E1's identity redesign: host ID *is* the libvirt domain name now — no separate
`vm_name` argument, no "guess the most recently modified build" resolution logic, since the state
store already knows exactly which disk belongs to which host ID.

The `inject-virtio-spice.sh` completion-marker check (a real qemu-nbd + ntfs-3g offline read, not a
trust-the-caller's-metadata shortcut) was extracted into its own script,
`image-apply/check-virtio-spice-marker.sh`, so both `register-vm.sh` (while it still existed) and the
new `register_vm.py` could share one implementation rather than re-implementing the
attach/mount/detach dance in Python — this project's "reuse the pattern, don't rewrite bash that
already works" standard, applied to its own prior work this time.

**Validated** end-to-end against a real disk (the E1 build above): `register-vm`'s marker check
passed against a genuine on-disk marker; `start` produced a real boot, confirmed both visually
(`virsh screenshot` — a genuine Windows lock screen) and over real, authenticated WinRM (`hostname` →
`WIN2022PROD`, over the libvirt `default` NAT network's own DHCP-leased IP, not a hostfwd tunnel);
`stop` gracefully shut it down within its timeout. Also confirmed live: the host/guest naming split
works exactly as designed — the libvirt domain name and the DHCP lease's own reported hostname are
visibly different, non-colliding identifiers throughout.

## E3: `destroy`

Sequence adopted directly from `vagrant-libvirt`'s own proven order (see Research above): stop if
running → delete snapshots → remove managed-save → undefine (`--nvram`, confirmed not optional) →
delete disk artifacts only if `--purge-disk` (kept by default).

### Real bug: `--purge-disk` didn't know about most of a build's own footprint

The first live `destroy --purge-disk` run correctly undefined the domain and deleted the one qcow2
path known to the state record — and, at the user's own prompting to verify rather than trust the
reported success, a direct `find` sweep for that host ID across the whole repo turned up real
leftovers: Packer's own scratch pre-build efivars file, Packer's entire per-build output directory
(with its own leftover `efivars.fd` inside), `inject-virtio-spice.sh`'s own per-run work directory,
and `install-tools.sh`'s own per-run work directory. Building this list also surfaced a second,
pre-existing gap: `create`'s own pre-Packer qcow2 copy
(`image-apply/output/builds/<host_id>.qcow2`) is never cleaned up even on a fully successful build —
`build.sh` had the identical gap before it, not something Phase 5 introduced, but genuinely part of a
build's real disk footprint and something a thorough `--purge-disk` should cover regardless of origin.

**Fix**: `destroy` now enumerates every known per-host-ID location across the pipeline's real output
directories up front, lists every one it actually finds before asking for confirmation (matching this
project's own disk-hygiene standard — state what's proposed for deletion, and why, before deleting
it), and removes all of them. Re-validated live: a second `destroy` run against the same
now-partially-cleaned host ID correctly found and removed all five remaining artifacts, confirmed
gone by a repeat `find` sweep.

One design choice made, then reversed, at explicit user request: `destroy` originally left a `state:
destroyed` tombstone record behind so `list` could show recently-destroyed VMs. The user didn't want
this ("I don't need a tombstone reminder") — changed to a full `ctx.store.delete(host_id)`, no history
kept, which is really just the state store's own "one state per VM, not history" principle applied
consistently through to the terminal state too.

DHCP lease cleanup remains the known, deliberate non-goal identified during research — documented
directly in `destroy.py`'s own module docstring rather than silently omitted.

## E4: `verify`

Four check groups, all requested together up front: connectivity/OS-identity baseline, role detection
(AD DS/IIS/SQL Server), VirtIO/SPICE device health, and Tools/Datadog Agent health. Each is a small,
self-contained PowerShell snippet sent over WinRM — the same shape every `image-apply/*.sh` script
already uses, not a framework (see Research above). Role/VirtIO/tool success criteria are copied
directly from this project's own already-proven evidentiary bar, not reinvented: NTDS/DNS/ADWS plus a
real `Get-ADDomain` call for AD DS; `W3SVC` plus a real HTTP 200 for IIS; `MSSQLSERVER` plus a real SA
login and `SELECT 1` for SQL Server (this project's own distinct SA password, never the OS
Administrator password); the identical `Get-Disk`/`Get-NetAdapter`/`Get-PnpDevice`/`vdservice` checks
`inject-virtio-spice.sh`'s own Stage 2 already performs; the identical registry `DetectPattern` regex
scan `install-tools.ps1`'s own `Get-ToolStatus` uses (re-invoking `install-tools.ps1` itself directly
wasn't an option — it's only ever staged onto a transient delivery ISO during
`install-tools.sh`'s own build-time session, never left on the guest afterward).

### Real bugs, found testing against a live VM

**Test methodology.** Rather than spend another full ~15-20 minute build cycle for a fresh test VM,
`verify` was pointed at an already-running VM from the *sibling* project
(`../windows-server-vm-automation`'s `win2022-dc`) via a manually-constructed, temporary state
record — a deliberate control expected to legitimately fail some checks, since that VM never went
through this project's own `inject-virtio-spice.sh`/`install-tools.sh`.

- **Bug 1**: an uncaught `InvalidCredentialsError` (the sibling project uses a different admin
  password, `ChangeMe-Lab123!`, than this project's own `TestP@ssw0rd123`) crashed with a raw Python
  traceback instead of reporting a clean check failure. Fixed in `winrm_util.py`'s `run_ps()`: it
  never raises now — any transport/auth/timeout exception is reported the same way a non-zero
  PowerShell exit would be, so every check function's existing `returncode != 0` handling covers it
  without each of the four needing its own `try`/`except`.
- **Bug 2** (found once `roles` could actually run, with the right password): the check reported a
  hard failure whose only visible "error" was harmless CLIXML progress-stream noise, discarding real,
  valid data. Direct re-testing of the identical command showed `pywinrm`'s `status_code` coming back
  non-zero even though `stdout` held fully valid JSON — `-ErrorAction SilentlyContinue` on service
  names that don't exist (`Get-Service NTDS,DNS,ADWS,W3SVC,MSSQLSERVER`) appears to still influence
  `pywinrm`'s own exit-code determination, with no real error present anywhere in the output. Fixed
  by trusting successfully-parsed JSON `stdout` regardless of `returncode`, falling back to
  `returncode`/`stderr` only when `stdout` is genuinely empty. The identical fix was applied
  proactively to the `virtio` check's own `Get-Service vdservice -ErrorAction SilentlyContinue` call,
  which has the exact same shape and would have hit the same bug the first time that service was ever
  actually absent from a guest.
- **Bug 3**, found in the same direct-debug pass: `ConvertTo-Json` serializes a
  `ServiceControllerStatus` enum as its underlying integer (`4`, not `"Running"`) under Windows
  PowerShell 5.1 — there's no `-EnumsAsStrings` switch before PowerShell 7, and every Server SKU here
  runs Windows PowerShell 5.1 by default. String-comparing the result to `"Running"` would have always
  silently evaluated `False`. Fixed by explicitly stringifying `Status` in the PowerShell script
  itself (`@{N='Status';E={$_.Status.ToString()}}`) before it ever reaches `ConvertTo-Json`, not
  after.

**Re-validated**, per explicit direction, against a genuine build from this project (`win2025app`, a
real Server 2025 IIS/SQL-Server build from 2026-08-26) rather than the sibling project's VM: all four
groups produced correct, differentiated results. `iis`/`sql-server` both passed with real functional
verification (an actual HTTP 200, an actual `SELECT 1` returning `1`); all four `virtio` checks
passed, including `vdservice: Running` this time (this VM did go through this project's own SPICE
injection, unlike the sibling project's); `datadog-agent: not installed` was correctly reported as a
genuine, expected absence — this VM predates Phase 4's tools installer entirely (built 2026-08-26,
shipped 2026-09-03), not a bug in the check.

## E5: packaging, shell completion, retiring `build.sh`/`register-vm.sh`

Shell completion via `argcomplete`, wired as a true optional extra
(`pip install "windows-pipeline[completion]"`) — `cli/main.py` only imports it defensively
(`try`/`except ImportError`), so the CLI behaves identically whether or not it's installed. A
dedicated `_complete_host_id()` completer reads the live state store directly, so tab-completing any
`host_id` argument (`register-vm`/`start`/`stop`/`destroy`/`verify`) offers actually-tracked VM IDs,
not just flag names — verified with a real completion request (`COMP_LINE`/`_ARGCOMPLETE`
simulation against a real state-store entry), not just import-success.

Considered and explicitly rejected: mirroring `../windows11-lab`'s own `install.sh`, which installs
into an isolated `~/.local/share/` location so the original repo clone becomes disposable afterward.
That model doesn't transfer here — `windows-pipeline` is an orchestration layer over
`image-apply/*.sh` and `packer/*.hcl`, which have to live in a specific repo checkout and can't be
relocated the way that tool's own image store can. A plain `pip install -e .` from within the
checkout is the honest install story, documented in `README.md` rather than automated by a script
that would be misleading about what it actually does.

**Retirement.** A full repo-wide reference search (`build.sh`/`register-vm.sh` as literal strings,
every tracked file, `.git` excluded) confirmed zero functional/executable dependents anywhere —
every hit outside the two scripts themselves was a comment, a historical engineering-log entry, or
`README.md`'s own user-facing usage instructions. `build.sh` and `register-vm.sh` were removed
(`git rm`); `README.md`'s usage sections were rewritten for `windows-pipeline` rather than left
pointing at deleted files (see `README.md`'s own "Using windows-pipeline" section). `CLAUDE.md` and
every file under `project_documentation/` were deliberately left with their historical references to
the old scripts unedited — they're a chronological record of what actually happened at the time, not
living documentation, and this project has never rewritten its own history after the fact (see any
prior phase's own log for the same convention).

---

## Status: Phase 5 is done

All seven commands (`create`, `list`, `register-vm`, `start`, `stop`, `destroy`, `verify`) are
implemented and validated against real builds, real libvirt domains, and real WinRM connections — not
dry runs. Three real, non-obvious bugs were found and fixed along the way (the `pywinrm`/venv
resolution failure in E1, `destroy`'s incomplete artifact enumeration in E3, and the two `verify`
bugs — non-zero-exit-despite-valid-output and enum-serialized-as-int — in E4), each root-caused with
direct evidence rather than patched around, consistent with this project's own standing engineering
discipline. `build.sh` and `register-vm.sh` are retired with a confirmed-empty dependent surface.
`windows-pipeline` is now the project's single entry point for its full lifecycle: apply an image,
boot it, register it, start/stop it, verify it's healthy, and tear it down completely.
