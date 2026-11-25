#!/bin/sh
# tools/s1_runner.sh - x86_64 bare-metal S1 runner with the gate CLI.
#
#   --img FILE [--mem MB] [--steps N] [--serial]
#   [--guest-script PATH] [--guest-stdout FILE] [--guest-stderr FILE]
#   [--peek 'ADDR[:LEN],...']
#
# FILE may be nmk .nan text or a flat NaN16 word cartridge (8-byte words).
# The guest runs on src/native64/s1_kabi.c -DS1_GUEST under QEMU x86_64 with
# the 512-byte boot fixture.  Guest PUTC bytes stay raw on COM1 before the
# framed control-block/peek protocol; this wrapper parses the frame, writes
# stdout/stderr files and prints peek words as %08X, like nan_cli.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)

usage() {
  echo "usage: $0 --img FILE [--mem MB] [--steps N] [--serial] [--guest-script PATH] [--guest-stdout FILE] [--guest-stderr FILE] [--peek 'ADDR[:LEN][,ADDR[:LEN]...]']" >&2
  exit 2
}
IMG=""; MEM_MB=128; STEPS=50000000; SERIAL=0; GOUT=""; GERR=""; PEEK=""; GSCRIPT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --img) [ "$#" -ge 2 ] || usage; IMG=$2; shift 2 ;;
    --mem) [ "$#" -ge 2 ] || usage; MEM_MB=$2; shift 2 ;;
    --steps) [ "$#" -ge 2 ] || usage; STEPS=$2; shift 2 ;;
    --serial) SERIAL=1; shift ;;
    --guest-script) [ "$#" -ge 2 ] || usage; GSCRIPT=$2; shift 2 ;;
    --guest-stdout) [ "$#" -ge 2 ] || usage; GOUT=$2; shift 2 ;;
    --guest-stderr) [ "$#" -ge 2 ] || usage; GERR=$2; shift 2 ;;
    --peek) [ "$#" -ge 2 ] || usage; PEEK=$2; shift 2 ;;
    *) echo "s1_runner: unknown argument $1" >&2; usage ;;
  esac
done
[ -n "$IMG" ] || usage
[ -f "$IMG" ] || { echo "s1_runner: no such image: $IMG" >&2; exit 1; }
case "$MEM_MB" in *[!0-9]*|"") echo "s1_runner: bad --mem" >&2; exit 2 ;; esac
case "$STEPS" in *[!0-9]*|"") echo "s1_runner: bad --steps" >&2; exit 2 ;; esac
[ "$MEM_MB" -eq 0 ] && MEM_MB=128
[ "$STEPS" -eq 0 ] && STEPS=50000000
QEMU_BIN=${QEMU:-qemu-system-x86_64}
command -v "$QEMU_BIN" >/dev/null 2>&1 || { echo "s1_runner: no $QEMU_BIN" >&2; exit 1; }
QEMU_ACCEL=""
if [ "${S1_QEMU_ACCEL:-}" = kvm ] && [ -e /dev/kvm ]; then
  QEMU_ACCEL="-enable-kvm -cpu host"
fi
if [ -n "${S1_QEMU_MEM:-}" ]; then QMEM=$S1_QEMU_MEM
else
    # --mem is MiB of C payload; guest words are 8 bytes and hold four C
    # bytes, so the machine needs twice that plus the kernel/BIOS/stack.
    QMEM=$((MEM_MB * 2 + 128))
    [ "$QMEM" -lt 256 ] && QMEM=256
fi

T="${TMPDIR:-/tmp}/s1_runner.$$"; mkdir -p "$T"; trap 'if [ "${S1_KEEP:-0}" = 1 ]; then echo "s1_runner: kept $T" >&2; else rm -rf "$T"; fi' EXIT INT TERM

# --mem MB follows nan_cli: MiB of guest C payload, power-of-two word count.
want=$((MEM_MB * 1024 * 1024 / 4))
WORDS=$((0x10000))
while [ "$WORDS" -lt "$want" ] && [ "$WORDS" -lt $((0x10000000)) ]; do WORDS=$((WORDS * 2)); done
if [ -n "${S1_GUEST_MEM:-}" ]; then WORDS=$((S1_GUEST_MEM)); fi
case "$WORDS" in *[!0-9]*|"") echo "s1_runner: bad S1_GUEST_MEM" >&2; exit 2 ;; esac
[ $((WORDS & (WORDS - 1))) -eq 0 ] || { echo "s1_runner: S1_GUEST_MEM must be a power of two" >&2; exit 2; }
SAFE=$(( (QMEM * 1024 * 1024 - 2097152) / 8 ))
[ "$SAFE" -lt $((0x1000)) ] && SAFE=$((0x1000))
[ "$SAFE" -gt "$WORDS" ] && SAFE=$WORDS

