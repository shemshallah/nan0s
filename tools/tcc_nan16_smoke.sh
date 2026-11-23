#!/bin/sh
# tools/tcc_nan16_smoke.sh - tcc0 NaN16 backend smoke test.
# Builds the vendored TCC with TCC_TARGET_NAN16, compiles 40 C programs, and
# executes every flat cartridge in nan_cli.  Coverage includes calls, loops,
# arrays, structs, 64-bit pairs, varargs, binary64 doubles, the saved-VT_CMP
# ternary path, constant-address lvalues and unaligned bit-field containers.
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
cat > "$T/lldiv.c" <<'EOC'
long long a = 5000000000LL;
int main(void){ return (int)(a / 1000000000LL); }
EOC
cat > "$T/lldivneg.c" <<'EOC'
long long a = -5000000000LL;
int main(void){ return (int)(a / 1000000000LL); }
EOC
cat > "$T/llmod.c" <<'EOC'
long long a = 5000000000LL;
int main(void){ return (int)(a % 7LL); }
EOC
cat > "$T/llshv.c" <<'EOC'
long long a = 1;
int main(void){ int n = 40; return (int)((a << n) >> 32); }
EOC
cat > "$T/llshrv.c" <<'EOC'
long long a = -0x100000000LL;
int main(void){ int n = 32; return (int)(a >> n); }
EOC
cat > "$T/llcmp.c" <<'EOC'
int main(void){ long long a = -5; return (a == -5) + (a < 0) + (a != 0); }
EOC
cat > "$T/va.c" <<'EOC'
typedef __builtin_va_list va_list;
#define va_start(ap,last) __builtin_va_start(ap,last)
#define va_arg(ap,t) __builtin_va_arg(ap,t)
int sum(int n, ...)
{
    va_list ap;
    int s = 0;
    va_start(ap, n);
    while (n-- > 0) s += va_arg(ap, int);
    return s;
}
int main(void){ return sum(3, 10, 20, 12); }
EOC
cat > "$T/vall.c" <<'EOC'
typedef __builtin_va_list va_list;
#define va_start(ap,last) __builtin_va_start(ap,last)
#define va_arg(ap,t) __builtin_va_arg(ap,t)
long long sumll(int n, ...)
{
    va_list ap;
    long long s = 0;
    va_start(ap, n);
    while (n-- > 0) s += va_arg(ap, long long);
    return s;
}
int main(void){ return (int)sumll(2, 20LL, 22LL); }
EOC
cat > "$T/dblarith.c" <<'EOC'
double d = 1.5;
int main(void){ return (int)(d * 2.0); }
EOC
cat > "$T/dblargs.c" <<'EOC'
double add(double a, double b){ return a + b; }
int main(void){ return (int)add(20.5, 21.5); }
EOC
cat > "$T/dblcmp.c" <<'EOC'
double d = 1.5;
int main(void){ return (d < 2.0) + (d == 1.5) + (d != 2.0); }
EOC
cat > "$T/dblva.c" <<'EOC'
typedef __builtin_va_list va_list;
#define va_start(ap,last) __builtin_va_start(ap,last)
#define va_arg(ap,t) __builtin_va_arg(ap,t)
double sum(int n, ...)
{
    va_list ap;
    double s = 0;
    va_start(ap, n);
    while (n-- > 0) { double v = va_arg(ap, double); s += v; }
    return s;
}
int main(void){ return (int)sum(2, 20.5, 21.5); }
EOC
cat > "$T/dblconv.c" <<'EOC'
int main(void){ double d = (double)42; long double e = 2.5L; return (int)d + (int)(e * 2.0L); }
EOC
cat > "$T/dblstruct.c" <<'EOC'
struct S { double a; int b; };
int main(void){ struct S s; s.a = 40.5; s.b = 1; return (int)s.a + s.b; }
EOC
cat > "$T/dblprec.c" <<'EOC'
typedef union { double d; unsigned u[2]; } U;
int main(void)
{
    U x; int r = 0;
    x.d = 0.1 + 0.2;
    if (x.u[0] != 0x33333334u || x.u[1] != 0x3FD33333u) r = 1;
    x.d = 1.0 / 3.0;
    if (x.u[0] != 0x55555555u || x.u[1] != 0x3FD55555u) r = 2;
    x.d = 0.1 * 10.0;
    if (x.u[0] != 0 || x.u[1] != 0x3FF00000u) r = 3;
    x.d = 5.5 - 2.25;
    if (x.u[0] != 0 || x.u[1] != 0x400A0000u) r = 4;
    return r ? r : 42;
}
EOC
cat > "$T/dblnan.c" <<'EOC'
int main(void)
{
    double z = 0.0, o = 1.0; int r = 0;
    if (z / z == z / z) r = 1;
    if (!(z / z != z / z)) r = 2;
    if (!(o / z > 1e308)) r = 3;
    return r ? r : 42;
}
EOC
cat > "$T/dblptr.c" <<'EOC'
double addp(double s, double *p){ return s + *p; }
int main(void){ double x = 21.5; return (int)addp(20.5, &x); }
EOC
cat > "$T/dblull.c" <<'EOC'
int main(void)
{
    unsigned long long u = 18446744073709551615ULL;
    double d = (double)u;
    return (int)(d / 18446744073709551616.0);
}
EOC
cat > "$T/constaddr.c" <<'EOC'
int main(void)
{
    *(volatile unsigned char *)0x00040000u = 42;
    return *(volatile unsigned char *)0x00040000u;
}
EOC
cat > "$T/ternary.c" <<'EOC'
typedef long long i64;
struct CI { i64 key; };
static int t32(int eq, int a, int b) { return eq ? (a > b) : (a >= b); }
static int t64(int eq, long long a, long long b)
{
    return eq ? (a > b) : (a >= b);
}
static int check(void *p, unsigned pg, i64 *out, i64 bound)
{
    struct CI ci;
    int eq = 1;
    (void)p; (void)pg;
    ci.key = 443;
    if (eq ? (ci.key > bound) : (ci.key >= bound))
        return 1;
    *out = ci.key;
    return 0;
}
static volatile int gv = 3;
static volatile long long gl = 443;
int main(void)
{
    i64 m = 0;
    int r = 0;
    if (t32(1, gv, gv) != 0) r |= 1;
    if (t32(1, gv, gv + 1) != 0) r |= 2;
    if (t32(1, gv + 1, gv) != 1) r |= 4;
    if (t32(0, gv, gv) != 1) r |= 8;
    if (t32(0, gv, gv + 1) != 0) r |= 16;
    if (t32(0, gv + 1, gv) != 1) r |= 32;
    if (t64(1, gl, gl) != 0) r |= 64;
    if (t64(1, gl, gl + 1) != 0) r |= 128;
    if (t64(1, gl + 1, gl) != 1) r |= 256;
    if (t64(0, gl, gl) != 1) r |= 512;
    if (t64(0, gl, gl + 1) != 0) r |= 1024;
    if (t64(0, gl + 1, gl) != 1) r |= 2048;
    if (check((void *)0, 16, &m, 443) != 0) r |= 4096;
    if (m != 443) r |= 8192;
    return r ? r : 42;
}
EOC
cat > "$T/bitfield.c" <<'EOC'
struct S {
    unsigned newTnum;
    unsigned char iDb;
    unsigned char busy;
    unsigned orphanTrigger : 1;
    unsigned imposterTable : 2;
    unsigned reopenMemdb : 1;
    const char **azInit;
};
int main(void)
{
    struct S s;
    s.newTnum = 1;
    s.iDb = 1;
    s.busy = 1;
    s.orphanTrigger = 0;
    s.imposterTable = 0;
    s.reopenMemdb = 0;
    s.azInit = 0;
    if (s.iDb != 1 || s.busy != 1) return 1;
    s.orphanTrigger = 1;
    if (s.iDb != 1 || s.busy != 1) return 2;
    if (s.orphanTrigger != 1) return 3;
    s.imposterTable = 3;
    s.reopenMemdb = 1;
    if (s.imposterTable != 3 || s.reopenMemdb != 1) return 4;
    if (s.iDb != 1 || s.busy != 1) return 5;
    s.orphanTrigger = 0;
    s.imposterTable = 0;
    s.reopenMemdb = 0;
    if (s.iDb != 1 || s.busy != 1) return 6;
    return 42;
}
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
"$T/tcc_nan16" -c "$T/lldiv.c" -o "$T/lldiv.bin"
"$T/tcc_nan16" -c "$T/lldivneg.c" -o "$T/lldivneg.bin"
"$T/tcc_nan16" -c "$T/llmod.c" -o "$T/llmod.bin"
"$T/tcc_nan16" -c "$T/llshv.c" -o "$T/llshv.bin"
"$T/tcc_nan16" -c "$T/llshrv.c" -o "$T/llshrv.bin"
"$T/tcc_nan16" -c "$T/llcmp.c" -o "$T/llcmp.bin"
"$T/tcc_nan16" -c "$T/va.c" -o "$T/va.bin"
"$T/tcc_nan16" -c "$T/vall.c" -o "$T/vall.bin"
"$T/tcc_nan16" -c "$T/dblarith.c" -o "$T/dblarith.bin"
"$T/tcc_nan16" -c "$T/dblargs.c" -o "$T/dblargs.bin"
"$T/tcc_nan16" -c "$T/dblcmp.c" -o "$T/dblcmp.bin"
"$T/tcc_nan16" -c "$T/dblva.c" -o "$T/dblva.bin"
"$T/tcc_nan16" -c "$T/dblconv.c" -o "$T/dblconv.bin"
"$T/tcc_nan16" -c "$T/dblstruct.c" -o "$T/dblstruct.bin"
"$T/tcc_nan16" -c "$T/dblprec.c" -o "$T/dblprec.bin"
"$T/tcc_nan16" -c "$T/dblnan.c" -o "$T/dblnan.bin"
"$T/tcc_nan16" -c "$T/dblptr.c" -o "$T/dblptr.bin"
"$T/tcc_nan16" -c "$T/dblull.c" -o "$T/dblull.bin"
"$T/tcc_nan16" -c "$T/constaddr.c" -o "$T/constaddr.bin"
"$T/tcc_nan16" -c "$T/bitfield.c" -o "$T/bitfield.bin"
"$T/tcc_nan16" -c "$T/ternary.c" -o "$T/ternary.bin"
for b in ret42 call loop global larray garray fact sw ptr str struct gstruct fnptr lladd llfact llg llsh sbv sret lldiv lldivneg llmod llshv llshrv llcmp va vall dblarith dblargs dblcmp dblva dblconv dblstruct dblprec dblnan dblptr dblull constaddr bitfield ternary; do
  [ -s "$T/$b.bin" ] || { echo "tcc_nan16_smoke: FAIL (empty $b object)"; exit 1; }
