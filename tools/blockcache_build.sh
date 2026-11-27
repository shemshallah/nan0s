#!/bin/sh
# blockcache_build.sh - build the nasm1 block cache and native dispatcher.
#
# The cache is a pure function of nasm1's compiled word image and the NaN
# translator.  It is regenerated only when that key changes.  The translator
# runs under the reference NaN VM once; tools/xgold.sh then executes the
# resulting native blocks under QEMU.  A committed cache lets a build run
# without nan_cli or a host toolchain.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C

T=build/cache
NAN_CLI=${NAN_CLI:-aarch64/android/nan_cli}
FORCE=${1:-}
mkdir -p "$T"

KEY=$(cat src/prog/nasm1.nas src/prog/nasm1_cache.nas \
          src/translate/x64_block.nas src/translate/x86_64.nas \
          src/translate/abi64.nas src/native64/cache_body.S \
          src/native64/cache.ld tools/blockcache_build.sh |
      sha256sum | awk '{print $1}')
if [ "$FORCE" != "--force" ] && [ -f "$T/key" ] && [ "$(cat "$T/key")" = "$KEY" ] &&
   [ -f "$T/nasm1.cache" ] && [ -f "$T/nasm1.masks" ] && [ -f "$T/cache.elf" ] &&
   [ -f "$T/cache.sha256" ] &&
   (cd "$T" && sha256sum -c cache.sha256 >/dev/null 2>&1); then
  echo "blockcache: up to date $KEY"
  exit 0
fi

[ -x "$NAN_CLI" ] || { echo "blockcache: missing $NAN_CLI (needed to regenerate the cache)" >&2; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "blockcache: clang is required" >&2; exit 1; }
command -v ld.lld >/dev/null 2>&1 || { echo "blockcache: ld.lld is required" >&2; exit 1; }

echo "blockcache: building $KEY"
awk -f tools/nmk.awk -v CMD=emit src/prog/nasm1.nas > "$T/nasm1.nan"
grep -E '^[0-9A-Fa-f]{4}_[0-9A-Fa-f]{8}_[0-9A-Fa-f]{4}' "$T/nasm1.nan" |
  sed 's/[[:space:]].*//' | awk '{print ".raw "$0}' > "$T/nasm1_words.nas"
N=$(grep -c '^\.raw ' "$T/nasm1_words.nas")
[ "$N" -gt 0 ] || { echo "blockcache: empty nasm1 word table" >&2; exit 1; }

sed "s/@CACHE_N@/$N/" src/prog/nasm1_cache.nas > "$T/gen.nas"
X64_R=32768 X64_XPC=32980 X64_FLAGM=32832 X64_MASK=32960 \
X64_HALT=32984 X64_TRAP=32988 X64_V=8192 \
  awk -f tools/nmk.awk -v CMD=emit "$T/gen.nas" > "$T/gen.nan"

# Two runs, one dump each: the CLI keeps only one --dump-bytes option.
timeout 600 "$NAN_CLI" --img "$T/gen.nan" --mem 64 --steps 500000000 --serial \
  --dump-bytes "0x100000:$((N * 512)):$T/nasm1.cache" > "$T/gen.out1" 2>"$T/gen.err1" || true
timeout 600 "$NAN_CLI" --img "$T/gen.nan" --mem 64 --steps 500000000 --serial \
  --dump-bytes "0x300000:$N:$T/nasm1.masks" > "$T/gen.out2" 2>"$T/gen.err2" || true
[ "$(head -c 1 "$T/gen.out1")" = "Y" ] || { echo "blockcache: translator run 1 failed" >&2; head -c 200 "$T/gen.out1" >&2; exit 1; }
[ "$(head -c 1 "$T/gen.out2")" = "Y" ] || { echo "blockcache: translator run 2 failed" >&2; head -c 200 "$T/gen.out2" >&2; exit 1; }
[ "$(wc -c < "$T/nasm1.cache")" -eq "$((N * 512))" ] || { echo "blockcache: bad cache size" >&2; exit 1; }
[ "$(wc -c < "$T/nasm1.masks")" -eq "$N" ] || { echo "blockcache: bad mask size" >&2; exit 1; }

MASK_BASE=$(printf '0x%X' $((0x2000000 + N * 512)))
sed -e "s/^\.equ CACHE_N,.*/.equ CACHE_N, $N/" \
    -e "s/^\.equ MASK_BASE,.*/.equ MASK_BASE, $MASK_BASE/" \
    src/native64/cache_body.S > "$T/cache_body.S"
clang --target=i386-none-elf -c "$T/cache_body.S" -o "$T/cache.o"
ld.lld -m elf_i386 -T src/native64/cache.ld -o "$T/cache.elf" "$T/cache.o"
printf '%s\n' "$MASK_BASE" > "$T/mask_base"
printf '%s\n' "$N" > "$T/count"
printf '%s\n' "$KEY" > "$T/key"
(cd "$T" && sha256sum nasm1.cache nasm1.masks cache.elf > cache.sha256)
echo "blockcache: $N words, cache $(wc -c < "$T/nasm1.cache") bytes, masks $N bytes, $MASK_BASE"
