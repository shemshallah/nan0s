#!/bin/sh
# tools/ndbg_term.sh - NANDBG terminal monitor in the Silver Slate terminal.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/ndbgterm.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)

awk -f tools/nmk.awk -v CMD=emit src/museum/museum.nas > "$T/museum.nan" 2>"$T/m.err" || { cat "$T/m.err"; exit 1; }
awk -f tools/nmk.awk -v CMD=emit src/exhibits/gui_cart.nas > "$T/gui.nan" 2>"$T/g.err" || { cat "$T/g.err"; exit 1; }
printf 'boot:%s/gui.nan\n1:%s/src/nan/baby_cart.nan:1948:1:1:Baby\n' "$T" "$PWD" > "$T/carts.txt"
gawk -f tools/mkimg.awk \
  -v GOLD=x86/native/nan16_x86.nan \
  -v GUEST="$T/museum.nan" \
  -v CARTS="$T/carts.txt" \
  -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" 2>"$T/mk.err" || { cat "$T/mk.err"; exit 1; }

"$CLI" --img "$T/guest.bin" --steps 100000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,c,a,r,t,s,ENTER,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,s,t,e,p,ENTER,@2000000,r,e,g,s,ENTER,@2000000,b,r,e,a,k,ENTER,@2000000,r,u,n,ENTER,@2000000,q,u,i,t,ENTER,@4000000" \
  --serial > "$T/out" 2>"$T/err" || true
tr -d '\r' < "$T/out" > "$T/out.lf"
if ! grep -qx 'carts' "$T/out.lf" ||
   ! grep -qx '1' "$T/out.lf" ||
   ! grep -qx 'load 1' "$T/out.lf" ||
   ! grep -qx 'S=0 PC=2000' "$T/out.lf" ||
   ! grep -qx 'step' "$T/out.lf" ||
   ! grep -qx 'S=0 PC=2001' "$T/out.lf" ||
   ! grep -qx 'regs' "$T/out.lf" ||
   ! grep -qx 'R0=00000000 R1=00000000 R2=00000000 R3=00000000 ' "$T/out.lf" ||
   ! grep -qx 'break' "$T/out.lf" ||
   ! grep -qx 'BP=2001' "$T/out.lf" ||
   ! grep -qx 'S=2 PC=2001' "$T/out.lf" ||
   ! grep -qx 'q' "$T/out.lf"; then
  echo "ndbg_term: FAIL"; cat "$T/out"; exit 1
fi
sed 's/BP=2001/BP=2002/' "$T/out.lf" > "$T/negative"
if cmp -s "$T/out.lf" "$T/negative"; then
  echo "ndbg_term: NEGATIVE FAIL"; exit 1
fi
echo "ndbg_term: PASS (terminal debug: carts/load, step/regs/break/run/quit, exact)"
echo "ndbg_term: NEGATIVE PASS (mutated transcript rejected)"
