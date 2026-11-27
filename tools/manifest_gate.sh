#!/bin/sh
# tools/manifest_gate.sh - F16 signed/authenticated product image manifest gate.
#
# Scope (honest):
#   1. Build the product image twice with a compiler-free PATH and compare the
#      full image + manifest region byte-for-byte (deterministic manifest).
#   2. Independently re-hash boot/kernel/guest, the manifest root and the
#      HMAC-SHA-256 tag from the emitted bytes.
#   3. Boot the unmodified image and require NANIX SHELL READY on COM1.
#   4. Flip one byte in boot, kernel, guest, manifest header/table/root and the
#      authentication tag; require the native verifier to halt before entering
#      the guest with exactly !MAN or !SIG and no shell banner.
#   5. Run no_c_outside_tests; no C source is added outside src/tests.
#
# The tag is HMAC-SHA-256 with an embedded build key.  This is symmetric
# tamper detection, not a public-key signature: an attacker who can rewrite
# the kernel can also rewrite the key.  The gate proves fail-closed integrity
# checking against mutation/corruption.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/manifest_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"; pkill -f "qemu-system-i386.*manifest_gate" 2>/dev/null || true' EXIT INT TERM

fail() { echo "manifest_gate: FAIL: $*" >&2; exit 1; }
sha()  { sha256sum "$1" | awk '{print $1}'; }
same() { cmp -s "$1" "$2" || fail "$3"; }
short() { printf '%s' "$1" | awk '{print substr($0,1,16)}'; }

MANOFF=65536
KERNOFF=512
KERNSZ=65024
GUESTOFF=66048
KIPAD=78577806651b7007001b585b57585f505345421b54435f5a521b5d534f1b06073636363636363636363636363636363636363636363636363636363636363636
KOPAD=123d126c0f711a6d6a7132313d32353a392f28713e2935303871373925716c6d5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c

SH=$(command -v sh) || fail "no sh"
command -v qemu-system-i386 >/dev/null 2>&1 || fail "qemu-system-i386 missing"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum missing"
command -v xxd >/dev/null 2>&1 || fail "xxd missing"

BIN="$T/bin"
mkdir -p "$BIN"
for t in sh gawk awk cat dd wc sed ls rm mkdir dirname basename tr head cmp od grep sha256sum; do
  p=$(command -v "$t" 2>/dev/null || true)
  [ -n "$p" ] && ln -sf "$p" "$BIN/$t"
done
[ -x "$BIN/gawk" ] || fail "gawk unavailable"
[ -x "$BIN/sha256sum" ] || fail "sha256sum unavailable"

build_one() { # dir
  d=$1
  mkdir -p "$d/tmp"
  env -i PATH="$BIN" LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1 \
    "$BIN/gawk" -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas \
    > "$d/guest.nan" 2> "$d/guest.err" || {
      cat "$d/guest.err" >&2; fail "guest emission failed in $d"; }
  env -i PATH="$BIN" LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1 \
    NAN0S_IMG="$d/nan0s.img" NAN0S_GUEST="$d/guest.nan" TMPDIR="$d/tmp" \
    "$SH" tools/mkall.sh > "$d/mkall.out" 2> "$d/mkall.err" || {
      cat "$d/mkall.err" >&2; fail "mkall failed in $d"; }
  [ -f "$d/nan0s.img" ] || fail "no image in $d"
}

echo "== 1. deterministic two-build =="
build_one "$T/b1"
build_one "$T/b2"
same "$T/b1/nan0s.img" "$T/b2/nan0s.img" "two builds differ"
I1=$(sha "$T/b1/nan0s.img")
echo "image sha256 $I1 (2 isolated builds identical, compiler-free PATH)"
dd if="$T/b1/nan0s.img" of="$T/m1.bin" bs=1 skip="$MANOFF" count=512 status=none
dd if="$T/b2/nan0s.img" of="$T/m2.bin" bs=1 skip="$MANOFF" count=512 status=none
same "$T/m1.bin" "$T/m2.bin" "manifest differs between builds"
M1=$(sha "$T/m1.bin")
echo "manifest sha256 $M1 (512 bytes at LBA 128)"
same "$T/b1/nan0s.img" build/nan0s.img \
  "build/nan0s.img is stale; run: sh tools/mkall.sh"

