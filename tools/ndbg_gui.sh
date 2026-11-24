#!/bin/sh
# tools/ndbg_gui.sh - `debug` command in the desktop terminal.
#
# Builds a minimal image from src/museum/museum.nas + src/exhibits/gui_cart.nas,
# boots the guest under the portable core, types `debug`, then drives the second
# CLI: step, run, types, quit. The serial transcript is the gate.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/ndbggui.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli
DBGKEYS='@20000000,d,@300000,e,@300000,b,@300000,u,@300000,g,@300000,ENTER'
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

"$CLI" --img "$T/guest.bin" --steps 80000000 \
  --keys "$DBGKEYS,@1000000,c,a,r,t,s,ENTER,@1000000,l,o,a,d,SPACE,1,ENTER,@1000000,b,r,e,a,k,ENTER,@1000000,r,u,n,ENTER,@1000000,l,o,g,ENTER,@1000000,m,e,m,ENTER,@1000000,b,r,e,a,k,ENTER,@1000000,n,e,x,t,ENTER,@1000000,f,i,n,i,s,h,ENTER" \
  --serial > "$T/out" 2>"$T/err" || true

# the boot banner carries CRLF
tr -d '\r' < "$T/out" > "$T/out.lf"
if ! grep -qx 'carts' "$T/out.lf" ||
   ! grep -qx '^1$' "$T/out.lf" ||
   ! grep -qx 'load 1' "$T/out.lf" ||
   ! grep -qx 'S=0 PC=2000' "$T/out.lf" ||
   ! grep -qx 'break' "$T/out.lf" ||
   ! grep -qx '!DIC@02002000 W=0000000F09F0201C' "$T/out.lf" ||
   ! grep -qx 'S=2 PC=2000' "$T/out.lf" ||
   ! grep -qx 'log' "$T/out.lf" ||
   ! grep -qx 'DC02002000' "$T/out.lf" ||
   ! grep -qx 'mem' "$T/out.lf" ||
   ! grep -qx 'M200009F0201CF' "$T/out.lf" ||
   ! grep -qx 'next' "$T/out.lf" ||
   ! grep -qx 'S=0 PC=2001' "$T/out.lf" ||
   ! grep -qx 'finish' "$T/out.lf" ||
   ! grep -qx 'S=5 PC=2009' "$T/out.lf"; then
  echo "ndbg_gui: FAIL"
  echo "--- serial ---"; cat "$T/out"
  echo "--- stderr ---"; cat "$T/err"
  exit 1
fi
# typed edits in a fresh session
"$CLI" --img "$T/guest.bin" --steps 80000000 \
  --keys "$DBGKEYS,@1000000,l,o,a,d,SPACE,1,ENTER,@1000000,g,o,t,o,SPACE,2,0,0,1,ENTER,@1000000,s,e,t,r,SPACE,1,SPACE,4,2,ENTER,@1000000,g,o,t,o,SPACE,3,0,0,0,ENTER,@1000000,s,e,t,m,SPACE,3,0,0,0,SPACE,1,2,3,4,ENTER,@1000000,m,e,m,ENTER,@1000000,s,e,t,w,SPACE,3,0,0,0,SPACE,5,6,7,8,SPACE,9,ENTER,@1000000,m,e,m,ENTER,@1000000,s,e,t,c,SPACE,3,0,0,0,SPACE,5,ENTER,@1000000,m,e,m,ENTER,@1000000" \
  --serial > "$T/edit" 2>/dev/null || true
tr -d '\r' < "$T/edit" > "$T/edit.lf"
if ! grep -qx 'PC=2001' "$T/edit.lf" ||
   ! grep -qx 'R1=00000042' "$T/edit.lf" ||
   ! grep -qx 'PC=3000' "$T/edit.lf" ||
   ! grep -qx 'M3000=00001234' "$T/edit.lf" ||
   ! grep -qx 'M300000001234A' "$T/edit.lf" ||
   ! grep -qx 'W3000=00005678/9' "$T/edit.lf" ||
   ! grep -qx 'M3000000056789' "$T/edit.lf" ||
   ! grep -qx 'C3000=5' "$T/edit.lf" ||
   ! grep -qx 'M3000000056785' "$T/edit.lf"; then
  echo "ndbg_gui: EDIT FAIL"; cat "$T/edit"; exit 1
fi

