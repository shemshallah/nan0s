#!/bin/sh
# M46 gate: NFS persistence through the ATA primary master (--disk).
set -e; cd "$(dirname "$0")/.."
T="${TMPDIR:-/tmp}/nccm46.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
for n in persist_w persist_r; do
  awk -f tools/nmk.awk -v CMD=emit "src/tests/$n.nas" > "$T/$n.nan"
done
dd if=/dev/zero of="$T/dsk" bs=1M count=2 2>/dev/null
./aarch64/android/nan_cli --img "$T/persist_w.nan" --disk "$T/dsk" \
  --steps 80000000 --serial > "$T/wout" 2>"$T/werr" || true
./aarch64/android/nan_cli --img "$T/persist_r.nan" --disk "$T/dsk" \
  --steps 80000000 --serial > "$T/rout" 2>"$T/rerr" || true
sed -e 's/^\[nan_cli\].*$//' -e '/^$/d' "$T/rout" > "$T/got"
if diff -u src/tests/ncc_m46.expected "$T/got"; then
  echo "ncc_m46: PASS (persistent files over ATA)"
else
  echo "ncc_m46: FAIL"; tail -2 "$T/rerr"; exit 1
fi
