#!/usr/bin/env python3
"""nan16_branch_audit.py - verify the NaN16 branch encoding of a cartridge.

Usage:
  python3 tools/nan16_branch_audit.py IMAGE [TEXT_WORDS]

The compiler uses 24-bit absolute far branches (opcode 0x38; 0x39 for a far
call) and 32-bit MOVI/MOVHI + CALLR direct calls.  Legacy 16-bit 0x0A/0x0B
branches cannot reach past word 65535 and must not appear in executable text.

If TEXT_WORDS is given, every far-branch target must be inside it.  Without
it, the scan covers the whole file (data words can look like opcodes, so the
target bound is only meaningful with a text size).
"""
import struct
import sys

FAR = {0x38: "JMPF", 0x39: "CALLF"}
LEGACY = {0x0A: "JMP16", 0x0B: "CALL16"}


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = sys.argv[1]
    text_words = int(sys.argv[2], 0) if len(sys.argv) == 3 else None
    raw = open(path, "rb").read()
    if len(raw) % 8:
        print("not a NaN16 word cartridge (length is not a multiple of 8)", file=sys.stderr)
        return 2
    words = [struct.unpack_from("<Q", raw, i)[0] for i in range(0, len(raw), 8)]
    limit = text_words if text_words is not None else len(words)
    counts = {}
    bad = []
    over = 0
    for pc in range(min(limit, len(words))):
        p = (words[pc] >> 16) & 0xFFFFFFFF
        op = p >> 24
        if op in LEGACY:
            counts[LEGACY[op]] = counts.get(LEGACY[op], 0) + 1
            bad.append((pc, "legacy %s" % LEGACY[op], p & 0xFFFF))
        elif op in FAR:
            name = FAR[op]
            counts[name] = counts.get(name, 0) + 1
            target = p & 0xFFFFFF
            if target > 0xFFFF:
                over += 1
            if text_words is not None and target >= text_words:
                bad.append((pc, name, target))
    print("image=%s words=%d audited=%d" % (path, len(words), limit))
    for name in sorted(counts):
        print("  %-6s %d" % (name, counts[name]))
    print("  far targets >64k words: %d" % over)
    if bad:
        for pc, what, target in bad[:20]:
            print("  BAD pc=%d %s target=%s" % (pc, what, target))
        print("FAIL")
        return 1
    print("PASS (no legacy 16-bit branches; far targets in range)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
