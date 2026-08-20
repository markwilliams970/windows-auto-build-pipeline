# Phase 3 Engineering Log: Role Provisioning Confirmed for Server 2022 and Server 2025

Status as of this writing: **Phase 3 is done.** All four OS × profile combinations (Windows Server
2022/2025 × domain-controller/app-server) were confirmed live against this project's own
offline-applied, Phase-2-proven reference disks. The reused role-provisioning scripts needed zero
changes beyond a new, project-specific mutual-exclusion guard. One real, non-obvious defect was
found and fixed in the new test harness itself (Finding 1 below) — not in the reused scripts, and
not in Phase 2's mechanism. See `CLAUDE.md`'s Phase 3 section for the current status summary and
`PHASE2_ENGINEERING_LOG.md` for the offline-apply mechanism this phase builds on.

This log follows the sibling project's and `PHASE2_ENGINEERING_LOG.md`'s own convention: symptom,
diagnosis, root cause, fix, in the order they were actually hit, including the dead ends.

---

## Setup summary (context for the finding below)

- Reused `scripts/run-services.ps1`, `install-ad.ps1`, `install-iis.ps1`, `install-sql-server.ps1`,
  `verify-post-reboot.ps1` from `../windows-server-vm-automation/scripts/` byte-for-byte, per
  `CLAUDE.md`'s explicit reuse instruction — no changes needed to any of the four role scripts.
- **New requirement not present in the sibling project:** two mutually-exclusive profiles —
  `ad-ds` alone vs. `iis`/`sql-server` together — enforced twice: a fast host-side pre-check in the
  new `dev/run-phase3-test.sh` wrapper (fails in well under a second, before any VM boots) and a
  defense-in-depth guard added directly to `scripts/run-services.ps1` (throws if both role groups
  are present, in case `services.yaml` is ever hand-edited or the orchestrator is invoked some other
  way). `services.yaml`'s flat-list shape is otherwise unchanged from the sibling project. Two
  ready-made profile files: `dev/services-domain-controller.yaml` (`ad-ds`), `dev/services-app-server.yaml`
  (`iis` + `sql-server`).
- **New test harness**: `dev/role-test.pkr.hcl` + `dev/run-phase3-test.sh`, following
  `CLAUDE.md`'s "reuse the pattern, not necessarily the exact files" note about the sibling
  project's own `dev/` fast-iteration harness. Boots a disposable copy-on-write overlay
  (`use_backing_file = true`) on top of Phase 2's own confirmed-good, WinRM-reachable reference
  disks (`image-apply/output/win2022-session12.qcow2` / `win2025-session11.qcow2`, sha256-verified
  before use) rather than a separately-maintained `dev/baseline/` copy — the reference disks already
  live in `image-apply/output/` (already gitignored there) and never need duplicating. Deliberately
  `disk_interface = "virtio"` (→ `virtio-blk-pci`), **not** `"virtio-scsi"` like the sibling
  project's own dev harness uses — `tools/gen-viostor-ddb-reg.py`'s offline driver injection was
  registered against a real `virtio-blk-pci` hardware ID (`PHASE2_ENGINEERING_LOG.md`, around line
  692), and `virtio-scsi` presents a different device entirely; using it here would have
  reintroduced `INACCESSIBLE_BOOT_DEVICE`. Caught by reading the prior log before running anything,
  not hit empirically.
- This harness is explicitly **not** the production `packer/boot-and-provision.pkr.hcl` named in
  `CLAUDE.md`'s repo-structure sketch — that file still doesn't exist, and isn't real buildable work
  yet, since `image-apply/`'s own scripts (`partition-disk.sh`/`apply-image.sh`/`make-bootable.sh`/
  `apply-unattend.sh`) are still hand-run steps recorded only in `PHASE2_ENGINEERING_LOG.md`, not
  formalized. See "STATUS AND NEXT STEPS" below.

---

## Finding 1: Server 2025 reliably failed Packer's WinRM wait against a disk already proven WinRM-reachable

**Symptom:** `./dev/run-phase3-test.sh server2025 dev/services-domain-controller.yaml` errored with
`Timeout waiting for WinRM` after 11m43s (default `winrm_timeout = "10m"`). Bumping the timeout to
15m and retrying produced the identical failure at 15m40s. Server 2022, by contrast, had already
passed both profiles cleanly (6m58s and 18m06s) using the exact same `role-test.pkr.hcl`, differing
only in which reference disk/checksum the shared `locals.os_config` map selected.

**Diagnosis:** The failing disk (`win2025-session11.qcow2`) was `PHASE2_ENGINEERING_LOG.md` Session
11/13's own confirmed-good, real-WinRM-verified reference disk, so a broken disk seemed unlikely but
had to be ruled out empirically, not assumed — per `CLAUDE.md`'s "verify before trusting" standard
and its QMP-screendump convention for exactly this kind of situation (Packer's own qemu builder
doesn't expose QMP, per `CLAUDE.md`'s documented caveat, so this needed a separate ad hoc
`qemu-system-x86_64` invocation, not a Packer-internal debugging trick):

1. Built a throwaway COW overlay of `win2025-session11.qcow2` and booted it directly with
   `qemu-system-x86_64` (`virtio-blk-pci` disk, `virtio-net-pci` net, `q35`, OVMF, `-cpu host`,
   `-qmp unix:/tmp/diag2025.sock,server,nowait`), watched via `tools/qmp-watch.sh` at 20s intervals.
   Reached a fully booted, logged-in Administrator desktop (Server Manager auto-launched) within
   ~4 minutes, and a direct `curl http://127.0.0.1:<hostfwd-port>/wsman` got back the exact response
   a working WinRM listener returns to a bare GET (`405`, `Allow: POST`,
   `Server: Microsoft-HTTPAPI/2.0`) — WinRM was genuinely up and correct. The disk was not broken.
