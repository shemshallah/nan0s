; ncc header-macro gate: fixed-width integer typedefs and the C89/C99
; <limits.h>, <stdint.h>, <float.h>, <stdio.h>, <locale.h>, <errno.h>,
; <signal.h>, <math.h>, and <wchar.h> constants that are not keyword or
; function builtins. ncc is ILP32 with a 32-bit float/double payload, so
; DBL_*/LDBL_* track FLT_* and long long is 8 bytes. All execution is
; raw NaN16; the C source is embedded below.
.org 0
JMP @main
.include "../lib/ncc.nas"
main:
MOVI r13,1
LA r1,@c_src
CALL @ncc_compile
CALL @ncc_run
HALT
c_src:
.str "union F { float f; unsigned u; };\nint main(void){\n printf(\"%d %d %d %d %d %d %d %d\\n\",(int)sizeof(int8_t),(int)sizeof(uint8_t),(int)sizeof(int16_t),(int)sizeof(uint16_t),(int)sizeof(int32_t),(int)sizeof(uint32_t),(int)sizeof(int64_t),(int)sizeof(uint64_t));\n printf(\"%d %d %d %d %d %d\\n\",(int)sizeof(int_least8_t),(int)sizeof(int_fast8_t),(int)sizeof(int_least64_t),(int)sizeof(int_fast64_t),(int)sizeof(intmax_t),(int)sizeof(uintmax_t));\n printf(\"%d %d %d\\n\",INT8_MIN,INT8_MAX,UINT8_MAX);\n printf(\"%d %d %u\\n\",INT16_MIN,INT32_MAX,UINT32_MAX);\n printf(\"%d %d %u\\n\",CHAR_MIN,CHAR_MAX,WEOF);\n printf(\"%d %d %d %d %d %d\\n\",LC_ALL,LC_COLLATE,LC_CTYPE,LC_MONETARY,LC_NUMERIC,LC_TIME);\n printf(\"%d %d %d %d %d\\n\",BUFSIZ,FILENAME_MAX,FOPEN_MAX,TMP_MAX,L_tmpnam);\n printf(\"%d %d %d %d %d\\n\",_IOFBF,_IOLBF,_IONBF,SIG_ERR,MB_LEN_MAX);\n printf(\"%d %d %d %d %d\\n\",FP_NAN,FP_INFINITE,FP_ZERO,FP_SUBNORMAL,FP_NORMAL);\n printf(\"%d %d %d\\n\",FLT_RADIX,FLT_MANT_DIG,FLT_DIG);\n union F a,b,c;\n a.f=FLT_MIN; b.f=FLT_MAX; c.f=FLT_EPSILON;\n printf(\"%08x %08x %08x\\n\",a.u,b.u,c.u);\n printf(\"%lld %lld %llu\\n\",LLONG_MIN,LLONG_MAX,ULLONG_MAX);\n printf(\"%lld %lld %llu\\n\",INT64_MIN,INT64_MAX,UINT64_MAX);\n printf(\"%lld %lld %llu\\n\",INTMAX_MIN,INTMAX_MAX,UINTMAX_MAX);\n return 0;\n}\n"
