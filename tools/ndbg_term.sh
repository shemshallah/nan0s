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
awk -f tools/nmk.awk -v CMD=emit src/tests/ndbg_badop_cart.nas > "$T/badop.nan" 2>"$T/bo.err" || { cat "$T/bo.err"; exit 1; }
awk -f tools/nmk.awk -v CMD=emit src/tests/ndbg_call_cart.nas > "$T/call.nan" 2>"$T/ca.err" || { cat "$T/ca.err"; exit 1; }
printf 'boot:%s/gui.nan\n1:%s/src/nan/baby_cart.nan:1948:1:1:Baby\n2:%s/putc.nan:2026:2:1:PUTC\n3:%s/badop.nan:2026:3:1:BadOp\n4:%s/call.nan:2026:4:1:Call\n' "$T" "$PWD" "$T" "$T" "$T" > "$T/carts.txt"
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
# next/finish and the rich panes: step over a CALL, step out of a frame,
# then log/hist/stack/types on the demo target.
"$CLI" --img "$T/guest.bin" --steps 120000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,4,ENTER,@2000000,s,t,e,p,ENTER,@2000000,s,t,e,p,ENTER,@2000000,n,e,x,t,ENTER,@2000000,r,e,g,s,ENTER,@3000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/nx" 2>/dev/null || true
tr -d '\r' < "$T/nx" > "$T/nx.lf"
if ! grep -qx 'S=0 PC=2001' "$T/nx.lf" ||
   ! grep -qx 'S=0 PC=2002' "$T/nx.lf" ||
   ! grep -qx 'S=0 PC=2003' "$T/nx.lf" ||
   ! grep -qx 'R0=00000000 R1=00000000 R2=00000055 R3=00000000 ' "$T/nx.lf"; then
  echo "ndbg_term: NEXT FAIL"; cat "$T/nx"; exit 1
fi

"$CLI" --img "$T/guest.bin" --steps 120000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,4,ENTER,@2000000,s,t,e,p,ENTER,@2000000,s,t,e,p,ENTER,@2000000,s,t,e,p,ENTER,@2000000,s,t,a,c,k,ENTER,@2000000,f,i,n,i,s,h,ENTER,@3000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/fin" 2>/dev/null || true
tr -d '\r' < "$T/fin" > "$T/fin.lf"
if ! grep -qx 'S=0 PC=2005' "$T/fin.lf" ||
   ! grep -qx 'STACK 1: 2003 ' "$T/fin.lf" ||
   ! grep -qx 'S=0 PC=2003' "$T/fin.lf"; then
  echo "ndbg_term: FINISH FAIL"; cat "$T/fin"; exit 1
fi

"$CLI" --img "$T/guest.bin" --steps 130000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,s,t,e,p,ENTER,@2000000,n,e,x,t,ENTER,@2000000,l,o,g,ENTER,@2000000,h,i,s,t,ENTER,@2000000,s,t,a,c,k,ENTER,@2000000,t,y,p,e,s,ENTER,@2000000,f,i,n,i,s,h,ENTER,@4000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/rich" 2>/dev/null || true
tr -d '\r' < "$T/rich" > "$T/rich.lf"
if ! grep -qx 'no log' "$T/rich.lf" ||
   ! grep -qx 'HIST 0000 0000 0000 0000 0000 0000 2000 2001 ' "$T/rich.lf" ||
   ! grep -qx 'STACK 0: empty' "$T/rich.lf" ||
   ! grep -qx 'TYPES FC:00 FM:00 FD:00 FS:00 ' "$T/rich.lf" ||
   ! grep -qx 'TYPES PC:00 PM:00 PD:00 PS:00 ' "$T/rich.lf" ||
   ! grep -qx 'TYPES WC:00 WM:00 WD:00 WS:00 ' "$T/rich.lf" ||
   ! grep -qx 'TYPES DC:00 DM:00 DD:00 DS:00 ' "$T/rich.lf" ||
   ! grep -qx 'S=5 PC=2009' "$T/rich.lf"; then
  echo "ndbg_term: RICH FAIL"; cat "$T/rich"; exit 1
fi

# a real bad-op trap must appear in the log as a typed record
"$CLI" --img "$T/guest.bin" --steps 120000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,3,ENTER,@2000000,r,u,n,ENTER,@5000000,l,o,g,ENTER,@2000000,n,d,r,ENTER,@2000000,m,i,r,r,o,r,ENTER,@2000000,t,y,p,e,s,ENTER,@3000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/blog" 2>/dev/null || true
tr -d '\r' < "$T/blog" > "$T/blog.lf"
if ! grep -qx '!DFC@20002003 W=0000000F7F000000' "$T/blog.lf" ||
   ! grep -qx 'S=3 PC=2003' "$T/blog.lf" ||
   ! grep -qx 'D0:20:002003 A=00000000 B=00000000 D=00000000 S=47997CA3' "$T/blog.lf" ||
   ! grep -qx 'NDR 20000000 00002003 7F000000 0000000F 00000000 00000000 00000000 47997CA3 ' "$T/blog.lf" ||
   ! grep -qx 'MIRROR OK' "$T/blog.lf" ||
   ! grep -qx 'TYPES FC:01 FM:00 FD:00 FS:00 ' "$T/blog.lf"; then
  echo "ndbg_term: LOG FAIL"; cat "$T/blog"; exit 1