# Text .nan or flat 8-byte words.
if od -An -tu1 -N512 "$IMG" | awk '{for(i=1;i<=NF;i++){b=$i; if(b<9||(b>13&&b<32)||b>126) bad=1}} END{exit bad?1:0}'; then
  awk '{
    line=$0; sub(/;.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
    n=split(line, a, "_")
    if (n==3 && length(a[1])==4 && length(a[2])==8 && length(a[3])==4) {
      printf "%s%s%s%s%s%s%s%s", \
        substr(a[3],3,2), substr(a[3],1,2), \
        substr(a[2],7,2), substr(a[2],5,2), substr(a[2],3,2), substr(a[2],1,2), \
        substr(a[1],3,2), substr(a[1],1,2)
    }
  }' "$IMG" | xxd -r -p > "$T/guest.bin"
else
  cp "$IMG" "$T/guest.bin"
fi
BYTES=$(wc -c < "$T/guest.bin")
[ "$BYTES" -gt 0 ] || { echo "s1_runner: empty guest image" >&2; exit 1; }
[ $((BYTES % 8)) -eq 0 ] || { echo "s1_runner: guest image is not 8-byte words" >&2; exit 1; }
GWORDS=$((BYTES / 8))
[ "$GWORDS" -le "$WORDS" ] || { echo "s1_runner: image $GWORDS words > --mem capacity $WORDS" >&2; exit 1; }
[ "$GWORDS" -le "$SAFE" ] || { echo "s1_runner: image exceeds QEMU RAM (raise S1_QEMU_MEM)" >&2; exit 1; }

# Peek specs are word addresses/lengths, embedded at link time.
printf '%s' "$PEEK" | tr ',' '\n' > "$T/peeks.txt"
NPEEK=0
if [ -n "$PEEK" ]; then NPEEK=$(awk 'NF{n++} END{print n+0}' "$T/peeks.txt"); fi
{
  echo '.section .rodata'
  echo '.global s1_peek_count'
  echo "s1_peek_count: .long $NPEEK"
  echo '.global s1_peek_specs'
  echo 's1_peek_specs:'
  if [ "$NPEEK" -eq 0 ]; then
    echo '  .long 0,0'
  else
    awk -F: 'NF {a=$1; n=(NF>1 && $2!="" ? $2 : 1); print "  .long " a "," n}' "$T/peeks.txt"
  fi
  echo '.text'
} > "$T/peek.S"

# <=384 KiB: floppy staging through the boot fixture below the VGA aperture.
# Larger: raw IDE disk
# (QEMU if=ide) read by the S1 ATA PIO loader, no size cap below 2^28 sectors.
if [ "$BYTES" -le $((384 * 1024)) ]; then
  GDISK=0
  GSECT=$(( (BYTES + 511) / 512 ))
  [ "$GSECT" -le 768 ] || { echo "s1_runner: bad small-image sector count" >&2; exit 1; }
else
  GDISK=1
  GSECT=0
fi
cat > "$T/guest.S" <<EOF
.section .rodata
.global s1_guest_bytes
s1_guest_bytes: .long $BYTES
.global s1_guest_disk
s1_guest_disk: .long $GDISK
.text
EOF

STACK_DEF=""
[ -n "${S1_GUEST_STACK:-}" ] && STACK_DEF="-DS1_GUEST_STACK=$S1_GUEST_STACK"

clang --target=i386-none-elf -DS1_GUEST_SECTORS="$GSECT" -c src/native64/s1_bootsec.S -o "$T/bootsec.o"
ld.lld -m elf_i386 --image-base=0 -Ttext=0x7C00 -e _start -o "$T/bootsec.elf" "$T/bootsec.o"
llvm-objcopy -O binary "$T/bootsec.elf" "$T/bootsec.bin"
[ "$(wc -c < "$T/bootsec.bin")" -eq 512 ]
clang --target=x86_64-none-elf -c src/native64/s1_boot.S -o "$T/boot.o"
clang --target=x86_64-none-elf -std=gnu99 -O3 -Wall -Wextra -ffp-contract=off -fno-fast-math \
  -ffreestanding -fno-builtin -fno-stack-protector -mno-red-zone \
  -DS1_GUEST -DS1_GUEST_MEM="$WORDS" -DS1_GUEST_STEPS="$STEPS" \
  -DS1_GUEST_ZERO_WORDS="$SAFE" $STACK_DEF \
  -c src/native64/s1_kabi.c -o "$T/s1.o"
python3 - "$GSCRIPT" "$T/script.S" <<'PY'
import sys
path = sys.argv[1].encode("utf-8")
with open(sys.argv[2], "w") as f:
    f.write(".section .rodata\n")
    f.write(".global s1_script_len\ns1_script_len: .long %d\n" % len(path))
    f.write(".global s1_script_data\ns1_script_data:\n")
    if path:
        for i in range(0, len(path), 16):
            f.write("  .byte " + ",".join(str(b) for b in path[i:i+16]) + "\n")
    else:
        f.write("  .byte 0\n")
    f.write(".text\n")
