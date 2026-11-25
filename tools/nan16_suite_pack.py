#!/usr/bin/env python3
"""nan16_suite_pack.py OUT.n16pack [--tree DIR=PREFIX ...] [--file NAME=PATH ...]

Build an N16PACK1 guest suite image (see PACK_FORMAT.md).  Paths inside the
image are absolute guest paths; nothing host-specific is stored.
"""
import argparse
import os
import struct
import sys

MAGIC = b"N16PACK1"
SKIP_SUFFIX = {
    ".o", ".obj", ".exe", ".dll", ".so", ".dylib", ".a", ".lib",
    ".zip", ".gz", ".tgz", ".bz2", ".xz", ".output", ".db", ".pyc",
    ".n16pack", ".test.db",
}


def add_file(files, name, path):
    if not name.startswith("/"):
        raise SystemExit("pack: guest name must be absolute: %r" % name)
    nb = name.encode("utf-8")
    if not (0 < len(nb) < 128):
        raise SystemExit("pack: bad name length %d: %r" % (len(nb), name))
    data = open(path, "rb").read()
    if len(data) > 0xFFFFFFFF:
        raise SystemExit("pack: file too large: %s" % path)
    files.append((name, data))


def build(out, files):
    files.sort(key=lambda x: x[0])
    names = [n for n, _ in files]
    if len(names) != len(set(names)):
        raise SystemExit("pack: duplicate guest paths")
    if len(files) > 0xFFFFFFFF:
        raise SystemExit("pack: too many files")
    with open(out, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<I", len(files)))
        for name, data in files:
            nb = name.encode("utf-8")
            f.write(struct.pack("<HHI", len(nb), 0, len(data)))
            f.write(nb)
            f.write(data)
    return len(files), os.path.getsize(out)


def check(path):
    data = open(path, "rb").read()
    if len(data) < 12 or data[:8] != MAGIC:
        raise SystemExit("pack: bad magic")
    count = struct.unpack_from("<I", data, 8)[0]
    off = 12
    seen = set()
    for i in range(count):
        if off + 8 > len(data):
            raise SystemExit("pack: truncated header at %d" % off)
        nl, flags, dl = struct.unpack_from("<HHI", data, off)
        off += 8
        if not (0 < nl < 128) or off + nl + dl > len(data):
            raise SystemExit("pack: bad entry %d at %d" % (i, off))
        name = data[off:off + nl].decode("utf-8")
        if name in seen:
            raise SystemExit("pack: duplicate %r" % name)
        seen.add(name)
        off += nl + dl
    if off != len(data):
        raise SystemExit("pack: %d trailing bytes" % (len(data) - off))
    return count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--tree", action="append", default=[], help="DIR=PREFIX")
    ap.add_argument("--file", action="append", default=[], help="NAME=PATH")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    files = []
    for spec in args.tree:
        root, prefix = spec.split("=", 1)
        root = os.path.abspath(root)
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if d != ".git")
            for fn in sorted(filenames):
                path = os.path.join(dirpath, fn)
                if os.path.splitext(fn)[1].lower() in SKIP_SUFFIX:
                    continue
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                add_file(files, prefix.rstrip("/") + "/" + rel, path)
    for spec in args.file:
        name, path = spec.split("=", 1)
        add_file(files, name, path)

    if not files:
        raise SystemExit("pack: no input files")
    n, size = build(args.out, files)
    if args.check:
        c = check(args.out)
        if c != n:
            raise SystemExit("pack: check count mismatch")
    print("pack: %d files, %d bytes -> %s" % (n, size, args.out))


if __name__ == "__main__":
    main()
