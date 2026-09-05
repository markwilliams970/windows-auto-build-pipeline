"""Bridge to image-apply/lib/common.sh's per-OS lookup functions.

common.sh's OS table (WIM index, driver subfolder, disk size, ComputerName)
is independently-verified, per-OS data (see that file's own header) - it is
not duplicated here as a second Python table, which would be exactly the
kind of silent-drift risk CLAUDE.md's "Version-sensitivity and brittleness"
standard warns about (two sources of truth for the same fact, only one of
which gets updated when an OS's values change). Instead this shells out to
the real common.sh, so there is only ever one table.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


class UnknownOSError(ValueError):
    pass


def _common_sh(repo_root: Path) -> Path:
    return repo_root / "image-apply" / "lib" / "common.sh"


def _call(repo_root: Path, func: str, os_name: str) -> str:
    result = subprocess.run(
        ["bash", "-c", f'source "$1"; {func} "$2"', "_", str(_common_sh(repo_root)), os_name],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise UnknownOSError(result.stderr.strip() or f"{func} failed for OS '{os_name}'")
    return result.stdout.strip()


def validate_os(repo_root: Path, os_name: str) -> None:
    _call(repo_root, "validate_os", os_name)


def os_computer_name(repo_root: Path, os_name: str) -> str:
    return _call(repo_root, "os_computer_name", os_name)


def os_disk_size_gb(repo_root: Path, os_name: str) -> int:
    return int(_call(repo_root, "os_disk_size_gb", os_name))
