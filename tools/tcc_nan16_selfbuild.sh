#!/bin/sh
# tools/tcc_nan16_selfbuild.sh - tcc1 raw-source self-build and SQLite scale gate.
#
# Stage 1 (C1b): tcc1 (the self-hosted libtcc built by tcc0) reads the raw TCC
# source tree from an N16PACK1 guest VFS archive and compiles raw libtcc.c,
# raw libc.c and the generic build driver into a replacement compiler R.
# Stage 2: R compiles raw test.c to a 42 cartridge, then compiles the vendored
# SQLite 3.54.1 amalgamation + nan16_vfs.c + a SQL probe from the same VFS
# format into a runnable cartridge and runs the probe.
#
# The pack sits at guest byte 0x01000000 and is encoded four archive bytes per
# 32-bit payload word (see tools/nan16_pack_image.py).  Memory map:
#   0x00000000 compiler image; 0x00800000 stack floor; SP top 0x00c00000
#   0x00c00000-0x00ffffff reserved for S1 trap/kernel
#   0x01000000 low pack base (this gate; <= 0x03000000)
#   0x03000000 job 0 output, 0x03800000 job 1 output (8 MiB each)
#   0x03e00000 diagnostics, 0x03f00000 progress, 0x04000000 heap (128 MiB)
# The suite-sized 25.8 MB pack is checked by tools/tcc_nan16_vfs_pack.sh.
#
# Product target is x86_64 bare metal.  The portable C core is the current
# conformance oracle because the x86_64 S1 does not yet load guest images; the
# flat cartridge, payload-word encoding and this memory contract are shared.
#
#   SELFBUILD_DIR=...        persistent, resumable state directory
#   SB_BUILD_STEPS=N         builder-B budget (default 8,000,000,000)
#   SB_RUN_STEPS=N           replacement-compiler budget (default 40,000,000,000)
#   SB_SQL_STEPS=N           probe execution budget (default 2,000,000,000)
#   SB_SLICE=N               cumulative steps per checkpoint (default 4,000,000,000)
#   SB_REBUILD=1             discard build and self-build checkpoints
#   SB_SKIP_SQL=1            stop after the test.c proof
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
KEEP=${SB_KEEP:-0}
if [ -n "${SELFBUILD_DIR:-}" ]; then
    T=$SELFBUILD_DIR
    mkdir -p "$T"
    KEEP=1
else
    T="${TMPDIR:-/tmp}/tcc_selfbuild.$$"
    mkdir -p "$T"
