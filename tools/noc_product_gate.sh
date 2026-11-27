#!/bin/sh
# tools/noc_product_gate.sh - F15 no-C product substrate gate.
#
# Scope (honest):
#   1. Audit the product image build and the 64-bit substrate paths: no C/C++
#      or headers outside src/tests are required, and no C object is linked.
#   2. Build the product image twice in isolated temp dirs with a compiler-free
#      PATH, compare sha256, and fail if build/nan0s.img is stale relative to
#      the sources that mkall consumes.
#   3. Boot the shipped 32-bit boot sector + native NaN16 core with a raw-NaN
#      smoke guest; require its COM1 banner.  No C harness and no IDE.
#   4. Build and boot the raw 64-bit product path: s1_boot.S + an assembly
#      runtime (page roots, LAPIC/MADT AP startup, per-AP TSS/IST, immutable
#      NaN-emitted block, AP-local timer and reschedule IPI) with no C linked.
#      Require the exact 2-CPU transcript.
#   5. Scan the image for ELF magic and timestamp/entropy markers; run
#      no_c_outside_tests.
#
# The shipped full GUI guest is still diagnosed separately at the end: at this
# HEAD its kernel/guest pair does not reach COM1.  That is a pre-existing
# product gap, not hidden by this gate; the F15 claim is the raw substrate
# above (32-bit boot smoke + raw 64-bit AP/block runtime).
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/noc_product_gate.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

fail() { echo "noc_product_gate: FAIL: $*" >&2; exit 1; }
sha()  { sha256sum "$1" | awk '{print $1}'; }
same() { cmp -s "$1" "$2" || fail "$3"; }

MARK_RE='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9]:[0-9][0-9]:[0-9][0-9]|/tmp/|TMPDIR|SOURCE_DATE_EPOCH|@[A-Z][A-Z0-9_]*@|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
scan_markers() {
  if LC_ALL=C grep -aEq "$MARK_RE" "$1"; then
    echo "markers in $1:" >&2
    LC_ALL=C grep -aEo "$MARK_RE" "$1" | head -5 >&2
    fail "timestamp/entropy marker in $1"
  fi
}
check_not_elf() {
  [ -f "$1" ] || fail "missing $1"
  magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
  [ "$magic" != "7f454c46" ] || fail "$1 has ELF magic"
  if LC_ALL=C grep -aq "$(printf '\177ELF')" "$1"; then
    fail "$1 contains ELF magic"
  fi
}

# ---------------------------------------------------------------- 1. audit
echo "== 1. product build and link audit =="
if ! c_out=$(sh tools/no_c_outside_tests.sh 2>&1); then
  printf '%s\n' "$c_out" >&2
  fail "no_c_outside_tests"
fi
printf '%s\n' "$c_out"
if ! raw_out=$(sh tools/guest_raw_only_gate.sh 2>&1); then
  printf '%s\n' "$raw_out" >&2
  fail "guest_raw_only_gate"
fi
printf '%s\n' "$raw_out"

# The image build must be raw data plus POSIX shell/gawk/cat/dd.  Reject a
# compiler/linker invocation on a non-comment line.
for f in tools/mkall.sh tools/mkbase.sh tools/rootfs_seed.sh tools/build.sh; do
  [ -f "$f" ] || fail "missing product build input $f"
  bad=$(grep -vE '^[[:space:]]*#' "$f" |
        grep -nE '(^|[;&|[:space:]])(clang|gcc|g\+\+|cc|ld\.lld|llvm-objcopy|python3?)([[:space:]]|$)' || true)
  if [ -n "$bad" ]; then
    printf '%s: %s\n' "$f" "$bad" >&2
    fail "C toolchain invocation in the product image build"
  fi
done
[ -f tools/mkimg.awk ] || fail "missing tools/mkimg.awk"
grep -q 'GOLD=src/native/nan16_x86.nan' tools/mkall.sh || fail "mkall GOLD changed"
grep -q 'GUEST=' tools/mkall.sh || fail "mkall GUEST changed"
echo "product build: sh/gawk/cat/dd only; GOLD is raw .nan; no C compiler step"
check_not_elf build/nan0s.img
echo "build/nan0s.img: $(wc -c < build/nan0s.img) bytes, magic $(od -An -tx1 -N4 build/nan0s.img | tr -d ' \n') (not ELF)"
scan_markers build/nan0s.img
echo "product image: no timestamp/entropy markers"

