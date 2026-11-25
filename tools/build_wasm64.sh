#!/bin/sh
# Host-only packaging for the WASM x86-64 player. No guest code generation in JS.
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
OUT="$(pwd)/docs/wasm64"
mkdir -p "$OUT"
sh tools/build.sh
python3 - "$T/system.bin" "$OUT/palette.json" <<'PY'
import sys,re,json,struct
d=open('build/nan0s.img','rb').read()
n=int.from_bytes(d[504:508],'little')
p=d[512+65536:512+65536+n*8]
assert n and len(p)==n*8
open(sys.argv[1],'wb').write(p)
s=open('src/lib/fb.nas').read().split('pal_tab:',1)[1].split('.word 0xFFFF',1)[0]
pal=[[0,0,0] for _ in range(256)]
for i,r,g,b in re.findall(r'\.word (\d+),(\d+),(\d+),(\d+)',s):
    pal[int(i)]=[round(int(v)*255/63) for v in (r,g,b)]
json.dump(pal,open(sys.argv[2],'w'))
PY
S1_EXPORT_DIR="$OUT" S1_QEMU_MEM=512 sh tools/s1_runner.sh --img "$T/system.bin" --mem 64 --steps 18446744073709551615
sha256sum "$OUT"/boot64.img "$OUT"/system64.img
