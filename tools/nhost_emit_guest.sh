#!/bin/sh
# nhost_emit_guest.sh - emit a .nan word stream with nhost.
#
# Usage: sh tools/nhost_emit_guest.sh [MAIN.nas [OUT.nan]]
#   MAIN defaults to src/gui/gui_sched_boot.nas; OUT defaults to stdout.
#
# BOOTSTRAP/ORACLE path: stage0 is built with nmk.awk, then nhost assembles
# itself (stage1, fixed-point checked), then stage1 emits MAIN.  nan_cli is
# the bootstrap machine for this development path; the shipped product image
# is still produced by the hermetic tools/mkall.sh path.  Use
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
[ -x "$CLI" ] || { echo "nhost_emit: missing $CLI" >&2; exit 1; }
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

# Stage 0: the host awk bootstrap.
awk -f tools/nmk.awk -v CMD=emit src/prog/nhost.nas > "$T/stage0.nan" 2> "$T/stage0.err" ||
  { cat "$T/stage0.err" >&2; exit 1; }
words "$T/stage0.nan" > "$T/stage0.words"

# Stage 1: nhost assembles its own source; must be the same 4,530-word image.
bundle src/prog/nhost.nas
run_nhost "$T/stage0.nan" "$T/bundle.img" 64 8000000000 "$T/self.out"
cmp -s "$T/stage0.words" "$T/self.out.words" ||
  { echo "nhost_emit: self-host fixed point differs" >&2; exit 1; }
cp "$T/self.out.words" "$T/stage1.nan"

# Product guest: stage 1 (self-hosted) emits MAIN.
bundle "$MAIN"
run_nhost "$T/stage1.nan" "$T/bundle.img" 128 80000000000 "$T/guest.out"
if [ -n "$OUT" ]; then
  cp "$T/guest.out.words" "$OUT"
else
  cat "$T/guest.out.words"
fi
