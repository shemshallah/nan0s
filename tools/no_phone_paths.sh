#!/bin/sh
# tools/no_phone_paths.sh - portability guard for the x86_64 product/gates.
# Product code and acceptance tooling must not hardcode a Termux/phone path.
# Upstream TCC's configure (which knows about Termux) and docs are excluded.
set -eu
cd "$(dirname "$0")/.."
fail=0
files=$(
    { git ls-files 'tools/*.sh' 'third_party/nan16-libc/*' 'third_party/sqlite/*' \
        'src/*' 'aarch64/*' 'x86/*';
      git ls-files --others --exclude-standard 'tools/*.sh' 'src/*'; } |
    grep -vE '^third_party/sqlite/(sqlite3|sqlite3ext)\.(c|h)$' | grep -vE '^tools/no_phone_paths\.sh$' | sort -u
)
for f in $files; do
    [ -f "$f" ] || continue
    if grep -Iq '/data/data/com.termux' "$f"; then
        echo "no_phone_paths: hardcoded phone path in $f" >&2
        fail=1
    fi
done
[ "$fail" -eq 0 ] || exit 1
echo "no_phone_paths: PASS (no phone paths in product/gate files)"
