"""Small virsh wrappers shared by register_vm/start/stop.

Deliberately thin - libvirt's own domstate/dominfo output is the ground truth
for whether a domain exists and what state it's in, never this project's own
state record (which tracks intent/history, not live libvirt state, and could
drift from it - a VM could be started/stopped outside windows-pipeline
entirely, e.g. via virt-manager).
"""

from __future__ import annotations

import shutil
import subprocess


def virsh(*args: str, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    cmd = ["virsh", "-c", "qemu:///system", *args]
    if capture:
        return subprocess.run(cmd, check=check, capture_output=True, text=True)
    return subprocess.run(cmd, check=check)


def ensure_libvirt_reachable() -> None:
    if shutil.which("virsh") is None:
        raise RuntimeError("virsh is not installed or not on PATH")
    result = virsh("list", check=False, capture=True)
    if result.returncode != 0:
        raise RuntimeError(
            "cannot reach libvirt at qemu:///system - is libvirtd running, "
            "and is this user in the 'libvirt' group?"
        )


def domain_exists(name: str) -> bool:
    return virsh("dominfo", name, check=False, capture=True).returncode == 0


def domain_state(name: str) -> str:
    return virsh("domstate", name, capture=True).stdout.strip()
