#!/bin/sh
# tools/tcc_nan16_vfs_pack.sh - prove the N16PACK1 guest VFS byte encoding.
#
# The flat cartridge is a stream of 8-byte NaN16 words with the 32-bit payload
# at bits 16..47.  Raw host bytes appended to the image would not be visible to
# guest LDB, so tools/nan16_pack_image.py packs four archive bytes per payload
# word.  This gate places a known pack at guest byte 0x01000000, opens its
# files through the guest VFS, and compares every byte, including 0x00..0xFF
# and a non-ASCII blob.  It also checks libc snprintf '*' width/precision,
# including negative precision and runtime values.
#
# Product target is x86_64 bare metal.  This gate currently runs on the
# portable C core because the x86_64 S1 does not yet load guest images; the
# same flat cartridge and payload-word layout are the S1 contract.
#
#   PACK_STEPS=N  VM step budget (default 200,000,000)
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/tcc_vfs_pack.$$"; mkdir -p "$T"
trap 'if [ "${PACK_KEEP:-0}" = 1 ]; then echo "vfs_pack: kept $T"; else rm -rf "$T"; fi' EXIT
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
CLI=aarch64/android/nan_cli
STEPS=${PACK_STEPS:-200000000}
BASE=0x01000000
MAX_IMAGE=134217728

