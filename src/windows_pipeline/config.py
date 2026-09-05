"""Repo-root and state-store location resolution.

This tool is an orchestration layer over image-apply/*.sh and
packer/boot-and-provision.pkr.hcl, which live in a specific repo checkout -
it is not a standalone, relocatable tool the way a pure-Python CLI could be.
REPO_ROOT is therefore resolved by walking up from this file's own location
(not the current working directory) to find image-apply/lib/common.sh, which
still works under an editable install (`pip install -e .`/`pipx install -e .`)
since that leaves this file in place inside the checkout rather than copying
it elsewhere. WINDOWS_PIPELINE_REPO_ROOT overrides this for the rare case
that doesn't hold (e.g. a non-editable install).

State store location follows this project's existing repo-relative
convention (ISO_CACHE_DIR, image-apply/output/, packer/output/) rather than
windows11-lab's system-path default (/var/lib/libvirt/images/winlab-store) -
that project supports a system-wide golden-image store shared across
checkouts; this one doesn't have an equivalent need. image-apply/output/ is
already entirely gitignored (see .gitignore's own comment on why), so no new
ignore rule is needed for the state subdirectory.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from windows_pipeline.state import StateStore

_MARKER = Path("image-apply") / "lib" / "common.sh"


def _find_repo_root() -> Path:
    override = os.environ.get("WINDOWS_PIPELINE_REPO_ROOT")
    if override:
        root = Path(override).resolve()
        if not (root / _MARKER).is_file():
            raise RuntimeError(
                f"WINDOWS_PIPELINE_REPO_ROOT={root} does not look like a "
                f"windows-auto-build-pipeline checkout (missing {_MARKER})"
            )
        return root

    here = Path(__file__).resolve()
    for candidate in (here, *here.parents):
        if (candidate / _MARKER).is_file():
            return candidate

    raise RuntimeError(
        "could not locate the windows-auto-build-pipeline checkout root "
        f"(looked for {_MARKER} above {here}) - set WINDOWS_PIPELINE_REPO_ROOT"
    )


@dataclass(frozen=True)
class Context:
    repo_root: Path
    store: StateStore


def build_context() -> Context:
    repo_root = _find_repo_root()
    state_dir = Path(
        os.environ.get(
            "WINDOWS_PIPELINE_STATE_DIR", str(repo_root / "image-apply" / "output" / "state")
        )
    )
    return Context(repo_root=repo_root, store=StateStore(state_dir))
