#!/usr/bin/env python3
"""Type a literal ASCII string into a running QEMU VM via QMP 'sendkey', one
character at a time, then optionally press Enter. Complements qmp-sendkey.py
(which sends raw key-combo names) for typing actual command text - e.g. running
diagnostic commands in a WinPE/Setup command prompt reached via Shift+F10."""
import argparse
import json
import socket
import sys
import time

CHAR_MAP = {
    ' ': 'spc', '\\': 'backslash', ':': 'shift-semicolon', ';': 'semicolon',
    '.': 'dot', ',': 'comma', '/': 'slash', '-': 'minus', '_': 'shift-minus',
    '=': 'equal', '\n': 'ret', '>': 'shift-dot', '<': 'shift-comma',
    '"': 'shift-apostrophe', "'": 'apostrophe', '(': 'shift-9', ')': 'shift-0',
    '*': 'shift-8', '\t': 'tab', '~': 'shift-grave_accent', '$': 'shift-4',
}


def key_for(ch):
    if ch in CHAR_MAP:
        return CHAR_MAP[ch]
    if ch.isupper():
        return f"shift-{ch.lower()}"
    if ch.isalnum():
        return ch.lower()
    raise ValueError(f"no mapping for character {ch!r}")


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
    ap.add_argument("--delay", type=float, default=0.05)
    ap.add_argument("--enter", action="store_true", help="press Enter after typing")
    ap.add_argument("text")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)
    f = sock.makefile("rwb", buffering=0)
    read_json_line(f)
    send(sock, {"execute": "qmp_capabilities"})
    resp = read_json_line(f)
    if "error" in resp:
        sys.exit(f"qmp_capabilities failed: {resp['error']}")

    text = args.text + ("\n" if args.enter else "")
    for ch in text:
        k = key_for(ch)
        send(sock, {"execute": "human-monitor-command", "arguments": {"command-line": f"sendkey {k}"}})
        resp = read_json_line(f)
        if "error" in resp:
            sys.exit(f"sendkey {k} (for {ch!r}) failed: {resp['error']}")
        time.sleep(args.delay)

    print("typed", len(text), "chars")


if __name__ == "__main__":
    main()
