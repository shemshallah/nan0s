; nixjobs_sh.nas - worker-safe command stages for SVC 9 jobs.
;
; Contract: spec/NIX_JOBS.md (worker contexts and ring pipes) and the stage
; ABI below.  Every function is a stage entry called by nj_worker_entry:
;
;   entry: r12 = worker context, r13 = 1, r14 = private worker stack
;   exit:  r1  = status (0 success, non-zero failure)
;
; The stage uses only its context, its stack and the nj_* routines.  r12 is
; preserved across every nj_* call and across every helper below, so a stage
; can treat r12 as a stable context pointer.  No shell parser state, no
; process-global descriptor table and no shared pipe library state is used.
;
; Context fields consumed/produced by these stages:
;
;   NJ_C_SCRATCH      byte pointer to the stage buffer
;   NJ_C_SCRATCH_LEN  njs_cat/njs_echo: bytes to emit when non-zero.
;                     njs_wc: capacity of the read buffer in bytes.
;   NJ_C_TICKS        njs_sleep: scheduler ticks to sleep
;   NJ_C_TOTAL        njs_cat: emitted bytes (synthetic mode) or 0 (stream);
;                     njs_wc: bytes counted
;   NJ_C_DONE         njs_cat/njs_echo: progress in bytes;
;                     njs_wc: bytes counted (mirror of TOTAL)
;   NJ_C_TMP0         njs_wc: line count; njs_sleep: finished flag
;   NJ_C_TMP1         njs_wc: word count; njs_sleep: entered flag
;   NJ_C_TMP2         njs_wc: in-word flag
;   NJ_C_TMP3         njs_wc: 1 when PEER was partial at stage entry
;   NJ_C_PEER         njs_wc: optional upstream context read for TMP3
;   NJ_C_WIT          untouched by these stages
;
; fd 0 and fd 1 are the stage's context descriptors, set by the caller with
; nj_fd_set/nj_fd_pipe.  A stage closes fd 1 when it has finished producing
; so a ring reader observes EOF; the process exit is the final close.

.equ NJS_CHUNK 128

; ---------------------------------------------------------------------------
; njs_cat: if SCRATCH_LEN != 0 emit exactly SCRATCH_LEN bytes from SCRATCH to
; fd 1; otherwise stream fd 0 to fd 1 in NJS_CHUNK blocks.  Returns 0/-1.
njs_cat:
  LD r1,r12,#NJ_C_SCRATCH_LEN
  CMP r1,r0
  JMP[NE] @njs_emit_scratch
  ; ---- stream fd 0 -> fd 1 ------------------------------------------------
  ST r15,r14,0
  ADDI r14,r14,64
  ST r0,r12,#NJ_C_TOTAL
  ST r0,r12,#NJ_C_DONE
njs_cat_stream:
  ADDI r3,r14,16
  SHL r3,r3,2
  ADD r1,r12,r0
  MOVI r2,0
  MOVI r4,#NJS_CHUNK
  CALL @nj_fd_read
  CMP r1,r0
  JMP[LT] @njs_cat_bad
  CMP r1,r0
  JMP[EQ] @njs_cat_done
  ST r1,r14,1
  ADDI r3,r14,16
  SHL r3,r3,2
  ADD r1,r12,r0
  MOVI r2,1
  LD r4,r14,1
  CALL @nj_fd_write
  CMP r1,r0
  JMP[LE] @njs_cat_bad
  LD r2,r12,#NJ_C_DONE
  ADD r2,r2,r1
  ST r2,r12,#NJ_C_DONE
  JMP @njs_cat_stream
njs_cat_done:
  ADD r1,r12,r0
  MOVI r2,1
  CALL @nj_fd_close
  MOVI r1,0
  JMP @njs_cat_out
njs_cat_bad:
  MOVI r1,1
njs_cat_out:
  ADDI r14,r14,-64
  LD r15,r14,0
  RET

; njs_echo: emit exactly SCRATCH_LEN bytes from SCRATCH to fd 1.  A zero
; length is legal and simply closes fd 1.
njs_echo:
  JMP @njs_emit_scratch

; ---------------------------------------------------------------------------
; njs_emit_scratch - shared synthetic-buffer emitter.  r12 = context.
; Uses SCRATCH_LEN as total, updates DONE, closes fd 1, returns 0/-1.
njs_emit_scratch:
  ST r15,r14,0
  ADDI r14,r14,24
  LD r1,r12,#NJ_C_SCRATCH_LEN
  ST r1,r12,#NJ_C_TOTAL
  ST r0,r12,#NJ_C_DONE
