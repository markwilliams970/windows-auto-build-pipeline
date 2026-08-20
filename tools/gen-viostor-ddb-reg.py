#!/usr/bin/env python3
"""Generate a .reg file that offline-registers a virtio PCI driver into a Windows
SYSTEM hive's DriverDatabase - the same offline "driver preinstallation" namespace
DISM's own /Add-Driver uses - so Windows' PnP manager finds and loads it on first
real boot without ever booting the target OS first.

Originally written for viostor (virtio-blk) specifically, to clear
INACCESSIBLE_BOOT_DEVICE (0x7B); recipe transcribed directly from virt-v2v's actual
source (libguestfs/libguestfs-common, mlcustomize/inject_virtio_win.ml,
add_guestor_to_registry/cdb_regedits/ddb_regedits), not reconstructed from memory -
see PHASE2_ENGINEERING_LOG.md Finding 29 for the full verification trail.

Key correction versus this project's own first attempt (Findings 7-8, which failed
silently): DriverDatabase lives at the SYSTEM hive ROOT (a sibling of ControlSet001),
not nested under ControlSet001\\Control - confirmed empirically via hivexsh against a
real applied image. Registering under the wrong parent is a silent no-op: hivexregedit
raises no error, and Windows never sees the registration.

Generalized (Session 9) to also cover netkvm (virtio-net), after confirming - by
reading virt-v2v's real source again, not assuming the viostor recipe just carries
over - that virt-v2v itself only ever calls add_guestor_to_registry for the
boot-critical block driver; it never touches the network driver at all (NetKVM's
files just get copied to %WINDIR%\\Drivers\\VirtIO and left for virt-v2v's own
Setup.exe/sysprep-driven specialize pass to find, which doesn't apply to this
project's Setup.exe-free pipeline - see Finding 36). DriverDatabase registration is
still the right generalization: it's Windows' own general offline-driver-staging
namespace (confirmed via libguestfs-common's mldrivers/windows_drivers.ml, which reads
DriverDatabase\\DeviceIds generically, not as a boot-only structure), not something
virt-v2v invented. But viostor's hardcoded Services values (Start=0 boot-start,
Group="SCSI miniport") are viostor-specific, not generic - confirmed by reading
netkvm.inf directly, which specifies StartType=3 (demand-start, i.e. normal PnP-started,
which makes sense for a non-boot-critical device) and LoadOrderGroup=NDIS. Also: the
synthetic "guestor.inf" driver-package label virt-v2v uses is a fixed literal in its
own source (never parameterized, since virt-v2v only ever registers one driver this
way per call) - reusing it unchanged for a second driver would silently collide with
and corrupt viostor's already-registered DriverDatabase entries under the same key
path, so netkvm gets its own distinct synthetic label instead.

Usage:
    gen-viostor-ddb-reg.py > viostor-ddb.reg                       # viostor (default)
    gen-viostor-ddb-reg.py --driver netkvm > netkvm-ddb.reg
    hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\\SYSTEM' \\
        <mounted-image>/Windows/System32/config/SYSTEM viostor-ddb.reg

Also requires (not done by this script):
  - <driver>.sys copied to <image>/Windows/System32/drivers/<driver>.sys
  - a real BCD for the target disk (BCD-SYS or bcdboot; either has been shown to work)
"""
import argparse

WINARCH = "amd64"

# System-defined device setup class GUIDs (Microsoft's own docs -
# MicrosoftDocs/windows-driver-docs, system-defined-device-setup-classes-available-to-vendors.md
# - confirmed directly, not assumed from the viostor value already in this script).
SCSIADAPTER_CLASS_GUID = "4d36e97b-e325-11ce-bfc1-08002be10318"
NET_CLASS_GUID = "4d36e972-e325-11ce-bfc1-08002be10318"

# Per-driver values. viostor's are virt-v2v's own hardcoded literals (Services Group/
# Start, the "guestor.inf"/"guestor_conf" synthetic labels); netkvm's Services Group/
# Start/class GUID are confirmed by reading netkvm.inf directly, and its synthetic
# labels are this project's own choice, distinct from viostor's to avoid collision.
DRIVER_PRESETS = {
    "viostor": dict(
        legacy_pciid="VEN_1AF4&DEV_1001&REV_00",
        modern_pciid="VEN_1AF4&DEV_1042&REV_01",
        drv_inf="guestor.inf",
        drv_config="guestor_conf",
        service_group="SCSI miniport",
        start=0,  # SERVICE_BOOT_START - must load before the boot disk is readable
        class_guid=SCSIADAPTER_CLASS_GUID,
    ),
    "netkvm": dict(
        legacy_pciid="VEN_1AF4&DEV_1000&REV_00",
        modern_pciid="VEN_1AF4&DEV_1041&REV_01",
        drv_inf="netkvm.inf",
        drv_config="netkvm_conf",
        service_group="NDIS",
        start=3,  # SERVICE_DEMAND_START, per netkvm.inf's own StartType=3 - normal
                  # PnP-started, not boot-critical
        class_guid=NET_CLASS_GUID,
    ),
}


