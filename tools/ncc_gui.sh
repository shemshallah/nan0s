#!/bin/sh
# tools/ncc_gui.sh - end-to-end gate: boot the shipped image, open the terminal,
# press 'e', and require the C demo's output (compiled and run by the raw-NaN16
# ncc front end) to appear in that terminal's virtual console.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
IMG=build/nan0s.img
[ -f "$IMG" ] || { echo "ncc_gui: SKIP (no $IMG; run tools/build.sh)"; exit 77; }
T="${TMPDIR:-/tmp}/nccgui.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
"$CLI" --img "$IMG" --steps 300000000 --keys "@5000000,e,@5000000,ENTER" --peek 0x40000:900 > "$T/o" 2> "$T/e" || true
grep -E '^[0-9A-F]{8}$' "$T/o" | awk '{v=strtonum("0x"$1); c=v%256; if(c>=32&&c<127)printf "%c",c; else printf " "}' > "$T/txt"
ok=1
grep -q "NaN C in the terminal" "$T/txt" || ok=0
grep -q "55 23" "$T/txt" || ok=0
grep -q "hello from NaN16 C" "$T/txt" || ok=0
if grep -q "rc=3" "$T/e"; then ok=0; fi
if [ "$ok" -eq 1 ]; then
  echo "ncc_gui: PASS (C ran inside the GUI terminal)"
else
  echo "ncc_gui: FAIL"; tail -3 "$T/e"; head -c 400 "$T/txt"; echo; exit 1
fi
