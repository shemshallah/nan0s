; nanobj.nas - NANIX typed object table and capability words (M1a).
;
; This is the first native object primitive, deliberately independent of the
; POSIX path/fd layer.  An object has a class, a generation, a word payload
; and a reference count.  Callers hold a capability word, never a raw pointer.
;
; ABI (r0=0, r13=1, r14 soft stack grows up, r15 link):
;   nobj_init
;   nobj_create r1=class r2=words(1..8) -> r1=cap or 0
;   nobj_read   r1=cap r2=dst word ptr r3=offset r4=len -> words / -1
;   nobj_write  r1=cap r2=src word ptr r3=offset r4=len -> words / -1
;   nobj_grant  r1=cap r2=new rights -> new cap or 0
;   nobj_revoke r1=cap -> new generation, old caps invalidated
;   nobj_release r1=cap -> 0 / -1
;   nobj_check  r1=cap r2=required rights -> entry ptr or 0
;   nobj_set_io r1=save hook r2=load hook
;   nobj_save   r1=path byte -> 0/-1
;   nobj_load   r1=path byte -> 0/-1
;
; Capability word (32-bit payload value):
;   bits 31..24 0xCA
;   bits 23..16 object id (1..64)
;   bits 15..8  generation (1..255)
;   bits 7..0   rights (1 read, 2 write, 4 execute, 8 grant, 16 replace)
;
; Object entry (16 words at NOBJ_TAB):
;   0 magic, 1 id, 2 generation, 3 class, 4 size words, 5 refs,
;   6 flags, 7 checksum, 8..31 payload (24 words).
;
; Cross-call state lives in globals, never in caller stack words above SP:
; NANIX callees are allowed to overwrite those.  LD/ST have a 16-bit immediate,
; so these words are deliberately in the reserved low block 0x3A0..0x3D2;
; high buffers must be addressed through an LA base register.

.equ NOBJ_TAB     0x340000
.equ NOBJ_MAX     64
.equ NOBJ_ENT     32
.equ NOBJ_TOTAL   2048
.equ NOBJ_MAGIC   0x4E4F424A       ; "NOBJ"
.equ NOBJ_G       0x3A0
.equ NOBJ_G_CAP    0x3A0
.equ NOBJ_G_DST    0x3A1
.equ NOBJ_G_OFF    0x3A2
.equ NOBJ_G_LEN    0x3A3
.equ NOBJ_G_ENT    0x3A4
.equ NOBJ_G_ID    0x3A5
.equ NOBJ_G_GEN    0x3A6
.equ NOBJ_G_RIGHT    0x3A7
.equ NOBJ_G_TMP    0x3A8
.equ NOBJ_G_TMP2    0x3A9
.equ NOBJ_G_SRC     0x3AA
.equ NOBJ_G_WORDS   0x3AB
.equ NOBJ_G_IDX     0x3AC
.equ NOBJ_HOOK_SAVE 0x3D0
.equ NOBJ_HOOK_LOAD 0x3D1
.equ NOBJ_G_PATH    0x3D2
.equ NOBJ_R_READ  1
.equ NOBJ_R_WRITE 2
.equ NOBJ_R_EXEC  4
.equ NOBJ_R_GRANT 8
.equ NOBJ_R_REPL  16
.equ NOBJ_R_ALL   31

; ---------------------------------------------------------------------------
nobj_init:
  MOVI r2,0
  LA r3,#NOBJ_TAB
  MOVI r4,#NOBJ_TOTAL
nobj_i_l:
  CMP r4,r0
  JMP[EQ] @nobj_i_d
  ST r0,r3,0
  ADD r3,r3,r13
  SUB r4,r4,r13
  JMP @nobj_i_l
nobj_i_d:
  MOVI r1,0
  RET

; nobj_magic -> r1 = NOBJ_MAGIC
nobj_magic:
  MOVI r1,0x4E4F
  SHL r1,r1,16
  MOVI r3,0x424A
  ADD r1,r1,r3
  RET

; nobj_cap_magic -> r1 = 0xCA000000
nobj_cap_magic:
  MOVI r1,0xCA00
  SHL r1,r1,16
  RET

; nobj_entry_index: r1=id(1..64) -> r1=entry ptr or 0
nobj_entry_index:
  CMP r1,r0
  JMP[EQ] @nobj_ei_n
  MOVI r2,#NOBJ_MAX
  CMP r1,r2
  JMP[GT] @nobj_ei_n
  SUB r1,r1,r13
  MOVI r2,#NOBJ_ENT
  MUL r1,r1,r2
  LA r2,#NOBJ_TAB
  ADD r1,r1,r2
  RET
