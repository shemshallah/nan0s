#!/bin/sh
# ots_gate.sh - F16b Winternitz-4 OTS product-manifest gate.
#
# Builds the raw product image twice with a fixed development OTS master,
# verifies the 4 KiB manifest and 512-byte anchor independently, boots clean
# to NANIX SHELL READY, and mutates boot/kernel/guest/manifest/root/key/
# signature/anchor one byte at a time.  Every path fails closed before guest
# entry: digest/structure -> !MAN, OTS/key/anchor -> !OTS, HMAC -> !SIG.
#
# The development seed is public and is not a production signing key.  A
# production build sets OTS_MASTER to an offline 32-byte secret.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-$PWD/tmp}/ots_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"; pkill -f "qemu-system-i386.*ots_gate" 2>/dev/null || true' EXIT INT TERM

fail() { echo "ots_gate: FAIL: $*" >&2; exit 1; }
sha()  { sha256sum "$1" | awk '{print $1}'; }
same() { cmp -s "$1" "$2" || fail "$3"; }
short() { printf '%s' "$1" | awk '{print substr($0,1,16)}'; }
hex()  { dd if="$1" bs=1 skip="$2" count="$3" status=none | xxd -p -c 999 | tr -d '\n'; }

command -v qemu-system-i386 >/dev/null 2>&1 || fail "qemu-system-i386 missing"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum missing"
command -v xxd >/dev/null 2>&1 || fail "xxd missing"
[ -f tools/ots_dev_seed.hex ] || fail "missing tools/ots_dev_seed.hex"

MANOFF=61440
MANSZ=4096
ANCHOROFF=65536
KERNOFF=512
KERNSZ=60928
GUESTOFF=66048
KIPAD=78577806651b7007001b585b57585f505345421b54435f5a521b5d534f1b06073636363636363636363636363636363636363636363636363636363636363636
KOPAD=123d126c0f711a6d6a7132313d32353a392f28713e2935303871373925716c6d5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c

SEED=$(tr -d ' \r\n' < tools/ots_dev_seed.hex)
[ "${#SEED}" -eq 64 ] || fail "dev seed is not 32 bytes"
printf '%s\n' "$SEED" > "$T/master.hex"
chmod 600 "$T/master.hex"

build_one() { # dir
  d=$1
  mkdir -p "$d/tmp"
  OTS_MASTER="$T/master.hex" NAN0S_IMG="$d/nan0s.img" \
    NAN0S_GUEST=src/nan/nixsched.nan TMPDIR="$d/tmp" \
    sh tools/mkall.sh > "$d/mkall.out" 2> "$d/mkall.err" || {
      cat "$d/mkall.err" >&2; fail "mkall failed in $d"; }
  [ -f "$d/nan0s.img" ] || fail "no image in $d"
}

echo "== 1. deterministic OTS build =="
build_one "$T/b1"
build_one "$T/b2"
same "$T/b1/nan0s.img" "$T/b2/nan0s.img" "two OTS builds differ"
I1=$(sha "$T/b1/nan0s.img")
echo "image sha256 $I1 (2 isolated builds identical with fixed dev OTS key)"

echo "== 2. manifest layout and independent verification =="
IMG="$T/b1/nan0s.img"
dd if="$IMG" of="$T/man.bin" bs=1 skip="$MANOFF" count="$MANSZ" status=none
dd if="$IMG" of="$T/anchor.bin" bs=1 skip="$ANCHOROFF" count=512 status=none
[ "$(od -An -tx1 -N4 "$T/man.bin" | tr -d ' \n')" = "4e4d414e" ] || fail "bad manifest magic"
[ "$(od -An -tu4 -j4 -N4 "$T/man.bin" | tr -d ' ')" -eq 2 ] || fail "bad manifest version"
[ "$(od -An -tu4 -j12 -N4 "$T/man.bin" | tr -d ' ')" -eq 3 ] || fail "bad manifest flags"
[ "$(od -An -tu4 -j16 -N4 "$T/man.bin" | tr -d ' ')" -eq 3 ] || fail "bad region count"
[ "$(od -An -tu4 -j24 -N4 "$T/man.bin" | tr -d ' ')" -eq 296 ] || fail "bad root offset"
[ "$(od -An -tu4 -j28 -N4 "$T/man.bin" | tr -d ' ')" -eq 328 ] || fail "bad tag offset"
[ "$(od -An -tu4 -j32 -N4 "$T/man.bin" | tr -d ' ')" -eq 1 ] || fail "bad OTS algo"
[ "$(od -An -tu4 -j36 -N4 "$T/man.bin" | tr -d ' ')" -eq 4 ] || fail "bad OTS w"
[ "$(od -An -tu4 -j44 -N4 "$T/man.bin" | tr -d ' ')" -eq 512 ] || fail "bad OTS sig offset"
[ "$(od -An -tu4 -j48 -N4 "$T/man.bin" | tr -d ' ')" -eq 2144 ] || fail "bad OTS sig bytes"

