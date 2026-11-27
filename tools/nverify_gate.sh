#!/bin/sh
# tools/nverify_gate.sh - F14 reproducible-build + translation-validation gate.
#
# Scope (honest):
#   1. nmk emits the same NaN source repeatedly and under a scrubbed
#      environment: byte-identical output, no timestamp/entropy markers.
#   2. The NaN translator re-emits the same block image twice: byte-identical
#      blocks.  Small blocks are compared against hand-derived x86-64 bytes;
#      the loop block is pinned by sha256 as a regression fingerprint.
#   3. One deterministic guest image runs natively (C core) and under the
#      raw-NaN n16i interpreter.  Serial output and a 32-word trace must be
#      identical; the two step counts prove both paths actually ran.
#   4. The qgate64prog block path must still report r1=3, XPC=5 on QEMU.
#   5. Coq is used when available (targeted LiteralImageData.v kernel check);
#      otherwise COQ SKIP is printed and the Python UTM image/table/step
#      anchors are run.  No Coq theorem is claimed without coqc.
#   6. The product image is not an ELF; src outside src/tests is C-free.
#
# This gate does not prove the translator correct and does not prove the UTM
# universality theorem.  It rejects nondeterminism and checks the emitted
# bytes against small hand-computed goldens.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nverify.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

fail() { echo "nverify: FAIL: $*" >&2; exit 1; }
sha()  { sha256sum "$1" | awk '{print $1}'; }
same() { cmp -s "$1" "$2" || fail "$3"; }

emit_nmk() {
  if ! awk -f tools/nmk.awk -v CMD=emit "$1" > "$2" 2>"$2.err"; then
    cat "$2.err" >&2
    fail "nmk failed on $1"
  fi
}

emit_nmk_labels() {
  if ! awk -f tools/nmk.awk -v CMD=emit -v LABELS="$3" "$1" > "$2" 2>"$2.err"; then
    cat "$2.err" >&2
    fail "nmk failed on $1"
  fi
}

# ---- 1. reproducible assembler emission -----------------------------------
echo "== 1. reproducible nmk emission =="
emit_nmk src/tests/xlate64_test.nas "$T/xt1.nan"
emit_nmk src/tests/xlate64_test.nas "$T/xt2.nan"
if ! env -i PATH="$PATH" LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1 \
     gawk -f tools/nmk.awk -v CMD=emit src/tests/xlate64_test.nas \
     > "$T/xt3.nan" 2>"$T/xt3.err"; then
  cat "$T/xt3.err" >&2
  fail "scrubbed-environment nmk failed"
fi
same "$T/xt1.nan" "$T/xt2.nan" "two nmk runs differ (xlate64_test)"
same "$T/xt1.nan" "$T/xt3.nan" "scrubbed-environment nmk differs (xlate64_test)"
echo "xlate64_test.nan sha256 $(sha "$T/xt1.nan") (3 emissions identical)"

emit_nmk src/tests/xlate64_prog.nas "$T/xp1.nan"
emit_nmk src/tests/xlate64_prog.nas "$T/xp2.nan"
same "$T/xp1.nan" "$T/xp2.nan" "two nmk runs differ (xlate64_prog)"
echo "xlate64_prog.nan sha256 $(sha "$T/xp1.nan") (2 emissions identical)"

# ---- 2. no timestamp / entropy markers ------------------------------------
echo "== 2. timestamp/entropy marker scan =="
MARK_RE='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9]:[0-9][0-9]:[0-9][0-9]|/tmp/|TMPDIR|SOURCE_DATE_EPOCH|@[A-Z][A-Z0-9_]*@|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
scan_markers() {
  if LC_ALL=C grep -aEq "$MARK_RE" "$1"; then
    echo "markers in $1:" >&2
    LC_ALL=C grep -aEo "$MARK_RE" "$1" | head -5 >&2
    fail "timestamp/entropy marker in $1"
  fi
}
scan_markers "$T/xt1.nan"
scan_markers "$T/xp1.nan"
echo "emitted NaN text: no date/time/tmp/UUID/build markers"

