#!/bin/sh
# tools/tcc_nan16_smoke.sh - tcc0 NaN16 backend smoke test.
# Builds the vendored TCC with TCC_TARGET_NAN16, compiles two C programs,
# prepends the SP/CALL/ST/HALT entry stub and executes the result in nan_cli:
#   int main(void){return 42;}
#   int add(int,int); int main(void){return add(20,22);} int add(...){...}
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
T="${TMPDIR:-/tmp}/tccnan16smoke.$$"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
CC=${HOST_CC:-cc}
TT=third_party/tinycc
CLI=aarch64/android/nan_cli; [ -x $CLI ] || (cd aarch64/android && make -s nan_cli)

[ -f "$TT/config.h" ] || (cd "$TT" && ./configure --cpu=x86_64 >/dev/null 2>&1)
grep -q 'TCC_TARGET_NAN16' "$TT/config.h" || \
  sed -i 's/TCC_TARGET_RISCV64 || TCC_TARGET_C67)/TCC_TARGET_RISCV64 || TCC_TARGET_C67 || TCC_TARGET_NAN16)/' "$TT/config.h"
[ -f "$TT/tccdefs_.h" ] || (cd "$TT" && $CC -DC2STR conftest.c -o c2str.exe && ./c2str.exe include/tccdefs.h tccdefs_.h)
$CC -std=gnu99 -O2 -DTCC_TARGET_NAN16 -DONE_SOURCE -I"$TT" "$TT/tcc.c" \
    -o "$T/tcc_nan16" -lm -ldl

cat > "$T/ret42.c" <<'EOC'
int main(void){ return 42; }
EOC
cat > "$T/call.c" <<'EOC'
int add(int a, int b);
int main(void){ return add(20, 22); }
int add(int a, int b){ return a + b; }
EOC
cat > "$T/loop.c" <<'EOC'
int main(void){ int i, s = 0; for (i = 0; i < 10; i++) s += i; return s; }
EOC
cat > "$T/global.c" <<'EOC'
int g = 40;
int main(void){ return g + 2; }
EOC
cat > "$T/larray.c" <<'EOC'
int main(void){ int a[3]; a[0] = 40; a[1] = 1; a[2] = 1; return a[0] + a[1] + a[2]; }
EOC

"$T/tcc_nan16" -c "$T/ret42.c" -o "$T/ret42.bin"
"$T/tcc_nan16" -c "$T/call.c" -o "$T/call.bin"
"$T/tcc_nan16" -c "$T/loop.c" -o "$T/loop.bin"
"$T/tcc_nan16" -c "$T/global.c" -o "$T/global.bin"
"$T/tcc_nan16" -c "$T/larray.c" -o "$T/larray.bin"
for b in ret42 call loop global larray; do
  [ -s "$T/$b.bin" ] || { echo "tcc_nan16_smoke: FAIL (empty $b object)"; exit 1; }
done


for p in ret42 call loop global larray; do
  "$CLI" --img "$T/$p.bin" --mem 16 --steps 4000 --serial --peek 0x100:1 \
      > "$T/$p.out" 2> "$T/$p.err" || true
  want=0000002A
  case "$p" in loop*) want=0000002D ;; esac
  if ! grep -qx "$want" "$T/$p.out"; then
    echo "tcc_nan16_smoke: FAIL ($p did not return $want)"
    cat -v "$T/$p.out" "$T/$p.err"; exit 1
  fi
  grep -q 'rc=3' "$T/$p.err" || { echo "tcc_nan16_smoke: FAIL ($p did not halt)"; cat -v "$T/$p.err"; exit 1; }
done
echo "tcc_nan16_smoke: PASS (TCC emits NaN16: return 42, add(20,22), loop 45, global 42, local array 42)"
