"""WinRM connection + IP resolution for a registered, running libvirt VM.

Same credentials convention as every image-apply/*.sh script (ADMIN_PASSWORD
env var, default TestP@ssw0rd123 - this project's disposable lab password,
not a real secret; see CLAUDE.md's Engineering Standards).
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass

import winrm

from windows_pipeline.libvirt_util import virsh

ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "TestP@ssw0rd123")


class VMUnreachableError(RuntimeError):
    pass


def resolve_ip(host_id: str) -> str:
    """The VM's current DHCP-leased IP, via virsh domifaddr (source: lease) -
    same libvirt "default" NAT network register-vm.sh's own domain XML uses,
    reachable directly from the host (confirmed live, Phase 5 E2 validation)."""
    result = virsh("domifaddr", host_id, "--source", "lease", capture=True, check=False)
    if result.returncode != 0:
        raise VMUnreachableError(
            f"could not query network addresses for '{host_id}' - is it running? "
            f"(virsh domifaddr said: {result.stderr.strip()})"
        )
    match = re.search(r"(\d+\.\d+\.\d+\.\d+)/\d+", result.stdout)
    if not match:
        raise VMUnreachableError(
            f"'{host_id}' has no DHCP lease yet - it may still be booting; try again shortly"
        )
    return match.group(1)


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str


def connect(host_id: str, *, timeout_sec: int = 20) -> winrm.Session:
    ip = resolve_ip(host_id)
    return winrm.Session(
        f"http://{ip}:5985/wsman",
        auth=("Administrator", ADMIN_PASSWORD),
        transport="basic",
        server_cert_validation="ignore",
        operation_timeout_sec=timeout_sec,
        read_timeout_sec=timeout_sec + 5,
    )


def run_ps(session: winrm.Session, script: str) -> subprocess.CompletedProcess:
    """Matches image-apply/*.sh's own winrm_ps() shape (a CompletedProcess-like
    object) so check functions can use the same status_code/stdout/stderr checks.

    Never raises - a transport/auth/timeout failure (found the hard way testing
    verify against a VM with different-than-expected credentials: pywinrm's
    InvalidCredentialsError propagated as a raw traceback instead of a clean
    check failure) is reported the same way a non-zero PowerShell exit would
    be, so every check function's existing `r.returncode != 0` handling covers
    it without each of them needing its own try/except.
    """
    try:
        r = session.run_ps(script)
    except Exception as exc:  # noqa: BLE001 - deliberately broad, see docstring
        return subprocess.CompletedProcess(
            args=script, returncode=1, stdout=b"", stderr=f"{type(exc).__name__}: {exc}".encode()
        )
    return subprocess.CompletedProcess(
        args=script, returncode=r.status_code, stdout=r.std_out, stderr=r.std_err
    )
