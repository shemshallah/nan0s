#!/bin/sh
# guest_raw_only_gate.sh - enforce the raw-NaN16 guest boundary.
#
# Product guest trees may contain .nas/.nan and the native x86 boot
# trampoline .xa only.  C, .s/.S and .o files are host toolchain/test
# artifacts; they must not be product sources or linked into the image.
# C files in nanfs/ are inert NPAF demo inputs for the raw-NaN16 ncc.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C

fail=0
for d in src/nan src/nix src/lib src/exhibits src/boot; do
  bad=$(find "$d" -type f \( -name '*.c' -o -name '*.s' -o -name '*.S' -o -name '*.o' \) -print -quit)
  if [ -n "$bad" ]; then
    echo "guest_raw_only: FAIL (non-NaN source in $d: $bad)"
    fail=1
  fi
done

# Every OS cart must be a NaN text cartridge.
if [ -f tools/os_carts.txt ]; then
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
      *:*)
        cart=${line#*:}
        case "$cart" in
          *.nan) ;;
          *) echo "guest_raw_only: FAIL (non-.nan cart: $line)"; fail=1 ;;
        esac
        ;;
      *) echo "guest_raw_only: FAIL (bad cart line: $line)"; fail=1 ;;
    esac
  done < tools/os_carts.txt
fi

# No ELF object may be embedded in the shipped images.
if [ -f build/nan0s.img ]; then
  if LC_ALL=C grep -aq "$(printf '\177ELF')" build/nan0s.img; then
    echo "guest_raw_only: FAIL (ELF magic in build/nan0s.img)"; fail=1
  fi
fi
if [ -f build/disk.nanfs ]; then
  if LC_ALL=C grep -aq "$(printf '\177ELF')" build/disk.nanfs; then
    echo "guest_raw_only: FAIL (ELF magic in build/disk.nanfs)"; fail=1
  fi
fi

# The root seed may contain C text, but it is data, not compiled code.
cseed=$(find nanfs -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' \) 2>/dev/null | wc -l)
[ "$fail" -eq 0 ] || exit 1
echo "guest_raw_only: PASS (guest sources .nas/.nan/.xa; carts .nan; no ELF in images)"
echo "guest_raw_only: root seed has $cseed inert C/header demo file(s) for ncc (data, not OS code)"
