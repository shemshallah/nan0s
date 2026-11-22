#!/bin/sh
# tools/xgold.sh - rebuild the native x86 gold stream from .xa sources.
# The NaN-native assembler (src/prog/nasm1.nas) runs in the NaN16 core; the
# outer shell only stages source/bytes.  Output is src/native/nan16_x86.nan
# (boot 512 + kernel bytes), the stream tools/mkimg.awk consumes.
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/xgold.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CLI=aarch64/android/nan_cli; [ -x "$CLI" ] || (cd aarch64/android && make -s nan_cli)

asm_one() { # src out.bin
  src="$1"; out="$2"
  awk -v SRC="$src" 'BEGIN {
    printf ".org 0\n.include \"nasm1.nas\"\n.org 0x20000\n.str \""
    while ((getline line < SRC) > 0) {
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      printf "%s\\n", line
    }
    print "\""
  }' > src/prog/_xgold_h.nas
  awk -f tools/nmk.awk -v CMD=emit src/prog/_xgold_h.nas > "$T/h.nan"
  rm -f src/prog/_xgold_h.nas
  "$CLI" --img "$T/h.nan" --mem 16 --steps 2000000000 --serial > "$T/ser" 2>"$T/err" || true
  [ "$(head -c 1 "$T/ser")" = "Y" ] || { echo "xgold: assembler rejected $src"; tail -2 "$T/err"; exit 1; }
  tail -c +3 "$T/ser" > "$out"
}

asm_one x86/boot/kboot0.xa "$T/boot.bin"
asm_one src/native/kan16.xa "$T/kern.bin"
[ "$(wc -c < "$T/boot.bin")" -eq 512 ] || { echo "xgold: boot is not 512 bytes"; exit 1; }
[ "$(wc -c < "$T/kern.bin")" -le 65536 ] || { echo "xgold: kernel exceeds 128 boot sectors"; exit 1; }
python3 - "$T" <<'PY'
import sys
T=sys.argv[1]
boot=open(T+'/boot.bin','rb').read(); kern=open(T+'/kern.bin','rb').read()
out=['; NaN16 gold: boot 512 + kernel %d bytes (runtime E820 memory sizing)'%len(kern)]
for base,name,blob in [(0,'boot',boot),(512,'kernel',kern)]:
    for off in range(0,len(blob),16):
        out.append('%s   ; %s+%04X'%(' '.join('%02x'%b for b in blob[off:off+16]),name,off))
open('src/native/nan16_x86.nan','w').write('\n'.join(out)+'\n')
open('x86/native/nan16_x86.nan','w').write('\n'.join(out)+'\n')
print('xgold: boot 512 + kernel %d bytes' % len(kern))
PY