def version_blob(class_guid: str) -> bytes:
    """48-byte Version blob: 8-byte header + 16-byte raw device-setup-class GUID
    (mixed-endian) + 24 zero bytes. "Version is necessary for Windows-Kernel-Pnp
    in w10/w2k16" per virt-v2v's own source comment."""
    hex_str = class_guid.replace("-", "")
    raw = bytes.fromhex(hex_str)
    guid_le = raw[0:4][::-1] + raw[4:6][::-1] + raw[6:8][::-1] + raw[8:16]
    blob = bytes([0x00, 0xff, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00]) + guid_le + bytes(24)
    assert len(blob) == 48
    return blob


def multi_sz_hex(strings):
    data = b""
    for s in strings:
        data += s.encode("utf-16-le") + b"\x00\x00"
    data += b"\x00\x00"  # final empty-string terminator
    return ",".join(f"{b:02x}" for b in data)


def hex_bytes(data: bytes) -> str:
    return ",".join(f"{b:02x}" for b in data)


def build_reg(drv_name: str) -> str:
    preset = DRIVER_PRESETS[drv_name]
    legacy_pciid = preset["legacy_pciid"]
    modern_pciid = preset["modern_pciid"]
    drv_inf = preset["drv_inf"]
    drv_config = preset["drv_config"]
    drv_inf_label = f"{drv_inf}_{WINARCH}_0000000000000000"
    blob = version_blob(preset["class_guid"])

    lines = ["Windows Registry Editor Version 5.00", ""]

    # Services key - common to both the legacy CriticalDeviceDatabase branch and
    # the modern DriverDatabase branch; this part matched Findings 7-8 already.
    # Group/Start are driver-specific (confirmed per-driver from each driver's own
    # .inf, not assumed to carry over from viostor - see Finding 36's write-up).
    lines += [
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\{drv_name}]",
        '"Type"=dword:00000001',
        f'"Start"=dword:{preset["start"]:08x}',
        f'"Group"="{preset["service_group"]}"',
        '"ErrorControl"=dword:00000001',
        '"ImagePath"=hex(2):' + hex_bytes(
            f"system32\\drivers\\{drv_name}.sys".encode("utf-16-le") + b"\x00\x00"
        ),
        "",
    ]

    # DriverDatabase\DriverInfFiles\<drv_inf> - AT HIVE ROOT.
    lines += [
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverInfFiles\{drv_inf}]",
        f'@=hex(7):{multi_sz_hex([drv_inf_label])}',
        f'"Active"="{drv_inf_label}"',
        f'"Configurations"=hex(7):{multi_sz_hex([drv_config])}',
        "",
    ]

    # DriverDatabase\DeviceIds\PCI\<pciid> - value name is the bare drv_inf,
    # NOT the label. One block per hardware ID variant (legacy + modern).
    for pciid in (legacy_pciid, modern_pciid):
        lines += [
            rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DeviceIds\PCI\{pciid}]",
            f'"{drv_inf}"=hex:01,ff,00,00',
            "",
        ]

    # DriverDatabase\DriverPackages\<label> - the Version blob.
    lines += [
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{drv_inf_label}]",
        f'"Version"=hex:{hex_bytes(blob)}',
        "",
    ]

    # hivexregedit requires every intermediate key to already exist before a
    # child under it can be created - it will not auto-create multiple levels
    # of nesting in one jump the way real regedit.exe does - so declare each
    # empty parent key explicitly before its populated child.
    lines += [
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{drv_inf_label}\Configurations]",
        "",
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{drv_inf_label}\Configurations\{drv_config}]",
        '"ConfigFlags"=dword:00000000',
        f'"Service"="{drv_name}"',
        "",
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{drv_inf_label}\Descriptors]",
        "",
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{drv_inf_label}\Descriptors\PCI]",
        "",
    ]
    for pciid in (legacy_pciid, modern_pciid):
        lines += [
            rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{drv_inf_label}\Descriptors\PCI\{pciid}]",
            f'"Configuration"="{drv_config}"',
            "",
        ]

    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--driver", default="viostor", choices=sorted(DRIVER_PRESETS),
                     help="which driver to generate DriverDatabase registration for (default: viostor)")
    ap.add_argument("-o", "--output", help="write to this file instead of stdout")
    args = ap.parse_args()

    reg_text = build_reg(args.driver)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(reg_text)
    else:
        print(reg_text, end="")


if __name__ == "__main__":
    main()