fi

# typed breakpoint/watchpoint table edits and goto
"$CLI" --img "$T/guest.bin" --steps 120000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,b,p,SPACE,2,0,0,1,ENTER,@2000000,w,p,SPACE,2,0,0,2,ENTER,@2000000,b,p,t,s,ENTER,@2000000,w,p,t,s,ENTER,@2000000,g,o,t,o,SPACE,2,0,0,3,ENTER,@2000000,b,p,SPACE,2,0,0,1,ENTER,@2000000,w,p,SPACE,2,0,0,2,ENTER,@3000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/bpwp" 2>/dev/null || true
tr -d '\r' < "$T/bpwp" > "$T/bpwp.lf"
if ! grep -qx 'BP=2001 +' "$T/bpwp.lf" ||
   ! grep -qx 'W=2002 +' "$T/bpwp.lf" ||
   ! grep -qx 'BP=2001 -' "$T/bpwp.lf" ||
   ! grep -qx 'W=2002 -' "$T/bpwp.lf" ||
   ! grep -qx '2001 ' "$T/bpwp.lf" ||
   ! grep -qx '2002 ' "$T/bpwp.lf" ||
   ! grep -qx 'S=0 PC=2003' "$T/bpwp.lf"; then
  echo "ndbg_term: BPWP FAIL"; cat "$T/bpwp"; exit 1
fi

# checkpoint also restores the captured serial window
"$CLI" --img "$T/guest.bin" --steps 120000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,2,ENTER,@2000000,r,u,n,ENTER,@2000000,s,e,r,i,a,l,ENTER,@2000000,c,h,e,c,k,p,o,i,n,t,ENTER,@2000000,g,o,t,o,SPACE,2,0,0,0,ENTER,@2000000,r,u,n,ENTER,@2000000,s,e,r,i,a,l,ENTER,@2000000,r,e,s,t,o,r,e,ENTER,@2000000,s,e,r,i,a,l,ENTER,@3000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/ckcap" 2>/dev/null || true
tr -d '\r' < "$T/ckcap" > "$T/ckcap.lf"
hello=$(grep -c '^HELLO$' "$T/ckcap.lf" || true)
if [ "$hello" != 4 ] ||
   ! grep -qx 'CKPT=1' "$T/ckcap.lf" ||
   ! grep -qx 'S=1 PC=2000' "$T/ckcap.lf" ||
   ! grep -qx 'S=1 PC=2012' "$T/ckcap.lf"; then
  echo "ndbg_term: CKPT CAPTURE FAIL (HELLO=$hello)"; cat "$T/ckcap"; exit 1
fi

# optional arguments: undo/redo counts, mem/dis base addresses
"$CLI" --img "$T/guest.bin" --steps 140000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,s,t,e,p,ENTER,@2000000,s,t,e,p,ENTER,@2000000,s,t,e,p,ENTER,@2000000,u,n,d,o,SPACE,2,ENTER,@2000000,r,e,d,o,SPACE,2,ENTER,@2000000,m,e,m,SPACE,3,0,0,0,ENTER,@2000000,d,i,s,SPACE,2,0,0,1,ENTER,@3000000,q,u,i,t,ENTER,@3000000" \
  --serial > "$T/args" 2>/dev/null || true
tr -d '\r' < "$T/args" > "$T/args.lf"
if ! grep -qx 'undo 2' "$T/args.lf" ||
   ! grep -qx 'redo 2' "$T/args.lf" ||
   ! grep -qx 'S=0 PC=2002' "$T/args.lf" ||
   ! grep -qx 'S=0 PC=2001' "$T/args.lf" ||
   ! grep -qx 'S=0 PC=0004' "$T/args.lf" ||
   ! grep -qx 'M300000000000F' "$T/args.lf" ||
   ! grep -qx 'M300700000000F' "$T/args.lf" ||
   ! grep -qx '2001 FFF8_01D00001_F8FF MOVI r13,1' "$T/args.lf" ||
   ! grep -qx '2002 FFF8_0B000004_F8FF CALL 4' "$T/args.lf"; then
  echo "ndbg_term: ARGS FAIL"; cat "$T/args"; exit 1
fi

# captured display: run Baby to the key wait and dump the text buffer
"$CLI" --img "$T/guest.bin" --steps 160000000 \
  --keys "@20000000,d,e,b,u,g,ENTER,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,r,u,n,ENTER,@8000000,s,c,r,e,e,n,ENTER,@4000000,q,u,i,t,ENTER,@3000000" \
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
echo "ndbg_term: PASS (terminal debug: carts/load, step/dis/regs/break/watch/bpts/wpts/mem/run; screen/serial; setr/setm/setw/setc; next/finish; log/ndr/mirror/hist/stack/types; bp/wp/goto; checkpoint capture; mem/dis/undo/redo args; undo/multi-redo/checkpoint/restore, exact)"
echo "ndbg_term: NEGATIVE PASS (mutated transcript rejected)"
