#!/bin/sh
# nhost_emit_guest.sh - emit a .nan word stream with nhost.
#
# Usage: sh tools/nhost_emit_guest.sh [MAIN.nas [OUT.nan]]
#   MAIN defaults to src/gui/gui_sched_boot.nas; OUT defaults to stdout.
#
# BOOTSTRAP path: stage0 is built with nmk.awk, then nhost assembles itself
# (stage1, fixed-point checked), then stage1 emits MAIN.
#
# Machine selection:
#   default           nan_cli (fast bootstrap)
#   NHOST_NATIVE=1    raw native NaN16 core under QEMU, no nan_cli/S1 KABI
#                     (self-host ~18 s; the full guest is ~30 min)
#
# The default product build uses the hermetic tools/mkall.sh path; use
# tools/nhost_product_gate.sh to prove the emitted guest packs to the same
# image.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/nhost_emit.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

CLI=${NAN_CLI:-aarch64/android/nan_cli}
NATIVE=${NHOST_NATIVE:-0}
QEMU=${QEMU:-qemu-system-i386}
MAIN=${1:-src/gui/gui_sched_boot.nas}
OUT=${2:-}

words() { # .nan/.out -> word-only stream
  grep -E '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{8}_[0-9A-Fa-f]{4}' "$1" |
    sed 's/[[:space:]].*//'
}

bundle() { # MAIN -> padded disk image path
  awk -f tools/nhost_bundle.awk -v MAIN="$1" > "$T/bundle"
  sz=$(wc -c < "$T/bundle"); rem=$((sz % 512))
  [ "$rem" -eq 0 ] || dd if=/dev/zero bs=1 count=$((512 - rem)) >> "$T/bundle" 2>/dev/null
  cp "$T/bundle" "$T/bundle.img"
}

run_nhost() { # img disk mem steps out
  timeout 900 "$CLI" --img "$1" --disk "$2" --mem "$3" --steps "$4" \
    --serial > "$5" 2> "$5.err" || true
  grep -q '^;END .* err=00000000' "$5" ||
    { echo "nhost_emit: nhost errors" >&2; tail -3 "$5" >&2; exit 1; }
  words "$5" > "$5.words"
}

run_native() { # img bundle limit out
  img=$1; bnd=$2; limit=$3; out=$4
  command -v "$QEMU" >/dev/null 2>&1 ||
    { echo "nhost_emit: $QEMU absent" >&2; exit 1; }
  NAN0S_IMG="$T/native.img" NAN0S_GUEST="$img" TMPDIR="$T/mk.$$" \
    sh tools/mkall.sh > "$T/mk.out" 2> "$T/mk.err" ||
    { echo "nhost_emit: mkall failed" >&2; cat "$T/mk.err" >&2; exit 1; }
  truncate -s $((2048 * 512)) "$T/native.img"
  cat "$bnd" >> "$T/native.img"
  # QEMU's auto CHS for a small raw disk can be shorter than the bundle.
  truncate -s 8388608 "$T/native.img"
  truncate -s 1474560 "$T/floppy.img"
  dd if="$T/native.img" of="$T/floppy.img" conv=notrunc bs=512 count=2880 status=none

  rm -f "$out"
  "$QEMU" -m 512 \
    -drive format=raw,if=floppy,file="$T/floppy.img" \
    -drive format=raw,if=ide,file="$T/native.img" \
    -boot a -display none -serial file:"$out" -no-reboot \
    >/dev/null 2> "$T/q.err" &
  qp=$!
  start=$(date +%s); now=$start
  found=0
  while kill -0 "$qp" 2>/dev/null; do
    if grep -aq ';END' "$out" 2>/dev/null; then found=1; break; fi
    now=$(date +%s)
    [ $((now - start)) -lt "$limit" ] || break
    sleep 1
  done
  kill "$qp" 2>/dev/null || true
  wait "$qp" 2>/dev/null || true
  [ "$found" -eq 1 ] ||
    { echo "nhost_emit: native run timed out after $((now - start))s" >&2; tail -3 "$out" >&2; exit 1; }
  grep -q '^;END .* err=00000000' "$out" ||
    { echo "nhost_emit: nhost errors (native)" >&2; tail -3 "$out" >&2; exit 1; }
  words "$out" > "$out.words"
}

run_image() { # img bundle mem steps limit out
  if [ "$NATIVE" = 1 ]; then
    run_native "$1" "$2" "$5" "$6"
  else
    [ -x "$CLI" ] || { echo "nhost_emit: missing $CLI (or set NHOST_NATIVE=1)" >&2; exit 1; }
    run_nhost "$1" "$2" "$3" "$4" "$6"
  fi
}

# Stage 0: the host awk bootstrap.
awk -f tools/nmk.awk -v CMD=emit src/prog/nhost.nas > "$T/stage0.nan" 2> "$T/stage0.err" ||
  { cat "$T/stage0.err" >&2; exit 1; }
words "$T/stage0.nan" > "$T/stage0.words"

# Stage 1: nhost assembles its own source; must be the same 4,532-word image.
bundle src/prog/nhost.nas
run_image "$T/stage0.nan" "$T/bundle.img" 64 8000000000 180 "$T/self.out"
cmp -s "$T/stage0.words" "$T/self.out.words" ||
  { echo "nhost_emit: self-host fixed point differs" >&2; exit 1; }
cp "$T/self.out.words" "$T/stage1.nan"

# Product guest: stage 1 (self-hosted) emits MAIN.
bundle "$MAIN"
run_image "$T/stage1.nan" "$T/bundle.img" 128 80000000000 3600 "$T/guest.out"
if [ -n "$OUT" ]; then
  cp "$T/guest.out.words" "$OUT"
else
  cat "$T/guest.out.words"
fi
