"""`windows-pipeline register-vm <host_id>` - defines a libvirt domain from an
already-built disk, ported from register-vm.sh.

The one real design change from register-vm.sh: there is no separate vm_name
argument or default-by-newest-mtime resolution anymore. host_id (the state
store's own key, generated at `create` time) *is* the libvirt domain name -
that identifier was designed from the start to be host-side-unique (Phase 5's
naming redesign - <netbios-lowercase>-<timestamp>-<uuid8>), so it needs no
separate scheme here, and the qcow2/state lookup that used to require
guessing "the most recently modified build" is now a direct state-store read.

Device model (virtio-scsi disk, virtio-net NIC, qxl-vga + SPICE, USB tablet)
and the inject-virtio-spice.sh completion-marker precondition are unchanged
from register-vm.sh - see check-virtio-spice-marker.sh for why that check is
a real disk read, not a trust-the-state-record shortcut.
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

from windows_pipeline.libvirt_util import domain_exists, domain_state, ensure_libvirt_reachable, virsh
from windows_pipeline.util import log, run

DOMAIN_XML_TEMPLATE = """<domain type='kvm'>
  <name>{vm_name}</name>
  <memory unit='MiB'>{memory_mb}</memory>
  <currentMemory unit='MiB'>{memory_mb}</currentMemory>
  <vcpu placement='static'>{cpus}</vcpu>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>{efi_firmware_code}</loader>
    <nvram>{nvram_path}</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='localtime'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='{qcow2_path}'/>
      <target dev='sda' bus='scsi'/>
    </disk>
    <controller type='scsi' index='0' model='virtio-scsi'/>
    <interface type='network'>
      <source network='{network}'/>
      <model type='virtio'/>
    </interface>
    <graphics type='spice' autoport='yes' listen='127.0.0.1' tlsPort='-1'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <video>
      <model type='qxl' vgamem='32768'/>
    </video>
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
    </channel>
    <!-- Without this, libvirt defaults to a relative PS/2 mouse, which desyncs from
         SPICE's own absolute cursor position and makes the console unusable (clicks land
         somewhere other than the visible cursor) - see CLAUDE.md's "VM screen inspection"
         section. -->
    <input type='tablet' bus='usb'/>
  </devices>
</domain>
"""


def cmd_register_vm(args, ctx) -> int:
    host_id = args.host_id
    try:
        record = ctx.store.load(host_id)
    except KeyError:
        print(
            f"ERROR: no tracked VM with id '{host_id}' - run 'windows-pipeline create' "
            "first, or check 'windows-pipeline list'",
            file=sys.stderr,
        )
        return 1

    if record.state not in ("built", "registered"):
        print(
            f"ERROR: '{host_id}' is in state '{record.state}', not 'built' - refusing to register",
            file=sys.stderr,
        )
        return 1

    qcow2_path = Path(record.qcow2_path)
    if not qcow2_path.is_file():
        print(f"ERROR: {qcow2_path} does not exist - the disk may have been moved or deleted", file=sys.stderr)
        return 1

    try:
        ensure_libvirt_reachable()
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    efi_firmware_code = Path(args.efi_firmware_code)
    if not efi_firmware_code.is_file():
        print(
            f"ERROR: OVMF code file not found at {efi_firmware_code} - override with --efi-firmware-code",
            file=sys.stderr,
        )
        return 1

    if virsh("net-info", args.network, check=False, capture=True).returncode != 0:
        print(
            f"ERROR: libvirt network '{args.network}' does not exist - override with "
            "--network, or create it (virsh net-define/net-start)",
            file=sys.stderr,
        )
        return 1

    # Real disk-content check, not a trust-the-state-record shortcut - see
    # check-virtio-spice-marker.sh's own docstring for why.
    run([str(ctx.repo_root / "image-apply" / "check-virtio-spice-marker.sh"), str(qcow2_path)])

    vm_name = host_id  # the whole point of Phase 5's naming redesign - one identifier, reused as-is

    nvram_dir = ctx.repo_root / "image-apply" / "output" / "registered-vms"
    nvram_dir.mkdir(parents=True, exist_ok=True)
    nvram_path = nvram_dir / f"{vm_name}-efivars.fd"

    if domain_exists(vm_name):
        state = domain_state(vm_name)
        if state != "shut off":
            print(
                f"ERROR: libvirt domain '{vm_name}' already exists and is '{state}' - "
                "shut it down (or destroy it) before re-registering",
                file=sys.stderr,
            )
            return 1
        log(f"Domain '{vm_name}' already registered and shut off - undefining before re-registering")
        virsh("undefine", "--nvram", vm_name)

    shutil.copy("/usr/share/OVMF/OVMF_VARS_4M.fd", nvram_path)

    domain_xml = DOMAIN_XML_TEMPLATE.format(
        vm_name=vm_name,
        memory_mb=args.memory_mb,
        cpus=args.cpus,
        efi_firmware_code=efi_firmware_code,
        nvram_path=nvram_path,
        qcow2_path=qcow2_path,
        network=args.network,
    )
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as f:
        f.write(domain_xml)
        xml_path = f.name
    try:
        log(f"Defining libvirt domain '{vm_name}' from {qcow2_path}")
        virsh("define", xml_path)
    finally:
        Path(xml_path).unlink(missing_ok=True)

    record.state = "registered"
    record.nvram_path = str(nvram_path)
    ctx.store.save(record)

    log(f"Registered '{vm_name}' - visible in virt-manager now, shut off.")
    log(f"Start it with: windows-pipeline start {vm_name}")
    log(f"Console (SPICE, loopback-only): virt-viewer --connect qemu:///system {vm_name}")
    return 0
