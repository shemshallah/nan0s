; avx2_feature_test.nas - is the AVX2 tier active?
; Reads the native machine query (CPUID leaf 0x4E4D00FF, subleaf 2) and
; tests bit 8.  The native core sets bit 8 only after XSAVE+AVX2 detection,
; CR4.OSXSAVE and XCR0=7 succeeded.
.org 0
JMP @main
main:
MOVI r13,1
LA r1,0x4E4D00FF
MOVI r2,2
MOVI r3,0
CPUID r4,r1,r2
SHR r4,r4,8
MOVI r5,1
BOOL.8 r4,r4,r5
CMP r4,r0
JMP[EQ] @off
LA r1,@s_on
JMP @puts
off:
LA r1,@s_off
puts:
SHL r1,r1,2
pl:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @pd
PUTC r2
ADDI r1,r1,1
JMP @pl
pd:
HALT
s_on:
.str "AVX2 ON\n"
s_off:
.str "AVX2 OFF\n"
