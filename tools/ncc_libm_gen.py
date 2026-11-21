#!/usr/bin/env python3
"""ncc_libm_gen.py - corpus and guest-source generator for tools/ncc_libm_exact.sh.

Subcommands:
  corpus            (re)write the checked-in corpus files in src/tests/
  nas OUT.nas       write the ncc guest program that evaluates the corpus

The corpus files are plain text:
  ncc_libm_corpus.txt          one binary32 input (8 hex digits) per line;
                               each value is fed to both sin() and cos()
  ncc_libm_unary_corpus.txt    "<fabs|sqrt|floor|ceil|trunc|round> <bits>"
  ncc_libm_fmod_corpus.txt     "<xbits> <ybits>"

Only the guest program is generated at gate time; the expected file is a
checked-in artifact produced by host clang (tools/ncc_libm_ref.c).
"""
import math
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TESTS = os.path.join(ROOT, "src", "tests")
CORPUS = os.path.join(TESTS, "ncc_libm_corpus.txt")
UNARY = os.path.join(TESTS, "ncc_libm_unary_corpus.txt")
FMOD = os.path.join(TESTS, "ncc_libm_fmod_corpus.txt")

F32 = lambda x: struct.unpack("<f", struct.pack("<f", float(x)))[0]
BITS = lambda x: struct.unpack("<I", struct.pack("<f", float(x)))[0]
FLT = lambda b: struct.unpack("<f", struct.pack("<I", b & 0xFFFFFFFF))[0]
def finite(x):
    return math.isfinite(x)


def _f32_ulp_bits(bits, n):
    """Move a binary32 value by n representable steps, away from zero for n>0."""
    sign = bits & 0x80000000
    mag = bits & 0x7FFFFFFF
    mag = max(0, min(0x7F800000, mag + n))
    return sign | mag


def make_corpus(seed=0x5EED):
    rng = random.Random(seed)
    sc = []

    # Dense grid over [-2*pi, 2*pi] (2501 values, about 0.0025 apart).
    for i in range(2501):
        sc.append(BITS(-2.0 * math.pi + i * (4.0 * math.pi / 2500.0)))

    # Random binary32 values in [-100,100].
    n0 = len(sc)
    while len(sc) - n0 < 3000:
        x = FLT(rng.getrandbits(32))
        if finite(x) and abs(x) <= 100.0:
            sc.append(BITS(x))

    # Around multiples of pi/2: +-0..3 ulp and +-1e-5/1e-4 absolute offsets.
    seen = set(sc)
    for k in range(-63, 64):
        base = F32(k * math.pi / 2.0)
        bb = BITS(base)
        for d in (-3, -2, -1, 0, 1, 2, 3):
            b = _f32_ulp_bits(bb, d)
            if b not in seen:
                seen.add(b)
                sc.append(b)
        for d in (-1e-4, -1e-5, 1e-5, 1e-4):
            b = BITS(F32(base + d))
            if b not in seen:
                seen.add(b)
                sc.append(b)

    # Larger, still in the documented exact range |x| <= 65536.
    n1 = len(sc)
    while len(sc) - n1 < 1000:
        x = rng.uniform(100.0, 65536.0)
        if rng.random() < 0.5:
            x = -x
        sc.append(BITS(F32(x)))

    # Fixed edge values.
    for x in (0.0, -0.0, 1.0, -1.0, 0.5, -0.5,
              math.pi / 2.0, -math.pi / 2.0, math.pi, -math.pi,
              2.0 * math.pi, -2.0 * math.pi, 65536.0, -65536.0):
        sc.append(BITS(F32(x)))

    unary = []
    rngu = random.Random(seed ^ 0x1234)
    vals = []
    while len(vals) < 800:
        x = FLT(rngu.getrandbits(32))
        if finite(x):
            vals.append(BITS(x))
    for x in (0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.5, -2.5,
              3.5, -3.5, 8388608.0, -8388608.0, 16777216.0, -16777216.0,
              1e20, -1e20, 3.4028234663852886e38, -3.4028234663852886e38):
        vals.append(BITS(F32(x)))
    # sqrt gets its own non-negative inputs; keep this group first so the
    # corpus order matches the generated guest program's loop order.
    sq = [BITS(0.0), BITS(1.0), BITS(2.0), BITS(4.0), BITS(1e-30),
          BITS(3.4028234663852886e38), BITS(float("inf"))]
    while len(sq) < 500:
        x = FLT(rngu.getrandbits(32) & 0x7FFFFFFF)
        if finite(x):
            sq.append(BITS(x))
    for b in sq:
        unary.append(("sqrt", b))
    for tag in ("fabs", "floor", "ceil", "trunc", "round"):
        for b in vals:
            unary.append((tag, b))

    fmod = []
    rg = random.Random(seed ^ 0x777)
    while len(fmod) < 900:
        ea = rg.randrange(80, 145)
        eb = rg.randrange(80, 145)
        x = FLT((ea << 23) | rg.getrandbits(23))
        y = FLT((eb << 23) | rg.getrandbits(23))
        if rg.random() < 0.5:
            x = -x
        if rg.random() < 0.5:
            y = -y
        if y == 0.0 or not finite(x) or not finite(y):
            continue
        if abs(x / y) < 2.0 ** 23:
            fmod.append((BITS(x), BITS(y)))
    extra = [(5.0, 2.0), (-5.0, 2.0), (5.0, -2.0), (-5.0, -2.0),
             (6.0, 3.0), (-6.0, 3.0), (1.0, 3.0), (-1.0, 3.0),
             (0.0, 1.0), (-0.0, 1.0), (0.0, -1.0), (-0.0, -1.0),
             (1.0, float("inf")), (-1.0, float("inf")),
             (10.0, 3.0), (-10.0, 3.0), (12345.678, 1.2345)]
    for x, y in extra:
        fmod.append((BITS(F32(x)), BITS(F32(y))))
    return sc, unary, fmod


