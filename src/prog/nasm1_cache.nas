; nasm1_cache.nas - translate the compiled nasm1 word image into x86-64 blocks.
; This file is a template: tools/blockcache_build.sh copies it to build/cache
; and substitutes @CACHE_N@ with the number of nasm1 words.  The word table
; (nasm1_words.nas, full .raw words with NaN headers) and nasm1.nan must be
; in the same directory.
;
; Output: one 512-byte block per guest PC at 0x100000, and one predicate mask
; byte per PC at 0x300000.  A mask of 0xFF marks opcode 0 (unconditional);
; otherwise mask == the NaN header class nibble (bit 1=LT, 2=EQ/zero, 0=GT).
; The blocks use the kernel ABI: R=0x8000, FLAGM=0x8040, MASK=0x80C0,
; XPC=0x80D4, HALT=0x80D8, TRAP=0x80DC, G=0x200000.
.org 0
JMP @main
.include "../../src/translate/x64_block.nas"
main:
MOVI r13,1
LA r14,0x1F0000
MOVI r2,0
ST r2,r0,@gpc
g_l:
LD r10,r0,@gpc
MOVI r11,@CACHE_N@
CMP r10,r11
JMP[EQ] @g_done
LA r1,@words
ADD r1,r1,r10
MOVI r2,1
LA r3,0x100000
SHL r4,r10,9
ADD r3,r3,r4
ADD r4,r10,r13
CALL @x64_block
; predicate mask for this instruction, from the header class nibble
LA r1,@words
LD r10,r0,@gpc
ADD r1,r1,r10
LD r5,r1,0
LDN r2,r1,0
SHR r6,r5,24
CMP r6,r0
JMP[NE] @g_m1
MOVI r2,0xFF
JMP @g_m2
g_m1:
CMP r2,r0
JMP[NE] @g_m2
MOVI r2,0
g_m2:
LA r3,0x300000
ADD r3,r3,r10
STB r2,r3,0
LD r10,r0,@gpc
ADDI r10,r10,1
ST r10,r0,@gpc
JMP @g_l
g_done:
MOVI r1,89
PUTC r1
HALT
gpc:
.word 0
.org 0x9000
words:
.include "nasm1_words.nas"
