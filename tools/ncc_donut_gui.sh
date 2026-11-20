#!/bin/sh
# GUI donut gate: cc /donut_fast.c inside the terminal and require the torus.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
IMG=build/nan0s.img
[ -f "$IMG" ] || { echo "ncc_donut_gui: SKIP (no $IMG)"; exit 77; }
T="${TMPDIR:-/tmp}/nccdg.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
K=$(printf '%s' 'cc /donut_fast.c' | awk '{for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c==" ")c="SPACE"; printf "%s%s",(i>1?",":""),c}}')
"$CLI" --img "$IMG" --steps 600000000 --keys "@5000000,$K,ENTER" --peek 0x40000:8192 > "$T/o" 2> "$T/e" || true
grep -E '^[0-9A-F]{8}$' "$T/o" | awk '{v=strtonum("0x"$1); c=v%256; if(c>=32&&c<127)printf "%c",c; else printf " "}' > "$T/txt"
if grep -q '@@' "$T/txt" && grep -q '\$\$' "$T/txt"; then echo "ncc_donut_gui: PASS (C donut ran in the NaN0S terminal)"; else echo "ncc_donut_gui: FAIL"; tail -2 "$T/e"; exit 1; fi