njs_emit_loop:
  LD r1,r12,#NJ_C_DONE
  LD r2,r12,#NJ_C_TOTAL
  CMP r1,r2
  JMP[GE] @njs_emit_done
  SUB r2,r2,r1
  MOVI r3,#NJS_CHUNK
  CMP r2,r3
  JMP[LE] @njs_emit_n
  ADD r2,r3,r0
njs_emit_n:
  ST r2,r14,1
  LD r3,r12,#NJ_C_SCRATCH
  ADD r3,r3,r1
  ADD r1,r12,r0
  MOVI r2,1
  LD r4,r14,1
  CALL @nj_fd_write
  CMP r1,r0
  JMP[LE] @njs_emit_bad
  LD r2,r12,#NJ_C_DONE
  ADD r2,r2,r1
  ST r2,r12,#NJ_C_DONE
  JMP @njs_emit_loop
njs_emit_done:
  ADD r1,r12,r0
  MOVI r2,1
  CALL @nj_fd_close
  MOVI r1,0
  JMP @njs_emit_out
njs_emit_bad:
  MOVI r1,1
njs_emit_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; njs_wc: read fd 0 until EOF and write "lines words bytes\n" to fd 1.
; Whitespace is space, TAB, CR or LF.  The read buffer is
; [SCRATCH, SCRATCH+SCRATCH_LEN).  Cumulative counters live in the context.
njs_wc:
  ST r15,r14,0
  ADDI r14,r14,40
  ST r0,r12,#NJ_C_TOTAL
  ST r0,r12,#NJ_C_DONE
  ST r0,r12,#NJ_C_TMP0
  ST r0,r12,#NJ_C_TMP1
  ST r0,r12,#NJ_C_TMP2
  ST r0,r12,#NJ_C_TMP3
  ; Overlap witness: if PEER exists, is partial and has not finished,
  ; record that this consumer started while the producer was still active.
  LD r1,r12,#NJ_C_PEER
  CMP r1,r0
  JMP[EQ] @njs_wc_buf
  LD r2,r1,#NJ_C_DONE
  CMP r2,r0
  JMP[EQ] @njs_wc_buf
  LD r3,r1,#NJ_C_TOTAL
  CMP r2,r3
  JMP[GE] @njs_wc_buf
  MOVI r4,1
  ST r4,r12,#NJ_C_TMP3
njs_wc_buf:
  LD r1,r12,#NJ_C_SCRATCH
  CMP r1,r0
  JMP[EQ] @njs_wc_bad
  LD r1,r12,#NJ_C_SCRATCH_LEN
  CMP r1,r0
  JMP[EQ] @njs_wc_bad
njs_wc_read:
  ADD r1,r12,r0
  MOVI r2,0
  LD r3,r12,#NJ_C_SCRATCH
  LD r4,r12,#NJ_C_SCRATCH_LEN
  CALL @nj_fd_read
  CMP r1,r0
  JMP[LT] @njs_wc_bad
  CMP r1,r0
  JMP[EQ] @njs_wc_done
  ST r1,r14,1
  ST r0,r14,2
njs_wc_byte:
  LD r1,r14,2
  LD r2,r14,1
  CMP r1,r2
  JMP[GE] @njs_wc_read
  LD r3,r12,#NJ_C_SCRATCH
  ADD r3,r3,r1
  LDB r4,r3,0
  ; bytes++
  LD r5,r12,#NJ_C_TOTAL
  ADD r5,r5,r13
  ST r5,r12,#NJ_C_TOTAL
  ; lines on LF
  MOVI r5,10
  CMP r4,r5
  JMP[NE] @njs_wc_not_nl
  LD r5,r12,#NJ_C_TMP0
  ADD r5,r5,r13
  ST r5,r12,#NJ_C_TMP0
njs_wc_not_nl:
  ; whitespace: 32, 9, 13, 10
  MOVI r5,32
  CMP r4,r5
  JMP[EQ] @njs_wc_space
  MOVI r5,9
  CMP r4,r5
  JMP[EQ] @njs_wc_space
  MOVI r5,13
  CMP r4,r5
  JMP[EQ] @njs_wc_space
  MOVI r5,10
  CMP r4,r5
  JMP[EQ] @njs_wc_space
  ; non-space: count a word on the transition out of whitespace
  LD r5,r12,#NJ_C_TMP2
  CMP r5,r0
  JMP[NE] @njs_wc_next
  LD r5,r12,#NJ_C_TMP1
  ADD r5,r5,r13
  ST r5,r12,#NJ_C_TMP1
  MOVI r5,1
  ST r5,r12,#NJ_C_TMP2
  JMP @njs_wc_next
