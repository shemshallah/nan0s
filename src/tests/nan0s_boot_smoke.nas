; nan0s_boot_smoke.nas - raw NaN16 substrate boot smoke.
;
; This is a test guest for the shipped 32-bit boot sector + native NaN16 core.
; It prints a fixed banner on COM1 and halts; no C, no filesystem, no GUI.
; tools/noc_product_gate.sh boots it from a floppy image built with the same
; GOLD stream as build/nan0s.img.
.org 0
MOVI r13,1
LA r1,@msg
SHL r1,r1,2
loop:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @done
PUTC r2
ADD r1,r1,r13
JMP @loop
done:
HALT
msg:
.str "NaN/0S SMOKE OK\n"