2. Since the disk was fine, the difference had to be in *how* Packer specifically invokes qemu.
   Captured Packer's actual generated command via `PACKER_LOG=1 PACKER_LOG_PATH=...`:
   ```
   qemu-system-x86_64 -machine type=q35,accel=kvm -netdev user,id=user.0,hostfwd=tcp::PORT-:5985
     -vnc 127.0.0.1:N -m 16384M -smp 4 -device virtio-net,netdev=user.0
     -drive file=...,if=virtio,cache=writeback,discard=ignore,format=qcow2
     -drive file=OVMF_CODE_4M.fd,if=pflash,unit=0,format=raw,readonly=on
     -drive file=efivars.fd,if=pflash,unit=1,format=raw -name phase3-server2025.qcow2
   ```
   Compared against the working ad hoc command from step 1: **Packer's invocation never passes
   `-cpu` at all.**
3. Reproduced Packer's exact command line by hand (`-m 16384M`, `-device virtio-net,netdev=user.0`,
   `if=virtio` drive shorthand — every quirk preserved) with only `-cpu host` and a QMP socket
   added. WinRM answered correctly within about a minute — confirming the missing `-cpu` argument,
   not memory size or device-naming differences, was the actual variable.

**Root cause:** The Packer qemu plugin's `cpu_model` field defaults to unset (verified against
HashiCorp's own documentation via a real search, not assumed): with nothing set, QEMU never
receives a `-cpu` argument under KVM at all and silently falls back to its generic, feature-minimal
`qemu64` baseline CPU model instead of the host's real CPU — no error, no warning either way.
Windows Server 2022 tolerated this fine (WinRM up well within the original 10-minute wait, on both
profiles). Windows Server 2025 did not, twice, even at 15 minutes. The exact mechanism for *why*
2025 is more sensitive was not directly confirmed — no screendump exists of a `qemu64`-CPU 2025 boot
specifically, since Packer doesn't expose QMP and the two failed Packer runs left nothing to inspect
after their own timeout cleanup. Best-supported hypothesis, not proven: Server 2025's heavier
default security posture (VBS/HVCI-adjacent features expecting CPU virtualization-extension flags
that `qemu64` doesn't expose) combined with simply more baseline first-boot work than Server 2022,
so a modest per-operation slowdown compounds into a much larger total delay. This hypothesis is not
load-bearing for the fix.

**Fix:** Added `cpu_model = "host"` to the single shared `source "qemu" "role_test"` block in
`dev/role-test.pkr.hcl` (HashiCorp's own docs recommend `"host"` under a hypervisor for exactly this
reason). Confirmed: Server 2025 AD-DS, retried immediately after with no other change, passed in
17m37s with WinRM connecting quickly. Server 2025 App-Server (`iis` + `sql-server`) then also passed
cleanly in 47m29s — longer than Server 2022's 18m06s for the same profile, consistent with (not
independent confirmation of) the "more baseline work" half of the hypothesis above, since SQL
Server's own install is itself CPU-heavy.

**Also worth knowing:** this same gap likely exists in the sibling project's own
`dev/role-test.pkr.hcl` (the direct pattern this file was built from) and possibly its production
`packer/windows-server.pkr.hcl` — neither was touched or fixed here, out of scope for this project's
repository, but worth checking over there at some point.

---

## Confirmed results (all four combinations)

| OS | Profile | Result | Time |
|---|---|---|---|
| Server 2022 | `ad-ds` | NTDS/DNS up, domain live after reboot, `verify-post-reboot.ps1` passed | 6m58s |
| Server 2022 | `iis` + `sql-server` | `W3SVC`/HTTP 200; SA login + `SELECT 1` over real SQL Server 2022 Developer | 18m06s |
| Server 2025 | `ad-ds` | NTDS/DNS up, domain live after reboot, `verify-post-reboot.ps1` passed | 17m37s |
| Server 2025 | `iis` + `sql-server` | `W3SVC`/HTTP 200; SA login + `SELECT 1` over real SQL Server 2022 Developer | 47m29s |

No VM left running, no stray `qemu-system-x86_64`/`packer` processes, no leftover `/tmp/diag*` files
at the end of this session (confirmed via `pgrep`).

---

## STATUS AND NEXT STEPS ON RESUMPTION (Session 1)

**Where things stand: Phase 3 is complete.** Both target OSes, both mutually-exclusive profiles,
all confirmed live with real in-guest verification (not just "WinRM connected"). Nothing in the
reused role scripts needed changing; the one real defect found and fixed lives entirely in the new
test harness, not in Phase 2's mechanism or the sibling project's scripts.

**Immediate next steps, whenever directed (neither is a continuation of Phase 3 itself, both are
separate, not-yet-scoped pieces of work):**
1. Formalize `image-apply/`'s real scripts (`partition-disk.sh`/`apply-image.sh`/`make-bootable.sh`/
   `apply-unattend.sh`) — Phase 2's recipe is still hand-run steps recorded only in
   `PHASE2_ENGINEERING_LOG.md`, confirmed four times across three OSes but never turned into
   idempotent, reusable scripts.
2. Build the production `packer/boot-and-provision.pkr.hcl` on top of those scripts once they exist
   — **must set `cpu_model = "host"` on its qemu source block from the start**, or Server 2025 will
   fail there the exact same way documented in Finding 1 above.

**Persistent state that survives** (under `image-apply/output/`, gitignored, unchanged by this
session): `win2022-session12.qcow2` and `win2025-session11.qcow2` remain exactly as Phase 2 left
them — every Phase 3 test booted a copy-on-write overlay (`dev/output/vm-*`, itself gitignored) and
never wrote to the reference disks directly.
