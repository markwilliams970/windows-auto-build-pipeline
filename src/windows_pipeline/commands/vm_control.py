"""`windows-pipeline start/stop <host_id>` - thin virsh wrappers.

libvirt's own domstate is the ground truth for whether a domain exists and
what state it's in (see libvirt_util's own docstring) - the state record is
only used here to produce a clearer error message when a VM hasn't been
registered yet, and to record intent afterward; it never overrides what
virsh actually reports.
"""

from __future__ import annotations

import sys
import time

from windows_pipeline.libvirt_util import domain_exists, domain_state, ensure_libvirt_reachable, virsh
from windows_pipeline.state import HostRecord
from windows_pipeline.util import log


def _load_or_none(host_id: str, ctx) -> HostRecord | None:
    try:
        return ctx.store.load(host_id)
    except KeyError:
        print(f"ERROR: no tracked VM with id '{host_id}'", file=sys.stderr)
        return None


def cmd_start(args, ctx) -> int:
    host_id = args.host_id
    record = _load_or_none(host_id, ctx)
    if record is None:
        return 1

    try:
        ensure_libvirt_reachable()
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if not domain_exists(host_id):
        print(
            f"ERROR: no libvirt domain named '{host_id}' - run 'windows-pipeline register-vm {host_id}' first",
            file=sys.stderr,
        )
        return 1

    if domain_state(host_id) == "running":
        log(f"'{host_id}' is already running")
    else:
        log(f"Starting '{host_id}'")
        virsh("start", host_id)

    record.state = "running"
    ctx.store.save(record)
    return 0


def cmd_stop(args, ctx) -> int:
    host_id = args.host_id
    record = _load_or_none(host_id, ctx)
    if record is None:
        return 1

    try:
        ensure_libvirt_reachable()
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if not domain_exists(host_id):
        print(f"ERROR: no libvirt domain named '{host_id}'", file=sys.stderr)
        return 1

    if domain_state(host_id) == "shut off":
        log(f"'{host_id}' is already shut off")
        record.state = "stopped"
        ctx.store.save(record)
        return 0

    if args.force:
        log(f"Force-stopping '{host_id}' (virsh destroy)")
        virsh("destroy", host_id)
    else:
        log(f"Gracefully shutting down '{host_id}' (up to {args.timeout}s) - never a hard "
            f"kill by default, matching this project's own standing convention")
        virsh("shutdown", host_id)
        deadline = time.time() + args.timeout
        while time.time() < deadline:
            if domain_state(host_id) == "shut off":
                break
            time.sleep(3)
        else:
            print(
                f"ERROR: '{host_id}' did not shut down within {args.timeout}s - "
                "retry with --force, or investigate inside the guest",
                file=sys.stderr,
            )
            return 1
        log(f"'{host_id}' is shut off")

    record.state = "stopped"
    ctx.store.save(record)
    return 0