PY

clang --target=x86_64-none-elf -c "$T/script.S" -o "$T/script.o"
clang --target=x86_64-none-elf -c "$T/guest.S" -o "$T/guest.o"
clang --target=x86_64-none-elf -c "$T/peek.S" -o "$T/peek.o"
ld.lld -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
  -o "$T/s1.elf" "$T/boot.o" "$T/s1.o" "$T/guest.o" "$T/script.o" "$T/peek.o"
llvm-objcopy -O binary "$T/s1.elf" "$T/s1.bin"
[ "$(wc -c < "$T/s1.bin")" -le 65536 ] || { echo "s1_runner: S1 image > 64 KiB" >&2; exit 1; }
cat "$T/bootsec.bin" "$T/s1.bin" > "$T/image"
truncate -s 66048 "$T/image"          # boot + 64 KiB kernel window
if [ "$GDISK" -eq 0 ]; then
  cat "$T/guest.bin" >> "$T/image"    # LBA 129: boot staging at 0x40000
fi
truncate -s 1474560 "$T/image"
if [ "$GDISK" -eq 1 ]; then
  cp "$T/guest.bin" "$T/guest.disk"
  truncate -s $(( ((BYTES + 511) / 512) * 512 )) "$T/guest.disk"
  DRIVE="-drive format=raw,if=ide,index=0,file=$T/guest.disk"
else
  DRIVE=""
fi

rm -f "$T/com" "$T/dbg"
timeout "${S1_QEMU_TIMEOUT:-600}" "$QEMU_BIN" -m "$QMEM" $QEMU_ACCEL \
  -drive format=raw,if=floppy,file="$T/image" $DRIVE -boot a \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -display none -serial "file:$T/com" -debugcon "file:$T/dbg" \
  -no-reboot >/dev/null 2>&1 || true

python3 - "$T/com" "$T/dbg" "$GOUT" "$GERR" "$SERIAL" <<'PY'
import re, sys
com, dbg, gout, gerr, serial = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
data = open(com, "rb").read()
mark = b"@@NAN16 SOUT "
i = data.find(mark)
if i < 0:
    sys.stderr.write("s1_runner: no @@NAN16 frame on COM1\n")
    sys.stderr.buffer.write(b"--- COM1 tail ---\n" + data[-4096:] + b"\n")
    try:
        sys.stderr.buffer.write(b"--- debugcon ---\n" + open(dbg, "rb").read()[-4096:] + b"\n")
    except OSError:
        pass
    sys.exit(2)
prefix, frame = data[:i], data[i:]
pos = 0
def take(pat):
    global pos
    m = re.match(pat, frame[pos:])
    if not m:
        sys.stderr.write("s1_runner: malformed frame\n")
        sys.exit(2)
    pos += m.end()
    return m
m = take(rb"@@NAN16 SOUT (\d+)\n")
sout = frame[pos:pos+int(m.group(1))]; pos += int(m.group(1))
if frame[pos:pos+1] != b"\n": sys.stderr.write("s1_runner: missing SOUT newline\n"); sys.exit(2)
pos += 1
m = take(rb"@@NAN16 SERR (\d+)\n")
serr = frame[pos:pos+int(m.group(1))]; pos += int(m.group(1))
if frame[pos:pos+1] != b"\n": sys.stderr.write("s1_runner: missing SERR newline\n"); sys.exit(2)
pos += 1
peeks, end_rc = [], None
for line in frame[pos:].split(b"\n"):
    if line.startswith(b"@@NAN16 PEEK "):
        peeks.append(int(line[13:].decode(), 16))
    elif line.startswith(b"@@NAN16 END "):
        end_rc = int(line[12:].decode()); break
if end_rc is None:
    sys.stderr.write("s1_runner: missing END\n"); sys.exit(2)
if end_rc != 3:
    sys.stderr.write("s1_runner: guest did not HALT cleanly (END %d)\n" % end_rc)
    sys.exit(1)
if gout:
    open(gout, "wb").write(sout)
if gerr:
    open(gerr, "wb").write(serr)
if serial:
    sys.stdout.buffer.write(prefix)
for v in peeks:
    sys.stdout.write("%08X\n" % (v & 0xFFFFFFFF))
PY
grep -q "S1GUEST LOAD $GWORDS WORDS" "$T/dbg" || {
  echo "s1_runner: loader word count mismatch on debugcon" >&2
  cat "$T/dbg" >&2; exit 1; }
grep -q 'S1GUEST HALT rc=3' "$T/dbg" || {
  echo "s1_runner: guest did not HALT" >&2
  cat "$T/dbg" >&2; exit 1; }
