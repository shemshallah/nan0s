; nancore_scale_test.nas - 4096-core NanCore layout proof.
.org 0
JMP @main
.include "../lib/nancore.nas"
main:
MOVI r13,1
MOVI r14,0x7000
MOVI r1,0
CALL @nc_record
LA r2,0x400000
CMP r1,r2
JMP[NE] @fail
MOVI r1,4095
CALL @nc_record
LA r2,0x43FFC0
CMP r1,r2
JMP[NE] @fail
MOVI r1,4096
CALL @nc_record
CMP r1,r0
JMP[NE] @fail
MOVI r1,4095
MOVI r2,#NC_APIC
CALL @nc_field
MOVI r3,0xAB
ST r3,r1,0
MOVI r1,4095
MOVI r2,#NC_APIC
CALL @nc_field
LD r4,r1,0
MOVI r5,0xAB
CMP r4,r5
JMP[NE] @fail
MOVI r1,4095
CALL @nc_online_set
MOVI r1,4095
CALL @nc_online_test
CMP r1,r13
JMP[NE] @fail
MOVI r1,4094
CALL @nc_online_test
CMP r1,r0
JMP[NE] @fail
MOVI r1,79
PUTC r1
HALT

fail:
MOVI r1,70
PUTC r1
HALT
