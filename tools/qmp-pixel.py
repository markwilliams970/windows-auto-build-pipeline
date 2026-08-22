#!/usr/bin/env python3
"""Grab a QEMU framebuffer screenshot via QMP and print the RGB value of one pixel -
a cheap, OCR-free, dependency-free (stdlib zlib/struct only, no Pillow/ImageMagick)
signal for distinguishing coarse screen states during an unattended install, e.g.
"still showing Windows Setup's blue background" vs "black (rebooting/spinner)" vs
"white (reached a real desktop)". Only handles the specific PNG shape QEMU's own
screendump produces (8-bit, non-interlaced, truecolor - PNG color type 2); anything
else is a hard error rather than a silent wrong answer.

Requires the target qemu process to have been started with a QMP socket, e.g.:
    qemu-system-x86_64 ... -qmp unix:/path/to/qmp.sock,server,nowait

Usage:
    qmp-pixel.py --socket /path/to/qmp.sock --x 640 --y 400 [--keep-png /tmp/shot.png]
Prints: R G B
"""
import argparse
import json
import os
import socket
import struct
import sys
import tempfile
import zlib


def send(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def read_json_line(f):
    line = f.readline()
    if not line:
        raise RuntimeError("QMP socket closed unexpectedly")
    return json.loads(line)


def screendump(qmp_socket, out_path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(qmp_socket)
    f = sock.makefile("rwb", buffering=0)
    read_json_line(f)  # greeting
    send(sock, {"execute": "qmp_capabilities"})
    resp = read_json_line(f)
    if "error" in resp:
        sys.exit(f"qmp_capabilities failed: {resp['error']}")
    send(sock, {"execute": "screendump", "arguments": {"filename": out_path, "format": "png"}})
    resp = read_json_line(f)
    if "error" in resp:
        sys.exit(f"screendump failed: {resp['error']}")


def read_pixel_rgb(png_path, x, y):
    with open(png_path, "rb") as fh:
        data = fh.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{png_path}: not a PNG file")

    pos = 8
    idat = b""
    w = h = bitdepth = colortype = None
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8].decode("ascii")
        cdata = data[pos + 8:pos + 8 + length]
        if ctype == "IHDR":
            w, h, bitdepth, colortype, _, _, interlace = struct.unpack(">IIBBBBB", cdata)
            if interlace != 0:
                sys.exit("unsupported PNG: interlaced")
        elif ctype == "IDAT":
            idat += cdata
        pos += 8 + length + 4

    if bitdepth != 8 or colortype != 2:
        sys.exit(f"unsupported PNG: bitdepth={bitdepth} colortype={colortype} (expected 8-bit truecolor)")
    if not (0 <= x < w and 0 <= y < h):
        sys.exit(f"pixel ({x},{y}) out of bounds for {w}x{h} image")

    raw = zlib.decompress(idat)
    stride = w * 3 + 1
    prev = bytearray(w * 3)
    cur = bytearray(w * 3)
    for row_idx in range(y + 1):
        rs = row_idx * stride
        filt = raw[rs]
        cur = bytearray(raw[rs + 1:rs + 1 + w * 3])
        for i in range(w * 3):
            a = cur[i - 3] if i >= 3 else 0
            b = prev[i]
            c = prev[i - 3] if i >= 3 else 0
            if filt == 1:
                cur[i] = (cur[i] + a) & 0xFF
            elif filt == 2:
                cur[i] = (cur[i] + b) & 0xFF
            elif filt == 3:
                cur[i] = (cur[i] + (a + b) // 2) & 0xFF
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[i] = (cur[i] + pr) & 0xFF
        prev = cur

    idx = x * 3
    return tuple(cur[idx:idx + 3])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--socket", required=True, help="Path to the QMP unix socket")
    ap.add_argument("--x", type=int, required=True)
    ap.add_argument("--y", type=int, required=True)
    ap.add_argument("--keep-png", help="Also save the screendump here (default: discarded after sampling)")
    args = ap.parse_args()

    if args.keep_png:
        out_path = args.keep_png
    else:
        fd, out_path = tempfile.mkstemp(suffix=".png", prefix="qmp-pixel-")
        os.close(fd)

    try:
        screendump(args.socket, out_path)
        r, g, b = read_pixel_rgb(out_path, args.x, args.y)
        print(f"{r} {g} {b}")
    finally:
        if not args.keep_png:
            try:
                os.unlink(out_path)
            except OSError:
                pass


if __name__ == "__main__":
    main()
