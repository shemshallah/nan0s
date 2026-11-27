#!/bin/sh
# blockcache_run.sh - assemble one NaN source with the cached nasm1 blocks.
# Usage: blockcache_run.sh SOURCE OUT
# Emits exactly the bytes nasm1 writes after its leading "Y\n".
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C

SRC=$1
OUT=$2
[ -n "$SRC" ] && [ -n "$OUT" ] || { echo "usage: blockcache_run.sh SOURCE OUT" >&2; exit 1; }
T=build/cache
sh tools/blockcache_build.sh >/dev/null
[ -f "$T/cache.elf" ] || { echo "blockcache: no dispatcher" >&2; exit 1; }
(cd "$T" && sha256sum -c cache.sha256 >/dev/null 2>&1) ||
  { echo "blockcache: cache hash mismatch" >&2; exit 1; }
MASK_BASE=$(cat "$T/mask_base")

W=$T/run.$$
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
cp src/prog/nasm.nas src/prog/nasm0.nas src/prog/nasm0_tables.nas "$W/"

# Stage the source exactly as tools/xgold.sh does.
awk -v SRC="$SRC" 'BEGIN {
  printf ".org 0\n.include \"nasm.nas\"\n.org 0x20000\n.str \""
  while ((getline line < SRC) > 0) {
    gsub(/\\/, "\\\\", line)
    gsub(/"/, "\\\"", line)
    printf "%s\\n", line
  }
  print "\""
}' > "$W/stage.nas"
awk -f tools/nmk.awk -v CMD=emit "$W/stage.nas" > "$W/stage.nan" 2>"$W/nmk.err" ||
  { cat "$W/nmk.err" >&2; exit 1; }

awk '{
  line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
  n=split(line, a, "_")
  if (n==3 && length(a[1])==4 && length(a[2])==8 && length(a[3])==4)
    printf "%s%s%s%s%s%s%s%s", \
      substr(a[3],3,2), substr(a[3],1,2), \
      substr(a[2],7,2), substr(a[2],5,2), substr(a[2],3,2), substr(a[2],1,2), \
      substr(a[1],3,2), substr(a[1],1,2)
}' "$W/stage.nan" | xxd -r -p > "$W/guest.bin"
[ -s "$W/guest.bin" ] || { echo "blockcache: empty guest" >&2; exit 1; }

set +e
timeout 300 qemu-system-x86_64 -m 512 -kernel "$T/cache.elf" -display none \
  -serial "file:$W/ser" -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot \
  -device loader,file="$W/guest.bin",addr=0x200000,force-raw=on \
  -device loader,file="$T/nasm1.cache",addr=0x2000000,force-raw=on \
  -device loader,file="$T/nasm1.masks",addr="$MASK_BASE",force-raw=on \
  >/dev/null 2>"$W/qemu.err"
rc=$?
set -e
if [ "$rc" -ne 33 ]; then
  echo "blockcache: dispatcher failed rc=$rc (halt=33)" >&2
  head -c 200 "$W/ser" 2>/dev/null | cat -v >&2 || true
  cat "$W/qemu.err" >&2 || true
  exit 1
fi
[ "$(head -c 1 "$W/ser")" = "Y" ] || {
  echo "blockcache: nasm1 rejected $SRC" >&2
  head -c 200 "$W/ser" | cat -v >&2 || true
  exit 1
}
[ "$(dd if="$W/ser" bs=1 skip=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' ')" = "0a" ] ||
  { echo "blockcache: malformed nasm1 header" >&2; exit 1; }
tail -c +3 "$W/ser" > "$OUT"