echo "== 2. manifest layout and independent hashes =="
magic=$(od -An -tx1 -N4 "$T/m1.bin" | tr -d ' \n')
[ "$magic" = "4e4d414e" ] || fail "manifest magic $magic != NMAN"
[ "$(od -An -tu4 -j4 -N4 "$T/m1.bin" | tr -d ' ')" -eq 1 ] || fail "manifest version"
[ "$(od -An -tu4 -j16 -N4 "$T/m1.bin" | tr -d ' ')" -eq 3 ] || fail "manifest region count"
LMAX=$(od -An -tu4 -j504 -N4 "$T/b1/nan0s.img" | tr -d ' ')
GSZ=$((LMAX * 8))
[ "$GSZ" -gt 0 ] || fail "zero guest size"
[ $((GUESTOFF + GSZ)) -le "$(wc -c < "$T/b1/nan0s.img")" ] || fail "guest overruns image"
HB=$(dd if="$T/b1/nan0s.img" bs=1 skip=0 count=512 status=none | sha256sum | awk '{print $1}')
HK=$(dd if="$T/b1/nan0s.img" bs=1 skip="$KERNOFF" count="$KERNSZ" status=none | sha256sum | awk '{print $1}')
HG=$(dd if="$T/b1/nan0s.img" bs=1 skip="$GUESTOFF" count="$GSZ" status=none | sha256sum | awk '{print $1}')
mb=$(dd if="$T/m1.bin" bs=1 skip=$((0x40 + 24)) count=32 status=none | xxd -p -c 64)
mk=$(dd if="$T/m1.bin" bs=1 skip=$((0x78 + 24)) count=32 status=none | xxd -p -c 64)
mg=$(dd if="$T/m1.bin" bs=1 skip=$((0xB0 + 24)) count=32 status=none | xxd -p -c 64)
[ "$HB" = "$mb" ] || fail "boot digest mismatch"
[ "$HK" = "$mk" ] || fail "kernel digest mismatch"
[ "$HG" = "$mg" ] || fail "guest digest mismatch"
ROOT=$(dd if="$T/m1.bin" bs=1 count=232 status=none | sha256sum | awk '{print $1}')
mr=$(dd if="$T/m1.bin" bs=1 skip=$((0xE8)) count=32 status=none | xxd -p -c 64)
[ "$ROOT" = "$mr" ] || fail "root mismatch"
hexbin() { gawk -v H="$1" -v N="$2" 'BEGIN {
  for (i = 1; i <= N; i++) printf "%c", strtonum("0x" substr(H, 2*i-1, 2))
}'; }
{ hexbin "$KIPAD" 64; hexbin "$ROOT" 32; } > "$T/in.bin"
INNER=$(sha256sum "$T/in.bin" | awk '{print $1}')
{ hexbin "$KOPAD" 64; hexbin "$INNER" 32; } > "$T/out.bin"
TAG=$(sha256sum "$T/out.bin" | awk '{print $1}')
mt=$(dd if="$T/m1.bin" bs=1 skip=$((0x108)) count=32 status=none | xxd -p -c 64)
[ "$TAG" = "$mt" ] || fail "auth tag mismatch"
[ "$(od -An -tu4 -j8 -N4 "$T/m1.bin" | tr -d ' ')" -ne 0 ] || fail "zero build id"
echo "boot $(short "$HB") kernel $(short "$HK") guest $(short "$HG")"
echo "root $(short "$ROOT") tag $(short "$TAG") guest $GSZ bytes"
echo "region digests, root and HMAC tag independently recomputed: exact"

