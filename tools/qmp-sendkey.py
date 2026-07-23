#!/usr/bin/env python3
"""Send one or more key combos to a running QEMU VM via QMP's human-monitor-command
'sendkey', for interacting with a GUI that has no other automation path (e.g. WinPE's
Shift+F10 command prompt during Windows Setup, or tabbing/entering through a dialog).

Complements qmp-screenshot.py (capture) and qmp-type.py (typing literal text) - together
these are the toolkit for driving a QEMU guest's GUI without a VNC viewer or any
Packer-managed qemuargs reconstruction (see CLAUDE.md's QMP caveat for ad hoc invocations).

Usage:
    qmp-sendkey.py --socket /path/to/qmp.sock keycombo1 keycombo2 ...

Each keycombo is QEMU monitor 'sendkey' syntax, e.g.: shift-f10, ret, tab, down, right
Multiple keycodes joined with '-' are pressed together (e.g. shift-f10).
"""
import argparse
import json
import socket
import sys
import time


def send(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def read_json_line(f):
    line = f.readline()
    if not line:
        raise RuntimeError("QMP socket closed unexpectedly")
    return json.loads(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--socket", required=True)
    ap.add_argument("--delay", type=float, default=0.08, help="seconds between keys")
    ap.add_argument("keys", nargs="+")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)
    f = sock.makefile("rwb", buffering=0)
    read_json_line(f)
    send(sock, {"execute": "qmp_capabilities"})
    resp = read_json_line(f)
    if "error" in resp:
        sys.exit(f"qmp_capabilities failed: {resp['error']}")

    for k in args.keys:
        send(sock, {"execute": "human-monitor-command", "arguments": {"command-line": f"sendkey {k}"}})
        resp = read_json_line(f)
        if "error" in resp:
            sys.exit(f"sendkey {k} failed: {resp['error']}")
        time.sleep(args.delay)

    print("sent", len(args.keys), "keys")


if __name__ == "__main__":
    main()
