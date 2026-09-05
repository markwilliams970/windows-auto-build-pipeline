"""Flat, one-record-per-VM state tracking.

Deliberately NOT a history/overlay graph (contrast with ../windows11-lab's
ImageGraph/NodeManifest, which tracks an immutable qcow2 layer lineage
because that project supports cloning from golden images). This project
never does that - every build applies the WIM fresh (CLAUDE.md's "Ephemeral
Infrastructure, Still") - so each HostRecord holds only the *current* state
of one VM, overwritten in place as it moves through its lifecycle
(creating -> built|failed -> registered -> running|stopped). There is no
"destroyed" terminal state: destroy.py deletes the record outright (explicit
user preference - no tombstone), so a destroyed VM simply stops appearing in
the store at all, rather than lingering with a terminal state. There is no
record of what the state used to be for anything still tracked, either.

Persistence follows winlab.metadata.store.ManifestStore's proven shape:
atomic writes (temp file + os.replace) so a killed process never leaves a
corrupt, partially-written record under its final name.
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

SCHEMA_VERSION = 1


@dataclass
class HostRecord:
    id: str
    os: str
    guest_computer_name: str
    created_at: str  # ISO 8601
    state: str  # creating | built | failed | registered | running | stopped
    # (no "destroyed" value - destroy.py deletes the record instead of writing one)
    qcow2_path: Optional[str] = None
    nvram_path: Optional[str] = None
    services_yaml: Optional[str] = None
    tools_yaml: Optional[str] = None
    virtio_spice_injected: bool = False
    tools_installed: list[str] = field(default_factory=list)
    last_verified_at: Optional[str] = None
    last_verify_result: Optional[dict] = None
    error: Optional[str] = None
    schema_version: int = SCHEMA_VERSION

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2, sort_keys=True)

    @classmethod
    def from_json(cls, data: str) -> "HostRecord":
        payload = json.loads(data)
        known = set(cls.__dataclass_fields__)
        unknown = set(payload) - known
        if unknown:
            raise ValueError(f"unknown HostRecord field(s): {sorted(unknown)}")
        return cls(**payload)


class StateStore:
    """Reads and writes HostRecord JSON files under a state directory."""

    def __init__(self, state_dir: Path | str):
        self.state_dir = Path(state_dir)

    def _path(self, host_id: str) -> Path:
        return self.state_dir / f"{host_id}.json"

    def save(self, record: HostRecord) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        final_path = self._path(record.id)
        tmp_path = final_path.with_suffix(final_path.suffix + ".tmp")
        tmp_path.write_text(record.to_json())
        os.replace(tmp_path, final_path)

    def load(self, host_id: str) -> HostRecord:
        try:
            data = self._path(host_id).read_text()
        except FileNotFoundError:
            raise KeyError(f"no state record for host id: {host_id!r}") from None
        return HostRecord.from_json(data)

    def exists(self, host_id: str) -> bool:
        return self._path(host_id).exists()

    def delete(self, host_id: str) -> None:
        self._path(host_id).unlink(missing_ok=True)

    def list_ids(self) -> list[str]:
        if not self.state_dir.exists():
            return []
        return sorted(p.stem for p in self.state_dir.glob("*.json"))

    def list_records(self) -> list[HostRecord]:
        records = [self.load(host_id) for host_id in self.list_ids()]
        return sorted(records, key=lambda r: r.created_at)
