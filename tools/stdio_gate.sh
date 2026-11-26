#!/bin/sh
# stdio_gate.sh - C guest stdout/stderr over the NANIX fd ABI (spec/NIX_FD.md).
#
# Assembles a raw-NaN16 ncc cart whose C program writes through printf,
# fprintf, fputs, fputc, fwrite and fgets.  The stdio library must translate
# FILE handles 1/2/3 to NANIX descriptors 0/1/2 through nfd_read/nfd_write.
# The product image links the real src/lib/nixfd.nas after the GUI cart; this
# gate supplies a minimal conforming shim in $TMPDIR so the two C streams can
# be captured independently of the shell's live fd table.  The shim appends
# fd 1 to a guest stdout buffer, fd 2 to a guest stderr buffer and serves one
# canned fd 0 line.  The x86_64 S1 runner dumps those buffers through the
# standard console control block, making the streams byte-exact.
#
# Shell redirection (cmd > / 2>&1) is covered by tools/nixsh_io_gate.sh; this
# gate proves the FILE -> nfd mapping those descriptors rely on.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
TMPDIR="${TMPDIR:-$PWD/tmp}"
mkdir -p "$TMPDIR"
T="$TMPDIR/stdio_gate.$$"
mkdir -p "$T"
if [ "${STDIO_GATE_KEEP:-0}" = 1 ]; then
    trap 'echo "stdio_gate: kept $T" >&2' EXIT INT TERM
else
    trap 'rm -rf "$T"' EXIT INT TERM
fi

# --- conforming nfd_* shim (test data, not product code) -------------------
cat > "$T/nfd_stub.nas" <<'EOF'
; Minimal nfd_read/nfd_write shim for tools/stdio_gate.sh.
; fd 1 -> stdout capture, fd 2 -> stderr capture, fd 0 -> one canned line.
.equ NFDS_OCTL 0x0FBFC00
.equ NFDS_ECTL 0x0FBFC02
.equ NFDS_OBUF 0x03D00000
.equ NFDS_EBUF 0x03D80000

nfd_write:
ST r15,r14,0
ADD r14,r14,r13
MOVI r4,1
CMP r1,r4
JMP[EQ] @nfw_out
MOVI r4,2
CMP r1,r4
JMP[EQ] @nfw_err
LA r1,0xFFFFFFFF
JMP @nfw_d
nfw_out:
LA r5,#NFDS_OCTL
LA r6,#NFDS_OBUF
JMP @nfw_go
nfw_err:
LA r5,#NFDS_ECTL
LA r6,#NFDS_EBUF
nfw_go:
LD r7,r5,0
CMP r7,r0
JMP[NE] @nfw_ptr
ST r6,r5,0
nfw_ptr:
LD r7,r5,1
ADD r8,r6,r7
MOVI r9,0
nfw_l:
CMP r9,r3
JMP[GE] @nfw_ok
LDB r10,r2,0
STB r10,r8,0
ADD r2,r2,r13
ADD r8,r8,r13
ADD r9,r9,r13
JMP @nfw_l
nfw_ok:
ADD r7,r7,r9
ST r7,r5,1
ADD r1,r9,r0
nfw_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nfd_read:
ST r15,r14,0
ADD r14,r14,r13
CMP r1,r0
JMP[NE] @nfr_e
LA r5,@nfds_ioff
LD r6,r5,0
LA r7,@nfds_line
SHL r7,r7,2
ADD r7,r7,r6
MOVI r9,0
nfr_l:
CMP r9,r3
JMP[GE] @nfr_ok
LDB r10,r7,0
CMP r10,r0
JMP[EQ] @nfr_ok
STB r10,r2,0
ADD r7,r7,r13
ADD r2,r2,r13
ADD r9,r9,r13
JMP @nfr_l
nfr_ok:
ADD r6,r6,r9
ST r6,r5,0
ADD r1,r9,r0
JMP @nfr_d
nfr_e:
LA r1,0xFFFFFFFF
nfr_d:
SUB r14,r14,r13
LD r15,r14,0
RET

nfds_ioff:
.word 0
nfds_line:
.str "line1\n"
EOF

# --- C program (ncc input data) -------------------------------------------
cat > "$T/prog.c" <<'EOC'
int main(void)
{
    char buf[16];
    printf("out-%d\n", 7);
    fprintf(stderr, "err-%d\n", 8);
    fputs("out2", stdout);
    fputs("err2", stderr);
    fputc(79, stdout); fputc(75, stdout); fputc(10, stdout);
    fputc(69, stderr); fputc(75, stderr); fputc(10, stderr);
    fwrite("WR\n", 1, 3, stdout);
    fwrite("ER\n", 1, 3, stderr);
    if (fgets(buf, 16, stdin) != 0) printf("in=%s", buf);
    return 0;
}
EOC

python3 - "$T/prog.c" "$T/cart.nas" <<'PY'
import sys
src = open(sys.argv[1]).read()
esc = src.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
open(sys.argv[2], 'w').write(
    '.org 0\n'
    'JMP @main\n'
    '.include "../../src/lib/ncc.nas"\n'
    '.include "nfd_stub.nas"\n'
    'main:\n'
    'MOVI r13,1\n'
    'LA r1,@c_src\n'
    'CALL @ncc_compile\n'
    'CALL @ncc_run\n'
    'HALT\n'
    'c_src:\n'
    '.str "%s"\n' % esc)
PY

echo "stdio_gate: assemble"
awk -f tools/nmk.awk -v CMD=emit "$T/cart.nas" > "$T/cart.nan" 2> "$T/emit.err" || {
    echo "stdio_gate: FAIL (assemble)"; cat "$T/emit.err"; exit 1; }
awk -f tools/nmk.awk -v CMD=check "$T/cart.nan" 2> "$T/check.err" || {
    echo "stdio_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }
grep -q 'check: 0 mismatches' "$T/check.err" || {
    echo "stdio_gate: FAIL (assembler round-trip)"; cat "$T/check.err"; exit 1; }

echo "stdio_gate: run on x86_64 S1"
S1_FB_DELAY=1 sh tools/s1_runner.sh --img "$T/cart.nan" --mem 128 \
    --steps "${STDIO_GATE_STEPS:-60000000}" \
    --guest-stdout "$T/out" --guest-stderr "$T/err" \
    > "$T/run.out" 2> "$T/run.err" || true

[ -f "$T/out" ] && [ -f "$T/err" ] || {
    echo "stdio_gate: FAIL (no guest streams)"; tail -20 "$T/run.err"; exit 1; }

python3 - "$T/out" "$T/err" <<'PY'
import sys
out = open(sys.argv[1], 'rb').read()
err = open(sys.argv[2], 'rb').read()
want_out = b"out-7\nout2\nOK\nWR\nin=line1\n"
want_err = b"err-8\nerr2\nEK\nER\n"
ok = True
if out != want_out:
    ok = False
    print("stdio_gate: stdout mismatch")
    print("  got:  %r" % out)
    print("  want: %r" % want_out)
if err != want_err:
    ok = False
    print("stdio_gate: stderr mismatch")
    print("  got:  %r" % err)
    print("  want: %r" % want_err)
if not ok:
    raise SystemExit(1)
PY

echo "stdio_gate: stdout=$(tr '\n' '|' < "$T/out")"
echo "stdio_gate: stderr=$(tr '\n' '|' < "$T/err")"
echo "stdio_gate: PASS (C stdout=fd 1, stderr=fd 2, stdin=fd 0 through nfd_*)"
