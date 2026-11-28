; core_parity_test.nas - deterministic output for 32-bit/64-bit host-core parity.
; The guest ISA is unchanged; the test prints a marker and simple ALU/memory
; results, then halts.  The parity gate ignores the x64 host core's SPEL stage.
MOVI r1,126
PUTC r1
MOVI r1,65
PUTC r1
MOVI r2,17
MOVI r3,3
MUL r4,r2,r3
ADDI r4,r4,15
PUTC r4
MOVI r5,100
MOVI r6,33
SUB r7,r5,r6
PUTC r7
MOVI r8,0x1234
ST r8,r0,0x1000
LD r9,r0,0x1000
CMP r9,r8
JMP[NE] @bad
MOVI r8,0x5678
MOVHI r8,0x1234
ST r8,r0,0x1001
LD r9,r0,0x1001
CMP r9,r8
JMP[NE] @bad
MOVI r1,10
PUTC r1
MOVI r1,79
PUTC r1
MOVI r1,75
PUTC r1
HALT
bad:
MOVI r1,33
PUTC r1
HALT
