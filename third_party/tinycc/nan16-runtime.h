/* nan16-runtime.h - C runtime injected into every TCC NaN16 link.
   Kept as a string so the compiler itself can compile it for the target. */
#ifndef NAN16_RUNTIME_H
#define NAN16_RUNTIME_H

#define NAN16_RUNTIME_SRC \
    "typedef unsigned long long u64;\n" \
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
    "i64 __ashrdi3(i64 a, int n) { while (n > 0) { a = a >> 1; n--; } return a; }\n"

#endif
