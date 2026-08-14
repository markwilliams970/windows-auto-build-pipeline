#!/usr/bin/env python3
"""Generate a .reg file that offline-registers the viostor (virtio-blk) boot driver
into a Windows SYSTEM hive's DriverDatabase, clearing INACCESSIBLE_BOOT_DEVICE (0x7B)
on first real boot without ever booting the target OS.

Recipe transcribed directly from virt-v2v's actual source
(libguestfs/libguestfs-common, mlcustomize/inject_virtio_win.ml,
add_guestor_to_registry/cdb_regedits/ddb_regedits), not reconstructed from memory -
see PHASE2_ENGINEERING_LOG.md Finding 29 for the full verification trail.

Key correction versus this project's own first attempt (Findings 7-8, which failed
silently): DriverDatabase lives at the SYSTEM hive ROOT (a sibling of ControlSet001),
not nested under ControlSet001\\Control - confirmed empirically via hivexsh against a
real applied image. Registering under the wrong parent is a silent no-op: hivexregedit
raises no error, and Windows never sees the registration.

Usage:
    gen-viostor-ddb-reg.py > viostor-ddb.reg
    hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\\SYSTEM' \\
        <mounted-image>/Windows/System32/config/SYSTEM viostor-ddb.reg

Also requires (not done by this script):
  - viostor.sys copied to <image>/Windows/System32/drivers/viostor.sys
  - a real BCD for the target disk (BCD-SYS or bcdboot; either has been shown to work)
"""
import argparse

DRV_NAME = "viostor"
DRV_INF = "guestor.inf"
WINARCH = "amd64"
DRV_INF_LABEL = f"{DRV_INF}_{WINARCH}_0000000000000000"
DRV_CONFIG = "guestor_conf"
LEGACY_PCIID = "VEN_1AF4&DEV_1001&REV_00"
MODERN_PCIID = "VEN_1AF4&DEV_1042&REV_01"

# 48-byte Version blob: 8-byte header + 16-byte raw SCSIAdapter class GUID
# (mixed-endian) + 24 zero bytes. "Version is necessary for Windows-Kernel-Pnp
# in w10/w2k16" per virt-v2v's own source comment.
VERSION_BLOB = bytes([
    0x00, 0xff, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x7b, 0xe9, 0x36, 0x4d, 0x25, 0xe3, 0xce, 0x11,
    0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18,
]) + bytes(24)
assert len(VERSION_BLOB) == 48


def multi_sz_hex(strings):
    data = b""
    for s in strings:
        data += s.encode("utf-16-le") + b"\x00\x00"
    data += b"\x00\x00"  # final empty-string terminator
    return ",".join(f"{b:02x}" for b in data)


def hex_bytes(data: bytes) -> str:
    return ",".join(f"{b:02x}" for b in data)


def build_reg() -> str:
    lines = ["Windows Registry Editor Version 5.00", ""]

    # Services key - common to both the legacy CriticalDeviceDatabase branch and
    # the modern DriverDatabase branch; this part matched Findings 7-8 already.
    lines += [
        r"[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\viostor]",
        '"Type"=dword:00000001',
        '"Start"=dword:00000000',
        '"Group"="SCSI miniport"',
        '"ErrorControl"=dword:00000001',
        '"ImagePath"=hex(2):' + hex_bytes(
            "system32\\drivers\\viostor.sys".encode("utf-16-le") + b"\x00\x00"
        ),
        "",
    ]

    # DriverDatabase\DriverInfFiles\guestor.inf - AT HIVE ROOT.
    lines += [
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverInfFiles\{DRV_INF}]",
        f'@=hex(7):{multi_sz_hex([DRV_INF_LABEL])}',
        f'"Active"="{DRV_INF_LABEL}"',
        f'"Configurations"=hex(7):{multi_sz_hex([DRV_CONFIG])}',
        "",
    ]

    # DriverDatabase\DeviceIds\PCI\<pciid> - value name is the bare drv_inf,
    # NOT the label. One block per hardware ID variant (legacy + modern).
    for pciid in (LEGACY_PCIID, MODERN_PCIID):
        lines += [
            rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DeviceIds\PCI\{pciid}]",
            f'"{DRV_INF}"=hex:01,ff,00,00',
            "",
        ]

    # DriverDatabase\DriverPackages\<label> - the Version blob.
    lines += [
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{DRV_INF_LABEL}]",
        f'"Version"=hex:{hex_bytes(VERSION_BLOB)}',
        "",
    ]

    # hivexregedit requires every intermediate key to already exist before a
    # child under it can be created - it will not auto-create multiple levels
    # of nesting in one jump the way real regedit.exe does - so declare each
    # empty parent key explicitly before its populated child.
    lines += [
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{DRV_INF_LABEL}\Configurations]",
        "",
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{DRV_INF_LABEL}\Configurations\{DRV_CONFIG}]",
        '"ConfigFlags"=dword:00000000',
        f'"Service"="{DRV_NAME}"',
        "",
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{DRV_INF_LABEL}\Descriptors]",
        "",
        rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{DRV_INF_LABEL}\Descriptors\PCI]",
        "",
    ]
    for pciid in (LEGACY_PCIID, MODERN_PCIID):
        lines += [
            rf"[HKEY_LOCAL_MACHINE\SYSTEM\DriverDatabase\DriverPackages\{DRV_INF_LABEL}\Descriptors\PCI\{pciid}]",
            f'"Configuration"="{DRV_CONFIG}"',
            "",
        ]

    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--output", help="write to this file instead of stdout")
    args = ap.parse_args()

    reg_text = build_reg()
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(reg_text)
    else:
        print(reg_text, end="")


if __name__ == "__main__":
    main()
