"""`windows-pipeline list` - reads the state store, prints every tracked VM
regardless of its current state (built, registered, running, etc)."""

from __future__ import annotations

import json
from dataclasses import asdict


def cmd_list(args, ctx) -> int:
    records = ctx.store.list_records()

    if args.format == "json":
        print(json.dumps([asdict(r) for r in records], indent=2, sort_keys=True))
        return 0

    if not records:
        print("No tracked VMs.")
        return 0

    columns = ["ID", "OS", "GUEST NAME", "STATE", "CREATED"]
    rows = [
        [r.id, r.os, r.guest_computer_name, r.state, r.created_at]
        for r in records
    ]
    widths = [max(len(col), *(len(row[i]) for row in rows)) for i, col in enumerate(columns)]

    def fmt(row: list[str]) -> str:
        return "  ".join(cell.ljust(width) for cell, width in zip(row, widths))

    print(fmt(columns))
    print(fmt(["-" * w for w in widths]))
    for row in rows:
        print(fmt(row))
    return 0