nobj_ei_n:
  MOVI r1,0
  RET

; nobj_check: r1=cap r2=required rights -> entry ptr or 0
nobj_check:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NOBJ_G_CAP
  ST r2,r0,#NOBJ_G_RIGHT
  ; magic byte
  SHR r3,r1,24
  MOVI r4,0xCA
  CMP r3,r4
  JMP[NE] @nobj_c_n
  ; id
  SHR r3,r1,16
  MOVI r4,0xFF
  BOOL.8 r3,r3,r4
  ST r3,r0,#NOBJ_G_ID
  ; generation
  SHR r4,r1,8
  MOVI r5,0xFF
  BOOL.8 r4,r4,r5
  ST r4,r0,#NOBJ_G_GEN
  ; rights
  MOVI r5,0xFF
  BOOL.8 r5,r1,r5
  LD r6,r0,#NOBJ_G_RIGHT
  BOOL.8 r5,r5,r6
  CMP r5,r6
  JMP[NE] @nobj_c_n
  ; validate entry
  LD r1,r0,#NOBJ_G_ID
  CALL @nobj_entry_index
  CMP r1,r0
  JMP[EQ] @nobj_c_n
  ST r1,r0,#NOBJ_G_ENT
  LD r2,r1,0
  CALL @nobj_magic
  CMP r2,r1
  JMP[NE] @nobj_c_n
  LD r1,r0,#NOBJ_G_ENT
  LD r2,r1,1
  LD r3,r0,#NOBJ_G_ID
  CMP r2,r3
  JMP[NE] @nobj_c_n
  LD r2,r1,2
  LD r3,r0,#NOBJ_G_GEN
  CMP r2,r3
  JMP[NE] @nobj_c_n
  JMP @nobj_c_d
nobj_c_n:
  MOVI r1,0
nobj_c_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nobj_create: r1=class r2=size words -> cap or 0
nobj_create:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NOBJ_G_TMP
  ST r2,r0,#NOBJ_G_TMP2
  CMP r2,r0
  JMP[EQ] @nobj_cr_n
  MOVI r3,24
  CMP r2,r3
  JMP[GT] @nobj_cr_n
  ; scan for a free entry
  MOVI r4,0
  LA r5,#NOBJ_TAB
  MOVI r6,#NOBJ_MAX
nobj_cr_l:
  CMP r4,r6
  JMP[GE] @nobj_cr_n
  LD r7,r5,0
  CMP r7,r0
  JMP[EQ] @nobj_cr_use
  MOVI r7,#NOBJ_ENT
  ADD r5,r5,r7
  ADD r4,r4,r13
  JMP @nobj_cr_l
nobj_cr_use:
  ST r4,r0,#NOBJ_G_ID       ; index
  ; magic
  LA r7,@nobj_magic
  CALLR r7
  ST r1,r5,0
  ; id = index + 1
  LD r4,r0,#NOBJ_G_ID
  ADD r7,r4,r13
  ST r7,r5,1
  ; generation = 1
  MOVI r7,1
  ST r7,r5,2
  ; class
  LD r7,r0,#NOBJ_G_TMP
  ST r7,r5,3
  ; size
  LD r7,r0,#NOBJ_G_TMP2
  ST r7,r5,4
  ; refs = 1
  MOVI r7,1
  ST r7,r5,5
  ; flags, checksum
  ST r0,r5,6
  ST r0,r5,7
  ; zero payload (24 words)
  MOVI r6,24
  ADDI r7,r5,8
nobj_cr_z:
  CMP r6,r0
  JMP[EQ] @nobj_cr_cap
  ST r0,r7,0
  ADD r7,r7,r13
  SUB r6,r6,r13
  JMP @nobj_cr_z
nobj_cr_cap:
  ; cap = 0xCA000000 | id<<16 | gen<<8 | rights
  LA r7,@nobj_cap_magic
  CALLR r7
  LD r4,r0,#NOBJ_G_ID
  ADD r4,r4,r13             ; id
  SHL r4,r4,16
  ADD r1,r1,r4
  MOVI r4,1
  SHL r4,r4,8               ; gen 1
  ADD r1,r1,r4
  MOVI r4,#NOBJ_R_ALL
  ADD r1,r1,r4
  JMP @nobj_cr_d
nobj_cr_n:
  MOVI r1,0
