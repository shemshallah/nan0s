#!/bin/sh
# tools/ndbg_mon.sh - serial monitor gate for NANDBG.
#
# Drives a real scripted session: step twice, disassemble, print registers,
# set a breakpoint, run into it, clear it, run to HALT, quit. The whole serial
# transcript is exact. A second run mutates one byte and requires rejection.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-$PWD/build}/ndbgmon.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli
[ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)
awk -f tools/nmk.awk -v CMD=emit src/dbg/n16dbg.nas > "$T/m.nan" 2>"$T/asm.err" || {
  cat "$T/asm.err"; echo "ndbg_mon: ASSEMBLY FAIL"; exit 1;
}
"$CLI" --img "$T/m.nan" --steps 5000000 --keys "s,s,l,f,t,m,d,p,g,2,0,0,2,ENTER,b,r,n,v,b,w,3,0,0,0,ENTER,r,m,w,3,0,0,0,ENTER,s,r,o,H,R,2,0,0,0,Q,q" --serial > "$T/out" 2>"$T/err" || true
cat > "$T/expected" <<'EOF'
NANDBG MONITOR - s step  r run  b break  g goto  w watch  l hist  t stack  m types  p regs  d dis  x dump  n ndr  v mirror  f seal  o ndp  q quit
> S=0 PC=2001
> S=0 PC=2002
> HIST 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 2000 2001 
> HSEAL CFA1992A
> STACK empty
> TYPES FC:00 FM:00 FD:00 FS:00 
TYPES PC:00 PM:00 PD:00 PS:00 
TYPES WC:00 WM:00 WD:00 WS:00 
TYPES IC:00 IM:00 ID:00 IS:00 
> 2002 FFF8_0311000D_F8FF ADD r1,r1,r13
2003 FFF8_0120000A_F8FF MOVI r2,10
2004 FFF8_07010002_F8FF CMP r1,r2
2005 7FF1_0A002002_F87F JMP[LT] 8194
> K=0
R0=00000000 R1=00000000 R2=00000000 R3=00000000 R4=00000000 R5=00000000 R6=00000000 R7=00000000 
R8=00000000 R9=00000000 RA=00000000 RB=00000000 RC=00000000 RD=00000001 RE=00000000 RF=00000000 
> addr> PC=2002
> BP=2002
> !DIC@02002002 W=0000000F0311000D
S=2 PC=2002
> NDR 02000000 00002002 0311000D 0000000F 00000000 00000000 00000000 4B274FA1 
> MIRROR OK
> BP=off
> watch> W=3000
> !DIM@03002008 W=0000000A00000000
S=2 PC=2007
> TYPES FC:00 FM:00 FD:00 FS:00 
TYPES PC:00 PM:00 PD:00 PS:00 
TYPES WC:00 WM:00 WD:00 WS:00 
TYPES IC:01 IM:01 ID:00 IS:00 
> watch> W=off
> S=0 PC=2008
> S=1 PC=200A
> NDP
NDP1
R 2000 01D00001
BYE
> 
EOF
# the monitor halts immediately after the final prompt, with no newline
truncate -s -1 "$T/expected"
if ! cmp -s "$T/out" "$T/expected"; then
  echo "ndbg_mon: FAIL"
  diff -u "$T/expected" "$T/out" | head -40
  cat "$T/err"
  exit 1
fi
sed 's/PC=2007/PC=2008/' "$T/out" > "$T/negative"
if cmp -s "$T/out" "$T/negative"; then
  echo "ndbg_mon: NEGATIVE FAIL (mutated transcript accepted)"
  exit 1
fi
echo "ndbg_mon: PASS (step, disasm, regs, hist, stack, types, goto, breakpoint, watch, NDR, mirror, seal, NDP, run, quit, exact)"
echo "ndbg_mon: NEGATIVE PASS (mutated transcript rejected)"
