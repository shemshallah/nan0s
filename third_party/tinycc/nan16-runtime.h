/* nan16-runtime.h - C runtime injected into every TCC NaN16 link.
   Kept as a string so the compiler itself can compile it for the target. */
#ifndef NAN16_RUNTIME_H
#define NAN16_RUNTIME_H

#define NAN16_RUNTIME_SRC \
    "typedef unsigned long long u64;\n" \
    "typedef unsigned u32;\n" \
    "typedef long long i64;\n" \
    "\n" \
    "u64 __nan16_udivmod(u64 n, u64 d, int want_rem)\n" \
    "{\n" \
    "    u64 q = 0, r = 0, bit = 1ULL << 63;\n" \
    "    int i;\n" \
    "    if (d == 0) return 0;\n" \
    "    for (i = 0; i < 64; i++) {\n" \
    "        r = r << 1;\n" \
    "        if (n & bit) r = r | 1;\n" \
    "        if (r >= d) { r = r - d; q = q | bit; }\n" \
    "        bit = bit >> 1;\n" \
    "    }\n" \
    "    return want_rem ? r : q;\n" \
    "}\n" \
    "\n" \
    "u64 __udivdi3(u64 n, u64 d) { return __nan16_udivmod(n, d, 0); }\n" \
    "u64 __umoddi3(u64 n, u64 d) { return __nan16_udivmod(n, d, 1); }\n" \
    "\n" \
    "i64 __divdi3(i64 n, i64 d)\n" \
    "{\n" \
    "    int neg = 0;\n" \
    "    u64 un, ud, q;\n" \
    "    if (n < 0) { un = (u64)0 - (u64)n; neg = !neg; } else un = (u64)n;\n" \
    "    if (d < 0) { ud = (u64)0 - (u64)d; neg = !neg; } else ud = (u64)d;\n" \
    "    q = __nan16_udivmod(un, ud, 0);\n" \
    "    return neg ? (i64)((u64)0 - q) : (i64)q;\n" \
    "}\n" \
    "\n" \
    "i64 __moddi3(i64 n, i64 d)\n" \
    "{\n" \
    "    int neg = 0;\n" \
    "    u64 un, ud, r;\n" \
    "    if (n < 0) { un = (u64)0 - (u64)n; neg = 1; } else un = (u64)n;\n" \
    "    if (d < 0) { ud = (u64)0 - (u64)d; } else ud = (u64)d;\n" \
    "    r = __nan16_udivmod(un, ud, 1);\n" \
    "    return neg ? (i64)((u64)0 - r) : (i64)r;\n" \
    "}\n" \
    "\n" \
    "u64 __ashldi3(u64 a, int n) { while (n > 0) { a = a << 1; n--; } return a; }\n" \
    "u64 __lshrdi3(u64 a, int n) { while (n > 0) { a = a >> 1; n--; } return a; }\n" \
    "i64 __ashrdi3(i64 a, int n) { while (n > 0) { a = a >> 1; n--; } return a; }\n" \
    "\n" \
    "/* ---- binary64 helpers ---- */\n" \
    "#define DSIGN(x) ((int)((x) >> 63))\n" \
    "#define DEXP(x)  ((int)(((x) >> 52) & 0x7FF))\n" \
    "#define DFRAC(x) ((x) & 0xFFFFFFFFFFFFFULL)\n" \
    "#define DMASK52  0xFFFFFFFFFFFFFULL\n" \
    "\n" \
    "u32 __nan16_d2f(u64 d)\n" \
    "{\n" \
    "    u32 sign = (u32)(d >> 63) << 31;\n" \
    "    int exp = DEXP(d);\n" \
    "    u64 frac = DFRAC(d);\n" \
    "    int e, shift;\n" \
    "    u64 m, rem, half;\n" \
    "    u32 f;\n" \
    "    if (exp == 0x7FF) {\n" \
    "        if (frac == 0) return sign | 0x7F800000u;\n" \
    "        return sign | 0x7FC00000u | ((u32)(frac >> 29) & 0x3FFFFF);\n" \
    "    }\n" \
    "    if (exp == 0) return sign;\n" \
    "    e = exp - 1023 + 127;\n" \
    "    m = (1ULL << 52) | frac;\n" \
    "    shift = 29;\n" \
    "    f = (u32)(m >> shift) & 0x7FFFFF;\n" \
    "    rem = m & ((1ULL << shift) - 1);\n" \
    "    half = 1ULL << (shift - 1);\n" \
    "    if (rem > half || (rem == half && (f & 1))) {\n" \
    "        f++;\n" \
    "        if (f == 0x800000) { f = 0; e++; }\n" \
    "    }\n" \
    "    if (e >= 255) return sign | 0x7F800000u;\n" \
    "    if (e <= 0) {\n" \
    "        int sh;\n" \
    "        u32 sub;\n" \
    "        u64 rr, hh;\n" \
    "        if (e < -23) return sign;\n" \
    "        sh = 1 - e + 29;\n" \
    "        sub = (u32)(m >> sh);\n" \
    "        rr = m & ((1ULL << sh) - 1);\n" \
    "        hh = 1ULL << (sh - 1);\n" \
    "        if (rr > hh || (rr == hh && (sub & 1))) sub++;\n" \
    "        return sign | sub;\n" \
    "    }\n" \
    "    return sign | ((u32)e << 23) | f;\n" \
    "}\n" \
    "\n" \
    "u64 __nan16_f2d(u32 f)\n" \
    "{\n" \
    "    u32 sign = (f >> 31) & 1;\n" \
    "    int exp = (int)((f >> 23) & 0xFF);\n" \
    "    u32 frac = f & 0x7FFFFF;\n" \
    "    u64 s = (u64)sign << 63;\n" \
    "    if (exp == 0xFF) {\n" \
    "        if (frac == 0) return s | 0x7FF0000000000000ULL;\n" \
    "        return s | 0x7FF8000000000000ULL | ((u64)frac << 29);\n" \
    "    }\n" \
    "    if (exp == 0) {\n" \
    "        int n = 0;\n" \
    "        u32 t = frac;\n" \
    "        if (frac == 0) return s;\n" \
    "        while (!(t & 0x800000)) { t <<= 1; n++; }\n" \
    "        exp = 1 - 127 - n;\n" \
    "        frac = t & 0x7FFFFF;\n" \
    "        return s | ((u64)(exp + 1023) << 52) | ((u64)frac << 29);\n" \
    "    }\n" \
    "    return s | ((u64)(exp - 127 + 1023) << 52) | ((u64)frac << 29);\n" \
    "}\n" \
    "\n" \
    "static int sf_hi_bit(u64 x)\n" \
    "{\n" \
    "    int n = -1;\n" \
    "    while (x) { x >>= 1; n++; }\n" \
    "    return n;\n" \
    "}\n" \
    "\n" \
    "static void sf_add128(u64 *h, u64 *l, u64 xh, u64 xl)\n" \
    "{\n" \
    "    u64 old = *l;\n" \
    "    *l = old + xl;\n" \
    "    *h = *h + xh + (*l < old);\n" \
    "}\n" \
    "\n" \
    "static void sf_shl128(u64 *h, u64 *l, int n)\n" \
    "{\n" \
    "    if (n <= 0) return;\n" \
    "    if (n >= 128) { *h = *l = 0; return; }\n" \
    "    if (n >= 64) { *h = *l << (n - 64); *l = 0; }\n" \
    "    else {\n" \
    "        *h = (*h << n) | (*l >> (64 - n));\n" \
    "        *l = *l << n;\n" \
    "    }\n" \
    "}\n" \
    "\n" \
    "static void sf_shr128(u64 *h, u64 *l, int n, int *sticky)\n" \
    "{\n" \
    "    if (n <= 0) return;\n" \
    "    if (n >= 128) {\n" \
    "        if (*h || *l) *sticky = 1;\n" \
    "        *h = *l = 0;\n" \
    "        return;\n" \
    "    }\n" \
    "    if (n >= 64) {\n" \
    "        if (*l) *sticky = 1;\n" \
    "        *l = *h >> (n - 64);\n" \
    "        *h = 0;\n" \
    "    } else {\n" \
    "        if (*l & ((1ULL << n) - 1)) *sticky = 1;\n" \
    "        *l = (*l >> n) | (*h << (64 - n));\n" \
    "        *h = *h >> n;\n" \
    "    }\n" \
    "}\n" \
    "\n" \
    "static u64 sf_pack(int sign, int e, u64 m)\n" \
    "{\n" \
    "    u64 mant = m >> 3;\n" \
    "    u64 rem = m & 7;\n" \
    "    if (rem > 4 || (rem == 4 && (mant & 1))) mant++;\n" \
    "    if (mant & (1ULL << 53)) { mant >>= 1; e++; }\n" \
    "    if (e >= 0x7FF) return ((u64)sign << 63) | 0x7FF0000000000000ULL;\n" \
    "    if (e <= 0) {\n" \
    "        int sh = 1 - e;\n" \
    "        if (sh > 53) return (u64)sign << 63;\n" \
    "        mant = m >> (3 + sh);\n" \
    "        rem = (m >> sh) & 7;\n" \
    "        if (rem > 4 || (rem == 4 && (mant & 1))) mant++;\n" \
    "        return ((u64)sign << 63) | (mant & DMASK52);\n" \
    "    }\n" \
    "    return ((u64)sign << 63) | ((u64)e << 52) | (mant & DMASK52);\n" \
    "}\n" \
    "\n" \
    "static u64 sf_add(u64 a, u64 b)\n" \
    "{\n" \
    "    int sa = DSIGN(a), sb = DSIGN(b);\n" \
    "    int ea = DEXP(a), eb = DEXP(b);\n" \
    "    u64 fa = DFRAC(a), fb = DFRAC(b);\n" \
    "    u64 ma, mb, m, sticky;\n" \
    "    int e, d;\n" \
    "\n" \
    "    if (ea == 0x7FF) {\n" \
    "        if (fa) return a | 0x8000000000000ULL;\n" \
    "        if (eb == 0x7FF && fb) return b | 0x8000000000000ULL;\n" \
    "        if (eb == 0x7FF && (sb != sa)) return 0x7FF8000000000000ULL;\n" \
    "        return a;\n" \
    "    }\n" \
    "    if (eb == 0x7FF) {\n" \
    "        if (fb) return b | 0x8000000000000ULL;\n" \
    "        return b;\n" \
    "    }\n" \
    "    if (ea == 0) { if (fa == 0) return b; ma = fa; ea = 1; }\n" \
    "    else ma = (1ULL << 52) | fa;\n" \
    "    if (eb == 0) { if (fb == 0) return a; mb = fb; eb = 1; }\n" \
    "    else mb = (1ULL << 52) | fb;\n" \
    "\n" \
    "    if (ea < eb) {\n" \
    "        u64 t; int ti;\n" \
    "        t = ma; ma = mb; mb = t;\n" \
    "        ti = ea; ea = eb; eb = ti;\n" \
    "        ti = sa; sa = sb; sb = ti;\n" \
    "    }\n" \
    "    d = ea - eb;\n" \
    "    sticky = 0;\n" \
    "    if (d >= 64) { sticky = (mb != 0); mb = 0; }\n" \
    "    else if (d) {\n" \
    "        sticky = (mb & ((1ULL << d) - 1)) != 0;\n" \
    "        mb >>= d;\n" \
    "    }\n" \
    "    ma <<= 3;\n" \
    "    mb = (mb << 3) | (sticky ? 1 : 0);\n" \
    "    if (sa == sb) {\n" \
    "        m = ma + mb;\n" \
    "        e = ea;\n" \
    "        if (m & (1ULL << 56)) { m = (m >> 1) | (m & 1); e++; }\n" \
    "    } else {\n" \
    "        if (ma >= mb) { m = ma - mb; e = ea; }\n" \
    "        else { m = mb - ma; e = eb; sa = sb; }\n" \
    "        if (m == 0) return 0;\n" \
    "        while (!(m & (1ULL << 55))) { m <<= 1; e--; }\n" \
    "    }\n" \
    "    return sf_pack(sa, e, m);\n" \
    "}\n" \
    "\n" \
    "static u64 sf_sub(u64 a, u64 b) { return sf_add(a, b ^ (1ULL << 63)); }\n" \
    "\n" \
    "static u64 sf_mul(u64 a, u64 b)\n" \
    "{\n" \
    "    int sa = DSIGN(a), sb = DSIGN(b), sign = sa ^ sb;\n" \
    "    int ea = DEXP(a), eb = DEXP(b);\n" \
    "    u64 fa = DFRAC(a), fb = DFRAC(b);\n" \
    "    u64 ma, mb, hi, lo, m;\n" \
    "    u64 p0, p1, p2, p3;\n" \
    "    int e, msb, sh, sticky;\n" \
    "\n" \
    "    if ((ea == 0x7FF && fa) || (eb == 0x7FF && fb))\n" \
    "        return 0x7FF8000000000000ULL;\n" \
    "    if ((ea == 0x7FF && !fa) || (eb == 0x7FF && !fb)) {\n" \
    "        if ((ea == 0 && fa == 0) || (eb == 0 && fb == 0))\n" \
    "            return (u64)sign << 63;\n" \
    "        return ((u64)sign << 63) | 0x7FF0000000000000ULL;\n" \
    "    }\n" \
    "    if (ea == 0) { if (fa == 0) return (u64)sign << 63; ma = fa; ea = 1; }\n" \
    "    else ma = (1ULL << 52) | fa;\n" \
    "    if (eb == 0) { if (fb == 0) return (u64)sign << 63; mb = fb; eb = 1; }\n" \
    "    else mb = (1ULL << 52) | fb;\n" \
    "\n" \
    "    p0 = (ma & 0xFFFFFFFFULL) * (mb & 0xFFFFFFFFULL);\n" \
    "    p1 = (ma & 0xFFFFFFFFULL) * (mb >> 32);\n" \
    "    p2 = (ma >> 32) * (mb & 0xFFFFFFFFULL);\n" \
    "    p3 = (ma >> 32) * (mb >> 32);\n" \
    "    hi = lo = 0;\n" \
    "    sf_add128(&hi, &lo, 0, p0);\n" \
    "    sf_add128(&hi, &lo, p1 >> 32, p1 << 32);\n" \
    "    sf_add128(&hi, &lo, p2 >> 32, p2 << 32);\n" \
    "    sf_add128(&hi, &lo, p3, 0);\n" \
    "\n" \
    "    if (hi) msb = 64 + sf_hi_bit(hi); else msb = sf_hi_bit(lo);\n" \
    "    sh = msb - 55;\n" \
    "    sticky = 0;\n" \
    "    if (sh > 0) sf_shr128(&hi, &lo, sh, &sticky);\n" \
    "    else if (sh < 0) sf_shl128(&hi, &lo, -sh);\n" \
    "    if (sticky) lo |= 1;\n" \
    "    m = lo & 0xFFFFFFFFFFFFFFULL;\n" \
    "    e = ea + eb - 1023 + (msb - 104);\n" \
    "    return sf_pack(sign, e, m);\n" \
    "}\n" \
    "\n" \
    "static u64 sf_div(u64 a, u64 b)\n" \
    "{\n" \
    "    int sa = DSIGN(a), sb = DSIGN(b), sign = sa ^ sb;\n" \
    "    int ea = DEXP(a), eb = DEXP(b);\n" \
    "    u64 fa = DFRAC(a), fb = DFRAC(b);\n" \
    "    u64 ma, mb, q, rl;\n" \
    "    int i, e;\n" \
    "\n" \
    "    if ((ea == 0x7FF && fa) || (eb == 0x7FF && fb))\n" \
    "        return 0x7FF8000000000000ULL;\n" \
    "    if (ea == 0x7FF) {\n" \
    "        if (eb == 0x7FF) return 0x7FF8000000000000ULL;\n" \
    "        return ((u64)sign << 63) | 0x7FF0000000000000ULL;\n" \
    "    }\n" \
    "    if (eb == 0x7FF) return (u64)sign << 63;\n" \
    "    if (eb == 0 && fb == 0) {\n" \
    "        if (ea == 0 && fa == 0) return 0x7FF8000000000000ULL;\n" \
    "        return ((u64)sign << 63) | 0x7FF0000000000000ULL;\n" \
    "    }\n" \
    "    if (ea == 0) { if (fa == 0) return (u64)sign << 63; ma = fa; ea = 1; }\n" \
    "    else ma = (1ULL << 52) | fa;\n" \
    "    if (eb == 0) { mb = fb; eb = 1; }\n" \
    "    else mb = (1ULL << 52) | fb;\n" \
    "\n" \
    "    q = 0; rl = ma;\n" \
    "    if (rl >= mb) { rl -= mb; q = 1; }\n" \
    "    for (i = 0; i < 55; i++) {\n" \
    "        rl <<= 1;\n" \
    "        q <<= 1;\n" \
    "        if (rl >= mb) { rl -= mb; q |= 1; }\n" \
    "    }\n" \
    "    if (rl) q |= 1;\n" \
    "    e = ea - eb + 1023;\n" \
    "    if (q & (1ULL << 55)) { }\n" \
    "    else if (q & (1ULL << 54)) { q <<= 1; e--; }\n" \
    "    else { q <<= 2; e -= 2; }\n" \
    "    if (q == 0) return (u64)sign << 63;\n" \
    "    return sf_pack(sign, e, q);\n" \
    "}\n" \
    "\n" \
    "static int sf_cmp(u64 a, u64 b)\n" \
    "{\n" \
    "    int sa = DSIGN(a), sb = DSIGN(b);\n" \
    "    u64 ma = a & 0x7FFFFFFFFFFFFFFFULL;\n" \
    "    u64 mb = b & 0x7FFFFFFFFFFFFFFFULL;\n" \
    "    if (ma == 0 && mb == 0) return 0;\n" \
    "    if (sa != sb) return sa ? -1 : 1;\n" \
    "    if (ma < mb) return sa ? 1 : -1;\n" \
    "    if (ma > mb) return sa ? -1 : 1;\n" \
    "    return 0;\n" \
    "}\n" \
    "\n" \
    "u64 __nan16_dadd(u64 a, u64 b) { return sf_add(a, b); }\n" \
    "u64 __nan16_dsub(u64 a, u64 b) { return sf_sub(a, b); }\n" \
    "u64 __nan16_dmul(u64 a, u64 b) { return sf_mul(a, b); }\n" \
    "u64 __nan16_ddiv(u64 a, u64 b) { return sf_div(a, b); }\n" \
    "u64 __nan16_dneg(u64 a) { return a ^ (1ULL << 63); }\n" \
    "int __nan16_dbool(u64 a) { return (a & 0x7FFFFFFFFFFFFFFFULL) != 0; }\n" \
    "int __nan16_dlt(u64 a, u64 b) { return !((DEXP(a) == 0x7FF && DFRAC(a)) || (DEXP(b) == 0x7FF && DFRAC(b))) && sf_cmp(a,b) < 0; }\n" \
    "int __nan16_dle(u64 a, u64 b) { return !((DEXP(a) == 0x7FF && DFRAC(a)) || (DEXP(b) == 0x7FF && DFRAC(b))) && sf_cmp(a,b) <= 0; }\n" \
    "int __nan16_dgt(u64 a, u64 b) { return !((DEXP(a) == 0x7FF && DFRAC(a)) || (DEXP(b) == 0x7FF && DFRAC(b))) && sf_cmp(a,b) > 0; }\n" \
    "int __nan16_dge(u64 a, u64 b) { return !((DEXP(a) == 0x7FF && DFRAC(a)) || (DEXP(b) == 0x7FF && DFRAC(b))) && sf_cmp(a,b) >= 0; }\n" \
    "int __nan16_deq(u64 a, u64 b) { return !((DEXP(a) == 0x7FF && DFRAC(a)) || (DEXP(b) == 0x7FF && DFRAC(b))) && sf_cmp(a,b) == 0; }\n" \
    "int __nan16_dne(u64 a, u64 b) { return ((DEXP(a) == 0x7FF && DFRAC(a)) || (DEXP(b) == 0x7FF && DFRAC(b))) || sf_cmp(a,b) != 0; }\n" \
    "\n" \
    "u64 __nan16_ll2d(u64 v);\n" \
    "u64 __nan16_ull2d(u64 v);\n" \
    "u64 __nan16_i2d(int x) { return __nan16_ll2d((u64)(i64)x); }\n" \
    "u64 __nan16_u2d(u32 x) { return __nan16_ll2d((u64)x); }\n" \
    "\n" \
    "u64 __nan16_ll2d(u64 v)\n" \
    "{\n" \
    "    u32 sign = (u32)(v >> 63);\n" \
    "    u64 a = sign ? (0ULL - v) : v;\n" \
    "    int n = 63;\n" \
    "    u64 p = 1ULL << 63;\n" \
    "    u64 frac;\n" \
    "    if (a == 0) return 0;\n" \
    "    while (!(a & p)) { p >>= 1; n--; }\n" \
    "    if (n <= 52) {\n" \
    "        frac = (a << (52 - n)) & DMASK52;\n" \
    "    } else {\n" \
    "        int sh = n - 52;\n" \
    "        u64 rem, half;\n" \
    "        frac = (a >> sh) & DMASK52;\n" \
    "        rem = a & ((1ULL << sh) - 1);\n" \
    "        half = 1ULL << (sh - 1);\n" \
    "        if (rem > half || (rem == half && (frac & 1))) {\n" \
    "            frac++;\n" \
    "            if (frac == (1ULL << 52)) { frac = 0; n++; }\n" \
    "        }\n" \
    "    }\n" \
    "    return ((u64)sign << 63) | ((u64)(n + 1023) << 52) | frac;\n" \
    "}\n" \
    "u64 __nan16_ull2d(u64 a) { return __nan16_ll2d(a & 0x7FFFFFFFFFFFFFFFULL); }\n" \
    "\n" \
    "u64 __nan16_d2ll(u64 d)\n" \
    "{\n" \
    "    u32 sign = (u32)(d >> 63);\n" \
    "    int exp = DEXP(d);\n" \
    "    u64 frac = DFRAC(d);\n" \
    "    u64 m, r;\n" \
    "    int shift;\n" \
    "    if (exp == 0x7FF) return 0;\n" \
    "    if (exp == 0) return 0;\n" \
    "    m = (1ULL << 52) | frac;\n" \
    "    shift = exp - 1023 - 52;\n" \
    "    if (shift >= 0) {\n" \
    "        if (shift >= 64) return sign ? 0x8000000000000000ULL : 0;\n" \
    "        r = m << shift;\n" \
    "    } else {\n" \
    "        if (-shift >= 64) return 0;\n" \
    "        r = m >> (-shift);\n" \
    "    }\n" \
    "    if (sign) r = 0ULL - r;\n" \
    "    return r;\n" \
    "}\n" \
    "u64 __nan16_d2ull(u64 d) { return __nan16_d2ll(d); }\n" \
    "int __nan16_d2i(u64 d) { return (int)__nan16_d2ll(d); }\n" \
    "u32 __nan16_d2u(u64 d) { return (u32)__nan16_d2ll(d); }\n" \
    "u64 __nan16_ll2f(u64 v) { return (u64)__nan16_d2f(__nan16_ll2d(v)); }\n" \
    "u64 __nan16_ull2f(u64 v) { return (u64)__nan16_d2f(__nan16_ull2d(v)); }\n" \
    "u64 __nan16_u2f(u32 x) { return (u64)__nan16_d2f(__nan16_u2d(x)); }\n" \
    "u64 __nan16_f2ll(u32 f) { return __nan16_d2ll(__nan16_f2d(f)); }\n" \
    "u64 __nan16_f2ull(u32 f) { return __nan16_d2ll(__nan16_f2d(f)); }\n"

#endif