nobj_cr_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nobj_read: r1=cap r2=dst r3=offset words r4=len words -> words / -1
nobj_read:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NOBJ_G_CAP
  ST r2,r0,#NOBJ_G_DST
  ST r3,r0,#NOBJ_G_OFF
  ST r4,r0,#NOBJ_G_LEN
  MOVI r2,#NOBJ_R_READ
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @nobj_r_n
  ST r1,r0,#NOBJ_G_ENT
  ; bounds
  LD r3,r0,#NOBJ_G_OFF
  LD r4,r0,#NOBJ_G_LEN
  ADD r5,r3,r4
  LD r6,r1,4
  CMP r5,r6
  JMP[GT] @nobj_r_n
  ; copy
  ADDI r5,r1,8
  ADD r5,r5,r3
  LD r6,r0,#NOBJ_G_DST
  LD r7,r0,#NOBJ_G_LEN
nobj_r_l:
  CMP r7,r0
  JMP[EQ] @nobj_r_ok
  LD r4,r5,0
  ST r4,r6,0
  ADD r5,r5,r13
  ADD r6,r6,r13
  SUB r7,r7,r13
  JMP @nobj_r_l
nobj_r_ok:
  LD r1,r0,#NOBJ_G_LEN
  JMP @nobj_r_d
nobj_r_n:
  LA r1,0xFFFFFFFF
nobj_r_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nobj_write: r1=cap r2=src r3=offset words r4=len words -> words / -1
nobj_write:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NOBJ_G_CAP
  ST r2,r0,#NOBJ_G_DST
  ST r3,r0,#NOBJ_G_OFF
  ST r4,r0,#NOBJ_G_LEN
  MOVI r2,#NOBJ_R_WRITE
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @nobj_w_n
  ST r1,r0,#NOBJ_G_ENT
  LD r3,r0,#NOBJ_G_OFF
  LD r4,r0,#NOBJ_G_LEN
  ADD r5,r3,r4
  LD r6,r1,4
  CMP r5,r6
  JMP[GT] @nobj_w_n
  ADDI r5,r1,8
  ADD r5,r5,r3
  LD r6,r0,#NOBJ_G_DST
  LD r7,r0,#NOBJ_G_LEN
nobj_w_l:
  CMP r7,r0
  JMP[EQ] @nobj_w_ok
  LD r4,r6,0
  ST r4,r5,0
  ADD r5,r5,r13
  ADD r6,r6,r13
  SUB r7,r7,r13
  JMP @nobj_w_l
nobj_w_ok:
  LD r1,r0,#NOBJ_G_LEN
  JMP @nobj_w_d
nobj_w_n:
  LA r1,0xFFFFFFFF
nobj_w_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nobj_grant: r1=cap r2=new rights -> new cap or 0
nobj_grant:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NOBJ_G_CAP
  ST r2,r0,#NOBJ_G_TMP2
  MOVI r2,#NOBJ_R_GRANT
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @nobj_g_n
  ST r1,r0,#NOBJ_G_ENT
  ; granted rights = old rights & requested
  LD r3,r0,#NOBJ_G_CAP
  MOVI r4,0xFF
  BOOL.8 r3,r3,r4
  LD r4,r0,#NOBJ_G_TMP2
  BOOL.8 r3,r3,r4
  ST r3,r0,#NOBJ_G_RIGHT
  ; build same id/gen with new rights
  LA r7,@nobj_cap_magic
  CALLR r7
  LD r4,r0,#NOBJ_G_ENT
  LD r5,r4,1
  SHL r5,r5,16
  ADD r1,r1,r5
  LD r5,r4,2
  SHL r5,r5,8
  ADD r1,r1,r5
  LD r5,r0,#NOBJ_G_RIGHT
  ADD r1,r1,r5
  ; one more capability reference
  LD r5,r4,5
  ADD r5,r5,r13
  ST r5,r4,5
  JMP @nobj_g_d
nobj_g_n:
  MOVI r1,0
nobj_g_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nobj_revoke: r1=cap -> new cap with a new generation, or 0.
; Requires replace right.  Old capabilities fail the generation check; the
; reference count is reset to the one new capability (old holders are stale).
nobj_revoke:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NOBJ_G_CAP
  MOVI r2,#NOBJ_R_REPL
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @nobj_rv_n
  ST r1,r0,#NOBJ_G_ENT
  LD r2,r1,2
  ADD r2,r2,r13
  CMP r2,r0
  JMP[NE] @nobj_rv_gen
  MOVI r2,1
nobj_rv_gen:
  ST r2,r1,2
  MOVI r2,1
  ST r2,r1,5
  LA r7,@nobj_cap_magic
  CALLR r7
  LD r4,r0,#NOBJ_G_ENT
  LD r5,r4,1
  SHL r5,r5,16
  ADD r1,r1,r5
  LD r5,r4,2
  SHL r5,r5,8
  ADD r1,r1,r5
  LD r5,r0,#NOBJ_G_CAP
  MOVI r6,0xFF
  BOOL.8 r5,r5,r6
  ADD r1,r1,r5
  JMP @nobj_rv_d