# ---- 3. translator determinism and golden bytes ---------------------------
echo "== 3. translator re-emit and golden bytes =="
run_translator() { # image out peek_spec
  if ! ./aarch64/android/nan_cli --img "$1" --mem 16 --steps 100000 \
       --serial --peek "$3" > "$2" 2>"$2.err"; then
    cat "$2.err" >&2
    fail "translator execution failed for $1"
  fi
}
# --peek prints guest word payloads; rebuild the little-endian byte stream.
words_to_bytes() {
  awk 'length($0)==8 && $0 ~ /^[0-9A-F]+$/ {
         printf "%s%s%s%s", substr($0,7,2), substr($0,5,2), substr($0,3,2), substr($0,1,2)
       }' "$1" | xxd -r -p > "$2"
}
# Last 0xC3 in a 512-byte block window is the block's RET (same rule as
# qgate64prog).  Everything after it is zero padding.
last_c3() {
  od -An -v -tu1 "$1" | tr -s ' ' '\n' |
    awk 'NF { n++; if ($1 == 195) k = n } END { print k + 0 }'
}
trim_block() { # raw out
  n=$(last_c3 "$1")
  [ "$n" -gt 0 ] || fail "no RET (0xC3) in $1"
  dd if="$1" of="$2" bs=1 count="$n" 2>/dev/null
}
hexof() { xxd -p "$1" | tr -d '\n'; }

# 3a. 46-byte hand-derived golden: MOVI r1,42; ADD r1,r1,r1; XPC=0; RET.
run_translator "$T/xt1.nan" "$T/xt.peek" 0x4000:12
words_to_bytes "$T/xt.peek" "$T/xt.bin"
dd if="$T/xt.bin" of="$T/xt.block" bs=1 count=46 2>/dev/null
GOLD46='c70425040005002a0000008b0425040005008b0c250400050001c889042504000500c704250008050000000000c3'
[ "$(hexof "$T/xt.block")" = "$GOLD46" ] || {
  echo "got: $(hexof "$T/xt.block")" >&2
  fail "translator bytes differ from hand-derived 46-byte golden"
}
echo "xlate64_test block: 46 bytes == hand-derived golden"

# 3b. Three-block program emitted twice; block bytes must be identical.
run_translator "$T/xp1.nan" "$T/xp1.peek" 0x4000:2060
run_translator "$T/xp2.nan" "$T/xp2.peek" 0x4000:2060
same "$T/xp1.peek" "$T/xp2.peek" "translator re-emit differs (peek words)"
words_to_bytes "$T/xp1.peek" "$T/xp1.bin"
words_to_bytes "$T/xp2.peek" "$T/xp2.bin"
same "$T/xp1.bin" "$T/xp2.bin" "translator re-emit differs (byte stream)"

: > "$T/blocks1"
: > "$T/blocks2"
for b in 0 1 2; do
  off=$((b * 4096))
  dd if="$T/xp1.bin" of="$T/raw1.$b" bs=1 skip=$off count=512 2>/dev/null
  dd if="$T/xp2.bin" of="$T/raw2.$b" bs=1 skip=$off count=512 2>/dev/null
  trim_block "$T/raw1.$b" "$T/b1.$b"
  trim_block "$T/raw2.$b" "$T/b2.$b"
  same "$T/b1.$b" "$T/b2.$b" "block $b differs between translator runs"
  cat "$T/b1.$b" >> "$T/blocks1"
  cat "$T/b2.$b" >> "$T/blocks2"
done
same "$T/blocks1" "$T/blocks2" "translated block image is not deterministic"

