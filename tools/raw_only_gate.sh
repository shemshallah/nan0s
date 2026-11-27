#!/bin/sh
# tools/raw_only_gate.sh - the shipped guest system is raw NaN16 source.
#
# System directories may contain .nas sources, generated .nan word text, and
# documentation. Foreign-language implementation files are rejected.
set -e
cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/raw_only.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

: > "$T/bad"
for d in src/prog src/lib src/gui src/trust src/dbg src/tools src/nan src/nix; do
  find "$d" -type f \
    \( -name '*.c' -o -name '*.h' -o -name '*.cc' -o -name '*.cpp' \
       -o -name '*.py' -o -name '*.rs' -o -name '*.go' -o -name '*.js' \
       -o -name '*.ts' -o -name '*.java' -o -name '*.S' \) >> "$T/bad"
done
if [ -s "$T/bad" ]; then
  echo "raw_only: FAIL (foreign-language files in the guest system)"
  cat "$T/bad"
  exit 1
fi

# Every .nas source must live in one of the guest system directories; the
# generated .nan files are raw word text, not source.
for d in src/prog src/lib src/gui src/trust src/dbg src/tools src/nan src/nix; do
  find "$d" -type f -name '*.nas' >> "$T/nas"
done
[ -s "$T/nas" ] || { echo "raw_only: FAIL (no raw NaN source found)"; exit 1; }

echo "raw_only: PASS (guest system source is raw NaN16 .nas; no C/C++/Python/Rust)"