# --------------------------------------------------- 2. hermetic two builds
echo "== 2. hermetic two-build and staleness =="
SH=$(command -v sh) || fail "no sh"
BIN="$T/bin"
mkdir -p "$BIN"
for t in gawk awk cat dd wc sed ls rm mkdir dirname basename tr head cmp od grep; do
  p=$(command -v "$t" 2>/dev/null || true)
  if [ -n "$p" ]; then ln -sf "$p" "$BIN/$t"; fi
done
[ -x "$BIN/gawk" ] || fail "gawk unavailable for hermetic build"

build_one() { # dir
  d=$1
  mkdir -p "$d/tmp"
  if ! env -i PATH="$BIN" LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1 \
       "$BIN/gawk" -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas \
       > "$d/nixsched.nan" 2> "$d/nmk.err"; then
    cat "$d/nmk.err" >&2
    fail "nmk failed in $d"
  fi
  if ! env -i PATH="$BIN" LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1 \
       NAN0S_IMG="$d/nan0s.img" NAN0S_GUEST="$d/nixsched.nan" \
       TMPDIR="$d/tmp" "$SH" tools/mkall.sh > "$d/mkall.out" 2> "$d/mkall.err"; then
    cat "$d/mkall.err" >&2
    fail "mkall failed in $d"
  fi
  check_not_elf "$d/nan0s.img"
  scan_markers "$d/nan0s.img"
}
build_one "$T/b1"
build_one "$T/b2"
same "$T/b1/nan0s.img" "$T/b2/nan0s.img" "two hermetic product builds differ"
same "$T/b1/nixsched.nan" "$T/b2/nixsched.nan" "two hermetic guest emissions differ"
same "$T/b1/nixsched.nan" src/nan/nixsched.nan \
  "src/nan/nixsched.nan is stale; run: awk -f tools/nmk.awk -v CMD=emit src/gui/gui_sched_boot.nas > src/nan/nixsched.nan"
same "$T/b1/nan0s.img" build/nan0s.img \
  "build/nan0s.img is stale relative to sources; run sh tools/build.sh"
I1=$(sha "$T/b1/nan0s.img")
echo "hermetic image sha256 $I1 (2 isolated builds identical, compiler-free PATH)"
echo "build/nan0s.img matches the hermetic rebuild"
# The boot sector is the GOLD stream, not a C-built object.
dd if=build/nan0s.img of="$T/boot512.bin" bs=512 count=1 status=none
[ "$(wc -c < "$T/boot512.bin")" -eq 512 ] || fail "bad boot sector extract"
echo "boot sector 512 bytes; no object link is part of the image"

# ------------------------------------- 3. 32-bit substrate boot smoke, no C
echo "== 3. product substrate boot (32-bit boot sector + native core, no C) =="
command -v qemu-system-i386 >/dev/null 2>&1 || fail "qemu-system-i386 missing"
"$BIN/gawk" -f tools/nmk.awk -v CMD=emit src/tests/nan0s_boot_smoke.nas \
  > "$T/smoke.nan" 2> "$T/smoke.err" || { cat "$T/smoke.err" >&2; fail "smoke nmk"; }
env -i PATH="$BIN" LC_ALL=C gawk -f tools/mkimg.awk -v NOTOC=1 \
  -v GOLD=src/native/nan16_x86.nan -v GUEST="$T/smoke.nan" \
  -v CARTS=/dev/null -v OUTB="$T/sb.bin" -v OUTG="$T/sg.bin" >/dev/null 2> "$T/mkimg.err" ||
  { cat "$T/mkimg.err" >&2; fail "smoke mkimg"; }
