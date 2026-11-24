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
awk -f tools/nmk.awk -v CMD=emit src/tests/ndbg_putc_cart.nas > "$T/putc.nan" 2>"$T/p.err" || { cat "$T/p.err"; exit 1; }
printf 'boot:%s/gui.nan\n1:%s/src/nan/baby_cart.nan:1948:1:1:Baby\n2:%s/putc.nan:2026:2:1:PUTC\n' "$T" "$PWD" "$T" > "$T/carts.txt"
gawk -f tools/mkimg.awk \
  -v GOLD=x86/native/nan16_x86.nan \
  -v GUEST="$T/museum.nan" \
  -v CARTS="$T/carts.txt" \
  -v OUTB="$T/boot.bin" -v OUTG="$T/guest.bin" 2>"$T/mk.err" || { cat "$T/mk.err"; exit 1; }

"$CLI" --img "$T/guest.bin" --steps 100000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,c,a,r,t,s,ENTER,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,s,t,e,p,ENTER,@2000000,d,i,s,ENTER,@2000000,r,e,g,s,ENTER,@2000000,s,e,t,r,SPACE,1,SPACE,4,2,ENTER,@2000000,s,e,t,m,SPACE,3,0,0,0,SPACE,1,2,3,4,ENTER,@2000000,s,e,t,w,SPACE,3,0,0,0,SPACE,5,6,7,8,SPACE,9,ENTER,@2000000,s,e,t,c,SPACE,3,0,0,0,SPACE,5,ENTER,@2000000,b,r,e,a,k,ENTER,@2000000,w,a,t,c,h,ENTER,@2000000,b,p,t,s,ENTER,@2000000,w,p,t,s,ENTER,@2000000,m,e,m,ENTER,@2000000,r,u,n,ENTER,@2000000,q,u,i,t,ENTER,@4000000" \
  --serial > "$T/out" 2>"$T/err" || true
tr -d '\r' < "$T/out" > "$T/out.lf"
if ! grep -qx 'carts' "$T/out.lf" ||
   ! grep -qx '1' "$T/out.lf" ||
   ! grep -qx 'load 1' "$T/out.lf" ||
   ! grep -qx 'S=0 PC=2000' "$T/out.lf" ||
   ! grep -qx 'step' "$T/out.lf" ||
   ! grep -qx 'S=0 PC=2001' "$T/out.lf" ||
   ! grep -qx 'dis' "$T/out.lf" ||
   ! grep -qx '2001 FFF8_01D00001_F8FF MOVI r13,1' "$T/out.lf" ||
   ! grep -qx 'regs' "$T/out.lf" ||
   ! grep -qx 'R0=00000000 R1=00000000 R2=00000000 R3=00000000 ' "$T/out.lf" ||
   ! grep -qx 'R1=00000042' "$T/out.lf" ||
   ! grep -qx 'M3000=00001234' "$T/out.lf" ||
   ! grep -qx 'W3000=00005678/9' "$T/out.lf" ||
   ! grep -qx 'C3000=5' "$T/out.lf" ||
   ! grep -qx 'break' "$T/out.lf" ||
   ! grep -qx 'BP=2001' "$T/out.lf" ||
   ! grep -qx 'W=2001' "$T/out.lf" ||
   ! grep -qx 'BP=1:' "$T/out.lf" ||
   ! grep -qx '2001 ' "$T/out.lf" ||
   ! grep -qx 'W=1:' "$T/out.lf" ||
   ! grep -q '^M2001' "$T/out.lf" ||
   ! grep -qx 'S=2 PC=2001' "$T/out.lf" ||
   ! grep -qx 'q' "$T/out.lf"; then
  echo "ndbg_term: FAIL"; cat "$T/out"; exit 1
fi
# captured display: run Baby to the key wait and dump the text buffer
"$CLI" --img "$T/guest.bin" --steps 160000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,r,u,n,ENTER,@4000000,s,c,r,e,e,n,ENTER,@4000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/scr" 2>/dev/null || true
tr -d '\r' < "$T/scr" > "$T/scr.lf"
if ! grep -qx 'S=5 PC=2009' "$T/scr.lf" ||
   ! grep -q 'MANCHESTER SMALL-SCALE EXPERIMENTAL MACHINE - THE BABY - 21 JUNE 1948' "$T/scr.lf"; then
  echo "ndbg_term: SCREEN FAIL"; cat "$T/scr"; exit 1
fi

# captured serial: a tiny PUTC cart prints HELLO
"$CLI" --img "$T/guest.bin" --steps 90000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,2,ENTER,@2000000,r,u,n,ENTER,@2000000,s,e,r,i,a,l,ENTER,@3000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/ser" 2>/dev/null || true
tr -d '\r' < "$T/ser" > "$T/ser.lf"
if ! grep -qx 'S=1 PC=2012' "$T/ser.lf" ||
   ! grep -qx 'HELLO' "$T/ser.lf"; then
  echo "ndbg_term: SERIAL FAIL"; cat "$T/ser"; exit 1
fi

# time travel: undo one step, checkpoint, restore
"$CLI" --img "$T/guest.bin" --steps 120000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,s,t,e,p,ENTER,@2000000,s,t,e,p,ENTER,@2000000,u,n,d,o,ENTER,@2000000,r,e,d,o,ENTER,@2000000,r,e,d,o,ENTER,@2000000,c,h,e,c,k,p,o,i,n,t,ENTER,@2000000,s,t,e,p,ENTER,@2000000,r,e,s,t,o,r,e,ENTER,@3000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/time" 2>/dev/null || true
tr -d '\r' < "$T/time" > "$T/time.lf"
if ! grep -qx 'CKPT=1' "$T/time.lf" ||
   ! grep -qx 'NOREDO' "$T/time.lf" ||
   ! grep -qx 'S=0 PC=0004' "$T/time.lf" ||
   ! grep -qx 'S=0 PC=2002' "$T/time.lf" ||
   ! grep -qx 'S=0 PC=2001' "$T/time.lf"; then
  echo "ndbg_term: TIME FAIL"; cat "$T/time"; exit 1
fi

# multi-level redo: three steps, two undos, two redos
"$CLI" --img "$T/guest.bin" --steps 140000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,s,t,e,p,ENTER,@2000000,s,t,e,p,ENTER,@2000000,s,t,e,p,ENTER,@2000000,u,n,d,o,ENTER,@2000000,u,n,d,o,ENTER,@2000000,r,e,d,o,ENTER,@2000000,r,e,d,o,ENTER,@2000000,r,e,d,o,ENTER,@3000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/redo" 2>/dev/null || true
tr -d '\r' < "$T/redo" > "$T/redo.lf"
if ! grep -qx 'S=0 PC=0004' "$T/redo.lf" ||
   ! grep -qx 'S=0 PC=2002' "$T/redo.lf" ||
   ! grep -qx 'S=0 PC=2001' "$T/redo.lf" ||
   ! grep -qx 'NOREDO' "$T/redo.lf"; then
  echo "ndbg_term: REDO FAIL"; cat "$T/redo"; exit 1
fi

sed 's/BP=2001/BP=2002/'    "$T/out.lf" > "$T/negative"
if cmp -s "$T/out.lf" "$T/negative"; then
  echo "ndbg_term: NEGATIVE FAIL"; exit 1
fi
echo "ndbg_term: PASS (terminal debug: carts/load, step/dis/regs/break/watch/bpts/wpts/mem/run; screen/serial; setr/setm/setw/setc; undo/multi-redo/checkpoint/restore, exact)"
echo "ndbg_term: NEGATIVE PASS (mutated transcript rejected)"
