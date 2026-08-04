#!/usr/bin/env python3
"""Click (or double-click) at an absolute screen position in a running QEMU VM via QMP -
no VNC viewer, no host display session required. Complements qmp-screenshot.py (capture),
qmp-sendkey.py (key combos), and qmp-type.py (literal text) for driving a GUI end-to-end.

Requires a USB tablet device on the target VM (absolute pointer) - a plain PS/2 mouse only
supports relative movement, which this project's WinPE/Setup environments do not appear to
process at all this early in boot (confirmed: relative "rel" input-send-event calls succeed
at the QMP level with no error, but the guest's on-screen cursor never moves). Add both of
these to the qemu-system-x86_64 invocation:
    -device qemu-xhci,id=usbbus -device usb-tablet,bus=usbbus.0

Usage:
    qmp-click.py --socket /path/to/qmp.sock <x> <y> [--double] [--screen WxH]
"""
import argparse
import json
import socket
import sys
import time


def send(f, obj):
    f.write((json.dumps(obj) + "\n").encode())
    f.flush()


def read(f):
    line = f.readline()
    if not line:
        raise RuntimeError("QMP socket closed unexpectedly")
    return json.loads(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--socket", required=True, help="Path to the QMP unix socket")
    ap.add_argument("x", type=int)
    ap.add_argument("y", type=int)
    ap.add_argument("--double", action="store_true", help="Send two clicks in quick succession")
    ap.add_argument("--screen", default="1280x800", help="Guest display resolution, WxH (default 1280x800)")
    args = ap.parse_args()

    screen_w, screen_h = (int(v) for v in args.screen.lower().split("x"))

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(args.socket)
    f = s.makefile("rwb")

    read(f)  # greeting
    send(f, {"execute": "qmp_capabilities"})
    resp = read(f)
    if "error" in resp:
        sys.exit(f"qmp_capabilities failed: {resp['error']}")

    ax = int(args.x * 32767 / screen_w)
    ay = int(args.y * 32767 / screen_h)

    send(f, {"execute": "input-send-event", "arguments": {"events": [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ]}})
    resp = read(f)
    if "error" in resp:
        sys.exit(f"abs move failed: {resp['error']} (is a usb-tablet device attached?)")

    clicks = 2 if args.double else 1
    for i in range(clicks):
        send(f, {"execute": "input-send-event", "arguments": {"events": [{"type": "btn", "data": {"down": True, "button": "left"}}]}})
        read(f)
        send(f, {"execute": "input-send-event", "arguments": {"events": [{"type": "btn", "data": {"down": False, "button": "left"}}]}})
        read(f)
        if i + 1 < clicks:
            time.sleep(0.1)

    print(f"{'double-' if args.double else ''}clicked ({args.x}, {args.y})")


if __name__ == "__main__":
    main()