sz0=$(wc -c < "$T/b1.0"); sz1=$(wc -c < "$T/b1.1"); sz2=$(wc -c < "$T/b1.2")
[ "$sz0" -eq 34 ]  || fail "block0 size $sz0 != 34"
[ "$sz1" -eq 133 ] || fail "block1 size $sz1 != 133"
[ "$sz2" -eq 12 ]  || fail "block2 size $sz2 != 12"
GOLDB0='c704250400050000000000c704250800050003000000c704250008050002000000c3'
GOLDB2='c70425000c050001000000c3'
[ "$(hexof "$T/b1.0")" = "$GOLDB0" ] || fail "block0 differs from hand-derived golden"
[ "$(hexof "$T/b1.2")" = "$GOLDB2" ] || fail "block2 differs from hand-derived golden"
echo "blocks: 34/133/12 bytes; block0+block2 hand-derived, block1 sha256 $(sha "$T/b1.1")"
echo "translated image sha256 $(sha "$T/blocks1") (2 runs identical)"
scan_markers "$T/xt.block"
scan_markers "$T/blocks1"
echo "translated bytes: no timestamp/entropy markers"

# ---- 4. native NaN16 vs raw-NaN n16i differential ------------------------
echo "== 4. native vs n16i differential (nverify_prog) =="
emit_nmk_labels src/tests/nverify_prog.nas "$T/nv.nan" "$T/nv.lab"
MODE=$(awk '$1=="mode"{print $2}' "$T/nv.lab")
[ -n "$MODE" ] || fail "nverify_prog: mode label missing"
for m in 0 1; do
  cp "$T/nv.nan" "$T/nv$m.nan"
  printf '.org %d\n7FF8_%08X_F87F\n' "$MODE" "$m" >> "$T/nv$m.nan"
  if ! timeout 60 ./aarch64/android/nan_cli --img "$T/nv$m.nan" \
       --steps 2000000 --serial --peek 0x2040:32 \
       > "$T/nv$m.out" 2>"$T/nv$m.err"; then
    cat "$T/nv$m.err" >&2
    fail "nverify_prog mode $m did not finish"
  fi
  sed -n 's/.*: \([0-9][0-9]*\) steps, rc=\([0-9][0-9]*\).*/\1 \2/p' \
    "$T/nv$m.err" > "$T/nv$m.steps"
  [ -s "$T/nv$m.steps" ] || { cat "$T/nv$m.err" >&2; fail "mode $m: no step record"; }
  msteps=$(awk '{print $1}' "$T/nv$m.steps")
  mrc=$(awk '{print $2}' "$T/nv$m.steps")
  case "$msteps" in ''|*[!0-9]*) fail "mode $m: bad step count '$msteps'";; esac
  [ "$mrc" -eq 3 ] || fail "mode $m: rc=$mrc, expected HALT rc=3"
  if [ "$m" = 0 ]; then N0=$msteps; else N1=$msteps; fi
  grep -E '^[0-9A-F]{8}$' "$T/nv$m.out" > "$T/nv$m.trace" || true
  grep -vE '^[0-9A-F]{8}$' "$T/nv$m.out" > "$T/nv$m.serial" || true
done
same "$T/nv0.serial" "$T/nv1.serial" "native/n16i serial output differs"
same "$T/nv0.trace"  "$T/nv1.trace"  "native/n16i 32-word trace differs"
grep -Eq '^NV[0-9A-F]{8}$' "$T/nv0.serial" || fail "unexpected serial form: $(cat "$T/nv0.serial")"
[ "$(wc -l < "$T/nv0.trace")" -eq 32 ] || fail "trace is not 32 words"
serial_hex=$(sed -n 's/^NV\([0-9A-F]\{8\}\)$/\1/p' "$T/nv0.serial")
[ "$(tail -n 1 "$T/nv0.trace")" = "$serial_hex" ] || fail "serial checksum != last trace word"
[ "$N1" -gt "$N0" ] || fail "mode 1 did not take the slower n16i interpreter path"
cat "$T/nv0.serial" "$T/nv0.trace" > "$T/nvhash0"
cat "$T/nv1.serial" "$T/nv1.trace" > "$T/nvhash1"
same "$T/nvhash0" "$T/nvhash1" "native/n16i trace hash differs"
echo "native: $N0 steps | n16i: $N1 steps | trace sha256 $(sha "$T/nvhash0")"
echo "serial/trace identical: $(cat "$T/nv0.serial")"
for m in 0 1; do
  if ! timeout 60 ./aarch64/android/nan_cli --img "$T/nv$m.nan" \
       --steps 2000000 --serial --peek 0x2040:32 \
       > "$T/nv$m.replay" 2>"$T/nv$m.replay.err"; then
    cat "$T/nv$m.replay.err" >&2
    fail "mode $m replay did not finish"
  fi
  same "$T/nv$m.out" "$T/nv$m.replay" "mode $m is not replay-deterministic"