LMAX=$(od -An -tu4 -j504 -N4 "$IMG" | tr -d ' ')
GSZ=$((LMAX * 8))
[ "$GSZ" -gt 0 ] || fail "zero guest size"
HB=$(dd if="$IMG" bs=1 skip=0 count=512 status=none | sha256sum | awk '{print $1}')
HK=$(dd if="$IMG" bs=1 skip="$KERNOFF" count="$KERNSZ" status=none | sha256sum | awk '{print $1}')
HG=$(dd if="$IMG" bs=1 skip="$GUESTOFF" count="$GSZ" status=none | sha256sum | awk '{print $1}')
mb=$(hex "$T/man.bin" $((0x40 + 24)) 32)
mk=$(hex "$T/man.bin" $((0x78 + 24)) 32)
mg=$(hex "$T/man.bin" $((0xB0 + 24)) 32)
[ "$HB" = "$mb" ] || fail "boot digest mismatch"
[ "$HK" = "$mk" ] || fail "kernel digest mismatch"
[ "$HG" = "$mg" ] || fail "guest digest mismatch"

ROOT=$(dd if="$T/man.bin" bs=1 count=232 status=none | sha256sum | awk '{print $1}')
mr=$(hex "$T/man.bin" 296 32)
[ "$ROOT" = "$mr" ] || fail "root mismatch"
KID=$(hex "$T/man.bin" 232 16)
PUB=$(hex "$T/man.bin" 248 32)
SIG=$(hex "$T/man.bin" 512 2144)
[ "${#KID}" -eq 32 ] || fail "bad key id length"
[ "${#PUB}" -eq 64 ] || fail "bad public key length"
[ "${#SIG}" -eq 4288 ] || fail "bad signature length"
[ "$KID" = "$(printf '%s' "$PUB" | cut -c1-32)" ] || fail "key id != pub prefix"
[ "$(hex "$T/anchor.bin" 0 8)" = "4f54534130303031" ] || fail "bad anchor magic"
[ "$(hex "$T/anchor.bin" 8 16)" = "$KID" ] || fail "anchor key id mismatch"
[ "$(hex "$T/anchor.bin" 24 32)" = "$PUB" ] || fail "anchor public key mismatch"

printf '%s\n' "$SIG" > "$T/sig.hex"
gawk -f tools/ots.awk -v CMD=verify -v ROOT="$ROOT" \
  -v SIGFILE="$T/sig.hex" -v PUB="$PUB" >/dev/null ||
  fail "independent OTS verification failed"

# HMAC-SHA-256(build key, root), defense in depth.
hexbin() { gawk -v H="$1" -v N="$2" 'BEGIN {
  for (i = 1; i <= N; i++) printf "%c", strtonum("0x" substr(H, 2*i-1, 2))
}'; }
{ hexbin "$KIPAD" 64; hexbin "$ROOT" 32; } > "$T/in.bin"
INNER=$(sha256sum "$T/in.bin" | awk '{print $1}')
{ hexbin "$KOPAD" 64; hexbin "$INNER" 32; } > "$T/out.bin"
TAG=$(sha256sum "$T/out.bin" | awk '{print $1}')
[ "$TAG" = "$(hex "$T/man.bin" 328 32)" ] || fail "HMAC tag mismatch"
echo "boot $(short "$HB") kernel $(short "$HK") guest $(short "$HG")"
echo "root $(short "$ROOT") keyid $(short "$KID") sig 2144 bytes, guest $GSZ bytes"
echo "region digests, root, OTS and HMAC tag independently verified"

