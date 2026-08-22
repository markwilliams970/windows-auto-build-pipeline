#!/usr/bin/env python3
"""Eject one or more removable-media devices via QMP, confirming via query-block
rather than trusting the eject command's own (sometimes silent, per this project's
own Phase 3.3 sessions) immediate response.

Requires the target qemu process to have been started with a QMP socket, e.g.:
    qemu-system-x86_64 ... -qmp unix:/path/to/qmp.sock,server,nowait

Usage:
    qmp-eject.py --socket /path/to/qmp.sock --device installcd --device answercd
"""
import argparse
import json
import socket
import sys


def send(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def read_json_line(f):
    line = f.readline()
    if not line:
        raise RuntimeError("QMP socket closed unexpectedly")
    return json.loads(line)


def read_until_return(f):
    """Skip past any async events (e.g. DEVICE_TRAY_MOVED) to the command's own
    {"return": ...} reply - this project's own Phase 3.3 sessions observed the eject
    command's reply sometimes arriving interleaved with its own event, not always
    first."""
    while True:
        obj = read_json_line(f)
        if "return" in obj or "error" in obj:
            return obj


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--socket", required=True, help="Path to the QMP unix socket")
    ap.add_argument("--device", action="append", required=True, help="Device id to eject (repeatable)")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)
    f = sock.makefile("rwb", buffering=0)

    read_json_line(f)  # greeting banner

    send(sock, {"execute": "qmp_capabilities"})
    resp = read_until_return(f)
    if "error" in resp:
        sys.exit(f"qmp_capabilities failed: {resp['error']}")

    for device in args.device:
        send(sock, {"execute": "eject", "arguments": {"device": device}})
        resp = read_until_return(f)
        if "error" in resp:
            sys.exit(f"eject {device} failed: {resp['error']}")

    # Confirm via query-block rather than trusting the eject replies alone.
    send(sock, {"execute": "query-block"})
    resp = read_until_return(f)
    if "error" in resp:
        sys.exit(f"query-block failed: {resp['error']}")

    by_device = {d.get("device") or d.get("qdev", ""): d for d in resp["return"]}
    all_open = True
    for device in args.device:
        info = by_device.get(device)
        tray_open = bool(info and info.get("tray_open"))
        print(f"{device}: tray_open={tray_open}")
        all_open = all_open and tray_open

    if not all_open:
        sys.exit("ERROR: not all requested devices confirmed tray_open after eject")


if __name__ == "__main__":
    main()
