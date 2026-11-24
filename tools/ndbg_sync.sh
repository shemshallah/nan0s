#!/bin/sh
# tools/ndbg_sync.sh - refresh the vendored NANDBG component from an ndbg checkout.
#   sh tools/ndbg_sync.sh ../ndbg
set -e
cd "$(dirname "$0")/.."
SRC=${1:-}
if [ -z "$SRC" ] || [ ! -d "$SRC/src/dbg" ]; then
  echo "usage: sh tools/ndbg_sync.sh /path/to/ndbg" >&2
  exit 2
fi
mkdir -p src/dbg src/tests spec
cp -a "$SRC/src/dbg/." src/dbg/
rm -f src/dbg/README.md.bak
cp -a "$SRC/src/tests"/ndbg_* src/tests/
cp -a "$SRC/spec/NANDBG.md" spec/NANDBG.md
cp -a "$SRC/src/tools/disasm.nas" src/tools/disasm.nas
for g in ndbg ndbg_diff ndbg_mon ndbg_img; do
  cp -a "$SRC/tools/$g.sh" tools/$g.sh
  chmod +x tools/$g.sh
done
# The legacy pane gate is kept in ndbg until the Silver Slate port lands.
rm -f tools/ndbg_gui.sh
# Every includer of the shared disassembler provides the output hook.
for f in src/tests/disasm_test.nas src/tests/n16i_test.nas src/tools/mktables.nas; do
  [ -f "$f" ] || continue
  grep -q '^dis_out:' "$f" || printf '\n; output hook required by the shared disassembler\ndis_out:\n  PUTC r9\n  RET\n' >> "$f"
done
if ! grep -q 'NaN/0S integration:' src/dbg/README.md 2>/dev/null; then
  cat >> src/dbg/README.md <<'NOTE'

> **NaN/0S integration:** this directory ships with NaN/0S. `tools/ndbg.sh`,
> `ndbg_diff.sh`, `ndbg_mon.sh`, and `ndbg_img.sh` are the integrated gates.
> The desktop pane front end lives in `shemshallah/ndbg`; the Silver Slate port
> is pending.
NOTE
fi
sh tools/ndbg.sh
sh tools/ndbg_diff.sh
sh tools/ndbg_mon.sh
sh tools/ndbg_img.sh
