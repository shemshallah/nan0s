#!/usr/bin/env python3
"""Dump the NaN16 guest console buffer from a NAN1 checkpoint.

The libc console control block is four u32 at guest bytes 0x03EFF000:
stdout pointer, stdout length, stderr pointer, stderr length.  Guest pointers
are byte addresses; a guest byte A lives in word A//4, payload byte A%4, and
the payload occupies bytes 2..5 of the little-endian 8-byte word.
"""
import argparse
import struct
import sys

PAGE = 4096


def load_pages(path):
    d = open(path, "rb").read()
    if d[:4] != b"NAN1":
        sys.exit("not a NAN1 state")
    ver, scal = struct.unpack_from("<II", d, 4)
    off = 12 + scal
    nm, nv = struct.unpack_from("<II", d, off)
    off += 8
    pages = {}
    for _ in range(nm):
        ix = struct.unpack_from("<I", d, off)[0]
        off += 4
        pages[ix] = d[off:off + PAGE]
        off += PAGE
    return pages


def guest_byte(pages, a):
    wi = a // 4
    p = (wi * 8) // PAGE
    o = (wi * 8) % PAGE + 2 + (a % 4)
    page = pages.get(p)
    if page is None or o >= len(page):
        return 0
    return page[o]


def guest_u32(pages, a):
    return sum(guest_byte(pages, a + i) << (8 * i) for i in range(4))


def guest_bytes(pages, a, n):
    return bytes(guest_byte(pages, a + i) for i in range(n))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("state")
    ap.add_argument("--tail", type=int, default=30)
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    pages = load_pages(args.state)
    for name, ctl in (("stdout", 0x03EFF000), ("stderr", 0x03EFF008)):
        ptr = guest_u32(pages, ctl)
        n = guest_u32(pages, ctl + 4)
        print("%s ptr=%#x len=%d" % (name, ptr, n), file=sys.stderr)
        if not ptr or n > 64 * 1024 * 1024:
            continue
        data = guest_bytes(pages, ptr, n)
        if args.out:
            open(args.out + "." + name, "wb").write(data)
        text = data.decode("utf-8", "replace")
        lines = text.splitlines()
        print("--- %s tail ---" % name)
        for line in lines[-args.tail:]:
            print(line)


if __name__ == "__main__":
    main()