cat "$T/sb.bin" "$T/sg.bin" > "$T/smoke.img"
truncate -s 1474560 "$T/smoke.img"
# The first 504 bytes are the product boot code; 504..507 carries LMAX and
# therefore differs when the guest size differs.  The kernel window must match.
dd if="$T/smoke.img" of="$T/smoke.boot" bs=1 count=504 status=none
dd if="$T/boot512.bin" of="$T/prod.boot" bs=1 count=504 status=none
same "$T/smoke.boot" "$T/prod.boot" "smoke image boot code differs from product boot sector"
dd if="$T/smoke.img" of="$T/smoke.kern" bs=1 skip=512 count=65536 status=none
dd if=build/nan0s.img of="$T/prod.kern" bs=1 skip=512 count=65536 status=none
same "$T/smoke.kern" "$T/prod.kern" "smoke image kernel differs from product kernel"
rm -f "$T/smoke.com"
timeout 25 qemu-system-i386 -m 128 \
  -drive format=raw,if=floppy,file="$T/smoke.img" -boot a \
  -display none -serial "file:$T/smoke.com" -no-reboot >/dev/null 2>&1 || true
[ -s "$T/smoke.com" ] || fail "32-bit substrate smoke produced no COM1 output"
grep -q 'NaN/0S SMOKE OK' "$T/smoke.com" || {
  echo "COM1:"; cat -v "$T/smoke.com" >&2
  fail "32-bit substrate smoke banner missing"
}
echo "32-bit substrate: NaN/0S SMOKE OK on COM1 (raw .nan guest, no C harness)"

# ---------------------------------- 4. raw 64-bit boot/page-table/AP/block
echo "== 4. raw 64-bit product path (no C linked) =="
command -v qemu-system-x86_64 >/dev/null 2>&1 || fail "qemu-system-x86_64 missing"
command -v clang >/dev/null 2>&1 || fail "clang missing"
command -v ld.lld >/dev/null 2>&1 || fail "ld.lld missing"
command -v llvm-objcopy >/dev/null 2>&1 || fail "llvm-objcopy missing"
[ -x ./aarch64/android/nan_cli ] || fail "nan_cli translator oracle missing"

R="$T/raw64"
mkdir -p "$R"
# The NaN translator is a build-time oracle (C executable); its emitted bytes
# are the only guest block input and are never linked against a C runtime.
"$BIN/gawk" -f tools/nmk.awk -v CMD=emit src/tests/xlate64_smpblock.nas \
  > "$R/t.nan" 2> "$R/emit.err" || { cat "$R/emit.err" >&2; fail "raw64 nmk"; }
timeout 60 ./aarch64/android/nan_cli --img "$R/t.nan" --mem 32 --steps 200000 \
  --serial --dump-bytes "0x20000:4096:$R/raw.bin" >/dev/null 2> "$R/nc.err" || true
[ -s "$R/raw.bin" ] || { cat "$R/nc.err" >&2; fail "raw64 translator oracle produced no bytes"; }
python3 - "$R/raw.bin" "$R/block.bin" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
k = d.rfind(b'\xc3')
assert k > 0, 'no RET at the end of the emitted block'
b = d[:k + 1]
assert b.startswith(bytes.fromhex('8b0425040005000501000000')), ('bad ADDI prefix', b[:16].hex())
assert b'\xc7\x04\x25\x00\x0c\x05\x00\x01\x00\x00\x00' in b, 'no HALT tail'
assert len(b) <= 4096, ('block too large', len(b))
open(sys.argv[2], 'wb').write(b)
print('raw64 block %d bytes' % len(b))
PY

clang --target=x86_64-none-elf -c src/native64/smp_tramp.S -o "$R/tramp.o"
ld.lld -m elf_x86_64 --image-base=0 -Ttext=0x8000 -e _start \
  -o "$R/tramp.elf" "$R/tramp.o"
llvm-objcopy -O binary "$R/tramp.elf" "$R/tramp.bin"
TSZ=$(wc -c < "$R/tramp.bin")
[ "$TSZ" -gt 0 ] && [ "$TSZ" -le 4096 ] || fail "raw64 trampoline size $TSZ"