done
echo "replay: native and n16i each byte-identical across 2 runs"

# ---- 5. native/block path (qgate64prog) ----------------------------------
echo "== 5. native block path =="
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
  if ! out=$(sh tools/qgate64prog.sh 2>&1); then
    printf '%s\n' "$out" >&2
    fail "qgate64prog"
  fi
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -q 'PASS (NaN 3-block loop -> native dispatch, r1=3, XPC=5)' ||
    fail "qgate64prog did not report r1=3, XPC=5"
else
  echo "QEMU SKIP (no qemu-system-x86_64; block path not exercised)"
fi

# ---- 6. Coq / UTM anchors ------------------------------------------------
echo "== 6. Coq / UTM =="
if command -v coqc >/dev/null 2>&1 && command -v coq_makefile >/dev/null 2>&1; then
  echo "coqc: $(coqc --version 2>/dev/null | head -1)"
  cp formal/utm/LiteralImageData.v "$T/LiteralImageData.v"
  echo "COQ CMD (targeted): coqc -Q . NaNLM LiteralImageData.v"
  if (cd "$T" && timeout 600 coqc -Q . NaNLM LiteralImageData.v) \
       > "$T/coq.log" 2>&1; then
    echo "COQ PASS (targeted: LiteralImageData.v -> literal_image_length; UTM universality cone NOT built)"
  else
    cat "$T/coq.log" >&2
    fail "coqc LiteralImageData.v"
  fi
else
  echo "COQ SKIP (no coqc/coq_makefile on PATH; formal/utm not kernel-checked here)"
  echo "COQ not run: (cd formal/utm && make) ; make check"
fi
# These are source/byte anchors, not Coq kernel checks.
python3 formal/utm/check_nan16_literal_image.py > "$T/utm_img.log" 2>&1 ||
  { cat "$T/utm_img.log" >&2; fail "UTM literal image anchor"; }
tail -1 "$T/utm_img.log"
python3 formal/utm/check_minsky_table.py > "$T/utm_tab.log" 2>&1 ||
  { cat "$T/utm_tab.log" >&2; fail "Minsky table anchor"; }
tail -1 "$T/utm_tab.log"
python3 formal/utm/check_minsky_nan16_step.py > "$T/utm_step.log" 2>&1 ||
  { cat "$T/utm_step.log" >&2; fail "NaN16 step theorem transcription anchor"; }
tail -1 "$T/utm_step.log"

# ---- 7. product image is not ELF; C-free product source ------------------
echo "== 7. product image and source rule =="
[ -f build/nan0s.img ] || sh tools/mkall.sh >/dev/null
check_not_elf() {
  [ -f "$1" ] || fail "missing $1"
  magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
  [ "$magic" != "7f454c46" ] || fail "$1 has ELF magic"
  echo "$1: $(wc -c < "$1") bytes, magic $magic (not ELF)"
}
check_not_elf build/nan0s.img
if [ -f build/base.img ]; then check_not_elf build/base.img; fi
scan_markers build/nan0s.img
echo "product image: no timestamp/entropy markers"
[ "$(od -An -tx1 -N4 "$T/xt.block" | tr -d ' \n')" != "7f454c46" ] ||
  fail "translated block has ELF magic"
if ! c_out=$(sh tools/no_c_outside_tests.sh 2>&1); then
  printf '%s\n' "$c_out" >&2
  fail "no_c_outside_tests"
fi
printf '%s\n' "$c_out"

echo "nverify: PASS (reproducible emission, translator goldens, native/n16i trace, block gate, non-ELF image, C-free source)"
echo "O"
