#!/bin/sh
# Gate: type a C program into the GUI terminal's built-in C editor and run it
# with .run. Proves the source-entry path (not just the embedded demo).
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
IMG=build/nan0s.img
[ -f "$IMG" ] || { echo "ncc_editor: SKIP (no $IMG; run tools/build.sh)"; exit 77; }
T="${TMPDIR:-/tmp}/nccedit.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)
SRC='int main(void){ print_int(6*7); putchar(10); return 0; }'
TOK=$(printf '%s' "$SRC" | awk 'BEGIN{ORS=""} {for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c==" ")c="SPACE"; else if(c==",")c="COMMA"; printf "%s%s", (i>1?",":""), c}}')
KEYS="e,ENTER,@1000000,$TOK,ENTER,.,r,u,n,ENTER"
"$CLI" --img "$IMG" --steps 1200000000 --keys "@5000000,$KEYS" --peek 0x40000:1400 > "$T/o" 2> "$T/e" || true
grep -E '^[0-9A-F]{8}$' "$T/o" | awk '{v=strtonum("0x"$1); c=v%256; if(c>=32&&c<127)printf "%c",c; else printf " "}' > "$T/txt"
if grep -q "42" "$T/txt" && ! grep -q "rc=3" "$T/e"; then
  echo "ncc_editor: PASS (typed C compiled and ran in the terminal)"
else
  echo "ncc_editor: FAIL"; tail -3 "$T/e"; head -c 400 "$T/txt"; echo; exit 1
fi