njs_wc_space:
  ST r0,r12,#NJ_C_TMP2
njs_wc_next:
  LD r5,r14,2
  ADD r5,r5,r13
  ST r5,r14,2
  JMP @njs_wc_byte
njs_wc_done:
  LD r1,r12,#NJ_C_TOTAL
  ST r1,r12,#NJ_C_DONE
  ; lines
  MOVI r1,1
  LD r2,r12,#NJ_C_TMP0
  CALL @njs_put_dec
  CMP r1,r0
  JMP[NE] @njs_wc_bad
  ADD r1,r12,r0
  MOVI r2,1
  MOVI r3,32
  CALL @nj_fd_putc
  CMP r1,r0
  JMP[LE] @njs_wc_bad
  ; words
  MOVI r1,1
  LD r2,r12,#NJ_C_TMP1
  CALL @njs_put_dec
  CMP r1,r0
  JMP[NE] @njs_wc_bad
  ADD r1,r12,r0
  MOVI r2,1
  MOVI r3,32
  CALL @nj_fd_putc
  CMP r1,r0
  JMP[LE] @njs_wc_bad
  ; bytes
  MOVI r1,1
  LD r2,r12,#NJ_C_TOTAL
  CALL @njs_put_dec
  CMP r1,r0
  JMP[NE] @njs_wc_bad
  ADD r1,r12,r0
  MOVI r2,1
  MOVI r3,10
  CALL @nj_fd_putc
  CMP r1,r0
  JMP[LE] @njs_wc_bad
  ; close the output ring so a capture reader can see EOF
  ADD r1,r12,r0
  MOVI r2,1
  CALL @nj_fd_close
  MOVI r1,0
  JMP @njs_wc_out
njs_wc_bad:
  MOVI r1,1
njs_wc_out:
  ADDI r14,r14,-40
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; njs_put_dec: write unsigned decimal r2 to fd r1 via nj_fd_putc.
; r12 = context.  Returns 0 or -1.  Digits are built on the stack.
njs_put_dec:
  ST r15,r14,0
  ADDI r14,r14,24
  ST r1,r14,1               ; fd
  ST r2,r14,2               ; remaining value
  ST r0,r14,3               ; digit count
  CMP r2,r0
  JMP[NE] @njs_pd_nonzero
  ADD r1,r12,r0
  LD r2,r14,1
  MOVI r3,48
  CALL @nj_fd_putc
  CMP r1,r0
  JMP[LE] @njs_pd_bad
  MOVI r1,0
  JMP @njs_pd_out
njs_pd_nonzero:
  MOVI r4,0
njs_pd_loop:
  LD r2,r14,2
  MOVI r5,10
  DIV r6,r2,r5
  MOD r7,r2,r5
  ADDI r7,r7,48
  ADDI r8,r14,8
  SHL r8,r8,2
  ADD r8,r8,r4
  STB r7,r8,0
  ADDI r4,r4,1
  ST r4,r14,3
  ST r6,r14,2
  CMP r6,r0
  JMP[NE] @njs_pd_loop
njs_pd_write:
  LD r4,r14,3
  CMP r4,r0
  JMP[EQ] @njs_pd_done
  ADDI r4,r4,-1
  ST r4,r14,3
  ADDI r8,r14,8
  SHL r8,r8,2
  ADD r8,r8,r4
  LDB r3,r8,0
  ADD r1,r12,r0
  LD r2,r14,1
  CALL @nj_fd_putc
  CMP r1,r0
  JMP[LE] @njs_pd_bad
  JMP @njs_pd_write
njs_pd_done:
  MOVI r1,0
  JMP @njs_pd_out
njs_pd_bad:
  LA r1,0xFFFFFFFF
njs_pd_out:
  ADDI r14,r14,-24
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; njs_sleep: SVC 24 with NJ_C_TICKS.  TMP1 is set on entry and TMP0 on wake;
; the test uses them to prove the parent returned while the job was asleep.
njs_sleep:
  ST r15,r14,0
  ADDI r14,r14,9
  MOVI r1,1
  ST r1,r12,#NJ_C_TMP1
  LD r1,r12,#NJ_C_TICKS
  SVC 24
  MOVI r1,1
  ST r1,r12,#NJ_C_TMP0
  MOVI r1,0
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
njs_true:
  MOVI r1,0
  RET

njs_false:
  MOVI r1,1
  RET