[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "vfs_pack: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl

python3 - "$T" <<'EOF'
import sys
t = sys.argv[1]
open(t + "/pattern.bin", "wb").write(bytes(range(256)))
open(t + "/nonascii.bin", "wb").write(
    bytes([0xde, 0xad, 0xbe, 0xef, 0x00, 0x80, 0xff, 0x7f, 0x0a, 0x0d, 0xc3, 0xa9]))
open(t + "/small.txt", "wb").write(b"hi\n")
EOF

echo "vfs_pack: build N16PACK1 archive"
python3 tools/nan16_suite_pack.py "$T/test.n16pack" \
    --file "/test/pattern.bin=$T/pattern.bin" \
    --file "/test/nonascii.bin=$T/nonascii.bin" \
    --file "/test/small.txt=$T/small.txt" --check

# Report the exact byte offset of the non-ASCII file inside the pack.  The
# N16PACK1 header/names make it unaligned, so its bytes cross payload-word
# boundaries; the guest probe compares every one of them.
python3 - "$T/test.n16pack" <<'EOF'
import struct, sys
d = open(sys.argv[1], "rb").read()
off = 12
while off < len(d):
    nl, flags, dl = struct.unpack_from("<HHI", d, off)
    off += 8
    name = d[off:off+nl].decode()
    data_off = off + nl
    print("vfs_pack: %s at pack offset %d (mod4=%d), %d bytes" %
          (name, data_off, data_off & 3, dl))
    if name == "/test/nonascii.bin" and (data_off & 3) == 0:
        sys.exit("vfs_pack: non-ASCII file is word-aligned; test is weaker")
    off = data_off + dl
if off != len(d):
    sys.exit("vfs_pack: pack parse mismatch")
EOF

python3 tools/nan16_pack_image.py "$T/test.n16pack" \
    --header "$T/guest_pack.h" --encoded "$T/test.pack.enc"

# Layout tests: the raw length alone would fit, but the packed guest span does
# not; the encoded host image must also fit its own budget.
if python3 tools/nan16_pack_image.py "$T/test.n16pack" \
    --header "$T/overflow.h" --limit 0x01000165 >/dev/null 2>"$T/layout1.err"; then
    echo "vfs_pack: FAIL (rounded pack span crossed limit but was accepted)"
    exit 1
fi
grep -q 'exceeds limit' "$T/layout1.err" || {
    echo "vfs_pack: FAIL (unexpected layout error)"; cat "$T/layout1.err"; exit 1; }
if python3 tools/nan16_pack_image.py "$T/test.n16pack" \
    --header "$T/overflow.h" --base 0x00800000 >/dev/null 2>"$T/layout3.err"; then
    echo "vfs_pack: FAIL (pack base inside stack was accepted)"; exit 1
fi
if python3 tools/nan16_pack_image.py "$T/test.n16pack" \
    --header "$T/overflow.h" --base 0x05000000 >/dev/null 2>"$T/layout4.err"; then
    echo "vfs_pack: FAIL (pack base inside heap was accepted)"; exit 1
fi
echo "vfs_pack: layout guards PASS"

echo "vfs_pack: build guest probe"
"$T/tcc0" -nostdlib -o "$T/probe.raw.bin" -I"$T" -I"$LIBC/include" \
    -I"$TT/include" -I"$TT" "$LIBC/src/libc.c" src/tests/tcc/vfs_pack_probe.c
[ -s "$T/probe.raw.bin" ] || { echo "vfs_pack: FAIL (empty probe image)"; exit 1; }

if python3 tools/nan16_pack_image.py "$T/test.n16pack" \
    --header "$T/overflow.h" --image "$T/probe.raw.bin" --out "$T/nope.bin" \
    --max-image 2000000 >/dev/null 2>"$T/layout2.err"; then
    echo "vfs_pack: FAIL (encoded image exceeded host budget but was accepted)"
    exit 1
fi
grep -q 'exceeds budget' "$T/layout2.err" || {
    echo "vfs_pack: FAIL (unexpected image-budget error)"; cat "$T/layout2.err"; exit 1; }

python3 tools/nan16_pack_image.py "$T/test.n16pack" \
    --header "$T/guest_pack.h" --image "$T/probe.raw.bin" --out "$T/probe.bin" \
    --base "$BASE"

echo "vfs_pack: run byte comparison in the guest"
timeout 300 "$CLI" --img "$T/probe.bin" --mem 128 --steps "$STEPS" \
    --peek '0x100:1,0x0BFFFFC:1' > "$T/run.txt" 2> "$T/run.err" || true
rc_word=$(head -n 1 "$T/run.txt")
marker=$(tail -n 1 "$T/run.txt")
[ "$rc_word" = "00000000" ] || {
    echo "vfs_pack: FAIL (probe returned '$rc_word')"; tail -5 "$T/run.err"; exit 1; }
[ "$marker" = "00000001" ] || {
    echo "vfs_pack: FAIL (completion marker '$marker')"; tail -5 "$T/run.err"; exit 1; }


echo "vfs_pack: 2,133-file, 25,806,592-byte suite-sized pack"
python3 - "$T/many" <<'PY'
import os, sys
root = sys.argv[1]
os.makedirs(root, exist_ok=True)
name = lambda i: "/many/f%04d.bin" % i
overhead = 12 + 2133 * (8 + len(name(0)))
tail = 5 * 2132
first = 25806592 - overhead - tail
if first <= 0:
    sys.exit("bad suite-size arithmetic")
with open(os.path.join(root, "f0000.bin"), "wb") as f:
    f.truncate(first)
for i in range(1, 2133):
    with open(os.path.join(root, "f%04d.bin" % i), "wb") as f:
        f.write(bytes([i & 0xff, (i >> 8) & 0xff, 0, 0, 0x80]))
PY
python3 tools/nan16_suite_pack.py "$T/many.n16pack" --tree "$T/many=/many" --check
[ "$(wc -c < "$T/many.n16pack")" = 25806592 ] || {
    echo "vfs_pack: FAIL (suite pack size mismatch)"; exit 1; }
mkdir -p "$T/many_inc"
python3 tools/nan16_pack_image.py "$T/many.n16pack" \
    --header "$T/many_inc/guest_pack.h" --base "$BASE" --max-image "$MAX_IMAGE" > "$T/many.layout"
cat "$T/many.layout"
grep -q '0x1000000..0x289c700' "$T/many.layout" || {
    echo "vfs_pack: FAIL (unexpected suite guest span)"; exit 1; }
if python3 tools/nan16_pack_image.py "$T/many.n16pack" \
    --header "$T/many_inc/guest_pack.h" --max-image 80000000 >/dev/null 2>"$T/layout5.err"; then
    echo "vfs_pack: FAIL (suite encoded image exceeded budget but was accepted)"
    exit 1
fi
grep -q 'exceeds budget' "$T/layout5.err" || {
    echo "vfs_pack: FAIL (unexpected suite budget error)"; cat "$T/layout5.err"; exit 1; }
echo "vfs_pack: 25.8 MB suite layout PASS"
"$T/tcc0" -nostdlib -DVFS_PACK_MANY -DMANY_COUNT=2133 -DMANY_I=2132 \
    -o "$T/many.raw.bin" -I"$T/many_inc" -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$LIBC/src/libc.c" src/tests/tcc/vfs_pack_probe.c
python3 tools/nan16_pack_image.py "$T/many.n16pack" \
    --header "$T/many_inc/guest_pack.h" --image "$T/many.raw.bin" --out "$T/many.bin" \
    --base "$BASE" --max-image "$MAX_IMAGE" >/dev/null
timeout 600 "$CLI" --img "$T/many.bin" --mem 128 --steps 2000000000 \
    --peek '0x100:1,0x0BFFFFC:1' \
    --dump-bytes "0x03000000:16:$T/many.count" > "$T/many.out" 2> "$T/many.err" || true
rc=$(head -n 1 "$T/many.out"); marker2=$(tail -n 1 "$T/many.out")
[ "$rc" = "00000000" ] || {
    echo "vfs_pack: FAIL (many-file probe returned '$rc')"; tail -5 "$T/many.err"; exit 1; }
[ "$marker2" = "00000001" ] || {
    echo "vfs_pack: FAIL (many-file marker '$marker2')"; tail -5 "$T/many.err"; exit 1; }
count=$(python3 -c "import struct;d=open('$T/many.count','rb').read(16);w=struct.unpack('<4I',d);print(w[3] if w[3] else w[0])")
[ "$count" -ge 2133 ] || {
    echo "vfs_pack: FAIL (VFS count $count < 2133)"; exit 1; }
echo "vfs_pack: dynamic VFS registered $count files; last file /many/f2132.bin readable"

echo "vfs_pack: PASS (N16PACK1 bytes read back exactly; printf '*' width/precision)"
