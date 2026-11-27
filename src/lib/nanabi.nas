; nanabi.nas - custom NaN ABI constants and the AI-native ABI block.
;
; The ABI is implemented by n16i in NaN16; the native substrate only boots it.
; This header is shared by the kernel, scheduler, shell and AI libraries.

.equ NABI_BASE      0x3F200
.equ NABI_MAGIC     0x4E414249      ; "NABI"
.equ NABI_VERSION   0x0002

; ABI block words
.equ NABI_W_MAGIC   0
.equ NABI_W_VERSION 1
.equ NABI_W_FEAT    2
.equ NABI_W_MASK    3
.equ NABI_W_TICK    4
.equ NABI_W_TRACE   5
.equ NABI_W_CKPT    6
.equ NABI_W_CAPROOT 7
.equ NABI_W_SCHED   8
.equ NABI_W_OBJ     9
.equ NABI_W_TENSOR  10
.equ NABI_W_TRSTORE 11

; feature bits
.equ NABI_F_CAP     1
.equ NABI_F_CKPT    2
.equ NABI_F_TENSOR  4
.equ NABI_F_TRACE   8
.equ NABI_F_GEN     16
.equ NABI_F_BUDGET  32
.equ NABI_F_REPLAY  64
.equ NABI_F_ALL     127

; handle rights (same as nanobj)
.equ NABI_R_READ    1
.equ NABI_R_WRITE   2
.equ NABI_R_EXEC    4
.equ NABI_R_GRANT   8
.equ NABI_R_REPL    16
.equ NABI_R_ALL     31

; SVC numbers
.equ NABI_S_VERSION 29
.equ NABI_S_CAPCHK  30
.equ NABI_S_GRANT   31
.equ NABI_S_REVOKE  32
.equ NABI_S_OBJNEW  33
.equ NABI_S_TVIEW   34
.equ NABI_S_KV      35
.equ NABI_S_TRACE   36
.equ NABI_S_CKPT    37
.equ NABI_S_RESTORE 38
.equ NABI_S_PUBLISH 39
.equ NABI_S_SPAWN   40
.equ NABI_S_YIELD   41
.equ NABI_S_TOOL    42
.equ NABI_S_SEED    43
.equ NABI_S_READ    44
.equ NABI_S_WRITE   45

; publish the ABI block.  r1=mask r2=sched r3=obj r4=tensor r5=trace
nabi_publish:
  LA r6,#NABI_BASE
  LA r7,#NABI_MAGIC
  ST r7,r6,0
  MOVI r7,#NABI_VERSION
  ST r7,r6,1
  MOVI r7,#NABI_F_ALL
  ST r7,r6,2
  ST r1,r6,3
  ST r0,r6,4
  ST r0,r6,5
  ST r0,r6,6
  ST r0,r6,7
  ST r2,r6,8
  ST r3,r6,9
  ST r4,r6,10
  ST r5,r6,11
  RET
