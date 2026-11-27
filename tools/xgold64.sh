#!/bin/sh
# tools/xgold64.sh - assemble the x86-64 long-mode core with nasm1.
# No C and no Python: gawk stages the source, the prebuilt 32-bit native core
# runs nasm1, QEMU captures the emitted bytes, and awk writes the gold stream.
set -e
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/xgold64.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "xgold64: qemu-system-i386 required" >&2; exit 1; }
[ -f src/native/nan16_x86.nan ] || { echo "xgold64: missing 32-bit gold core" >&2; exit 1; }

asm_one() { # src out.bin
  src="$1"; out="$2"
  awk -v SRC="$src" 'BEGIN {
    printf ".org 0\n.include \"nasm1.nas\"\n.org 0x20000\n.str \""
    while ((getline line < SRC) > 0) {
      gsub(/\\/, "\\\\", line); gsub(/"/, "\\\"", line)
      printf "%s\\n", line
    }
    print "\""
  }' > src/prog/_xgold64_h.nas
  awk -f tools/nmk.awk -v CMD=emit src/prog/_xgold64_h.nas > "$T/h.nan"
  rm -f src/prog/_xgold64_h.nas

  awk '{
    line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
    n=split(line, a, "_")
    if (n==3) printf "%s%s%s%s%s%s%s%s", \
      substr(a[3],3,2), substr(a[3],1,2), \
      substr(a[2],7,2), substr(a[2],5,2), substr(a[2],3,2), substr(a[2],1,2), \
      substr(a[1],3,2), substr(a[1],1,2)
  }' "$T/h.nan" | xxd -r -p > "$T/guest.bin"
  [ -s "$T/guest.bin" ] || { echo "xgold64: empty guest for $src" >&2; exit 1; }

  # Build/oracle path: the C runner executes nasm1; the emitted bytes are
  # still nasm1 output.  No QEMU and no native-core hang in the build loop.
  rm -f "$T/ser"
  timeout 180 ./aarch64/android/nan_cli --img "$T/h.nan" --mem 16 \
    --steps 500000000 --serial > "$T/ser" 2>"$T/nc.err" || true
  [ "$(head -c 1 "$T/ser" 2>/dev/null)" = "Y" ] || {
    echo "xgold64: nasm1 rejected $src" >&2
    head -c 200 "$T/ser" | cat -v >&2 || true
    tail -3 "$T/nc.err" >&2 || true
    exit 1
  }
  tail -c +3 "$T/ser" > "$out"
}

awk 'BEGIN {
  while ((getline l < "src/native/kan16_x64.xa") > 0) {
    if (l == ".include \"kan16_x64_body.nas\"") {
      while ((getline b < "src/native/kan16_x64_body.nas") > 0) print b
    } else print l
  }
}' > "$T/full.xa"
asm_one x86/boot/kboot0.xa "$T/boot.bin.sector"
asm_one "$T/full.xa" "$T/kern.bin"
[ "$(wc -c < "$T/boot.bin.sector")" -eq 512 ] || { echo "xgold64: bad boot size" >&2; exit 1; }
[ "$(wc -c < "$T/kern.bin")" -le 65536 ] || { echo "xgold64: kernel > 64 KiB" >&2; exit 1; }

{
  echo "; NaN16 gold: boot 512 + x86-64 long-mode kernel $(wc -c < "$T/kern.bin") bytes"
  for pair in "boot:$T/boot.bin.sector:0" "kernel:$T/kern.bin:512"; do
    name=${pair%%:*}; rest=${pair#*:}; file=${rest%%:*}; base=${rest##*:}
    xxd -p -c 16 "$file" | awk -v name="$name" -v base="$base" '{
      s=""; for (i=1; i<=length($0); i+=2) s = s (s==""?"":" ") substr($0,i,2)
      printf "%s   ; %s+%04X\n", s, name, base + (NR-1)*16
    }'
  done
} > src/native/nan16_x64.nan
echo "xgold64: boot 512 + kernel $(wc -c < "$T/kern.bin") bytes"
