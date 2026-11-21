; headers.nas - C89/C99 header macros and fixed-width typedefs that
; are not covered by the core builtin/typedef tables. Everything is
; installed once at ncc_types_init time; execution stays raw NaN16.

ncc_headers_init:
ST r15,r14,0
ADD r14,r14,r13
LA r1,0x40FFA2F9
LA r2,@ncc_s_h_int8_t
MOVI r3,6
MOVI r4,#T_CHAR
CALL @ncc_add_typedef
LA r1,0x306340A8
LA r2,@ncc_s_h_uint8_t
MOVI r3,7
MOVI r4,#T_UCHAR
CALL @ncc_add_typedef
LA r1,0x0DFE5EDA
LA r2,@ncc_s_h_int16_t
MOVI r3,7
MOVI r4,#T_SHORT
CALL @ncc_add_typedef
LA r1,0x96C45519
LA r2,@ncc_s_h_uint16_t
MOVI r3,8
MOVI r4,#T_USHORT
CALL @ncc_add_typedef
LA r1,0xC04A1FBC
LA r2,@ncc_s_h_int32_t
MOVI r3,7
MOVI r4,#T_INT
CALL @ncc_add_typedef
LA r1,0xE9B20787
LA r2,@ncc_s_h_uint32_t
MOVI r3,8
MOVI r4,#T_UINT
CALL @ncc_add_typedef
LA r1,0x7270198F
LA r2,@ncc_s_h_int64_t
MOVI r3,7
MOVI r4,#T_LONGLONG
CALL @ncc_add_typedef
LA r1,0x682FE470
LA r2,@ncc_s_h_uint64_t
MOVI r3,8
MOVI r4,#T_ULONGLONG
CALL @ncc_add_typedef
LA r1,0xE986A81F
LA r2,@ncc_s_h_int_least8_t
MOVI r3,12
MOVI r4,#T_CHAR
CALL @ncc_add_typedef
LA r1,0x5997D3F2
LA r2,@ncc_s_h_uint_least8_t
MOVI r3,13
MOVI r4,#T_UCHAR
CALL @ncc_add_typedef
LA r1,0x9EEF5BE8
LA r2,@ncc_s_h_int_least16_t
MOVI r3,13
MOVI r4,#T_SHORT
CALL @ncc_add_typedef
LA r1,0x3687E483
LA r2,@ncc_s_h_uint_least16_t
MOVI r3,14
MOVI r4,#T_USHORT
CALL @ncc_add_typedef
LA r1,0x1A82E9CE
LA r2,@ncc_s_h_int_least32_t
MOVI r3,13
MOVI r4,#T_INT
CALL @ncc_add_typedef
LA r1,0xF39A4B45
LA r2,@ncc_s_h_uint_least32_t
MOVI r3,14
MOVI r4,#T_UINT
CALL @ncc_add_typedef
LA r1,0xB3C85D1D
LA r2,@ncc_s_h_int_least64_t
MOVI r3,13
MOVI r4,#T_LONGLONG
CALL @ncc_add_typedef
LA r1,0x40D4EDB2
LA r2,@ncc_s_h_uint_least64_t
MOVI r3,14
MOVI r4,#T_ULONGLONG
CALL @ncc_add_typedef
LA r1,0xCDF61B7C
LA r2,@ncc_s_h_int_fast8_t
MOVI r3,11
MOVI r4,#T_INT
CALL @ncc_add_typedef
LA r1,0xB0A832B3
LA r2,@ncc_s_h_uint_fast8_t
MOVI r3,12
MOVI r4,#T_UINT
CALL @ncc_add_typedef
LA r1,0x5BEE652D
LA r2,@ncc_s_h_int_fast16_t
MOVI r3,12
MOVI r4,#T_INT
CALL @ncc_add_typedef
LA r1,0xA4C4420C
LA r2,@ncc_s_h_uint_fast16_t
MOVI r3,13
MOVI r4,#T_UINT
CALL @ncc_add_typedef
LA r1,0x81A26553
LA r2,@ncc_s_h_int_fast32_t
MOVI r3,12
MOVI r4,#T_INT
CALL @ncc_add_typedef
LA r1,0x670F5B2A
LA r2,@ncc_s_h_uint_fast32_t
MOVI r3,13
MOVI r4,#T_UINT
CALL @ncc_add_typedef
LA r1,0x427A825C
LA r2,@ncc_s_h_int_fast64_t
MOVI r3,12
MOVI r4,#T_LONGLONG
CALL @ncc_add_typedef
LA r1,0x615C4B29
LA r2,@ncc_s_h_uint_fast64_t
MOVI r3,13
MOVI r4,#T_ULONGLONG
CALL @ncc_add_typedef
LA r1,0x1DA9B792
LA r2,@ncc_s_h_CHAR_MIN
MOVI r3,8
LA r4,0xFFFFFF80
CALL @ncc_add_enum_const
LA r1,0xE795DAD8
LA r2,@ncc_s_h_CHAR_MAX
MOVI r3,8
LA r4,0x0000007F
CALL @ncc_add_enum_const
LA r1,0xE46589DF
LA r2,@ncc_s_h_MB_LEN_MAX
MOVI r3,10
LA r4,0x00000004
CALL @ncc_add_enum_const
LA r1,0x8D2C4371
LA r2,@ncc_s_h_INT8_MIN
MOVI r3,8
LA r4,0xFFFFFF80
CALL @ncc_add_enum_const
LA r1,0x9F3FE77F
LA r2,@ncc_s_h_INT8_MAX
MOVI r3,8
LA r4,0x0000007F
CALL @ncc_add_enum_const
LA r1,0xADC9590A
LA r2,@ncc_s_h_UINT8_MAX
MOVI r3,9
LA r4,0x000000FF
CALL @ncc_add_enum_const
LA r1,0x9D2954BE
LA r2,@ncc_s_h_INT16_MIN
MOVI r3,9
LA r4,0xFFFF8000
CALL @ncc_add_enum_const
LA r1,0xEF164E1C
LA r2,@ncc_s_h_INT16_MAX
MOVI r3,9
LA r4,0x00007FFF
CALL @ncc_add_enum_const
LA r1,0xA606DCFF
LA r2,@ncc_s_h_UINT16_MAX
MOVI r3,10
LA r4,0x0000FFFF
CALL @ncc_add_enum_const
LA r1,0x8CD689FC
LA r2,@ncc_s_h_INT32_MIN
MOVI r3,9
LA r4,0x80000000
CALL @ncc_add_enum_const
LA r1,0x7AC2E5EE
LA r2,@ncc_s_h_INT32_MAX
MOVI r3,9
LA r4,0x7FFFFFFF
CALL @ncc_add_enum_const
LA r1,0xEE27F33D
LA r2,@ncc_s_h_UINT32_MAX
MOVI r3,10
LA r4,0xFFFFFFFF
CALL @ncc_add_enum_const
LA r1,0x5C9EC277
LA r2,@ncc_s_h_INTPTR_MIN
MOVI r3,10
LA r4,0x80000000
CALL @ncc_add_enum_const
LA r1,0x6AB26039
LA r2,@ncc_s_h_INTPTR_MAX
MOVI r3,10
LA r4,0x7FFFFFFF
CALL @ncc_add_enum_const
LA r1,0x4989C2B0
LA r2,@ncc_s_h_UINTPTR_MAX
MOVI r3,11
LA r4,0xFFFFFFFF
CALL @ncc_add_enum_const
LA r1,0xD78B793D
LA r2,@ncc_s_h_PTRDIFF_MIN
MOVI r3,11
LA r4,0x80000000
CALL @ncc_add_enum_const
LA r1,0xA1779C83
LA r2,@ncc_s_h_PTRDIFF_MAX
MOVI r3,11
LA r4,0x7FFFFFFF
CALL @ncc_add_enum_const
LA r1,0xFD7F0AC1
LA r2,@ncc_s_h_SIG_ATOMIC_MIN
MOVI r3,14
LA r4,0x80000000
CALL @ncc_add_enum_const
LA r1,0x2F92E12F
LA r2,@ncc_s_h_SIG_ATOMIC_MAX
MOVI r3,14
LA r4,0x7FFFFFFF
CALL @ncc_add_enum_const
LA r1,0x39368399
LA r2,@ncc_s_h_WCHAR_MIN
MOVI r3,9
LA r4,0x00000000
CALL @ncc_add_enum_const
LA r1,0x0B22B377
LA r2,@ncc_s_h_WCHAR_MAX
MOVI r3,9
LA r4,0x0010FFFF
CALL @ncc_add_enum_const
LA r1,0x82E55034
LA r2,@ncc_s_h_WINT_MIN
MOVI r3,8
LA r4,0x00000000
CALL @ncc_add_enum_const
LA r1,0x30F856D6
LA r2,@ncc_s_h_WINT_MAX
MOVI r3,8
LA r4,0x0010FFFF
CALL @ncc_add_enum_const
LA r1,0xA8C248AA
LA r2,@ncc_s_h_SIG_ERR
MOVI r3,7
LA r4,0xFFFFFFFF
CALL @ncc_add_enum_const
LA r1,0xE7568D44
LA r2,@ncc_s_h_LC_ALL
MOVI r3,6
LA r4,0x00000006
CALL @ncc_add_enum_const
LA r1,0x8C2B5C35
LA r2,@ncc_s_h_LC_COLLATE
MOVI r3,10
LA r4,0x00000003
CALL @ncc_add_enum_const
LA r1,0xA23C2702
LA r2,@ncc_s_h_LC_CTYPE
MOVI r3,8
LA r4,0x00000000
CALL @ncc_add_enum_const
LA r1,0xEB54FBC6
LA r2,@ncc_s_h_LC_MONETARY
MOVI r3,11
LA r4,0x00000004
CALL @ncc_add_enum_const
LA r1,0xE4091AA8
LA r2,@ncc_s_h_LC_NUMERIC
MOVI r3,10
LA r4,0x00000001
CALL @ncc_add_enum_const
LA r1,0x08A38304
LA r2,@ncc_s_h_LC_TIME
MOVI r3,7
LA r4,0x00000002
CALL @ncc_add_enum_const
LA r1,0x8581EF2C
LA r2,@ncc_s_h_BUFSIZ
MOVI r3,6
LA r4,0x00000200
CALL @ncc_add_enum_const
LA r1,0xECB2A669
LA r2,@ncc_s_h_FILENAME_MAX
MOVI r3,12
LA r4,0x00000100
CALL @ncc_add_enum_const
LA r1,0xA04C4190
LA r2,@ncc_s_h_FOPEN_MAX
MOVI r3,9
LA r4,0x00000010
CALL @ncc_add_enum_const
LA r1,0x4E834ACB
LA r2,@ncc_s_h_TMP_MAX
MOVI r3,7
LA r4,0x00000019
CALL @ncc_add_enum_const
LA r1,0x6AFE46BF
LA r2,@ncc_s_h_L_tmpnam
MOVI r3,8
LA r4,0x00000020
CALL @ncc_add_enum_const
LA r1,0xD15730A8
LA r2,@ncc_s_h__IOFBF
MOVI r3,6
LA r4,0x00000000
CALL @ncc_add_enum_const
LA r1,0x43E5E30E
LA r2,@ncc_s_h__IOLBF
MOVI r3,6
LA r4,0x00000001
CALL @ncc_add_enum_const
LA r1,0x58E52B50
LA r2,@ncc_s_h__IONBF
MOVI r3,6
LA r4,0x00000002
CALL @ncc_add_enum_const
LA r1,0xABBE0CFC
LA r2,@ncc_s_h_WEOF
MOVI r3,4
LA r4,0xFFFFFFFF
CALL @ncc_add_enum_const
LA r1,0xB51A6701
LA r2,@ncc_s_h_FP_NAN
MOVI r3,6
LA r4,0x00000000
CALL @ncc_add_enum_const
LA r1,0x93B128E4
LA r2,@ncc_s_h_FP_INFINITE
MOVI r3,11
LA r4,0x00000001
CALL @ncc_add_enum_const
LA r1,0x2DCA6A5E
LA r2,@ncc_s_h_FP_ZERO
MOVI r3,7
LA r4,0x00000002
CALL @ncc_add_enum_const
LA r1,0xDA7422BD
LA r2,@ncc_s_h_FP_SUBNORMAL
MOVI r3,12
LA r4,0x00000003
CALL @ncc_add_enum_const
LA r1,0xB89D4B9F
LA r2,@ncc_s_h_FP_NORMAL
MOVI r3,9
LA r4,0x00000004
CALL @ncc_add_enum_const
LA r1,0x04B9CAD5
LA r2,@ncc_s_h_FP_ILOGB0
MOVI r3,9
LA r4,0x80000000
CALL @ncc_add_enum_const
LA r1,0xB4024E30
LA r2,@ncc_s_h_FP_ILOGBNAN
MOVI r3,11
LA r4,0x80000000
CALL @ncc_add_enum_const
LA r1,0xDA5D4A54
LA r2,@ncc_s_h_MATH_ERRNO
MOVI r3,10
LA r4,0x00000001
CALL @ncc_add_enum_const
LA r1,0x5D1D26D6
LA r2,@ncc_s_h_MATH_ERREXCEPT
MOVI r3,14
LA r4,0x00000002
CALL @ncc_add_enum_const
LA r1,0x2D0023BC
LA r2,@ncc_s_h_FLT_RADIX
MOVI r3,9
LA r4,0x00000002
CALL @ncc_add_enum_const
LA r1,0x9E6F6871
LA r2,@ncc_s_h_FLT_MANT_DIG
MOVI r3,12
LA r4,0x00000018
CALL @ncc_add_enum_const
LA r1,0xD0924A7D
LA r2,@ncc_s_h_DBL_MANT_DIG
MOVI r3,12
LA r4,0x00000018
CALL @ncc_add_enum_const
LA r1,0x208DA867
LA r2,@ncc_s_h_LDBL_MANT_DIG
MOVI r3,13
LA r4,0x00000018
CALL @ncc_add_enum_const
LA r1,0x0386814A
LA r2,@ncc_s_h_FLT_DIG
MOVI r3,7
LA r4,0x00000006
CALL @ncc_add_enum_const
LA r1,0xC6C8D3AE
LA r2,@ncc_s_h_DBL_DIG
MOVI r3,7
LA r4,0x00000006
CALL @ncc_add_enum_const
LA r1,0x5A63DFC4
LA r2,@ncc_s_h_LDBL_DIG
MOVI r3,8
LA r4,0x00000006
CALL @ncc_add_enum_const
LA r1,0xC5FCCF8A
LA r2,@ncc_s_h_FLT_MIN_EXP
MOVI r3,11
LA r4,0xFFFFFF83
CALL @ncc_add_enum_const
LA r1,0x9EFC9F4E
LA r2,@ncc_s_h_DBL_MIN_EXP
MOVI r3,11
LA r4,0xFFFFFF83
CALL @ncc_add_enum_const
LA r1,0xCECB0808
LA r2,@ncc_s_h_LDBL_MIN_EXP
MOVI r3,12
LA r4,0xFFFFFF83
CALL @ncc_add_enum_const
LA r1,0x9CB2F04C
LA r2,@ncc_s_h_FLT_MAX_EXP
MOVI r3,11
LA r4,0x00000080
CALL @ncc_add_enum_const
LA r1,0xFC7E00C8
LA r2,@ncc_s_h_DBL_MAX_EXP
MOVI r3,11
LA r4,0x00000080
CALL @ncc_add_enum_const
LA r1,0x6EE468AE
LA r2,@ncc_s_h_LDBL_MAX_EXP
MOVI r3,12
LA r4,0x00000080
CALL @ncc_add_enum_const
LA r1,0x5A8437AE
LA r2,@ncc_s_h_FLT_MIN_10_EXP
MOVI r3,14
LA r4,0xFFFFFFDB
CALL @ncc_add_enum_const
LA r1,0x0CF066C2
LA r2,@ncc_s_h_DBL_MIN_10_EXP
MOVI r3,14
LA r4,0xFFFFFFDB
CALL @ncc_add_enum_const
LA r1,0x9D5AF704
LA r2,@ncc_s_h_LDBL_MIN_10_EXP
MOVI r3,15
LA r4,0xFFFFFFDB
CALL @ncc_add_enum_const
LA r1,0xB034FFF8
LA r2,@ncc_s_h_FLT_MAX_10_EXP
MOVI r3,14
LA r4,0x00000026
CALL @ncc_add_enum_const
LA r1,0x818769C4
LA r2,@ncc_s_h_DBL_MAX_10_EXP
MOVI r3,14
LA r4,0x00000026
CALL @ncc_add_enum_const
LA r1,0x1E327162
LA r2,@ncc_s_h_LDBL_MAX_10_EXP
MOVI r3,15
LA r4,0x00000026
CALL @ncc_add_enum_const
LA r1,0x8966C1A7
LA r2,@ncc_s_h_DECIMAL_DIG
MOVI r3,11
LA r4,0x00000009
CALL @ncc_add_enum_const
LA r1,0x605A4D8E
LA r2,@ncc_s_h_FLT_MIN
MOVI r3,7
MOVI r4,#T_DOUBLE
LA r5,0x00800000
CALL @ncc_add_global
LA r1,0xB1E02E12
LA r2,@ncc_s_h_DBL_MIN
MOVI r3,7
MOVI r4,#T_DOUBLE
LA r5,0x00800000
CALL @ncc_add_global
LA r1,0xE5539398
LA r2,@ncc_s_h_LDBL_MIN
MOVI r3,8
MOVI r4,#T_DOUBLE
LA r5,0x00800000
CALL @ncc_add_global
LA r1,0x12464B0C
LA r2,@ncc_s_h_FLT_MAX
MOVI r3,7
MOVI r4,#T_DOUBLE
LA r5,0x7F7FFFFF
CALL @ncc_add_global
LA r1,0x7BCC5158
LA r2,@ncc_s_h_DBL_MAX
MOVI r3,7
MOVI r4,#T_DOUBLE
LA r5,0x7F7FFFFF
CALL @ncc_add_global
LA r1,0xFB673DF2
LA r2,@ncc_s_h_LDBL_MAX
MOVI r3,8
MOVI r4,#T_DOUBLE
LA r5,0x7F7FFFFF
CALL @ncc_add_global
LA r1,0x9EB85864
LA r2,@ncc_s_h_FLT_EPSILON
MOVI r3,11
MOVI r4,#T_DOUBLE
LA r5,0x34000000
CALL @ncc_add_global
LA r1,0xF91B8F98
LA r2,@ncc_s_h_DBL_EPSILON
MOVI r3,11
MOVI r4,#T_DOUBLE
LA r5,0x34000000
CALL @ncc_add_global
LA r1,0x38345D16
LA r2,@ncc_s_h_LDBL_EPSILON
MOVI r3,12
MOVI r4,#T_DOUBLE
LA r5,0x34000000
CALL @ncc_add_global
LA r1,0x7D0CD2C8
LA r2,@ncc_s_h_HUGE_VALF
MOVI r3,9
MOVI r4,#T_DOUBLE
LA r5,0x7F800000
CALL @ncc_add_global
LA r1,0x770CC956
LA r2,@ncc_s_h_HUGE_VALL
MOVI r3,9
MOVI r4,#T_DOUBLE
LA r5,0x7F800000
CALL @ncc_add_global
LA r1,0x3134A00A
LA r2,@ncc_s_h_LLONG_MIN
MOVI r3,9
MOVI r4,#T_LONGLONG
LA r5,0x00000000
LA r6,0x80000000
CALL @ncc_add_global64
LA r1,0x3B483780
LA r2,@ncc_s_h_LLONG_MAX
MOVI r3,9
MOVI r4,#T_LONGLONG
LA r5,0xFFFFFFFF
LA r6,0x7FFFFFFF
CALL @ncc_add_global64
LA r1,0x7EF6A38F
LA r2,@ncc_s_h_ULLONG_MAX
MOVI r3,10
MOVI r4,#T_ULONGLONG
LA r5,0xFFFFFFFF
LA r6,0xFFFFFFFF
CALL @ncc_add_global64
LA r1,0x51FBE85B
LA r2,@ncc_s_h_INT64_MIN
MOVI r3,9
MOVI r4,#T_LONGLONG
LA r5,0x00000000
LA r6,0x80000000
CALL @ncc_add_global64
LA r1,0x87E8B5A5
LA r2,@ncc_s_h_INT64_MAX
MOVI r3,9
MOVI r4,#T_LONGLONG
LA r5,0xFFFFFFFF
LA r6,0x7FFFFFFF
CALL @ncc_add_global64
LA r1,0x51CDD352
LA r2,@ncc_s_h_UINT64_MAX
MOVI r3,10
MOVI r4,#T_ULONGLONG
LA r5,0xFFFFFFFF
LA r6,0xFFFFFFFF
CALL @ncc_add_global64
LA r1,0xFF3C483F
LA r2,@ncc_s_h_INTMAX_MIN
MOVI r3,10
MOVI r4,#T_LONGLONG
LA r5,0x00000000
LA r6,0x80000000
CALL @ncc_add_global64
LA r1,0xCD2871D1
LA r2,@ncc_s_h_INTMAX_MAX
MOVI r3,10
MOVI r4,#T_LONGLONG
LA r5,0xFFFFFFFF
LA r6,0x7FFFFFFF
CALL @ncc_add_global64
LA r1,0x9BF8C030
LA r2,@ncc_s_h_UINTMAX_MAX
MOVI r3,11
MOVI r4,#T_ULONGLONG
LA r5,0xFFFFFFFF
LA r6,0xFFFFFFFF
CALL @ncc_add_global64
SUB r14,r14,r13
LD r15,r14,0
RET
ncc_s_h_int8_t:
.str "int8_t"
ncc_s_h_uint8_t:
.str "uint8_t"
ncc_s_h_int16_t:
.str "int16_t"
ncc_s_h_uint16_t:
.str "uint16_t"
ncc_s_h_int32_t:
.str "int32_t"
ncc_s_h_uint32_t:
.str "uint32_t"
ncc_s_h_int64_t:
.str "int64_t"
ncc_s_h_uint64_t:
.str "uint64_t"
ncc_s_h_int_least8_t:
.str "int_least8_t"
ncc_s_h_uint_least8_t:
.str "uint_least8_t"
ncc_s_h_int_least16_t:
.str "int_least16_t"
ncc_s_h_uint_least16_t:
.str "uint_least16_t"
ncc_s_h_int_least32_t:
.str "int_least32_t"
ncc_s_h_uint_least32_t:
.str "uint_least32_t"
ncc_s_h_int_least64_t:
.str "int_least64_t"
ncc_s_h_uint_least64_t:
.str "uint_least64_t"
ncc_s_h_int_fast8_t:
.str "int_fast8_t"
ncc_s_h_uint_fast8_t:
.str "uint_fast8_t"
ncc_s_h_int_fast16_t:
.str "int_fast16_t"
ncc_s_h_uint_fast16_t:
.str "uint_fast16_t"
ncc_s_h_int_fast32_t:
.str "int_fast32_t"
ncc_s_h_uint_fast32_t:
.str "uint_fast32_t"
ncc_s_h_int_fast64_t:
.str "int_fast64_t"
ncc_s_h_uint_fast64_t:
.str "uint_fast64_t"
ncc_s_h_CHAR_MIN:
.str "CHAR_MIN"
ncc_s_h_CHAR_MAX:
.str "CHAR_MAX"
ncc_s_h_MB_LEN_MAX:
.str "MB_LEN_MAX"
ncc_s_h_INT8_MIN:
.str "INT8_MIN"
ncc_s_h_INT8_MAX:
.str "INT8_MAX"
ncc_s_h_UINT8_MAX:
.str "UINT8_MAX"
ncc_s_h_INT16_MIN:
.str "INT16_MIN"
ncc_s_h_INT16_MAX:
.str "INT16_MAX"
ncc_s_h_UINT16_MAX:
.str "UINT16_MAX"
ncc_s_h_INT32_MIN:
.str "INT32_MIN"
ncc_s_h_INT32_MAX:
.str "INT32_MAX"
ncc_s_h_UINT32_MAX:
.str "UINT32_MAX"
ncc_s_h_INTPTR_MIN:
.str "INTPTR_MIN"
ncc_s_h_INTPTR_MAX:
.str "INTPTR_MAX"
ncc_s_h_UINTPTR_MAX:
.str "UINTPTR_MAX"
ncc_s_h_PTRDIFF_MIN:
.str "PTRDIFF_MIN"
ncc_s_h_PTRDIFF_MAX:
.str "PTRDIFF_MAX"
ncc_s_h_SIG_ATOMIC_MIN:
.str "SIG_ATOMIC_MIN"
ncc_s_h_SIG_ATOMIC_MAX:
.str "SIG_ATOMIC_MAX"
ncc_s_h_WCHAR_MIN:
.str "WCHAR_MIN"
ncc_s_h_WCHAR_MAX:
.str "WCHAR_MAX"
ncc_s_h_WINT_MIN:
.str "WINT_MIN"
ncc_s_h_WINT_MAX:
.str "WINT_MAX"
ncc_s_h_SIG_ERR:
.str "SIG_ERR"
ncc_s_h_LC_ALL:
.str "LC_ALL"
ncc_s_h_LC_COLLATE:
.str "LC_COLLATE"
ncc_s_h_LC_CTYPE:
.str "LC_CTYPE"
ncc_s_h_LC_MONETARY:
.str "LC_MONETARY"
ncc_s_h_LC_NUMERIC:
.str "LC_NUMERIC"
ncc_s_h_LC_TIME:
.str "LC_TIME"
ncc_s_h_BUFSIZ:
.str "BUFSIZ"
ncc_s_h_FILENAME_MAX:
.str "FILENAME_MAX"
ncc_s_h_FOPEN_MAX:
.str "FOPEN_MAX"
ncc_s_h_TMP_MAX:
.str "TMP_MAX"
ncc_s_h_L_tmpnam:
.str "L_tmpnam"
ncc_s_h__IOFBF:
.str "_IOFBF"
ncc_s_h__IOLBF:
.str "_IOLBF"
ncc_s_h__IONBF:
.str "_IONBF"
ncc_s_h_WEOF:
.str "WEOF"
ncc_s_h_FP_NAN:
.str "FP_NAN"
ncc_s_h_FP_INFINITE:
.str "FP_INFINITE"
ncc_s_h_FP_ZERO:
.str "FP_ZERO"
ncc_s_h_FP_SUBNORMAL:
.str "FP_SUBNORMAL"
ncc_s_h_FP_NORMAL:
.str "FP_NORMAL"
ncc_s_h_FP_ILOGB0:
.str "FP_ILOGB0"
ncc_s_h_FP_ILOGBNAN:
.str "FP_ILOGBNAN"
ncc_s_h_MATH_ERRNO:
.str "MATH_ERRNO"
ncc_s_h_MATH_ERREXCEPT:
.str "MATH_ERREXCEPT"
ncc_s_h_FLT_RADIX:
.str "FLT_RADIX"
ncc_s_h_FLT_MANT_DIG:
.str "FLT_MANT_DIG"
ncc_s_h_DBL_MANT_DIG:
.str "DBL_MANT_DIG"
ncc_s_h_LDBL_MANT_DIG:
.str "LDBL_MANT_DIG"
ncc_s_h_FLT_DIG:
.str "FLT_DIG"
ncc_s_h_DBL_DIG:
.str "DBL_DIG"
ncc_s_h_LDBL_DIG:
.str "LDBL_DIG"
ncc_s_h_FLT_MIN_EXP:
.str "FLT_MIN_EXP"
ncc_s_h_DBL_MIN_EXP:
.str "DBL_MIN_EXP"
ncc_s_h_LDBL_MIN_EXP:
.str "LDBL_MIN_EXP"
ncc_s_h_FLT_MAX_EXP:
.str "FLT_MAX_EXP"
ncc_s_h_DBL_MAX_EXP:
.str "DBL_MAX_EXP"
ncc_s_h_LDBL_MAX_EXP:
.str "LDBL_MAX_EXP"
ncc_s_h_FLT_MIN_10_EXP:
.str "FLT_MIN_10_EXP"
ncc_s_h_DBL_MIN_10_EXP:
.str "DBL_MIN_10_EXP"
ncc_s_h_LDBL_MIN_10_EXP:
.str "LDBL_MIN_10_EXP"
ncc_s_h_FLT_MAX_10_EXP:
.str "FLT_MAX_10_EXP"
ncc_s_h_DBL_MAX_10_EXP:
.str "DBL_MAX_10_EXP"
ncc_s_h_LDBL_MAX_10_EXP:
.str "LDBL_MAX_10_EXP"
ncc_s_h_DECIMAL_DIG:
.str "DECIMAL_DIG"
ncc_s_h_FLT_MIN:
.str "FLT_MIN"
ncc_s_h_DBL_MIN:
.str "DBL_MIN"
ncc_s_h_LDBL_MIN:
.str "LDBL_MIN"
ncc_s_h_FLT_MAX:
.str "FLT_MAX"
ncc_s_h_DBL_MAX:
.str "DBL_MAX"
ncc_s_h_LDBL_MAX:
.str "LDBL_MAX"
ncc_s_h_FLT_EPSILON:
.str "FLT_EPSILON"
ncc_s_h_DBL_EPSILON:
.str "DBL_EPSILON"
ncc_s_h_LDBL_EPSILON:
.str "LDBL_EPSILON"
ncc_s_h_HUGE_VALF:
.str "HUGE_VALF"
ncc_s_h_HUGE_VALL:
.str "HUGE_VALL"
ncc_s_h_LLONG_MIN:
.str "LLONG_MIN"
ncc_s_h_LLONG_MAX:
.str "LLONG_MAX"
ncc_s_h_ULLONG_MAX:
.str "ULLONG_MAX"
ncc_s_h_INT64_MIN:
.str "INT64_MIN"
ncc_s_h_INT64_MAX:
.str "INT64_MAX"
ncc_s_h_UINT64_MAX:
.str "UINT64_MAX"
ncc_s_h_INTMAX_MIN:
.str "INTMAX_MIN"
ncc_s_h_INTMAX_MAX:
.str "INTMAX_MAX"
ncc_s_h_UINTMAX_MAX:
.str "UINTMAX_MAX"
