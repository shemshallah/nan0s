#!/bin/sh
# tools/tcc_nan16_multijob.sh - N16PACK1/two-job linker-state regression.
#
# The NaN16 linker keeps call/address relocation arrays and jump fixups in
# file-scope storage.  A process that compiles two independent jobs (the raw
# self-build driver does) must reset them in tcc_new(), otherwise the first
# job's relocations are applied to the second job's text at the same byte
# offsets.  This gate builds one tiny compiler with two jobs, runs both, and
# requires job a -> 0 and job b -> 42.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/tcc_multijob.$$"; mkdir -p "$T"
trap 'if [ "${MULTIJOB_KEEP:-0}" = 1 ]; then echo "multijob: kept $T"; else rm -rf "$T"; fi' EXIT
CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
CLI=aarch64/android/nan_cli
BASE=0x01000000
MEM=128

[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

echo "multijob: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl

echo "multijob: preprocess libtcc.c"
"$T/tcc0" -E -nostdinc -DTCC_TARGET_NAN16 -DONE_SOURCE -DCONFIG_TCC_STATIC \
    -DCONFIG_TCC_BACKTRACE=0 -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$TT/libtcc.c" -o "$T/libtcc.i"

echo "multijob: build two-job pack and job table"
python3 tools/nan16_suite_pack.py "$T/jobs.n16pack" \
    --file "/work/libc/libc.c=$LIBC/src/libc.c" \
    --file "/work/libc/nan16_pow10.h=$LIBC/src/nan16_pow10.h" \
    --tree "$LIBC/include=/usr/include" \
    --tree "$TT/include=/usr/lib/tcc/include" \
    --file "/work/job/a.c=src/tests/tcc/multijob_a.c" \
    --file "/work/job/b.c=src/tests/tcc/multijob_b.c" --check
mkdir -p "$T/job"
python3 tools/nan16_pack_image.py "$T/jobs.n16pack" \
    --header "$T/job/guest_pack.h" --base "$BASE" --max-image 134217728

cat > "$T/jobs.spec" <<'EOF'
job a a.bin 0x02fffff0 0x03000000
  include /work/libc
  include /usr/include
  include /usr/lib/tcc/include
  define GUEST=1
  define HEAP_SIZE=67108864
  source /work/libc/libc.c
  source /work/job/a.c
  runtime 1
job b b.bin 0x02fffff4 0x03800000
  include /work/libc
  include /usr/include
  include /usr/lib/tcc/include
  define GUEST=1
  define HEAP_SIZE=67108864
  source /work/libc/libc.c
  source /work/job/b.c
  runtime 1
EOF
python3 tools/nan16_build_job.py "$T/jobs.spec" "$T/job/guest_build_job.h"

echo "multijob: build the two-job compiler"
"$T/tcc0" -nostdlib -DNAN16_EXIT_DIAG -DHEAP_SIZE=67108864 \
    -o "$T/multijob.raw.bin" -I"$T/job" -I"$LIBC/include" -I"$TT/include" -I"$TT" \
    "$LIBC/src/libc.c" "$T/libtcc.i" "$LIBC/src/guest_build_driver.c"
python3 tools/nan16_pack_image.py "$T/jobs.n16pack" \
    --header "$T/job/guest_pack.h" --image "$T/multijob.raw.bin" \
    --out "$T/multijob.bin" --base "$BASE" --max-image 134217728 >/dev/null

echo "multijob: run both jobs"
timeout 300 "$CLI" --img "$T/multijob.bin" --mem "$MEM" --steps 2000000000 \
    --peek '0x0BFFFFC:1,0x0BFFFFD:1' --dump-bytes "0x03000000:0x100000:$T/a.bin" \
    > "$T/run.txt" 2> "$T/run.err" || true
timeout 300 "$CLI" --img "$T/multijob.bin" --mem "$MEM" --steps 2000000000 \
    --dump-bytes "0x03800000:0x100000:$T/b.bin" > /dev/null 2>> "$T/run.err" || true
sa=$(head -n 1 "$T/run.txt"); sb=$(tail -n 1 "$T/run.txt")
[ "$sa" != "00000000" ] || { echo "multijob: FAIL (job a emitted nothing)"; tail -5 "$T/run.err"; exit 1; }
[ "$sb" != "00000000" ] || { echo "multijob: FAIL (job b emitted nothing)"; tail -5 "$T/run.err"; exit 1; }
[ $((0x$sa)) -le 1048576 ] && [ $((0x$sb)) -le 1048576 ] || {
    echo "multijob: FAIL (unexpected output sizes $sa $sb)"; exit 1; }

run_ret() { # run_ret IMAGE SIZE -> return word
    "$CLI" --img "$1" --mem 64 --steps 100000 --peek '0x100:1' 2>/dev/null | tail -n 1
}
a=$(run_ret "$T/a.bin" "$sa")
b=$(run_ret "$T/b.bin" "$sb")
[ "$a" = "00000000" ] || { echo "multijob: FAIL (job a returned $a)"; exit 1; }
[ "$b" = "0000002A" ] || { echo "multijob: FAIL (job b returned $b, stale relocation?)"; exit 1; }
echo "multijob: PASS (two TCCState jobs share one process; relocations isolated)"