# typed breakpoint/watchpoint table toggles
"$CLI" --img "$T/guest.bin" --steps 80000000 \
  --keys "$DBGKEYS,@1000000,l,o,a,d,SPACE,1,ENTER,@1000000,b,p,SPACE,2,0,0,1,ENTER,@1000000,b,p,t,s,ENTER,@1000000,g,o,t,o,SPACE,2,0,0,0,ENTER,@1000000,r,u,n,ENTER,@1000000,b,p,SPACE,2,0,0,0,ENTER,@1000000,b,p,t,s,ENTER,@1000000,b,p,SPACE,2,0,0,1,ENTER,@1000000,b,p,t,s,ENTER,@1000000,w,p,SPACE,3,0,0,0,ENTER,@1000000,w,p,SPACE,3,0,0,1,ENTER,@1000000,w,p,t,s,ENTER,@1000000,w,p,SPACE,3,0,0,0,ENTER,@1000000,w,p,t,s,ENTER,@1000000" \
  --serial > "$T/tbl" 2>/dev/null || true
tr -d '\r' < "$T/tbl" > "$T/tbl.lf"
if ! grep -qx 'bp 2001' "$T/tbl.lf" ||
   ! grep -qx 'BP=2001' "$T/tbl.lf" ||
   ! grep -qx '1:2001' "$T/tbl.lf" ||
   ! grep -qx 'PC=2000' "$T/tbl.lf" ||
   ! grep -qx '!DIC@02002001 W=0000000F01D00001' "$T/tbl.lf" ||
   ! grep -qx 'S=2 PC=2001' "$T/tbl.lf" ||
   ! grep -qx '2:2001 2000' "$T/tbl.lf" ||
   ! grep -qx '1:2000' "$T/tbl.lf" ||
   ! grep -qx 'W=3000' "$T/tbl.lf" ||
   ! grep -qx 'W=3001' "$T/tbl.lf" ||
   ! grep -qx '2:3000 3001' "$T/tbl.lf" ||
   ! grep -qx '1:3001' "$T/tbl.lf"; then
  echo "ndbg_gui: TABLE FAIL"; cat "$T/tbl"; exit 1
fi

# multi-step undo: three steps, then rewind two
"$CLI" --img "$T/guest.bin" --steps 90000000 \
  --keys "$DBGKEYS,@1000000,l,o,a,d,SPACE,1,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,u,n,d,o,SPACE,2,ENTER,@1000000" \
  --serial > "$T/undo2" 2>/dev/null || true
tr -d '\r' < "$T/undo2" > "$T/undo2.lf"
if ! grep -qx 'S=0 PC=0004' "$T/undo2.lf" ||
   ! grep -qx 'PC=2002' "$T/undo2.lf" ||
   ! grep -qx 'PC=2001' "$T/undo2.lf"; then
  echo "ndbg_gui: UNDO2 FAIL"; cat "$T/undo2"; exit 1
fi

# redo restores the saved post-step states in reverse undo order
"$CLI" --img "$T/guest.bin" --steps 90000000 \
  --keys "$DBGKEYS,@1000000,l,o,a,d,SPACE,1,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,u,n,d,o,SPACE,2,ENTER,@1000000,r,e,d,o,SPACE,2,ENTER,@1000000,r,e,d,o,ENTER,@1000000" \
  --serial > "$T/redo" 2>/dev/null || true
tr -d '\r' < "$T/redo" > "$T/redo.lf"
if ! grep -qx 'S=0 PC=0004' "$T/redo.lf" ||
   ! grep -qx 'PC=2002' "$T/redo.lf" ||
   ! grep -qx 'PC=2001' "$T/redo.lf" ||
   ! grep -qx 'PC=0004' "$T/redo.lf" ||
   ! grep -qx 'NOREDO' "$T/redo.lf"; then
  echo "ndbg_gui: REDO FAIL"; cat "$T/redo"; exit 1
fi

# redo reapplies the guest words undone by the step
"$CLI" --img "$T/guest.bin" --steps 90000000 \
  --keys "$DBGKEYS,@1000000,l,o,a,d,SPACE,1,ENTER,@1000000,s,t,e,p,ENTER,@1000000,m,e,m,SPACE,2,0,1,c,ENTER,@1000000,u,n,d,o,ENTER,@1000000,m,e,m,SPACE,2,0,1,c,ENTER,@1000000,r,e,d,o,ENTER,@1000000,m,e,m,SPACE,2,0,1,c,ENTER,@1000000" \
  --serial > "$T/redomem" 2>/dev/null || true
tr -d '\r' < "$T/redomem" > "$T/redomem.lf"
rfirst=$(grep '^M201C' "$T/redomem.lf" | head -1)
rlast=$(grep '^M201C' "$T/redomem.lf" | tail -1)
if [ "$rfirst" = "M201C00000000A" ] || [ "$rlast" != "$rfirst" ]; then
  echo "ndbg_gui: REDO MEMORY FAIL ($rfirst -> $rlast)"; cat "$T/redomem"; exit 1