done


for p in ret42 call loop global larray garray fact sw ptr str struct gstruct fnptr lladd llfact llg llsh sbv sret lldiv lldivneg llmod llshv llshrv llcmp va vall dblarith dblargs dblcmp dblva dblconv dblstruct dblprec dblnan dblptr dblull constaddr bitfield ternary; do
  "$CLI" --img "$T/$p.bin" --mem 16 --steps 300000 --serial --peek 0x100:1 \
      > "$T/$p.out" 2> "$T/$p.err" || true
  want=0000002A
  case "$p" in
    loop) want=0000002D ;;
    garray) want=00000004 ;;
    fact|llfact) want=00000078 ;;
    str) want=00006869 ;;
    llsh|llshv) want=00000100 ;;
    lldiv) want=00000005 ;;
    lldivneg) want=FFFFFFFB ;;
    llshrv) want=FFFFFFFF ;;
    llmod) want=00000002 ;;
    llcmp|dblarith|dblcmp) want=00000003 ;;
    dblstruct) want=00000029 ;;
    dblconv) want=0000002F ;;
    dblull) want=00000001 ;;
  esac
  if ! grep -qx "$want" "$T/$p.out"; then
    echo "tcc_nan16_smoke: FAIL ($p did not return $want)"
    cat -v "$T/$p.out" "$T/$p.err"; exit 1
  fi
  grep -q 'rc=3' "$T/$p.err" || { echo "tcc_nan16_smoke: FAIL ($p did not halt)"; cat -v "$T/$p.err"; exit 1; }
done
echo "tcc_nan16_smoke: PASS (TCC emits NaN16: 40 programs incl. binary64 double/long double)"
