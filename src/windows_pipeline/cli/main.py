"""windows-pipeline CLI entry point.

E1-E5 scope: `create`, `list`, `register-vm`, `start`, `stop`, `destroy`,
`verify`, plus shell completion (this module). build.sh/register-vm.sh are
retired - see git history for the scripts this CLI replaces.

OS names are deliberately not validated via argparse `choices` - that would
be a second, Python-side copy of common.sh's OS list, exactly the kind of
duplicated source of truth this project's own standards warn about (see
common_sh.py's docstring). commands.create.cmd_create defers to common.sh's
own validate_os and reports its error directly.
"""

from __future__ import annotations

import argparse
import sys
from typing import Optional, Sequence

from windows_pipeline.commands.create import cmd_create
from windows_pipeline.commands.destroy import cmd_destroy
from windows_pipeline.commands.list_cmd import cmd_list
from windows_pipeline.commands.register_vm import cmd_register_vm
from windows_pipeline.commands.verify import ALL_GROUPS, cmd_verify
from windows_pipeline.commands.vm_control import cmd_start, cmd_stop
from windows_pipeline.config import build_context

PROG = "windows-pipeline"


def _complete_host_id(prefix, parsed_args, **kwargs):  # noqa: ARG001 - argcomplete's own signature
    """Tab-completes a host_id argument from the state store. Best-effort -
    argcomplete runs this in the user's shell-completion context, which may
    not even be inside a valid checkout, so any failure just yields no
    completions rather than breaking the user's shell."""
    try:
        return build_context().store.list_ids()
    except Exception:  # noqa: BLE001 - completion must never raise into the user's shell
        return []


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=PROG)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser(
        "create", help="apply a fresh Windows image, boot it, provision it, and stage tools"
    )
    create_parser.add_argument("os", help="server2019 | server2022 | server2025 | windows11")
    create_parser.add_argument("--services", help="path to a services.yaml (server OSes only)")
    create_parser.add_argument("--tools", help="path to a tools.yaml (default: $TOOLS_YAML_PATH or ./tools.yaml)")
    create_parser.add_argument(
        "--computer-name", help="override the OS's default NetBIOS ComputerName"
    )
    create_parser.set_defaults(func=cmd_create)

    list_parser = subparsers.add_parser("list", help="list VMs tracked by windows-pipeline")
    list_parser.add_argument("--format", choices=["table", "json"], default="table")
    list_parser.set_defaults(func=cmd_list)

    register_parser = subparsers.add_parser(
        "register-vm", help="define a libvirt domain from an already-built disk"
    )
    register_parser.add_argument(
        "host_id", help="id from 'windows-pipeline create' / 'list'"
    ).completer = _complete_host_id
    register_parser.add_argument("--cpus", type=int, default=4)
    register_parser.add_argument("--memory-mb", type=int, default=16384)
    register_parser.add_argument("--network", default="default", help="libvirt network name")
    register_parser.add_argument(
        "--efi-firmware-code", default="/usr/share/OVMF/OVMF_CODE_4M.fd"
    )
    register_parser.set_defaults(func=cmd_register_vm)

    start_parser = subparsers.add_parser("start", help="start a registered VM's libvirt domain")
    start_parser.add_argument("host_id").completer = _complete_host_id
    start_parser.set_defaults(func=cmd_start)

    stop_parser = subparsers.add_parser("stop", help="stop a registered VM's libvirt domain")
    stop_parser.add_argument("host_id").completer = _complete_host_id
    stop_parser.add_argument(
        "--force", action="store_true", help="virsh destroy instead of a graceful shutdown"
    )
    stop_parser.add_argument(
        "--timeout", type=int, default=120, help="seconds to wait for a graceful shutdown (default: 120)"
    )
    stop_parser.set_defaults(func=cmd_stop)

    destroy_parser = subparsers.add_parser(
        "destroy", help="tear down a registered VM (undefine domain; disk kept unless --purge-disk)"
    )
    destroy_parser.add_argument("host_id").completer = _complete_host_id
    destroy_parser.add_argument(
        "--purge-disk", action="store_true", help="also delete the qcow2 disk (kept by default)"
    )
    destroy_parser.add_argument(
        "--force", action="store_true", help="skip the confirmation prompt; force-stop instead of graceful shutdown"
    )
    destroy_parser.add_argument(
        "--timeout", type=int, default=120, help="seconds to wait for a graceful shutdown (default: 120)"
    )
    destroy_parser.set_defaults(func=cmd_destroy)

    verify_parser = subparsers.add_parser("verify", help="run health checks against a running VM")
    verify_parser.add_argument("host_id").completer = _complete_host_id
    verify_parser.add_argument(
        "--checks", default=None, help=f"comma-separated subset of {ALL_GROUPS} (default: all)"
    )
    verify_parser.add_argument("--format", choices=["text", "json"], default="text")
    verify_parser.set_defaults(func=cmd_verify)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    try:
        import argcomplete

        argcomplete.autocomplete(parser)
    except ImportError:
        pass  # completion is opt-in (pip install "windows-pipeline[completion]") - never required
    args = parser.parse_args(argv)
    ctx = build_context()
    return args.func(args, ctx)


if __name__ == "__main__":
    sys.exit(main())