# Boot helper.  A fresh IDE copy is used for every run because the guest can
# write to its volume; the floppy carries boot+kernel+manifest.
boot_run() { # image tag expect(shell|!MAN|!SIG) maxsec
  img=$1; tag=$2; expect=$3; max=$4
  ide="$T/ide.$tag.img"; fl="$T/fl.$tag.img"; com="$T/com.$tag"
  cp "$img" "$ide"
  truncate -s 1474560 "$fl"
  dd if="$img" of="$fl" bs=512 count=2880 conv=notrunc status=none
  rm -f "$com"
  qemu-system-i386 -m 512 -boot order=a \
    -drive format=raw,if=floppy,file="$fl",readonly=on \
    -drive format=raw,if=ide,file="$ide" \
    -display none -serial "file:$com" -no-reboot >/dev/null 2>&1 &
  qp=$!
  i=0
  while [ "$i" -lt "$max" ]; do
    if [ -s "$com" ]; then
      if [ "$expect" = shell ]; then
        grep -q 'NANIX SHELL READY' "$com" && break
      else
        grep -qx "$expect" "$com" && break
      fi
    fi
    kill -0 "$qp" 2>/dev/null || break
    sleep 1
    i=$((i+1))
  done
  kill "$qp" 2>/dev/null || true
  wait "$qp" 2>/dev/null || true
  printf '%s' "$(cat "$com" 2>/dev/null || true)" > "$T/com.$tag.text"
}

echo "== 3. unmodified image boot =="
boot_run "$T/b1/nan0s.img" clean shell 45
grep -q 'NANIX SHELL READY' "$T/com.clean" || {
  cat -v "$T/com.clean" >&2; fail "clean image did not reach NANIX SHELL READY"; }
if grep -q '!MAN\|!SIG' "$T/com.clean"; then fail "clean image printed a verifier error"; fi
echo "clean image: NANIX SHELL READY (manifest verified before guest entry)"

flip() { # img off label
  old=$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' ')
  new=$((old ^ 1))
  LC_ALL=C awk -v v="$new" 'BEGIN { printf "%c", v }' |
    dd of="$1" bs=1 seek="$2" conv=notrunc status=none
  echo "$3: byte $2 $old->$new"
}

echo "== 4. one-byte mutation fail-closed =="
run_mutant() { # name off mutcode
  name=$1; off=$2; want=$3
  cp "$T/b1/nan0s.img" "$T/$name.img"
  flip "$T/$name.img" "$off" "$name"
  boot_run "$T/$name.img" "$name" "$want" 20
  got=$(cat "$T/com.$name.text" 2>/dev/null || true)
  [ "$got" = "$want" ] || {
    echo "COM1:"; cat -v "$T/com.$name" >&2 2>/dev/null || true
    fail "$name: got '$got', expected exact '$want'"; }
  if grep -q 'NANIX SHELL READY' "$T/com.$name" 2>/dev/null; then
    fail "$name: guest ran after a failed verification"
  fi
  echo "$name: exact $want, guest not entered"
}

run_mutant boot      504                 '!MAN'
run_mutant kernel    $((512 + 0x800))    '!MAN'
run_mutant guest     $((66048 + 100))    '!MAN'
run_mutant manifest  $((65536 + 0))      '!MAN'
run_mutant region    $((65536 + 0x58))   '!MAN'
run_mutant root      $((65536 + 0xE8))   '!MAN'
run_mutant reserved  $((65536 + 0x1F0))  '!MAN'
run_mutant signature $((65536 + 0x108))  '!SIG'

echo "== 5. source rule =="
if ! c_out=$(sh tools/no_c_outside_tests.sh 2>&1); then
  printf '%s\n' "$c_out" >&2; fail "no_c_outside_tests"
fi
printf '%s\n' "$c_out"
bad=$(grep -nE '(^|[^A-Za-z0-9_])(clang|gcc|g\+\+|cc|ld\.lld|llvm-objcopy|python3?)([^A-Za-z0-9_]|$)' \
      tools/mkall.sh tools/manifest_build.sh tools/manifest_mk.awk 2>/dev/null || true)
[ -z "$bad" ] || { printf '%s\n' "$bad" >&2; fail "C toolchain token in the manifest build"; }
echo "manifest build: POSIX sh + gawk + sha256sum + dd/od; no C source outside src/tests"

echo "manifest_gate: PASS (2 hermetic builds identical; boot/kernel/guest digests, root and HMAC tag exact; clean boot to NANIX SHELL READY; one-byte boot/kernel/guest/manifest/root mutations -> !MAN, tag mutation -> !SIG, guest never entered; no C outside src/tests)"
echo "O"
