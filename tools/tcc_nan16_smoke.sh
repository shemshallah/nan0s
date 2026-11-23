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
cat > "$T/garray.c" <<'EOC'
int a[3] = {1, 2, 3};
int main(void){ return a[0] + a[2]; }
EOC
cat > "$T/fact.c" <<'EOC'
int fact(int n){ return n < 2 ? 1 : n * fact(n - 1); }
int main(void){ return fact(5); }
EOC
cat > "$T/sw.c" <<'EOC'
int main(void){ int x = 2; switch (x) { case 1: return 1; case 2: return 42; default: return 0; } }
EOC
cat > "$T/ptr.c" <<'EOC'
int main(void){ int x = 42; int *p = &x; return *p; }
EOC
cat > "$T/str.c" <<'EOC'
char *s = "hi";
int main(void){ return s[0] * 256 + s[1]; }
EOC
cat > "$T/struct.c" <<'EOC'
struct S { int a; int b; };
int main(void){ struct S s; s.a = 40; s.b = 2; return s.a + s.b; }
EOC
cat > "$T/gstruct.c" <<'EOC'
struct S { int a; char b; };
struct S s = {40, 2};
int main(void){ return s.a + s.b; }
EOC
cat > "$T/fnptr.c" <<'EOC'
int add(int a, int b){ return a + b; }
int main(void){ int (*f)(int,int) = add; return f(20, 22); }
EOC
cat > "$T/lladd.c" <<'EOC'
long long addll(long long a, long long b){ return a + b; }
int main(void){ return (int)addll(20, 22); }
EOC
cat > "$T/llfact.c" <<'EOC'
long long fact(long long n){ return n < 2 ? 1 : n * fact(n - 1); }
int main(void){ return (int)fact(5); }
EOC
cat > "$T/llg.c" <<'EOC'
long long x = 5000000000LL;
int main(void){ return (int)(x - 4999999958LL); }
EOC
cat > "$T/llsh.c" <<'EOC'
long long a = 1LL << 40;
int main(void){ return (int)(a >> 32); }
EOC
cat > "$T/sbv.c" <<'EOC'
struct S { int a; int b; };
int sum(struct S s){ return s.a + s.b; }
int main(void){ struct S s; s.a = 40; s.b = 2; return sum(s); }
EOC
cat > "$T/sret.c" <<'EOC'
struct S { int a; int b; };
struct S make(void){ struct S s; s.a = 40; s.b = 2; return s; }
int main(void){ struct S s = make(); return s.a + s.b; }
EOC

"$T/tcc_nan16" -c "$T/ret42.c" -o "$T/ret42.bin"
"$T/tcc_nan16" -c "$T/call.c" -o "$T/call.bin"
"$T/tcc_nan16" -c "$T/loop.c" -o "$T/loop.bin"
"$T/tcc_nan16" -c "$T/global.c" -o "$T/global.bin"
"$T/tcc_nan16" -c "$T/larray.c" -o "$T/larray.bin"
"$T/tcc_nan16" -c "$T/garray.c" -o "$T/garray.bin"
"$T/tcc_nan16" -c "$T/fact.c" -o "$T/fact.bin"
"$T/tcc_nan16" -c "$T/sw.c" -o "$T/sw.bin"
"$T/tcc_nan16" -c "$T/ptr.c" -o "$T/ptr.bin"
"$T/tcc_nan16" -c "$T/str.c" -o "$T/str.bin"
"$T/tcc_nan16" -c "$T/struct.c" -o "$T/struct.bin"
"$T/tcc_nan16" -c "$T/gstruct.c" -o "$T/gstruct.bin"
"$T/tcc_nan16" -c "$T/fnptr.c" -o "$T/fnptr.bin"
"$T/tcc_nan16" -c "$T/lladd.c" -o "$T/lladd.bin"
"$T/tcc_nan16" -c "$T/llfact.c" -o "$T/llfact.bin"
"$T/tcc_nan16" -c "$T/llg.c" -o "$T/llg.bin"
"$T/tcc_nan16" -c "$T/llsh.c" -o "$T/llsh.bin"
"$T/tcc_nan16" -c "$T/sbv.c" -o "$T/sbv.bin"
"$T/tcc_nan16" -c "$T/sret.c" -o "$T/sret.bin"
for b in ret42 call loop global larray garray fact sw ptr str struct gstruct fnptr lladd llfact llg llsh sbv sret; do
  [ -s "$T/$b.bin" ] || { echo "tcc_nan16_smoke: FAIL (empty $b object)"; exit 1; }
done


for p in ret42 call loop global larray garray fact sw ptr str struct gstruct fnptr lladd llfact llg llsh sbv sret; do
  "$CLI" --img "$T/$p.bin" --mem 16 --steps 4000 --serial --peek 0x100:1 \
      > "$T/$p.out" 2> "$T/$p.err" || true
  want=0000002A
  case "$p" in
    loop) want=0000002D ;;
    garray) want=00000004 ;;
    fact|llfact) want=00000078 ;;
    str) want=00006869 ;;
    llsh) want=00000100 ;;
  esac
  if ! grep -qx "$want" "$T/$p.out"; then
    echo "tcc_nan16_smoke: FAIL ($p did not return $want)"
    cat -v "$T/$p.out" "$T/$p.err"; exit 1
  fi
  grep -q 'rc=3' "$T/$p.err" || { echo "tcc_nan16_smoke: FAIL ($p did not halt)"; cat -v "$T/$p.err"; exit 1; }
done
echo "tcc_nan16_smoke: PASS (TCC emits NaN16: 20 programs incl. long long pairs, struct args and struct returns)"
