from __future__ import annotations

import subprocess
from datetime import datetime, timezone


def log(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def run(cmd: list[str]) -> None:
    """Run a subprocess with inherited stdio, matching build.sh's own live-output
    convention (no capture - a real build's Packer/QEMU output is exactly what a
    human watching it needs to see, not something to buffer and replay later).

    Deliberately inherits the caller's environment as-is (PATH included) rather
    than second-guessing it - image-apply/*.sh's own nested `python3` calls
    (winrm_ps, in inject-virtio-spice.sh/windows11-setup-install.sh/
    install-tools.sh) need pywinrm on whatever python3 that resolves to. The
    correct place to guarantee that is this package's own declared dependency
    on pywinrm (pyproject.toml) - once installed into this venv, an activated
    windows-pipeline venv's python3 has pywinrm too, so PATH doesn't need
    correcting here. An earlier version of this function stripped the active
    venv's bin dir from PATH to route those calls to the system python3
    instead - reverted: routing around the venv silently reintroduces exactly
    the kind of implicit, undeclared dependency this project's own standards
    warn against, and changing subprocess environment handling isn't something
    to decide unilaterally.
    """
    log(f"$ {' '.join(cmd)}")
    subprocess.run(cmd, check=True)
