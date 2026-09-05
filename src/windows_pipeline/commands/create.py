"""`windows-pipeline create <os>` - ports build.sh's body unchanged underneath.

Only the orchestration changes: a host id is generated up front (replacing
build.sh's own BUILD_ID) and a state record tracks progress
(creating -> built|failed). Every actual heavy-lifting script
(partition-disk.sh, apply-image.sh, make-bootable.sh, apply-unattend.sh,
Packer, inject-virtio-spice.sh, install-tools.sh, windows11-setup-install.sh)
is invoked exactly as build.sh already invoked it - see build.sh's own
history/comments for why each step is there and in that order.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

from windows_pipeline import common_sh, identity
from windows_pipeline.state import HostRecord
from windows_pipeline.util import log, now_iso, run


def cmd_create(args, ctx) -> int:
    repo_root = ctx.repo_root
    os_name = args.os

    try:
        common_sh.validate_os(repo_root, os_name)
    except common_sh.UnknownOSError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    computer_name = args.computer_name or common_sh.os_computer_name(repo_root, os_name)
    host_id = identity.generate_host_id(computer_name)

    build_dir = repo_root / "image-apply" / "output" / "builds"
    build_dir.mkdir(parents=True, exist_ok=True)
    target_qcow2 = build_dir / f"{host_id}.qcow2"
    if target_qcow2.exists():
        # Belt-and-suspenders, same as build.sh's own check - practically
        # unreachable now that the uuid8 suffix guarantees uniqueness, but
        # cheap and fails loud rather than silently overwriting a real disk.
        print(f"ERROR: {target_qcow2} already exists - refusing to overwrite", file=sys.stderr)
        return 1

    tools_yaml = args.tools or os.environ.get("TOOLS_YAML_PATH") or str(repo_root / "tools.yaml")

    record = HostRecord(
        id=host_id,
        os=os_name,
        guest_computer_name=computer_name,
        created_at=now_iso(),
        state="creating",
        qcow2_path=str(target_qcow2),
        services_yaml=str(args.services) if args.services else None,
        tools_yaml=tools_yaml,
    )
    ctx.store.save(record)
    log(f"create: {os_name} -> host_id={host_id}")

    try:
        if os_name == "windows11":
            final_qcow2 = _create_windows11(
                repo_root,
                os_name,
                target_qcow2,
                computer_name if args.computer_name else None,
                tools_yaml,
            )
        else:
            final_qcow2 = _create_server(
                repo_root,
                os_name,
                host_id,
                target_qcow2,
                computer_name if args.computer_name else None,
                args.services,
                tools_yaml,
            )
    except Exception as exc:
        record.state = "failed"
        record.error = str(exc)
        ctx.store.save(record)
        raise

    record.qcow2_path = str(final_qcow2)
    record.state = "built"
    record.virtio_spice_injected = True
    ctx.store.save(record)
    log(f"create complete: {host_id} -> {final_qcow2}")
    print(host_id)
    return 0


def _create_windows11(repo_root: Path, os_name: str, target_qcow2: Path,
                       computer_name_override: str | None, tools_yaml: str) -> Path:
    # Windows 11 has no Packer handoff and no roles (CLAUDE.md's standing
    # scope note) - one self-contained Setup.exe-driven script covers
    # partitioning, install, bootability, and specialize in a single run.
    log("[1/3] windows11-setup-install.sh (Setup.exe-driven)")
    cmd = [str(repo_root / "image-apply" / "windows11-setup-install.sh"), str(target_qcow2)]
    if computer_name_override:
        cmd.append(computer_name_override)
    run(cmd)

    log("[2/3] inject-virtio-spice.sh")
    run([str(repo_root / "image-apply" / "inject-virtio-spice.sh"), os_name, str(target_qcow2)])

    log("[3/3] install-tools.sh")
    run([str(repo_root / "image-apply" / "install-tools.sh"), os_name, str(target_qcow2), tools_yaml])

    return target_qcow2


def _create_server(repo_root: Path, os_name: str, host_id: str, target_qcow2: Path,
                    computer_name_override: str | None, services_yaml: str | None,
                    tools_yaml: str) -> Path:
    log("[1/4] partition-disk.sh")
    run([str(repo_root / "image-apply" / "partition-disk.sh"), os_name, str(target_qcow2)])

    log("[2/4] apply-image.sh")
    run([str(repo_root / "image-apply" / "apply-image.sh"), os_name, str(target_qcow2)])

    log("[3/4] make-bootable.sh")
    run([str(repo_root / "image-apply" / "make-bootable.sh"), os_name, str(target_qcow2)])

    log("[4/4] apply-unattend.sh")
    cmd = [str(repo_root / "image-apply" / "apply-unattend.sh"), os_name, str(target_qcow2)]
    if computer_name_override:
        cmd.append(computer_name_override)
    run(cmd)

    disk_size_mb = common_sh.os_disk_size_gb(repo_root, os_name) * 1024

    log("Handing off to Packer for first real boot + role provisioning")
    packer_dir = repo_root / "packer"
    packer_output_root = packer_dir / "output"
    packer_output_root.mkdir(parents=True, exist_ok=True)
    packer_efivars = packer_output_root / f"{host_id}-efivars.fd"
    packer_build_output_dir = packer_output_root / host_id
    if packer_efivars.exists() or packer_build_output_dir.exists():
        raise RuntimeError(
            f"{packer_efivars} or {packer_build_output_dir} already exists - "
            "refusing to overwrite; investigate before retrying"
        )
    shutil.copy("/usr/share/OVMF/OVMF_VARS_4M.fd", packer_efivars)

    run(["packer", "init", str(packer_dir / "boot-and-provision.pkr.hcl")])

    packer_args = [
        "-var", f"target_os={os_name}",
        "-var", f"build_id={host_id}",
        "-var", f"source_qcow2={target_qcow2}",
        "-var", f"disk_size_mb={disk_size_mb}",
    ]
    if services_yaml:
        packer_args += ["-var", f"services_yaml_path={services_yaml}"]

    run(["packer", "validate", *packer_args, str(packer_dir)])
    run(["packer", "build", *packer_args, str(packer_dir)])

    provisioned_qcow2 = packer_build_output_dir / f"{host_id}.qcow2"

    log("[Phase 3A] inject-virtio-spice.sh (vioscsi + QXL/SPICE)")
    run([str(repo_root / "image-apply" / "inject-virtio-spice.sh"), os_name, str(provisioned_qcow2)])

    log("[Phase 4] install-tools.sh")
    run([str(repo_root / "image-apply" / "install-tools.sh"), os_name, str(provisioned_qcow2), tools_yaml])

    return provisioned_qcow2
