"""`windows-pipeline destroy <host_id> [--purge-disk] [--force]` - tear down a
registered VM completely.

Sequence follows vagrant-libvirt's own proven destroy_domain.rb order (Phase 5
research): stop if running -> delete snapshots -> remove managed-save ->
undefine (with --nvram, not optional - see below) -> delete our own NVRAM
file -> delete the disk only if --purge-disk. Keeping the disk by default was
an explicit design decision (a build can take 15-50+ minutes; losing one to
an accidental destroy is expensive) - --purge-disk opts in.

Two hard libvirt failure modes this sequence exists to avoid (confirmed
directly against vagrant-libvirt/terraform-provider-libvirt's own issue
trackers during Phase 5 research, not assumed): `virsh undefine` on a
UEFI/NVRAM domain fails outright without an explicit --nvram/--keep-nvram
flag, and fails outright if the domain still has snapshots. Both are handled
here rather than left to surface as a cryptic virsh error.

Known, deliberate gap: DHCP lease cleanup. libvirt does not release a
domain's dynamic DHCP lease on undefine (confirmed in the same research
pass), and virsh has no command to do it either (`net-dhcp-leases` is
list-only in this project's libvirt 10.0.0 - checked directly, not assumed).
Doing this would mean hand-editing dnsmasq's lease file under
/var/lib/libvirt/dnsmasq/, which needs root and isn't covered by this
project's existing scoped sudoers grant (disk-prep commands only). Rather
than requesting broader sudo access for a cosmetic gap, this is left alone -
the lease expires on its own via dnsmasq's normal lease time.
"""

from __future__ import annotations

import shutil
import sys
import time
from pathlib import Path

from windows_pipeline.libvirt_util import domain_exists, domain_state, ensure_libvirt_reachable, virsh
from windows_pipeline.util import log


def _disk_artifacts(repo_root: Path, host_id: str, qcow2_path: Path | None) -> list[Path]:
    """Every known per-host_id location a real build can leave behind, not just
    the one path in the state record. Found the hard way (Phase 5, 2026-09-05):
    a real --purge-disk run left Packer's scratch efivars file, its whole
    per-build output directory (with its own leftover efivars.fd), and both
    inject-virtio-spice.sh's and install-tools.sh's per-run work directories
    still on disk - --purge-disk deleted only the one qcow2 it knew about.
    Also covers image-apply/output/builds/<host_id>.qcow2, the pre-Packer copy
    create.py's own _create_server leaves behind and never cleans up even on
    success (build.sh had the identical gap before it) - genuinely part of
    this build's disk footprint even though it's already-stale/superseded.
    """
    candidates = [
        repo_root / "image-apply" / "output" / "builds" / f"{host_id}.qcow2",
        repo_root / "packer" / "output" / f"{host_id}-efivars.fd",
        repo_root / "packer" / "output" / host_id,
        repo_root / "image-apply" / "output" / "virtio-spice-work" / host_id,
        repo_root / "image-apply" / "output" / "tools-install-work" / host_id,
    ]
    if qcow2_path:
        candidates.append(qcow2_path)
    seen: list[Path] = []
    for path in candidates:
        if path.exists() and path not in seen:
            seen.append(path)
    return seen


def _delete(path: Path) -> None:
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()


def cmd_destroy(args, ctx) -> int:
    host_id = args.host_id
    try:
        record = ctx.store.load(host_id)
    except KeyError:
        print(f"ERROR: no tracked VM with id '{host_id}'", file=sys.stderr)
        return 1

    try:
        ensure_libvirt_reachable()
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    registered = domain_exists(host_id)
    qcow2_path = Path(record.qcow2_path) if record.qcow2_path else None
    nvram_path = Path(record.nvram_path) if record.nvram_path else None
    artifacts = _disk_artifacts(ctx.repo_root, host_id, qcow2_path) if args.purge_disk else []

    if not registered and not artifacts:
        print(
            f"'{host_id}' has no registered libvirt domain and no disk artifacts to purge - nothing to do.",
            file=sys.stderr,
        )
        return 1

    actions = []
    if registered:
        actions.append(f"undefine libvirt domain '{host_id}'")
        actions.append("delete its NVRAM file")
    if args.purge_disk:
        if artifacts:
            actions.append("delete disk artifacts:")
            actions.extend(f"    {path}" for path in artifacts)
        else:
            actions.append("(no disk artifacts found to purge)")
    elif qcow2_path:
        actions.append(f"keep disk {qcow2_path}")

    if not args.force:
        print(f"About to destroy '{host_id}':")
        for action in actions:
            print(f"  - {action}")
        answer = input("Continue? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            print("Aborted.")
            return 1

    if registered:
        state = domain_state(host_id)
        if state in ("running", "paused"):
            if args.force:
                log(f"Force-stopping '{host_id}' (virsh destroy)")
                virsh("destroy", host_id, check=False)
            else:
                log(f"Gracefully shutting down '{host_id}' before destroying it (up to {args.timeout}s)")
                virsh("shutdown", host_id, check=False)
                deadline = time.time() + args.timeout
                while time.time() < deadline and domain_state(host_id) != "shut off":
                    time.sleep(3)
                if domain_state(host_id) != "shut off":
                    log(f"'{host_id}' did not shut down gracefully within {args.timeout}s - forcing off")
                    virsh("destroy", host_id, check=False)

        # libvirt refuses to undefine a domain that still has snapshots
        snap_result = virsh("snapshot-list", host_id, "--name", capture=True, check=False)
        for name in filter(None, (line.strip() for line in snap_result.stdout.splitlines())):
            log(f"Deleting snapshot '{name}'")
            virsh("snapshot-delete", host_id, name, check=False)

        info = virsh("dominfo", host_id, capture=True, check=False)
        if "Managed save: yes" in info.stdout:
            log("Removing managed-save state")
            virsh("managedsave-remove", host_id, check=False)

        # --nvram is not optional here: virsh undefine fails outright on a UEFI
        # domain without an explicit --nvram/--keep-nvram flag (Phase 5 research).
        log(f"Undefining libvirt domain '{host_id}' (--nvram)")
        virsh("undefine", "--nvram", host_id)
    elif nvram_path and nvram_path.exists():
        # Domain already gone (e.g. undefined outside windows-pipeline) but our
        # own NVRAM file may be orphaned - clean it up anyway.
        nvram_path.unlink(missing_ok=True)

    for path in artifacts:
        log(f"Deleting {path}")
        _delete(path)

    # No tombstone - a destroyed VM is gone, not kept around in `list` with a
    # terminal state (explicit user preference, 2026-09-05: "I don't need a
    # tombstone reminder").
    ctx.store.delete(host_id)

    log(f"'{host_id}' destroyed" + (" (disk purged)" if args.purge_disk else " (disk kept)"))
    return 0
