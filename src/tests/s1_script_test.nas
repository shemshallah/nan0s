; s1_script_test.nas - read the testfixture guest-script path block.
; Guest byte 0x03EFF020: u32 length; 0x03EFF024: path bytes (no NUL).
.org 0
JMP @main
main:
MOVI r13,1
LA r1,0x03EFF020
SHR r1,r1,2
LD r2,r1,0                  ; length
LA r1,0x03EFF024            ; path byte address
loop:
CMP r2,r0
JMP[EQ] @done
LDB r3,r1,0
PUTC r3
ADDI r1,r1,1
ADDI r2,r2,0xFFFF
JMP @loop
done:
MOVI r1,10
PUTC r1
MOVI r1,0
HALT