nobj_rv_n:
  MOVI r1,0
nobj_rv_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nobj_set_io: r1=save hook r2=load hook.  Hooks are called as:
;   save r1=path r2=src word ptr r3=words -> r1=0/-1
;   load r1=path -> r1=src word ptr r2=words / 0
nobj_set_io:
  ST r1,r0,#NOBJ_HOOK_SAVE
  ST r2,r0,#NOBJ_HOOK_LOAD
  MOVI r1,0
  RET

; nobj_save: r1=path byte -> 0/-1
nobj_save:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NOBJ_G_PATH
  LD r3,r0,#NOBJ_HOOK_SAVE
  CMP r3,r0
  JMP[EQ] @nobj_sv_n
  LD r1,r0,#NOBJ_G_PATH
  LA r2,#NOBJ_TAB
  MOVI r3,#NOBJ_TOTAL
  LD r4,r0,#NOBJ_HOOK_SAVE
  CALLR r4
  JMP @nobj_sv_d
nobj_sv_n:
  LA r1,0xFFFFFFFF
nobj_sv_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nobj_load: r1=path byte -> 0/-1
nobj_load:
  ST r15,r14,0
  ADD r14,r14,r13
  ST r1,r0,#NOBJ_G_PATH
  LD r3,r0,#NOBJ_HOOK_LOAD
  CMP r3,r0
  JMP[EQ] @nobj_ld_n
  LD r1,r0,#NOBJ_G_PATH
  CALLR r3
  CMP r1,r0
  JMP[EQ] @nobj_ld_n
  MOVI r3,#NOBJ_TOTAL
  CMP r2,r3
  JMP[NE] @nobj_ld_n
  ST r1,r0,#NOBJ_G_SRC
  ST r2,r0,#NOBJ_G_WORDS
  ; validate entries before replacing the live table
  MOVI r3,0
  ST r3,r0,#NOBJ_G_IDX
nobj_ld_l:
  LD r3,r0,#NOBJ_G_IDX
  MOVI r4,#NOBJ_MAX
  CMP r3,r4
  JMP[GE] @nobj_ld_copy
  MOVI r4,#NOBJ_ENT
  MUL r4,r3,r4
  LD r5,r0,#NOBJ_G_SRC
  ADD r5,r5,r4
  ST r5,r0,#NOBJ_G_ENT
  LD r4,r5,0
  CMP r4,r0
  JMP[EQ] @nobj_ld_next
  ; magic
  LD r6,r5,0
  CALL @nobj_magic
  CMP r6,r1
  JMP[NE] @nobj_ld_n
  ; id = index + 1
  LD r5,r0,#NOBJ_G_ENT
  LD r4,r5,1
  LD r3,r0,#NOBJ_G_IDX
  ADD r3,r3,r13
  CMP r4,r3
  JMP[NE] @nobj_ld_n
  ; generation nonzero
  LD r4,r5,2
  CMP r4,r0
  JMP[EQ] @nobj_ld_n
  ; payload <= 24 words
  LD r4,r5,4
  MOVI r6,24
  CMP r4,r6
  JMP[GT] @nobj_ld_n
nobj_ld_next:
  LD r3,r0,#NOBJ_G_IDX
  ADD r3,r3,r13
  ST r3,r0,#NOBJ_G_IDX
  JMP @nobj_ld_l
nobj_ld_copy:
  LD r1,r0,#NOBJ_G_SRC
  LA r2,#NOBJ_TAB
  MOVI r3,#NOBJ_TOTAL
  MOVI r4,0
nobj_ld_cp:
  CMP r4,r3
  JMP[GE] @nobj_ld_ok
  LD r5,r1,0
  ST r5,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  ADD r4,r4,r13
  JMP @nobj_ld_cp
nobj_ld_ok:
  MOVI r1,0
  JMP @nobj_ld_d
nobj_ld_n:
  LA r1,0xFFFFFFFF
nobj_ld_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; nobj_release: r1=cap -> 0 / -1
nobj_release:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0
  CALL @nobj_check
  CMP r1,r0
  JMP[EQ] @nobj_rel_n
  LD r3,r1,5
  SUB r3,r3,r13
  ST r3,r1,5
  CMP r3,r0
  JMP[NE] @nobj_rel_ok
nobj_rel_free:
  ST r0,r1,0
  ST r0,r1,5
nobj_rel_ok:
  MOVI r1,0
  JMP @nobj_rel_d
nobj_rel_n:
  LA r1,0xFFFFFFFF
nobj_rel_d:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