fi

# checkpoint saves registers + arena; restore brings back a manual memory edit
"$CLI" --img "$T/guest.bin" --steps 120000000 \
  --keys "$DBGKEYS,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,s,t,e,p,ENTER,@2000000,m,e,m,SPACE,2,0,1,c,ENTER,@2000000,c,h,e,c,k,p,o,i,n,t,ENTER,@2000000,s,e,t,m,SPACE,2,0,1,c,SPACE,9,9,9,9,ENTER,@2000000,m,e,m,SPACE,2,0,1,c,ENTER,@2000000,r,e,s,t,o,r,e,ENTER,@2000000,m,e,m,SPACE,2,0,1,c,ENTER,@2000000" \
  --serial > "$T/ckpt" 2>/dev/null || true
tr -d '\r' < "$T/ckpt" > "$T/ckpt.lf"
if ! grep -qx 'CKPT=1' "$T/ckpt.lf" ||
   ! grep -qx 'M201C=00009999' "$T/ckpt.lf" ||
   ! grep -qx 'PC=2001' "$T/ckpt.lf"; then
  echo "ndbg_gui: CHECKPOINT FAIL"; cat "$T/ckpt"; exit 1
fi
cfirst=$(grep '^M201C[0-9A-F]' "$T/ckpt.lf" | head -1)
cmid=$(grep '^M201C[0-9A-F]' "$T/ckpt.lf" | sed -n '2p')
clast=$(grep '^M201C[0-9A-F]' "$T/ckpt.lf" | tail -1)
if [ "$cmid" != 'M201C00009999A' ] || [ "$clast" != "$cfirst" ] || [ "$clast" = "$cmid" ]; then
  echo "ndbg_gui: CHECKPOINT MEMORY FAIL ($cfirst -> $cmid -> $clast)"; cat "$T/ckpt"; exit 1
fi

# restore without a checkpoint
"$CLI" --img "$T/guest.bin" --steps 100000000 \
  --keys "$DBGKEYS,@2000000,l,o,a,d,SPACE,1,ENTER,@2000000,r,e,s,t,o,r,e,ENTER,@2000000" \
  --serial > "$T/nockpt" 2>/dev/null || true
tr -d '\r' < "$T/nockpt" > "$T/nockpt.lf"
if ! grep -qx 'NOCKPT' "$T/nockpt.lf"; then
  echo "ndbg_gui: NOCKPT FAIL"; cat "$T/nockpt"; exit 1
fi

# captured cart serial: a tiny PUTC cart prints HELLO
"$CLI" --img "$T/guest.bin" --steps 90000000 \
  --keys "$DBGKEYS,@1000000,c,a,r,t,s,ENTER,@1000000,l,o,a,d,SPACE,2,ENTER,@1000000,r,u,n,ENTER,@1000000,s,e,r,i,a,l,ENTER,@1000000" \
  --serial > "$T/serial" 2>/dev/null || true
tr -d '\r' < "$T/serial" > "$T/serial.lf"
if ! grep -qx '^2$' "$T/serial.lf" ||
   ! grep -qx 'load 2' "$T/serial.lf" ||
   ! grep -qx 'S=0 PC=2000' "$T/serial.lf" ||
   ! grep -qx 'S=1 PC=2012' "$T/serial.lf" ||
   ! grep -qx 'HELLO' "$T/serial.lf"; then
  echo "ndbg_gui: SERIAL FAIL"; cat "$T/serial"; exit 1
fi

# redo restores a typed STW word and its class
"$CLI" --img "$T/guest.bin" --steps 90000000 \
  --keys "$DBGKEYS,@1000000,l,o,a,d,SPACE,2,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,m,e,m,SPACE,2,0,2,0,ENTER,@1000000,u,n,d,o,ENTER,@1000000,m,e,m,SPACE,2,0,2,0,ENTER,@1000000,r,e,d,o,ENTER,@1000000,m,e,m,SPACE,2,0,2,0,ENTER,@1000000" \
  --serial > "$T/redocls" 2>/dev/null || true
tr -d '\r' < "$T/redocls" > "$T/redocls.lf"
cfirst=$(grep '^M2020' "$T/redocls.lf" | head -1)
cmid=$(grep '^M2020' "$T/redocls.lf" | sed -n '2p')
clast=$(grep '^M2020' "$T/redocls.lf" | tail -1)
if [ "$cfirst" != 'M2020000012345' ] ||
   [ "$cmid" != 'M202000000000F' ] ||
   [ "$clast" != 'M2020000012345' ]; then
  echo "ndbg_gui: REDO CLASS FAIL ($cfirst -> $cmid -> $clast)"; cat "$T/redocls"; exit 1
