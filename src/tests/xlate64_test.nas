; xlate64_test.nas - NaN-native x86-64 block encoder proof.
; Emits MOVI r1,42; ADD r1,r1,r1; set XPC=0; RET at guest byte 0x10000.
.org 0
JMP @main
.include "../translate/x86_64.nas"
main:
MOVI r13,1
MOVI r14,0x7000
LA r1,0x10000
MOVI r5,1
MOVI r7,42
CALL @x64_movi
MOVI r5,1
MOVI r6,1
MOVI r8,1
CALL @x64_add
MOVI r7,0
CALL @x64_set_xpc
CALL @x64_ret
HALT