def write_corpus():
    sc, unary, fmod = make_corpus()
    with open(CORPUS, "w") as f:
        for b in sc:
            f.write("%08x\n" % b)
    with open(UNARY, "w") as f:
        for tag, b in unary:
            f.write("%s %08x\n" % (tag, b))
    with open(FMOD, "w") as f:
        for x, y in fmod:
            f.write("%08x %08x\n" % (x, y))
    print("corpus: %d sin/cos inputs, %d unary, %d fmod" %
          (len(sc), len(unary), len(fmod)))


def read_list(path):
    with open(path) as f:
        return [line.split("#")[0].strip() for line in f if line.split("#")[0].strip()]


def gen_nas(out):
    sc = read_list(CORPUS)
    un = read_list(UNARY)
    fm = read_list(FMOD)
    groups = {"fabs": [], "sqrt": [], "floor": [], "ceil": [], "trunc": [], "round": []}
    for line in un:
        tag, b = line.split()
        groups[tag].append(int(b, 16))
    fx = []
    fy = []
    for line in fm:
        a, b = line.split()
        fx.append(int(a, 16))
        fy.append(int(b, 16))

    # ncc's static-initializer machinery overflows its IR budget at roughly
    # 8.6k scalars, so the corpus is emitted as raw guest words at word 100000
    # (byte address 400000 for the C program) instead of C arrays.
    sections = [("sc", [int(x, 16) for x in sc])]
    for tag in ("sqrt", "fabs", "floor", "ceil", "trunc", "round"):
        sections.append((tag, groups[tag]))
    sections.append(("fxx", fx))
    sections.append(("fyy", fy))
    base_word = 100000
    addr = {}
    word = base_word
    for name, vals in sections:
        addr[name] = word * 4
        word += len(vals)
    names = {"sc": "sc", "sqrt": "sq", "fabs": "fa", "floor": "fl",
             "ceil": "ce", "trunc": "tr", "round": "ro",
             "fxx": "fx", "fyy": "fy"}

    src = ["#include <stdio.h>", "#include <math.h>",
           "union F{float f;unsigned u;};",
           "int main(void){int i;union F a,b,c;",
           "unsigned *sc,*sq,*fa,*fl,*ce,*tr,*ro,*fx,*fy;"]
    for name, _ in sections:
        src.append("%s=(unsigned*)%d;" % (names[name], addr[name]))
    src.append('for(i=0;i<%d;i++){a.u=sc[i];b.f=sin(a.f);printf("s %%08x %%08x\\n",a.u,b.u);'
               'b.f=cos(a.f);printf("c %%08x %%08x\\n",a.u,b.u);}' % len(sc))
    for tag in ("sqrt", "fabs", "floor", "ceil", "trunc", "round"):
        src.append('for(i=0;i<%d;i++){a.u=%s[i];b.f=%s(a.f);printf("%s %%08x %%08x\\n",a.u,b.u);}'
                   % (len(groups[tag]), names[tag], tag, tag))
    src.append('for(i=0;i<%d;i++){a.u=fx[i];c.u=fy[i];b.f=fmod(a.f,c.f);'
               'printf("fmod %%08x %%08x %%08x\\n",a.u,c.u,b.u);}' % len(fx))
    src.append("return 0;}")
    csrc = "\n".join(src) + "\n"
    esc = csrc.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    nas = (".org 0\nJMP @main\n.include \"../lib/ncc.nas\"\nmain:\n"
           "MOVI r13,1\nLA r1,@c_src\nCALL @ncc_compile\nCALL @ncc_run\nHALT\n"
           'c_src:\n.str "%s"\n' % esc)
    nas += ".org %d\ncorpus_data:\n" % base_word
    for name, vals in sections:
        for i in range(0, len(vals), 8):
            nas += ".word " + ",".join("0x%08X" % v for v in vals[i:i + 8]) + "\n"
    with open(out, "w") as f:
        f.write(nas)
    print("nas: %d sin/cos, %d unary, %d fmod, data words %d..%d" %
          (len(sc), len(un), len(fx), base_word, word - 1))


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "corpus":
        write_corpus()
    elif len(sys.argv) == 3 and sys.argv[1] == "nas":
        gen_nas(sys.argv[2])
    else:
        sys.exit("usage: ncc_libm_gen.py corpus | nas OUT.nas")
