#!/bin/sh
# tools/ncc_macro_text.sh - object-like replacement-text macro gate.
# Covers type/storage-class macros, expression/nested object macros, empty
# replacements, multi-line continuations, self and mutual reference (blue
# paint), later definitions, #undef/redefine, object+function composition,
# # stringification / ## pasting, no expansion in strings/chars/comments,
# and #if / defined() after text macro expansion.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/nccmacrotext.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/tests/ncc_macro_text_test.nas > "$T/a.nan" 2>"$T/e" || { cat "$T/e"; exit 1; }
"$CLI" --img "$T/a.nan" --steps 200000000 --serial > "$T/out" 2>"$T/err" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/out" > "$T/got"
if cmp -s "$T/got" src/tests/ncc_macro_text.expected; then
  echo "ncc_macro_text: PASS (object replacement text, nesting, blue paint, #if)"
else
  echo "ncc_macro_text: FAIL"; diff -u src/tests/ncc_macro_text.expected "$T/got" | head -30; tail -2 "$T/err"; exit 1
fi
