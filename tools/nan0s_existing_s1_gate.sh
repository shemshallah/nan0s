#!/bin/sh
# nan0s_existing_s1_gate.sh - boot the EXISTING nan0s system guest on x86_64 S1.
#
# Extracts the guest region from build/nan0s.img (the same bytes the 32-bit
# kboot0 image boots) and runs it on tools/s1_runner.sh.  Requires the real
# system banner and then drives the EXISTING text shell command line with
# --keys (ESC keeps the text shell, C starts the command line).  This is the
# 64-bit path for the existing system, not a separate CLI.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
T="${TMPDIR:-/tmp}/nan0s_existing.$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

LC_ALL=C awk -f tools/nmk.awk -v CMD=emit src/museum/museum.nas > src/nan/museum.nan
sh tools/mkall.sh > "$T/mkall.log" 2>&1
python3 - "$T/guest.bin" <<'PY'
import sys
d = open('build/nan0s.img', 'rb').read()
words = int.from_bytes(d[504:508], 'little')
off = 512 + 65536
open(sys.argv[1], 'wb').write(d[off:off + words * 8])
PY

S1_KEEP=1 TMPDIR="$T" sh tools/s1_runner.sh --img "$T/guest.bin" \
    --mem "${NAN0S_EXISTING_MEM:-128}" \
    --steps "${NAN0S_EXISTING_STEPS:-3000000}" --serial \
    > "$T/run.out" 2> "$T/run.err" || true

COM=$(find "$T" -path '*/s1_runner.*/com' -type f | head -1)
if [ -z "$COM" ]; then
    echo "nan0s_existing: FAIL (no COM1 capture)"
    tail -5 "$T/run.err"; exit 1
fi
if ! grep -q 'NaN/0S' "$COM"; then
    echo "nan0s_existing: FAIL (real system banner missing)"
    head -10 "$COM" | cat -v; exit 1
fi

# The OS default boot is the GUI desktop (qgate_gui).  A pending ESC at cold
# boot enters the text shell instead; no museum menu.  Commands go through
# bare_fs_* (the NaN POSIX service layer) and exit halts deterministically.
KEYS='\x1bmkdir /k\nwrite /k/a hi\ncat /k/a\nls /k\nstat /k/a\nrm /k/a\nrmdir /k\nhelp\nexit\n'
if ! sh tools/s1_runner.sh --img "$T/guest.bin" \
    --mem "${NAN0S_EXISTING_MEM:-128}" --steps 3000000 \
    --keys "$KEYS" --serial > "$T/cli.out" 2> "$T/cli.err"; then
    echo "nan0s_existing: FAIL (key-driven shell did not halt cleanly)"
    tail -5 "$T/cli.err"; cat -v "$T/cli.out" | tail -20; exit 1
fi
tr -d '\r' < "$T/cli.out" > "$T/cli.lf"
for want in \
    'NaN/0S text shell - NANIX POSIX command line' \
    'nan0s> mkdir /k' 'ok' \
    'nan0s> write /k/a hi' \
    'nan0s> cat /k/a' 'hi' \
    'nan0s> ls /k' 'a' \
    'nan0s> stat /k/a' 'file size=2 mode=33188' \
    'nan0s> rm /k/a' \
    'nan0s> rmdir /k' \
    'nan0s> help' \
    'nan0s> exit' 'bye'; do
    grep -Fqx "$want" "$T/cli.lf" || {
        echo "nan0s_existing: FAIL (shell transcript missing '$want')"
        cat -v "$T/cli.lf"; exit 1; }
done
echo "nan0s_existing: PASS (existing nan0s guest on x86_64 S1: $(head -1 "$COM" | tr -d '\r'))"
printf 'nan0s_existing: PASS (menu C -> mkdir/write/cat/ls/stat/rm/rmdir/help/exit)\n'
cat "$T/cli.lf"