fi
cleanup() {
    if [ "$KEEP" = 1 ]; then echo "selfbuild: kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

CC=${HOST_CC:-cc}
TT=third_party/tinycc
LIBC=third_party/nan16-libc
SQL=third_party/sqlite
CLI=aarch64/android/nan_cli
BASE=0x01000000
MAX_IMAGE=134217728
MEM=192
STEPS_BUILD=${SB_BUILD_STEPS:-8000000000}
STEPS_RUN=${SB_RUN_STEPS:-40000000000}
STEPS_SQL=${SB_SQL_STEPS:-2000000000}
if [ -f "$T/slice" ]; then
    SLICE=$(cat "$T/slice")
else
    SLICE=${SB_SLICE:-4000000000}
    printf '%s\n' "$SLICE" > "$T/slice"
fi

[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)

if [ "${SB_REBUILD:-0}" = 1 ]; then
    rm -f "$T"/builder.* "$T"/R.* "$T"/b_state*.nan1 "$T"/b_prog*.bin \
          "$T"/b_size*.txt "$T"/r_state*.nan1 "$T"/r_prog*.bin \
          "$T"/r_sizes*.txt "$T"/*.done
fi

echo "selfbuild: build tcc0"
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc0" -lm -ldl

# ------------------------------------------------------------------ sources
mkdir -p "$T/tcc_raw" "$T/job_b" "$T/job_r" "$T/pack_b" "$T/pack_j"
if [ ! -f "$T/R.raw" ]; then
    for f in libtcc.c tccpp.c tccgen.c tccdbg.c tccasm.c tccelf.c tccrun.c \
             nan16-gen.c nan16-link.c tcc.h libtcc.h tcctok.h elf.h dwarf.h \
             stab.h stab.def nan16-abi.h nan16-runtime.h tcclib.h tccdefs_.h; do
        cp "$TT/$f" "$T/tcc_raw/$f"
    done
    cat > "$T/tcc_raw/config.h" <<'EOF'
/* Minimal guest configuration for the raw TCC source tree.  Generated here
   instead of copying a host config.h so no host path can enter the image. */
#define TCC_VERSION "0.9.28rc"
#ifndef CONFIG_SYSROOT
#define CONFIG_SYSROOT "/usr"
#endif
#ifndef CONFIG_TCCDIR
#define CONFIG_TCCDIR "/usr/lib/tcc"
#endif
#define CONFIG_TCC_PREDEFS 1
EOF
    if grep -R -q '/data/data' "$T/tcc_raw"; then
        echo "selfbuild: FAIL (host path in raw TCC tree)"; exit 1
    fi
fi

# --------------------------------------------------- replacement job archive
if [ ! -f "$T/R.raw" ]; then
    echo "selfbuild: build N16PACK1 runtime archive for the replacement compiler"
    python3 tools/nan16_suite_pack.py "$T/pack_j/runtime.n16pack" \
        --file "/work/libc/libc.c=$LIBC/src/libc.c" \
        --file "/work/libc/nan16_pow10.h=$LIBC/src/nan16_pow10.h" \
        --tree "$LIBC/include=/usr/include" \
        --tree "$TT/include=/usr/lib/tcc/include" \
        --file "/work/sqlite/sqlite3.c=$SQL/sqlite3.c" \
        --file "/work/sqlite/sqlite3.h=$SQL/sqlite3.h" \
        --file "/work/sqlite/sqlite3ext.h=$SQL/sqlite3ext.h" \
        --file "/work/sqlite/nan16_vfs.c=$SQL/nan16_vfs.c" \
        --file "/work/job/test.c=src/tests/tcc/selfbuild_test.c" \
        --file "/work/job/probe.c=src/tests/sqlite/probe.c" --check
    python3 tools/nan16_pack_image.py "$T/pack_j/runtime.n16pack" \
        --header "$T/job_r/guest_pack.h" --base "$BASE" --max-image "$MAX_IMAGE"

    cat > "$T/r.jobs" <<'EOF'
job test test.bin 0x02fffff0 0x03000000
  include /work/libc
  include /usr/include
  include /usr/lib/tcc/include
  define GUEST=1
  define HEAP_SIZE=67108864
  source /work/libc/libc.c
  source /work/job/test.c
  runtime 1
job sqlite sqlite.bin 0x02fffff4 0x03800000
  include /work/sqlite
  include /work/libc
  include /usr/include
  include /usr/lib/tcc/include
  define GUEST=1
  define SQLITE_OS_OTHER=1
  define SQLITE_THREADSAFE=0
  define SQLITE_OMIT_LOAD_EXTENSION=1
  define SQLITE_TEMP_STORE=3
  define SQLITE_OMIT_WAL=1
  define SQLITE_OMIT_LOCALTIME=1
  define SQLITE_OMIT_DEPRECATED=1
  define SQLITE_DQS=0
  define SQLITE_OMIT_SHARED_CACHE=1
  define SQLITE_MAX_MMAP_SIZE=0
  define NDEBUG=1
  define HEAP_SIZE=134217728
  source /work/sqlite/sqlite3.c
  source /work/sqlite/nan16_vfs.c
  source /work/job/probe.c
  source /work/libc/libc.c
  runtime 1
EOF
    python3 tools/nan16_build_job.py "$T/r.jobs" "$T/job_r/guest_build_job.h"

    # ------------------------------------------------ builder job archive
    echo "selfbuild: build N16PACK1 archive for the tcc1 builder"
    python3 tools/nan16_suite_pack.py "$T/pack_b/builder.n16pack" \
        --tree "$T/tcc_raw=/work/tcc" \
        --file "/work/libc/libc.c=$LIBC/src/libc.c" \
        --file "/work/libc/nan16_pow10.h=$LIBC/src/nan16_pow10.h" \
        --tree "$LIBC/include=/usr/include" \
        --tree "$TT/include=/usr/lib/tcc/include" \
        --file "/work/src/guest_build_driver.c=$LIBC/src/guest_build_driver.c" \
        --file "/work/job/guest_build_job.h=$T/job_r/guest_build_job.h" \
        --file "/work/job/guest_pack.h=$T/job_r/guest_pack.h" --check
    python3 tools/nan16_pack_image.py "$T/pack_b/builder.n16pack" \
        --header "$T/job_b/guest_pack.h" --base "$BASE" --max-image "$MAX_IMAGE"

    cat > "$T/b.jobs" <<'EOF'
job selfbuild R.bin 0x02fffff0 0x03000000
  include /work/src
  include /work/job
  include /work/tcc
  include /usr/include
  include /usr/lib/tcc/include
  define TCC_TARGET_NAN16=1
  define CONFIG_TCC_STATIC=1
  define CONFIG_TCC_BACKTRACE=0
  define NAN16_EXIT_DIAG=1
  define HEAP_SIZE=134217728
  source /work/libc/libc.c
  source /work/tcc/libtcc.c
  source /work/src/guest_build_driver.c
  runtime 1
EOF
    python3 tools/nan16_build_job.py "$T/b.jobs" "$T/job_b/guest_build_job.h"

    echo "selfbuild: preprocess the bootstrap libtcc (builder B only)"
    "$T/tcc0" -E -nostdinc -DTCC_TARGET_NAN16 -DONE_SOURCE -DCONFIG_TCC_STATIC \
        -DCONFIG_TCC_BACKTRACE=0 -I"$T/tcc_raw" -I"$LIBC/include" -I"$TT/include" \
        "$T/tcc_raw/libtcc.c" -o "$T/libtcc.i"

    echo "selfbuild: build builder B"
    "$T/tcc0" -nostdlib -DNAN16_EXIT_DIAG -DHEAP_SIZE=134217728 \
        -o "$T/builder.raw.bin" -I"$T/job_b" -I"$LIBC/include" \
        -I"$TT/include" -I"$TT" "$LIBC/src/libc.c" "$T/libtcc.i" \
        "$LIBC/src/guest_build_driver.c"
    [ -s "$T/builder.raw.bin" ] || { echo "selfbuild: FAIL (empty builder)"; exit 1; }
    python3 tools/nan16_pack_image.py "$T/pack_b/builder.n16pack" \
        --header "$T/job_b/guest_pack.h" --image "$T/builder.raw.bin" \
        --out "$T/builder.bin" --base "$BASE" --max-image "$MAX_IMAGE"
fi

# ------------------------------------------------------- stage 1: build R
if [ ! -f "$T/R.raw" ]; then
    n=0
    while [ -f "$T/b_state$((n + 1)).nan1" ] && [ -f "$T/b_prog$((n + 1)).bin" ]; do
        n=$((n + 1))
    done
    if [ "$n" -gt 0 ]; then
        state="$T/b_state$n.nan1"
    else
        state=""
    fi
    echo "selfbuild: tcc1 raw self-build (slice=$SLICE budget=$STEPS_BUILD)"
    final=""; final_size=0
    while [ $((n * SLICE)) -lt "$STEPS_BUILD" ]; do
        n=$((n + 1))
        if [ -z "$state" ]; then img="$T/builder.bin"; else img="$state"; fi
        next="$T/b_state$n.nan1"
        timeout 900 "$CLI" --img "$img" --mem "$MEM" --steps "$((n * SLICE))" \
            --state-out "$next" --dump-bytes "0x03f00000:4:$T/b_prog$n.bin" \
            --peek '0x0BFFFFC:1' > "$T/b_size$n.txt" 2> "$T/b_err$n.txt" || true
        size_hex=$(tail -n 1 "$T/b_size$n.txt")
        prog=$(python3 -c "import struct;print(struct.unpack('<I',open('$T/b_prog$n.bin','rb').read(4))[0])")
        echo "selfbuild: B slice $n spent=$((n * SLICE)) size=$size_hex progress=$prog"
        if [ "$prog" -ge 999 ]; then
            [ "$size_hex" != "00000000" ] || {
                echo "selfbuild: FAIL (builder finished with empty R)"; exit 1; }
            final="$next"; final_size=$((0x$size_hex)); break
        fi
        state="$next"
    done
    [ -n "$final" ] || {
        echo "selfbuild: PARTIAL (builder budget $STEPS_BUILD reached; state in $T)"
        exit 2
    }
    echo "selfbuild: extract replacement compiler R ($final_size bytes)"
    "$CLI" --img "$final" --mem "$MEM" --steps 10 \
        --dump-bytes "0x03000000:$final_size:$T/R.raw" >/dev/null 2>&1 || true
    [ "$(wc -c < "$T/R.raw")" = "$final_size" ] || {
        echo "selfbuild: FAIL (R extraction truncated)"; exit 1; }
    if grep -a -q '/data/data' "$T/R.raw"; then
        echo "selfbuild: FAIL (host path embedded in R)"; exit 1
    fi
    : > "$T/selfbuild.done"
else
    echo "selfbuild: reusing replacement compiler R"
fi

# R.raw is a compiler; append the raw-source pack it will read at run time.
python3 tools/nan16_pack_image.py "$T/pack_j/runtime.n16pack" \
    --header "$T/job_r/guest_pack.h" --image "$T/R.raw" --out "$T/R.bin" \
    --base "$BASE" --max-image "$MAX_IMAGE"
size=$(wc -c < "$T/R.raw")
hash=$(sha256sum "$T/R.raw" | cut -d' ' -f1)
echo "selfbuild: R (tcc1-built raw compiler) $size bytes sha256 $hash"

run_inner_test() { # run_inner_test IMAGE STATE LABEL SIZE
    img="$1"; state="$2"; label="$3"; n="$4"
    "$CLI" --img "$state" --mem "$MEM" --steps 10 \
        --dump-bytes "0x03000000:$n:$T/test.bin" >/dev/null 2>&1 || true
    [ "$(wc -c < "$T/test.bin")" = "$n" ] || {
        echo "selfbuild: FAIL ($label extraction truncated)"; exit 1; }
    ret=$("$CLI" --img "$T/test.bin" --mem 64 --steps 100000 \
        --peek '0x100:1' 2>/dev/null | tail -n 1)
    [ "$ret" = "0000002A" ] || {
        echo "selfbuild: FAIL ($label inner returned '$ret')"; exit 1; }
    echo "selfbuild: $label compiles raw test.c -> 42 ($n bytes)"
}

# ------------------------------------------------------- stage 2: run R
n=0
while [ -f "$T/r_state$((n + 1)).nan1" ] && [ -f "$T/r_prog$((n + 1)).bin" ]; do
    n=$((n + 1))
done
if [ "$n" -gt 0 ]; then state="$T/r_state$n.nan1"; else state=""; fi
echo "selfbuild: replacement compiler test+SQLite (slice=$SLICE budget=$STEPS_RUN)"
test_done=0
[ -f "$T/test.done" ] && test_done=1
final=""; final_size=0
while [ $((n * SLICE)) -lt "$STEPS_RUN" ]; do
    n=$((n + 1))
    if [ -z "$state" ]; then img="$T/R.bin"; else img="$state"; fi
    next="$T/r_state$n.nan1"
    timeout 1800 "$CLI" --img "$img" --mem "$MEM" --steps "$((n * SLICE))" \
        --state-out "$next" --dump-bytes "0x03f00000:4:$T/r_prog$n.bin" \
        --peek '0x0BFFFFC:1,0x0BFFFFD:1' > "$T/r_sizes$n.txt" 2> "$T/r_err$n.txt" || true
    size1=$(head -n 1 "$T/r_sizes$n.txt")
    size2=$(tail -n 1 "$T/r_sizes$n.txt")
    prog=$(python3 -c "import struct;print(struct.unpack('<I',open('$T/r_prog$n.bin','rb').read(4))[0])")
    echo "selfbuild: R slice $n spent=$((n * SLICE)) test=$size1 sqlite=$size2 progress=$prog"
    if [ "$test_done" = 0 ] && [ "$prog" -ge 112 ] && [ "$size1" != "00000000" ]; then
        run_inner_test "$T/R.bin" "$next" "R" "$((0x$size1))"
        test_done=1; : > "$T/test.done"
    fi
    if [ "$prog" -ge 999 ] && [ "$size2" != "00000000" ]; then
        final="$next"; final_size=$((0x$size2)); break
    fi
    state="$next"
done

if [ "$test_done" = 0 ]; then
    echo "selfbuild: PARTIAL (test.c proof not reached; state in $T)"
    exit 2
fi
if [ "${SB_SKIP_SQL:-0}" = 1 ]; then
    echo "selfbuild: PASS (raw tcc1 self-build and test.c; SQLite skipped by SB_SKIP_SQL)"
    exit 0
fi
[ -n "$final" ] || {
    echo "selfbuild: PARTIAL (SQLite build budget $STEPS_RUN reached; test PASS;"
    echo "           resume with SELFBUILD_DIR=$T and a larger SB_RUN_STEPS)"
    exit 2
}

echo "selfbuild: extract SQLite probe cartridge ($final_size bytes)"
"$CLI" --img "$final" --mem "$MEM" --steps 10 \
    --dump-bytes "0x03800000:$final_size:$T/sqlprobe.bin" >/dev/null 2>&1 || true
[ "$(wc -c < "$T/sqlprobe.bin")" = "$final_size" ] || {
    echo "selfbuild: FAIL (SQLite extraction truncated)"; exit 1; }
marker=$("$CLI" --img "$T/sqlprobe.bin" --mem "$MEM" --steps "$STEPS_SQL" \
    --peek '0x0BFFFFC:1' --dump-bytes "0x03000000:24:$T/sql.out" \
    2> "$T/sql.err" | tail -n 1)
[ "$marker" = "00000001" ] || {
    echo "selfbuild: FAIL (SQL probe did not finish: marker '$marker')"
    tail -5 "$T/sql.err"; exit 1; }
python3 - "$T/sql.out" <<'EOF'
import struct, sys
d = open(sys.argv[1], "rb").read()
w = struct.unpack("<6I", d[:24])
if w[0] != 6 or w[1] != 3 or w[2] != 0x006f7774 or \
   w[3] != 0x53514c50 or w[4] != 0 or w[5] != 0x444e4521:
    sys.exit("selfbuild: FAIL (SQL probe words %s)" % (w,))
print("selfbuild: SQL probe sum=%d count=%d max=%r magic=%08x" %
      (w[0], w[1], d[8:11].decode(), w[3]))
EOF
echo "selfbuild: PASS (tcc1 builds itself from raw sources; R compiles raw test.c to 42;"
echo "           R compiles SQLite 3.54.1 + nan16 VFS + probe from the guest VFS)"
echo "selfbuild: R $size bytes sha256 $hash"