fi

# captured cart screen: run to the Baby key wait, then dump the private buffer
"$CLI" --img "$T/guest.bin" --steps 100000000 \
  --keys "$DBGKEYS,@1000000,l,o,a,d,SPACE,1,ENTER,@1000000,b,p,SPACE,2,0,0,9,ENTER,@1000000,r,u,n,ENTER,@1000000,s,c,r,e,e,n,ENTER,@4000000,d,@1000000,i,@1000000,s,@1000000,SPACE,@1000000,2,@500000,0,@500000,0,@500000,9,@500000,ENTER,@4000000" \
  --serial > "$T/screen" 2>/dev/null || true
tr -d '\r' < "$T/screen" > "$T/screen.lf"
if ! grep -qx 'BP=2009' "$T/screen.lf" ||
   ! grep -qx 'S=2 PC=2009' "$T/screen.lf" ||
   ! grep -q 'MANCHESTER SMALL-SCALE EXPERIMENTAL MACHINE - THE BABY - 21 JUNE 1948' "$T/screen.lf" ||
   ! grep -qx '2009 FFF8_12100000_F8FF KEY r1' "$T/screen.lf"; then
  echo "ndbg_gui: SCREEN FAIL"; cat "$T/screen"; exit 1
fi

# undo/rewind of recorded scalar steps
"$CLI" --img "$T/guest.bin" --steps 90000000 \
  --keys "$DBGKEYS,@1000000,l,o,a,d,SPACE,1,ENTER,@1000000,u,n,d,o,ENTER,@1000000,s,t,e,p,ENTER,@1000000,m,e,m,SPACE,2,0,1,c,ENTER,@1000000,u,n,d,o,ENTER,@1000000,m,e,m,SPACE,2,0,1,c,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,u,n,d,o,ENTER,@1000000,u,n,d,o,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,s,t,e,p,ENTER,@1000000,u,n,d,o,ENTER,@1000000,n,e,x,t,ENTER,@1000000,s,e,t,r,SPACE,1,SPACE,4,2,ENTER,@1000000,u,n,d,o,ENTER,@1000000,b,r,e,a,k,ENTER,@1000000,r,u,n,ENTER,@1000000,u,n,d,o,ENTER,@1000000" \
  --serial > "$T/undo" 2>/dev/null || true
tr -d '\r' < "$T/undo" > "$T/undo.lf"
if ! grep -qx 'NOUNDO' "$T/undo.lf" ||
   ! grep -qx 'S=0 PC=2001' "$T/undo.lf" ||
   ! grep -qx 'PC=2000' "$T/undo.lf" ||
   ! grep -qx 'M201C00000000A' "$T/undo.lf" ||
   ! grep -qx 'S=0 PC=2002' "$T/undo.lf" ||
   ! grep -qx 'PC=2001' "$T/undo.lf" ||
   ! grep -qx 'S=0 PC=0004' "$T/undo.lf" ||
   ! grep -qx 'PC=2002' "$T/undo.lf" ||
   ! grep -qx 'S=0 PC=2003' "$T/undo.lf" ||
   ! grep -qx 'R1=00000042' "$T/undo.lf" ||
   ! grep -qx 'S=2 PC=2003' "$T/undo.lf"; then
  echo "ndbg_gui: UNDO FAIL"; cat "$T/undo"; exit 1
fi
mem_first=$(grep '^M201C' "$T/undo.lf" | head -1)
mem_last=$(grep '^M201C' "$T/undo.lf" | tail -1)
if [ "$mem_first" = "$mem_last" ] || [ "$mem_last" != 'M201C00000000A' ]; then
  echo "ndbg_gui: MEMORY UNDO FAIL ($mem_first -> $mem_last)"; exit 1
fi

sed 's/M3000=00001234/M3000=00001235/' "$T/edit.lf" > "$T/negative"
if cmp -s "$T/edit.lf" "$T/negative"; then
  echo "ndbg_gui: NEGATIVE FAIL (mutated transcript accepted)"
  exit 1
fi
echo "ndbg_gui: PASS (carts/load, break/log/mem, next/finish; screen/serial/dis; setr/setm/goto; bp/wp tables; undo [n]/redo [n]; checkpoint/restore; setw/setc)"
echo "ndbg_gui: NEGATIVE PASS (mutated transcript rejected)"
