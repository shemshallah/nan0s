; nanpipe.nas - NaN16 byte pipes (POSIX pipe primitive).
;
; A pipe is a fixed 4 KiB window in NaN memory.  This is the single-threaded
; primitive: write() appends, read() drains, close() frees.  It is the
; storage layer for libc pipe()/dup2(); concurrency is supplied later by the
; process/thread kernel.
;
; ABI (r0=0, r13=1):
;   np_open              -> r1=id (1..NPIPE_MAX) or 0
;   np_write r1=id r2=src byte ptr r3=len -> r1=bytes written
;   np_read  r1=id r2=dst byte ptr r3=len -> r1=bytes read (0 = empty/EOF)
;   np_close r1=id       -> r1=0
.equ NPIPE_MAX  8
.equ NPIPE_BASE 0x240000
.equ NPIPE_CAP  4096
.equ NPIPE_SZ   1028
.equ NP_W_ID    0xF0780
.equ NP_W_SRC   0xF0781
.equ NP_W_LEN   0xF0782
.equ NP_W_N     0xF0783
.equ NP_W_REC   0xF0784

np_open:
MOVI r4,0
np_o_l:
MOVI r5,#NPIPE_MAX
CMP r4,r5
JMP[GE] @np_o_n
MOVI r5,#NPIPE_SZ
MUL r5,r4,r5
LA r6,#NPIPE_BASE
ADD r6,r6,r5
LD r7,r6,0
CMP r7,r0
JMP[EQ] @np_o_use
ADD r4,r4,r13
JMP @np_o_l
np_o_use:
MOVI r7,1
ST r7,r6,0
ST r0,r6,1
ST r0,r6,2
ST r0,r6,3
ADD r1,r4,r13
RET
np_o_n:
MOVI r1,0
RET

np_close:
CMP r1,r0
JMP[EQ] @np_c_d
SUB r1,r1,r13
MOVI r5,#NPIPE_SZ
MUL r5,r1,r5
LA r6,#NPIPE_BASE
ADD r6,r6,r5
ST r0,r6,0
np_c_d:
MOVI r1,0
RET

; np_record: r1=id -> r6=record or 0
np_record:
CMP r1,r0
JMP[EQ] @np_r_n
SUB r1,r1,r13
MOVI r5,#NPIPE_MAX
CMP r1,r5
JMP[GE] @np_r_n
MOVI r5,#NPIPE_SZ
MUL r5,r1,r5
LA r6,#NPIPE_BASE
ADD r6,r6,r5
LD r7,r6,0
CMP r7,r0
JMP[EQ] @np_r_n
RET
np_r_n:
MOVI r6,0
RET

; np_bcopy: r1=dst byte ptr r2=src byte ptr r3=len
np_bcopy:
CMP r3,r0
JMP[EQ] @np_bc_d
np_bc_l:
LDB r4,r2,0
STB r4,r1,0
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP[NE] @np_bc_l
np_bc_d:
RET

; np_write: r1=id r2=src byte ptr r3=len -> bytes written
np_write:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#NP_W_ID
ST r2,r0,#NP_W_SRC
ST r3,r0,#NP_W_LEN
CALL @np_record
CMP r6,r0
JMP[EQ] @np_w_zero
ST r6,r0,#NP_W_REC
; free = CAP - count
LD r7,r6,3
MOVI r8,#NPIPE_CAP
SUB r8,r8,r7
LD r9,r0,#NP_W_LEN
CMP r9,r8
JMP[LE] @np_w_fit
ADD r9,r8,r0
np_w_fit:
CMP r9,r0
JMP[EQ] @np_w_zero
ST r9,r0,#NP_W_N
; compact when write_pos + n would cross the end
LD r10,r6,2
ADD r11,r10,r9
MOVI r12,#NPIPE_CAP
CMP r11,r12
JMP[LE] @np_w_place
; move count bytes from buffer+read_pos to buffer+0
ADDI r1,r6,4
SHL r1,r1,2
LD r2,r6,1
ADD r2,r1,r2
LD r3,r6,3
CALL @np_bcopy
LD r6,r0,#NP_W_REC
ST r0,r6,1
LD r7,r6,3
ST r7,r6,2
np_w_place:
LD r6,r0,#NP_W_REC
ADDI r1,r6,4
SHL r1,r1,2
LD r7,r6,2
ADD r1,r1,r7
LD r2,r0,#NP_W_SRC
LD r3,r0,#NP_W_N
CALL @np_bcopy
LD r6,r0,#NP_W_REC
LD r7,r6,2
LD r9,r0,#NP_W_N
ADD r7,r7,r9
ST r7,r6,2
LD r7,r6,3
ADD r7,r7,r9
ST r7,r6,3
ADD r1,r9,r0
JMP @np_w_d
np_w_zero:
MOVI r1,0
np_w_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; np_read: r1=id r2=dst byte ptr r3=len -> bytes read (0 empty)
np_read:
ST r15,r14,0
ADD r14,r14,r13
ST r2,r0,#NP_W_SRC
ST r3,r0,#NP_W_LEN
CALL @np_record
CMP r6,r0
JMP[EQ] @np_rd_zero
ST r6,r0,#NP_W_REC
LD r9,r6,3
LD r10,r0,#NP_W_LEN
CMP r10,r9
JMP[LE] @np_rd_fit
ADD r10,r9,r0
np_rd_fit:
CMP r10,r0
JMP[EQ] @np_rd_zero
ST r10,r0,#NP_W_N
LD r1,r0,#NP_W_SRC
ADDI r2,r6,4
SHL r2,r2,2
LD r7,r6,1
ADD r2,r2,r7
LD r3,r0,#NP_W_N
CALL @np_bcopy
LD r6,r0,#NP_W_REC
LD r7,r6,1
LD r10,r0,#NP_W_N
ADD r7,r7,r10
ST r7,r6,1
LD r7,r6,3
SUB r7,r7,r10
ST r7,r6,3
CMP r7,r0
JMP[NE] @np_rd_ret
ST r0,r6,1
ST r0,r6,2
np_rd_ret:
ADD r1,r10,r0
JMP @np_rd_d
np_rd_zero:
MOVI r1,0
np_rd_d:
SUB r14,r14,r13
LD r15,r14,0
RET