echo "== 3. clean boot =="
boot_run() { # image tag expect maxsec
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
boot_run "$IMG" clean shell 45
grep -q 'NANIX SHELL READY' "$T/com.clean" || {
  cat -v "$T/com.clean" >&2; fail "clean image did not reach NANIX SHELL READY"; }
if grep -q '!MAN\|!OTS\|!SIG' "$T/com.clean"; then fail "clean image printed a verifier error"; fi
echo "clean image: NANIX SHELL READY (manifest+OTS verified before guest entry)"

flip() { # img off label
  old=$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' ')
  new=$((old ^ 1))
  LC_ALL=C awk -v v="$new" 'BEGIN { printf "%c", v }' |
    dd of="$1" bs=1 seek="$2" conv=notrunc status=none
  echo "$3: byte $2 $old->$new"
}
run_mutant() { # name off want
  name=$1; off=$2; want=$3
  cp "$IMG" "$T/$name.img"
  flip "$T/$name.img" "$off" "$name" >/dev/null
  boot_run "$T/$name.img" "$name" "$want" 20
  got=$(cat "$T/com.$name.text" 2>/dev/null || true)
  [ "$got" = "$want" ] || {
    echo "COM1:"; cat -v "$T/com.$name" 2>/dev/null || true
    fail "$name: got '$got', expected exact '$want'"; }
  if grep -q 'NANIX SHELL READY' "$T/com.$name" 2>/dev/null; then
    fail "$name: guest ran after failed verification"
  fi
  echo "$name: exact $want, guest not entered"
}

echo "== 4. one-byte fail-closed mutations =="
run_mutant boot      $((0 + 504))                 '!MAN'
run_mutant kernel    $((KERNOFF + 0x800))         '!MAN'
run_mutant guest     $((GUESTOFF + 100))          '!MAN'
run_mutant magic     $((MANOFF + 0))              '!MAN'
run_mutant bootdig   $((MANOFF + 0x58))           '!MAN'
run_mutant root      $((MANOFF + 0x128))          '!MAN'
run_mutant reserved  $((MANOFF + 0x1F0))          '!MAN'
run_mutant keyid     $((MANOFF + 0xE8))           '!OTS'
run_mutant pubkey    $((MANOFF + 0xF8))           '!OTS'
run_mutant signature $((MANOFF + 0x200))          '!OTS'
run_mutant hmac      $((MANOFF + 0x148))          '!SIG'
run_mutant anchmag   $((ANCHOROFF + 0))           '!OTS'
run_mutant anchkey   $((ANCHOROFF + 8))           '!OTS'
run_mutant anchpub   $((ANCHOROFF + 24))          '!OTS'

echo "== 5. source rule =="
sh tools/no_c_outside_tests.sh
bad=$(grep -nE '(^|[^A-Za-z0-9_])(clang|gcc|g\+\+|cc|ld\.lld|llvm-objcopy|python3?)([^A-Za-z0-9_]|$)' \
      tools/mkall.sh tools/manifest_build.sh tools/manifest_mk.awk tools/ots_keygen.sh tools/ots_sign.sh tools/ots.awk 2>/dev/null || true)
[ -z "$bad" ] || { printf '%s\n' "$bad" >&2; fail "C toolchain token in manifest/OTS build"; }
echo "manifest/OTS build: POSIX sh + gawk + sha256sum + dd/od; no C outside src/tests"

echo "ots_gate: PASS (2 deterministic builds; region/root/OTS/HMAC verified; clean boot to NANIX SHELL READY; boot/kernel/guest/manifest/root -> !MAN, key/pub/sig/anchor -> !OTS, HMAC tag -> !SIG; guest never entered)"
echo "O"