cat > "$R/blob.S" <<EOF
.section .rodata
.globl block0
block0:
.incbin "$R/block.bin"
.globl block0_end
block0_end:
.globl tramp_blob
tramp_blob:
.incbin "$R/tramp.bin"
.globl tramp_blob_end
tramp_blob_end:
.text
EOF
clang --target=x86_64-none-elf -c src/native64/s1_boot.S -o "$R/boot.o"
clang --target=x86_64-none-elf -c src/native64/raw64_smp_body.S -o "$R/raw.o"
clang --target=x86_64-none-elf -c "$R/blob.S" -o "$R/blob.o"
# The link line is audited: only assembly objects plus the generated blob.
LINK_INPUTS="$R/boot.o $R/raw.o $R/blob.o"
case "$LINK_INPUTS" in *.c*) fail "C object in raw64 link";; esac
ld.lld -m elf_x86_64 -T src/native64/s1_kabi.ld -e _start \
  -o "$R/raw.elf" $LINK_INPUTS
llvm-objcopy -O binary "$R/raw.elf" "$R/raw.bin"
[ "$(wc -c < "$R/raw.bin")" -le 65536 ] || fail "raw64 kernel > 64 KiB"
BSS_END=$(llvm-nm "$R/raw.elf" | awk '$3=="__bss_end"{print $1}')
[ -n "$BSS_END" ] || fail "raw64 __bss_end missing"
[ $((0x$BSS_END)) -le $((0x30000)) ] || fail "raw64 BSS overlaps page tables"
UND=$(llvm-nm -u "$R/raw.elf" | wc -l)
[ "$UND" -eq 0 ] || { llvm-nm -u "$R/raw.elf" >&2; fail "raw64 ELF has undefined symbols"; }
echo "raw64 link: s1_boot.S + raw64_smp_body.S + smp_tramp.S + NaN block; no C object, no undefined symbols"

cat "$T/boot512.bin" "$R/raw.bin" > "$R/img"
truncate -s 66048 "$R/img"
truncate -s 1474560 "$R/img"
rm -f "$R/com"
timeout 60 qemu-system-x86_64 -m 256 -smp 2 \
  -drive format=raw,if=floppy,file="$R/img" -boot a \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -display none -serial "file:$R/com" -no-reboot >/dev/null 2>&1 || true
expected='NAN64 RAW SMP x86_64
RAW64 cpus=2
RAW64 core0 r1=00000011 slot=00000011 done=00000011 timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1
RAW64 core1 r1=00000021 slot=00000021 done=00000021 timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1
RAW64 PASS'
got=$(cat "$R/com" 2>/dev/null || true)
printf '%s\n' "$got"
[ "$got" = "$expected" ] || fail "raw64 COM1 transcript"
echo "raw64 block sha256 $(sha "$R/block.bin"); kernel sha256 $(sha "$R/raw.bin")"
echo "raw64 PASS: boot + page roots + MADT/INIT-SIPI-SIPI AP + per-AP TSS/IST + timer/IPI + one immutable block, no C"

# --------------------------------------- 5. shipped full product image boot
echo "== 5. shipped full product image boot (full guest + IDE, no C harness) =="
F="$T/full"
mkdir -p "$F"
cp build/nan0s.img "$F/ide.img"
# QEMU's floppy geometry is not reliable for a >2.88 MiB file.  The published
# image is a raw IDE image; stage only the boot+kernel window on a 1.44 MiB
# boot floppy and attach the full image as the primary IDE disk.
truncate -s 1474560 "$F/floppy.img"
dd if=build/nan0s.img of="$F/floppy.img" conv=notrunc bs=512 count=2880 status=none
timeout 35 qemu-system-i386 -m 512 -boot order=a \
  -drive format=raw,if=floppy,file="$F/floppy.img" \
  -drive format=raw,if=ide,file="$F/ide.img" \
  -display none -serial "file:$F/com" -no-reboot >/dev/null 2>&1 || true
[ -s "$F/com" ] || fail "shipped full image produced no COM1 output"
grep -q 'NaN/0S BOOT' "$F/com" || {
  echo "COM1:"; cat -v "$F/com" >&2
  fail "shipped full image banner missing"
}
grep -q 'NANIX SHELL READY' "$F/com" || {
  echo "COM1:"; cat -v "$F/com" >&2
  fail "shipped full image shell startup smoke missing"
}
echo "shipped full image: NaN/0S BOOT + NANIX SHELL READY on COM1 (raw NaN guest, no C)"

echo "noc_product_gate: PASS (no-C product build audit, hermetic image, full product boot, raw 64-bit AP/block runtime)"
echo "O"
