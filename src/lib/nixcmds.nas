; nixcmds.nas - POSIX-ish line filters for NANIX (raw NaN16).
;
; Self-contained implementation of head, tail, grep, sort and uniq on top of
; the NANIX fd ABI in src/lib/nixfd.nas (spec/NIX_FD.md).  NANIX fd 0 is
; input, fd 1 is output, fd 2 is diagnostics.  The file only references
; nfd_open, nfd_read, nfd_write and nfd_close; a test image (or the shell)
; supplies those four symbols.
;
; Integration ABI (r0=0, r13=1, r14=software stack growing up, r15=link):
;
;   nxc_run r1=command  r2=arg1 byte ptr  r3=arg2 byte ptr  r4=flags
;     command: 0 head, 1 tail, 2 grep, 3 sort, 4 uniq
;     arg1:    input path for head/tail/sort/uniq (0 = fd 0)
;              fixed-search string for grep (required; grep reads fd 0)
;     arg2:    decimal line count for head/tail, or the two-token form
;              "-n N" / "-nN"; 0 or absent means 10.
;              Ignored by grep/sort/uniq.
;     flags:   bit0 -v (grep invert)
;              bit1 -n (grep line numbers)
;              bit2 -c (uniq run count)
;     -> r1 = 0 success, -1 runtime/input error, 1 usage
;
;   Per-command entry points use the same argument/return convention minus
;   the command word:
;     nxc_head r1=arg1 r2=arg2 r3=flags
;     nxc_tail r1=arg1 r2=arg2 r3=flags
;     nxc_grep r1=pattern r2=unused r3=flags
;     nxc_sort r1=arg1 r2=unused r3=flags
;     nxc_uniq r1=arg1 r2=unused r3=flags
;
; Semantics:
;   head   prints the first N lines (default 10), streaming.
;   tail   prints the last N lines (default 10), preserving bytes.
;   grep   fixed-string search (no BRE/ERE, no character classes).  -v
;          inverts the match, -n prefixes "LINENO:".  A matching final line
;          without a newline is emitted with one, like POSIX grep.
;   sort   C-locale bytewise lexicographic order, not stable.  A final line
;          without a newline is treated as newline-terminated on output.
;   uniq   collapses adjacent identical lines.  -c prints the run count,
;          decimal, followed by one space.
;
; Limits and failure:
;   tail/sort buffer the whole input in a 32768-byte buffer.  Input larger
;   than that fails before producing output: "nixcmds: input too large".
;   head/grep/uniq stream, but a single line longer than 32768 bytes fails
;   with "nixcmds: line too long".  Counts are capped at 65535.
;   All diagnostics go to fd 2; no partial line is emitted for size errors.
;
; Memory map (chosen above every buffer currently used by nixsh/nixfd):
;   NXC_BUF    byte 0x1300000, 32768 bytes  line / whole-input buffer
;   NXC_BUF2   byte 0x1380000, 32768 bytes  uniq previous-line buffer
;   NXC_IDXW   word 0x4E0000 (byte 0x1380000), 32768 words
;              line-start index (overlays NXC_BUF2; sort/tail only)
;   NXC_RBUF   byte 0x1280000, 4096 bytes   streaming read buffer
;   NXC_DECBUF byte 0x1281000, 16 bytes     decimal conversion
;   NXC_CH1    byte 0x1281010, 1 byte       nxc_put_ch
;   NXC_G      word 0x1000, 64 words        cross-call state (33 used)
;
; The shell uses byte 0x1000000..0x1011600, NX_VTAB/NX_VG around
; 0x1200000..0x1202xxx, NFD/NPAF below word 0x240000 and its stack at word
; 0x250000.  None of those ranges overlap the block above.  Word
; 0x3A0..0x3BB is reserved by nanobj/nantensor and is not used here.
;
; NaN16 caution: LD/ST immediate operands are 16 bits, so a direct
; "LD/ST rX,r0,#HIGH_EQU" silently truncates.  Every direct global access in
; this file therefore uses the low NXC_G block.  The high buffers are only
; reached with LA rB,#BUFFER plus a computed offset.

.equ NXC_BUF     0x1300000
.equ NXC_BUF2    0x1380000
.equ NXC_IDXW    0x4E0000
.equ NXC_RBUF    0x1280000
.equ NXC_DECBUF  0x1281000
.equ NXC_CH1     0x1281010
.equ NXC_CAP     0x8000

; Cross-call state lives in the low word block 0x1000..0x107F.  It is below
; the shell image (nixsh loads at word 0x80000) and above this gate image, and
; it avoids the 16-bit truncation of direct LD/ST immediates.
.equ NXC_G_CMD   0x1000
.equ NXC_G_ARG1  0x1001
.equ NXC_G_ARG2  0x1002
.equ NXC_G_FLAGS 0x1003
.equ NXC_G_INFD  0x1004
.equ NXC_G_OWN   0x1005
.equ NXC_G_COUNT 0x1006
.equ NXC_G_LINENO 0x1007
.equ NXC_G_LEN   0x1008
.equ NXC_G_N     0x1009
.equ NXC_G_I     0x100A
.equ NXC_G_J     0x100B
.equ NXC_G_GAP   0x100C
.equ NXC_G_TMP   0x100D
.equ NXC_G_RPOS  0x100E
.equ NXC_G_RLEN  0x100F
.equ NXC_G_RSTAT 0x1010
.equ NXC_G_PLEN  0x1011
.equ NXC_G_LLEN  0x1012
.equ NXC_G_VFLAG 0x1013
.equ NXC_G_NFLAG 0x1014
.equ NXC_G_CFLAG 0x1015
.equ NXC_G_HAVEP 0x1016
.equ NXC_G_RUN   0x1017
.equ NXC_G_PREVL 0x1018
.equ NXC_G_WFD   0x1019
.equ NXC_G_WPTR  0x101A
.equ NXC_G_WLEFT 0x101B
.equ NXC_G_DECVAL 0x101C
.equ NXC_G_START 0x101D
.equ NXC_G_ERRPTR 0x101E
.equ NXC_G_ERRK  0x101F
.equ NXC_G_MATCH 0x1020

; ---------------------------------------------------------------------------
; nxc_run - dispatch one line utility.
; r1=command (0 head, 1 tail, 2 grep, 3 sort, 4 uniq)
; r2=arg1 byte ptr, r3=arg2 byte ptr, r4=flags.  -> 0 / -1 / 1
nxc_run:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_CMD
  ST r2,r0,#NXC_G_ARG1
  ST r3,r0,#NXC_G_ARG2
  ST r4,r0,#NXC_G_FLAGS
  CMP r1,r0
  JMP[EQ] @nxc_run_head
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @nxc_run_tail
  MOVI r2,2
  CMP r1,r2
  JMP[EQ] @nxc_run_grep
  MOVI r2,3
  CMP r1,r2
  JMP[EQ] @nxc_run_sort
  MOVI r2,4
  CMP r1,r2
  JMP[EQ] @nxc_run_uniq
  CALL @nxc_usage
  JMP @nxc_run_done
nxc_run_head:
  LD r1,r0,#NXC_G_ARG1
  LD r2,r0,#NXC_G_ARG2
  LD r3,r0,#NXC_G_FLAGS
  CALL @nxc_head
  JMP @nxc_run_done
nxc_run_tail:
  LD r1,r0,#NXC_G_ARG1
  LD r2,r0,#NXC_G_ARG2
  LD r3,r0,#NXC_G_FLAGS
  CALL @nxc_tail
  JMP @nxc_run_done
nxc_run_grep:
  LD r1,r0,#NXC_G_ARG1
  LD r2,r0,#NXC_G_ARG2
  LD r3,r0,#NXC_G_FLAGS
  CALL @nxc_grep
  JMP @nxc_run_done
nxc_run_sort:
  LD r1,r0,#NXC_G_ARG1
  LD r2,r0,#NXC_G_ARG2
  LD r3,r0,#NXC_G_FLAGS
  CALL @nxc_sort
  JMP @nxc_run_done
nxc_run_uniq:
  LD r1,r0,#NXC_G_ARG1
  LD r2,r0,#NXC_G_ARG2
  LD r3,r0,#NXC_G_FLAGS
  CALL @nxc_uniq
nxc_run_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; head - first COUNT lines, streaming.
nxc_head:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_ARG1
  ST r2,r0,#NXC_G_ARG2
  ST r3,r0,#NXC_G_FLAGS
  LD r1,r0,#NXC_G_ARG2
  CALL @nxc_parse_count
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_head_usage
  ST r1,r0,#NXC_G_COUNT
  CALL @nxc_open_input
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_head_open
  ST r0,r0,#NXC_G_LINENO
nxc_head_loop:
  LD r1,r0,#NXC_G_LINENO
  LD r2,r0,#NXC_G_COUNT
  CMP r1,r2
  JMP[GE] @nxc_head_ok
  CALL @nxc_readline
  LD r2,r0,#NXC_G_RSTAT
  CMP r2,r0
  JMP[NE] @nxc_head_readerr
  CMP r1,r0
  JMP[EQ] @nxc_head_ok
  ST r1,r0,#NXC_G_LLEN
  LA r1,#NXC_BUF
  LD r2,r0,#NXC_G_LLEN
  CALL @nxc_emit
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_head_ioerr
  LD r1,r0,#NXC_G_LINENO
  ADD r1,r1,r13
  ST r1,r0,#NXC_G_LINENO
  JMP @nxc_head_loop
nxc_head_ok:
  CALL @nxc_close_input
  MOVI r1,0
  JMP @nxc_head_done
nxc_head_usage:
  CALL @nxc_usage
  JMP @nxc_head_done
nxc_head_open:
  LA r1,@nxc_s_open
  CALL @nxc_fail
  JMP @nxc_head_done
nxc_head_readerr:
  CALL @nxc_close_input
  CALL @nxc_reader_error
  JMP @nxc_head_done
nxc_head_ioerr:
  CALL @nxc_close_input
  LA r1,@nxc_s_io
  CALL @nxc_fail
nxc_head_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; tail - last COUNT lines.  Whole input is buffered (32 KiB bound).
nxc_tail:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_ARG1
  ST r2,r0,#NXC_G_ARG2
  ST r3,r0,#NXC_G_FLAGS
  LD r1,r0,#NXC_G_ARG2
  CALL @nxc_parse_count
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_tail_usage
  ST r1,r0,#NXC_G_COUNT
  CALL @nxc_open_input
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_tail_open
  CALL @nxc_read_all
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_tail_readerr
  CALL @nxc_prepare_lines
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_tail_readerr
  ST r1,r0,#NXC_G_N
  ; start = N - COUNT; COUNT >= N means start = 0.
  LD r1,r0,#NXC_G_COUNT
  LD r2,r0,#NXC_G_N
  CMP r1,r2
  JMP[LE] @nxc_tail_start
  MOVI r1,0
  JMP @nxc_tail_setstart
nxc_tail_start:
  SUB r1,r2,r1
nxc_tail_setstart:
  ST r1,r0,#NXC_G_START
  ST r1,r0,#NXC_G_I
nxc_tail_loop:
  LD r1,r0,#NXC_G_I
  LD r2,r0,#NXC_G_N
  CMP r1,r2
  JMP[GE] @nxc_tail_ok
  LA r2,#NXC_IDXW
  ADD r2,r2,r1
  LD r1,r2,0
  CALL @nxc_line_span
  CALL @nxc_emit
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_tail_ioerr
  LD r1,r0,#NXC_G_I
  ADD r1,r1,r13
  ST r1,r0,#NXC_G_I
  JMP @nxc_tail_loop
nxc_tail_ok:
  CALL @nxc_close_input
  MOVI r1,0
  JMP @nxc_tail_done
nxc_tail_usage:
  CALL @nxc_usage
  JMP @nxc_tail_done
nxc_tail_open:
  LA r1,@nxc_s_open
  CALL @nxc_fail
  JMP @nxc_tail_done
nxc_tail_readerr:
  CALL @nxc_close_input
  CALL @nxc_reader_error
  JMP @nxc_tail_done
nxc_tail_ioerr:
  CALL @nxc_close_input
  LA r1,@nxc_s_io
  CALL @nxc_fail
nxc_tail_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; grep - fixed-string line filter.  arg1 is the pattern; input is fd 0.
nxc_grep:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_ARG1
  ST r2,r0,#NXC_G_ARG2
  ST r3,r0,#NXC_G_FLAGS
  LD r1,r0,#NXC_G_ARG1
  CMP r1,r0
  JMP[EQ] @nxc_grep_usage
  CALL @nxc_strlen
  ST r1,r0,#NXC_G_PLEN
  CALL @nxc_decode_flags
  ST r0,r0,#NXC_G_INFD
  ST r0,r0,#NXC_G_OWN
  CALL @nxc_reset_reader
  MOVI r1,1
  ST r1,r0,#NXC_G_LINENO
nxc_grep_loop:
  CALL @nxc_readline
  LD r2,r0,#NXC_G_RSTAT
  CMP r2,r0
  JMP[NE] @nxc_grep_readerr
  CMP r1,r0
  JMP[EQ] @nxc_grep_ok
  ST r1,r0,#NXC_G_LLEN
  LA r1,#NXC_BUF
  LD r2,r0,#NXC_G_LLEN
  LD r3,r0,#NXC_G_ARG1
  LD r4,r0,#NXC_G_PLEN
  CALL @nxc_contains
  ST r1,r0,#NXC_G_MATCH
  LD r2,r0,#NXC_G_VFLAG
  CMP r2,r0
  JMP[EQ] @nxc_grep_normal
  LD r1,r0,#NXC_G_MATCH
  CMP r1,r0
  JMP[EQ] @nxc_grep_print
  JMP @nxc_grep_skip
nxc_grep_normal:
  LD r1,r0,#NXC_G_MATCH
  CMP r1,r0
  JMP[NE] @nxc_grep_print
nxc_grep_skip:
  LD r1,r0,#NXC_G_LINENO
  ADD r1,r1,r13
  ST r1,r0,#NXC_G_LINENO
  JMP @nxc_grep_loop
nxc_grep_print:
  LD r1,r0,#NXC_G_NFLAG
  CMP r1,r0
  JMP[EQ] @nxc_grep_body
  LD r1,r0,#NXC_G_LINENO
  CALL @nxc_put_dec
  MOVI r1,58
  CALL @nxc_put_ch
nxc_grep_body:
  LA r1,#NXC_BUF
  LD r2,r0,#NXC_G_LLEN
  CALL @nxc_emit
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_grep_ioerr
  ; grep supplies the newline of a non-terminated final line.
  LD r2,r0,#NXC_G_LLEN
  CMP r2,r0
  JMP[EQ] @nxc_grep_after
  LA r3,#NXC_BUF
  ADD r3,r3,r2
  SUB r3,r3,r13
  LDB r4,r3,0
  MOVI r5,10
  CMP r4,r5
  JMP[EQ] @nxc_grep_after
  MOVI r1,10
  CALL @nxc_put_ch
nxc_grep_after:
  LD r1,r0,#NXC_G_LINENO
  ADD r1,r1,r13
  ST r1,r0,#NXC_G_LINENO
  JMP @nxc_grep_loop
nxc_grep_ok:
  MOVI r1,0
  JMP @nxc_grep_done
nxc_grep_usage:
  CALL @nxc_usage
  JMP @nxc_grep_done
nxc_grep_readerr:
  CALL @nxc_reader_error
  JMP @nxc_grep_done
nxc_grep_ioerr:
  LA r1,@nxc_s_io
  CALL @nxc_fail
nxc_grep_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; sort - C-locale lexicographic line sort.  Whole input buffered (32 KiB).
nxc_sort:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_ARG1
  ST r2,r0,#NXC_G_ARG2
  ST r3,r0,#NXC_G_FLAGS
  CALL @nxc_open_input
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_sort_open
  CALL @nxc_read_all
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_sort_readerr
  CALL @nxc_prepare_lines
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_sort_readerr
  ST r1,r0,#NXC_G_N
  ; Shell sort: gap = n/2; gap halves to zero.
  SHR r1,r1,1
  ST r1,r0,#NXC_G_GAP
nxc_sort_gap:
  LD r1,r0,#NXC_G_GAP
  CMP r1,r0
  JMP[EQ] @nxc_sort_output
  ST r1,r0,#NXC_G_I
nxc_sort_i:
  LD r1,r0,#NXC_G_I
  LD r2,r0,#NXC_G_N
  CMP r1,r2
  JMP[GE] @nxc_sort_gapnext
  LA r2,#NXC_IDXW
  ADD r2,r2,r1
  LD r3,r2,0
  ST r3,r0,#NXC_G_TMP
  ST r1,r0,#NXC_G_J
nxc_sort_j:
  LD r1,r0,#NXC_G_J
  LD r2,r0,#NXC_G_GAP
  CMP r1,r2
  JMP[LT] @nxc_sort_place
  SUB r3,r1,r2
  LA r4,#NXC_IDXW
  ADD r4,r4,r3
  LD r1,r4,0
  LD r2,r0,#NXC_G_TMP
  CALL @nxc_compare
  ; Place when pa <= temp.  nxc_compare uses -1/0/1, and NaN16 CMP is
  ; unsigned, so test the -1 case explicitly before the non-negative cases.
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_sort_place
  CMP r1,r0
  JMP[LE] @nxc_sort_place
  LD r1,r0,#NXC_G_J
  LD r2,r0,#NXC_G_GAP
  SUB r3,r1,r2
  LA r4,#NXC_IDXW
  ADD r4,r4,r3
  LD r6,r4,0
  LA r5,#NXC_IDXW
  ADD r5,r5,r1
  ST r6,r5,0
  ST r3,r0,#NXC_G_J
  JMP @nxc_sort_j
nxc_sort_place:
  LD r1,r0,#NXC_G_J
  LA r2,#NXC_IDXW
  ADD r2,r2,r1
  LD r3,r0,#NXC_G_TMP
  ST r3,r2,0
  LD r1,r0,#NXC_G_I
  ADD r1,r1,r13
  ST r1,r0,#NXC_G_I
  JMP @nxc_sort_i
nxc_sort_gapnext:
  LD r1,r0,#NXC_G_GAP
  SHR r1,r1,1
  ST r1,r0,#NXC_G_GAP
  JMP @nxc_sort_gap
nxc_sort_output:
  ST r0,r0,#NXC_G_I
nxc_sort_outloop:
  LD r1,r0,#NXC_G_I
  LD r2,r0,#NXC_G_N
  CMP r1,r2
  JMP[GE] @nxc_sort_ok
  LA r2,#NXC_IDXW
  ADD r2,r2,r1
  LD r1,r2,0
  CALL @nxc_line_span
  CALL @nxc_emit
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_sort_ioerr
  LD r1,r0,#NXC_G_I
  ADD r1,r1,r13
  ST r1,r0,#NXC_G_I
  JMP @nxc_sort_outloop
nxc_sort_ok:
  CALL @nxc_close_input
  MOVI r1,0
  JMP @nxc_sort_done
nxc_sort_open:
  LA r1,@nxc_s_open
  CALL @nxc_fail
  JMP @nxc_sort_done
nxc_sort_readerr:
  CALL @nxc_close_input
  CALL @nxc_reader_error
  JMP @nxc_sort_done
nxc_sort_ioerr:
  CALL @nxc_close_input
  LA r1,@nxc_s_io
  CALL @nxc_fail
nxc_sort_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; uniq - collapse adjacent duplicate lines, streaming.
nxc_uniq:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_ARG1
  ST r2,r0,#NXC_G_ARG2
  ST r3,r0,#NXC_G_FLAGS
  CALL @nxc_decode_flags
  CALL @nxc_open_input
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_uniq_open
  ST r0,r0,#NXC_G_HAVEP
  ST r0,r0,#NXC_G_RUN
  ST r0,r0,#NXC_G_PREVL
nxc_uniq_loop:
  CALL @nxc_readline
  LD r2,r0,#NXC_G_RSTAT
  CMP r2,r0
  JMP[NE] @nxc_uniq_readerr
  CMP r1,r0
  JMP[EQ] @nxc_uniq_flush
  ST r1,r0,#NXC_G_LLEN
  LD r2,r0,#NXC_G_HAVEP
  CMP r2,r0
  JMP[EQ] @nxc_uniq_first
  LA r1,#NXC_BUF
  LD r2,r0,#NXC_G_LLEN
  LA r3,#NXC_BUF2
  LD r4,r0,#NXC_G_PREVL
  CALL @nxc_lineeq
  CMP r1,r0
  JMP[EQ] @nxc_uniq_new
  LD r1,r0,#NXC_G_RUN
  ADD r1,r1,r13
  ST r1,r0,#NXC_G_RUN
  JMP @nxc_uniq_loop
nxc_uniq_new:
  CALL @nxc_emit_prev
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_uniq_ioerr
  CALL @nxc_save_current
  MOVI r1,1
  ST r1,r0,#NXC_G_RUN
  JMP @nxc_uniq_loop
nxc_uniq_first:
  CALL @nxc_save_current
  MOVI r1,1
  ST r1,r0,#NXC_G_RUN
  ST r1,r0,#NXC_G_HAVEP
  JMP @nxc_uniq_loop
nxc_uniq_flush:
  LD r1,r0,#NXC_G_HAVEP
  CMP r1,r0
  JMP[EQ] @nxc_uniq_ok
  CALL @nxc_emit_prev
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_uniq_ioerr
nxc_uniq_ok:
  CALL @nxc_close_input
  MOVI r1,0
  JMP @nxc_uniq_done
nxc_uniq_open:
  LA r1,@nxc_s_open
  CALL @nxc_fail
  JMP @nxc_uniq_done
nxc_uniq_readerr:
  CALL @nxc_close_input
  CALL @nxc_reader_error
  JMP @nxc_uniq_done
nxc_uniq_ioerr:
  CALL @nxc_close_input
  LA r1,@nxc_s_io
  CALL @nxc_fail
nxc_uniq_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_emit_prev - print the buffered previous uniq line (plus count).
nxc_emit_prev:
  ST r15,r14,0
  ADDI r14,r14,9
  LD r1,r0,#NXC_G_CFLAG
  CMP r1,r0
  JMP[EQ] @nxc_ep_nocount
  LD r1,r0,#NXC_G_RUN
  CALL @nxc_put_dec
  MOVI r1,32
  CALL @nxc_put_ch
nxc_ep_nocount:
  LA r1,#NXC_BUF2
  LD r2,r0,#NXC_G_PREVL
  CALL @nxc_emit
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_save_current - copy NXC_BUF/LLEN to the uniq previous-line buffer.
nxc_save_current:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,#NXC_BUF
  LA r2,#NXC_BUF2
  LD r3,r0,#NXC_G_LLEN
  CALL @nxc_copy_bytes
  LD r1,r0,#NXC_G_LLEN
  ST r1,r0,#NXC_G_PREVL
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nxc_open_input - open NXC_G_ARG1 or select fd 0.
nxc_open_input:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r0,r0,#NXC_G_OWN
  ST r0,r0,#NXC_G_RPOS
  ST r0,r0,#NXC_G_RLEN
  ST r0,r0,#NXC_G_RSTAT
  ST r0,r0,#NXC_G_ERRK
  LD r1,r0,#NXC_G_ARG1
  CMP r1,r0
  JMP[EQ] @nxc_oi_stdin
  MOVI r2,0
  CALL @nfd_open
  LA r2,0xFFFFFFFF
  CMP r1,r2
  JMP[EQ] @nxc_oi_fail
  ST r1,r0,#NXC_G_INFD
  MOVI r2,1
  ST r2,r0,#NXC_G_OWN
  MOVI r1,0
  JMP @nxc_oi_done
nxc_oi_stdin:
  ST r0,r0,#NXC_G_INFD
  MOVI r1,0
  JMP @nxc_oi_done
nxc_oi_fail:
  LA r1,0xFFFFFFFF
nxc_oi_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_close_input - close the input if this command opened it.
nxc_close_input:
  ST r15,r14,0
  ADDI r14,r14,9
  LD r1,r0,#NXC_G_OWN
  CMP r1,r0
  JMP[EQ] @nxc_ci_done
  LD r1,r0,#NXC_G_INFD
  CALL @nfd_close
  ST r0,r0,#NXC_G_OWN
nxc_ci_done:
  MOVI r1,0
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_reset_reader - empty the streaming read buffer.
nxc_reset_reader:
  ST r0,r0,#NXC_G_RPOS
  ST r0,r0,#NXC_G_RLEN
  ST r0,r0,#NXC_G_RSTAT
  ST r0,r0,#NXC_G_ERRK
  RET

; nxc_getc - one byte from NXC_G_INFD.
; -> r1 = 0..255 byte, -1 EOF, -2 read error.
nxc_getc:
  ST r15,r14,0
  ADDI r14,r14,9
nxc_gc_again:
  LD r1,r0,#NXC_G_RPOS
  LD r2,r0,#NXC_G_RLEN
  CMP r1,r2
  JMP[LT] @nxc_gc_have
  LD r1,r0,#NXC_G_INFD
  LA r2,#NXC_RBUF
  MOVI r3,4096
  CALL @nfd_read
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nxc_gc_err
  CMP r1,r0
  JMP[EQ] @nxc_gc_eof
  ST r1,r0,#NXC_G_RLEN
  ST r0,r0,#NXC_G_RPOS
  JMP @nxc_gc_again
nxc_gc_have:
  LD r1,r0,#NXC_G_RPOS
  LA r2,#NXC_RBUF
  ADD r2,r2,r1
  LDB r3,r2,0
  ADD r1,r1,r13
  ST r1,r0,#NXC_G_RPOS
  ADD r1,r3,r0
  JMP @nxc_gc_done
nxc_gc_eof:
  LA r1,0xFFFFFFFF
  JMP @nxc_gc_done
nxc_gc_err:
  LA r1,0xFFFFFFFE
nxc_gc_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_readline - one line into NXC_BUF, including a trailing newline if any.
; -> r1 = length (0 at EOF), NXC_G_RSTAT = 0 or -1, NXC_G_ERRK set.
nxc_readline:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r0,r0,#NXC_G_RSTAT
  ST r0,r0,#NXC_G_ERRK
  ST r0,r0,#NXC_G_LLEN
nxc_rl_loop:
  CALL @nxc_getc
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nxc_rl_eof
  LA r4,0xFFFFFFFE
  CMP r1,r4
  JMP[EQ] @nxc_rl_err
  LD r2,r0,#NXC_G_LLEN
  MOVI r4,0x8000
  CMP r2,r4
  JMP[GE] @nxc_rl_long
  LA r3,#NXC_BUF
  ADD r3,r3,r2
  STB r1,r3,0
  ADD r2,r2,r13
  ST r2,r0,#NXC_G_LLEN
  MOVI r4,10
  CMP r1,r4
  JMP[NE] @nxc_rl_loop
  LD r1,r0,#NXC_G_LLEN
  JMP @nxc_rl_done
nxc_rl_eof:
  LD r1,r0,#NXC_G_LLEN
  JMP @nxc_rl_done
nxc_rl_err:
  MOVI r2,2
  ST r2,r0,#NXC_G_ERRK
  LA r1,0xFFFFFFFF
  ST r1,r0,#NXC_G_RSTAT
  MOVI r1,0
  JMP @nxc_rl_done
nxc_rl_long:
  MOVI r2,3
  ST r2,r0,#NXC_G_ERRK
  LA r1,0xFFFFFFFF
  ST r1,r0,#NXC_G_RSTAT
  MOVI r1,0
nxc_rl_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_read_all - read the whole input into NXC_BUF (max 32768 bytes).
; -> r1 = length or -1.  NXC_G_ERRK = 1 too large, 2 I/O error.
nxc_read_all:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r0,r0,#NXC_G_LEN
  ST r0,r0,#NXC_G_ERRK
nxc_ra_loop:
  LD r2,r0,#NXC_G_LEN
  MOVI r3,0x8000
  CMP r2,r3
  JMP[GE] @nxc_ra_full
  SUB r3,r3,r2
  LA r4,#NXC_BUF
  ADD r4,r4,r2
  LD r1,r0,#NXC_G_INFD
  ADD r2,r4,r0
  CALL @nfd_read
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nxc_ra_err
  CMP r1,r0
  JMP[EQ] @nxc_ra_done
  LD r2,r0,#NXC_G_LEN
  ADD r2,r2,r1
  ST r2,r0,#NXC_G_LEN
  JMP @nxc_ra_loop
nxc_ra_full:
  ; Exactly 32768 bytes are buffered.  One more byte means too large.
  LD r1,r0,#NXC_G_INFD
  LA r2,#NXC_CH1
  MOVI r3,1
  CALL @nfd_read
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nxc_ra_err
  CMP r1,r0
  JMP[EQ] @nxc_ra_done
  MOVI r1,1
  ST r1,r0,#NXC_G_ERRK
  LA r1,0xFFFFFFFF
  JMP @nxc_ra_done2
nxc_ra_err:
  MOVI r1,2
  ST r1,r0,#NXC_G_ERRK
  LA r1,0xFFFFFFFF
  JMP @nxc_ra_done2
nxc_ra_done:
  LD r1,r0,#NXC_G_LEN
nxc_ra_done2:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_prepare_lines - ensure a final newline and index line starts.
; r1 = buffered length.  -> r1 = line count or -1.
; Sets NXC_G_LEN to the (possibly grown) length.  NXC_G_ERRK=1 if append
; would exceed NXC_CAP.
nxc_prepare_lines:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_LEN
  ST r0,r0,#NXC_G_ERRK
  CMP r1,r0
  JMP[EQ] @nxc_pl_empty
  MOVI r2,0x8000
  CMP r1,r2
  JMP[GT] @nxc_pl_err
  LA r2,#NXC_BUF
  ADD r2,r2,r1
  SUB r2,r2,r13
  LDB r3,r2,0
  MOVI r4,10
  CMP r3,r4
  JMP[EQ] @nxc_pl_index
  MOVI r4,0x8000
  CMP r1,r4
  JMP[GE] @nxc_pl_err
  LA r2,#NXC_BUF
  ADD r2,r2,r1
  MOVI r3,10
  STB r3,r2,0
  ADD r1,r1,r13
  ST r1,r0,#NXC_G_LEN
nxc_pl_index:
  LA r2,#NXC_BUF
  MOVI r5,0
  ADD r6,r2,r0
  LD r3,r0,#NXC_G_LEN
  ADD r4,r2,r3
nxc_pl_outer:
  LA r7,#NXC_IDXW
  ADD r7,r7,r5
  ST r6,r7,0
  ADD r5,r5,r13
nxc_pl_scan:
  LDB r8,r6,0
  MOVI r9,10
  CMP r8,r9
  JMP[EQ] @nxc_pl_end
  ADD r6,r6,r13
  JMP @nxc_pl_scan
nxc_pl_end:
  ADD r6,r6,r13
  CMP r6,r4
  JMP[LT] @nxc_pl_outer
  ADD r1,r5,r0
  JMP @nxc_pl_done
nxc_pl_empty:
  MOVI r1,0
  JMP @nxc_pl_done
nxc_pl_err:
  MOVI r2,1
  ST r2,r0,#NXC_G_ERRK
  LA r1,0xFFFFFFFF
nxc_pl_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
; nxc_line_span - length of the newline-terminated line at r1.
; r1=line start -> r2=byte length through the newline (or to NXC_G_LEN).
; r1 is preserved.  Used by tail/sort after index reordering, where the next
; index entry is not necessarily the byte end of the current line.
nxc_line_span:
  ADD r3,r1,r0
  LA r4,#NXC_BUF
  LD r5,r0,#NXC_G_LEN
  ADD r4,r4,r5
nxc_ls_loop:
  CMP r3,r4
  JMP[GE] @nxc_ls_done
  LDB r5,r3,0
  MOVI r6,10
  CMP r5,r6
  JMP[EQ] @nxc_ls_nl
  ADD r3,r3,r13
  JMP @nxc_ls_loop
nxc_ls_nl:
  ADD r3,r3,r13
nxc_ls_done:
  SUB r2,r3,r1
  RET

; ---------------------------------------------------------------------------
; nxc_compare - line pointer comparison, newline terminated.
; r1=ptrA r2=ptrB -> r1 = -1 (A<B), 0 (equal), 1 (A>B).
nxc_compare:
  ST r15,r14,0
  ADDI r14,r14,9
nxc_cmp_loop:
  LDB r3,r1,0
  LDB r4,r2,0
  MOVI r5,10
  CMP r3,r5
  JMP[NE] @nxc_cmp_a_live
  CMP r4,r5
  JMP[EQ] @nxc_cmp_eq
  LA r1,0xFFFFFFFF
  JMP @nxc_cmp_done
nxc_cmp_a_live:
  CMP r4,r5
  JMP[EQ] @nxc_cmp_gt
  CMP r3,r4
  JMP[LT] @nxc_cmp_lt
  JMP[GT] @nxc_cmp_gt
  ADD r1,r1,r13
  ADD r2,r2,r13
  JMP @nxc_cmp_loop
nxc_cmp_eq:
  MOVI r1,0
  JMP @nxc_cmp_done
nxc_cmp_lt:
  LA r1,0xFFFFFFFF
  JMP @nxc_cmp_done
nxc_cmp_gt:
  MOVI r1,1
nxc_cmp_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_lineeq - exact byte equality for two length-counted lines.
; r1=ptrA r2=lenA r3=ptrB r4=lenB -> r1=1 equal / 0 not equal.
nxc_lineeq:
  ST r15,r14,0
  ADDI r14,r14,9
  CMP r2,r4
  JMP[NE] @nxc_le_no
  MOVI r5,0
nxc_le_loop:
  CMP r5,r2
  JMP[GE] @nxc_le_yes
  ADD r6,r1,r5
  LDB r7,r6,0
  ADD r6,r3,r5
  LDB r8,r6,0
  CMP r7,r8
  JMP[NE] @nxc_le_no
  ADD r5,r5,r13
  JMP @nxc_le_loop
nxc_le_yes:
  MOVI r1,1
  JMP @nxc_le_done
nxc_le_no:
  MOVI r1,0
nxc_le_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_contains - fixed-string containment.
; r1=line ptr r2=line len r3=pattern ptr r4=pattern len -> r1=1/0.
nxc_contains:
  CMP r4,r0
  JMP[EQ] @nxc_ct_yes
  MOVI r5,0
nxc_ct_outer:
  SUB r6,r2,r5
  CMP r6,r4
  JMP[LT] @nxc_ct_no
  MOVI r6,0
nxc_ct_inner:
  CMP r6,r4
  JMP[GE] @nxc_ct_yes
  ADD r7,r1,r5
  ADD r7,r7,r6
  LDB r8,r7,0
  ADD r9,r3,r6
  LDB r10,r9,0
  CMP r8,r10
  JMP[NE] @nxc_ct_next
  ADD r6,r6,r13
  JMP @nxc_ct_inner
nxc_ct_next:
  ADD r5,r5,r13
  JMP @nxc_ct_outer
nxc_ct_yes:
  MOVI r1,1
  RET
nxc_ct_no:
  MOVI r1,0
  RET

; nxc_copy_bytes - non-overlapping forward copy.
; r1=src r2=dst r3=len.
nxc_copy_bytes:
  MOVI r4,0
nxc_cb_loop:
  CMP r4,r3
  JMP[GE] @nxc_cb_done
  LDB r5,r1,0
  STB r5,r2,0
  ADD r1,r1,r13
  ADD r2,r2,r13
  ADD r4,r4,r13
  JMP @nxc_cb_loop
nxc_cb_done:
  RET

; ---------------------------------------------------------------------------
; nxc_parse_count - parse a decimal count, optionally "-n N" / "-nN".
; r1=byte ptr or 0 -> r1=count, or -1 for a malformed/absent value.
nxc_parse_count:
  CMP r1,r0
  JMP[EQ] @nxc_pc_default
  MOVI r2,0
  MOVI r6,0
nxc_pc_skip1:
  LDB r3,r1,0
  MOVI r4,32
  CMP r3,r4
  JMP[EQ] @nxc_pc_sk1
  MOVI r4,9
  CMP r3,r4
  JMP[NE] @nxc_pc_opt
nxc_pc_sk1:
  ADD r1,r1,r13
  JMP @nxc_pc_skip1
nxc_pc_opt:
  MOVI r4,45
  CMP r3,r4
  JMP[NE] @nxc_pc_digits
  ADD r1,r1,r13
  LDB r3,r1,0
  MOVI r4,110
  CMP r3,r4
  JMP[NE] @nxc_pc_bad
  ADD r1,r1,r13
nxc_pc_skip2:
  LDB r3,r1,0
  MOVI r4,32
  CMP r3,r4
  JMP[EQ] @nxc_pc_sk2
  MOVI r4,9
  CMP r3,r4
  JMP[NE] @nxc_pc_digits
nxc_pc_sk2:
  ADD r1,r1,r13
  JMP @nxc_pc_skip2
nxc_pc_digits:
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nxc_pc_finish
  MOVI r4,32
  CMP r3,r4
  JMP[EQ] @nxc_pc_ws
  MOVI r4,9
  CMP r3,r4
  JMP[EQ] @nxc_pc_ws
  MOVI r4,48
  CMP r3,r4
  JMP[LT] @nxc_pc_bad
  MOVI r4,57
  CMP r3,r4
  JMP[GT] @nxc_pc_bad
  MOVI r4,10
  MUL r2,r2,r4
  MOVI r4,48
  SUB r3,r3,r4
  ADD r2,r2,r3
  MOVI r4,0xFFFF
  CMP r2,r4
  JMP[LE] @nxc_pc_digok
  ADD r2,r4,r0
nxc_pc_digok:
  ADD r6,r6,r13
  ADD r1,r1,r13
  JMP @nxc_pc_digits
nxc_pc_ws:
  ADD r1,r1,r13
  JMP @nxc_pc_digits
nxc_pc_finish:
  CMP r6,r0
  JMP[EQ] @nxc_pc_bad
  ADD r1,r2,r0
  RET
nxc_pc_default:
  MOVI r1,10
  RET
nxc_pc_bad:
  LA r1,0xFFFFFFFF
  RET

; nxc_decode_flags - split NXC_G_FLAGS into V/N/C booleans.
nxc_decode_flags:
  LD r1,r0,#NXC_G_FLAGS
  SHL r2,r1,31
  SHR r2,r2,31
  ST r2,r0,#NXC_G_VFLAG
  SHL r2,r1,30
  SHR r2,r2,31
  ST r2,r0,#NXC_G_NFLAG
  SHL r2,r1,29
  SHR r2,r2,31
  ST r2,r0,#NXC_G_CFLAG
  RET

; ---------------------------------------------------------------------------
; Output helpers.
; nxc_write_fd r1=fd r2=ptr r3=len -> 0/-1, retrying short writes.
nxc_write_fd:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_WFD
  ST r2,r0,#NXC_G_WPTR
  ST r3,r0,#NXC_G_WLEFT
nxc_wf_loop:
  LD r3,r0,#NXC_G_WLEFT
  CMP r3,r0
  JMP[EQ] @nxc_wf_ok
  LD r1,r0,#NXC_G_WFD
  LD r2,r0,#NXC_G_WPTR
  CALL @nfd_write
  LA r4,0xFFFFFFFF
  CMP r1,r4
  JMP[EQ] @nxc_wf_err
  CMP r1,r0
  JMP[EQ] @nxc_wf_err
  LD r2,r0,#NXC_G_WPTR
  ADD r2,r2,r1
  ST r2,r0,#NXC_G_WPTR
  LD r3,r0,#NXC_G_WLEFT
  SUB r3,r3,r1
  ST r3,r0,#NXC_G_WLEFT
  JMP @nxc_wf_loop
nxc_wf_ok:
  MOVI r1,0
  JMP @nxc_wf_done
nxc_wf_err:
  LA r1,0xFFFFFFFF
nxc_wf_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_emit r1=ptr r2=len -> 0/-1 on fd 1.
nxc_emit:
  ST r15,r14,0
  ADDI r14,r14,9
  ADD r3,r2,r0
  ADD r2,r1,r0
  MOVI r1,1
  CALL @nxc_write_fd
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_put_ch r1=char -> 0/-1 on fd 1.
nxc_put_ch:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r2,#NXC_CH1
  STB r1,r2,0
  MOVI r3,1
  MOVI r1,1
  CALL @nxc_write_fd
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_put_dec r1=unsigned value -> 0/-1 on fd 1, no newline.
nxc_put_dec:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_DECVAL
  CMP r1,r0
  JMP[NE] @nxc_pd_nonzero
  MOVI r1,48
  CALL @nxc_put_ch
  JMP @nxc_pd_done
nxc_pd_nonzero:
  LA r5,#NXC_DECBUF
  MOVI r6,16
  ADD r5,r5,r6
  LD r1,r0,#NXC_G_DECVAL
nxc_pd_loop:
  MOVI r4,10
  DIVU r3,r1,r4
  MUL r7,r3,r4
  SUB r8,r1,r7
  MOVI r9,48
  ADD r8,r8,r9
  SUB r5,r5,r13
  STB r8,r5,0
  ADD r1,r3,r0
  CMP r1,r0
  JMP[NE] @nxc_pd_loop
  LA r2,#NXC_DECBUF
  MOVI r3,16
  ADD r2,r2,r3
  SUB r2,r2,r5
  ADD r1,r5,r0
  CALL @nxc_emit
nxc_pd_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_strlen r1=byte ptr -> r1=length.
nxc_strlen:
  MOVI r2,0
nxc_sl_loop:
  LDB r3,r1,0
  CMP r3,r0
  JMP[EQ] @nxc_sl_done
  ADD r1,r1,r13
  ADD r2,r2,r13
  JMP @nxc_sl_loop
nxc_sl_done:
  ADD r1,r2,r0
  RET

; nxc_diagz r1=zero-terminated byte ptr -> write it to fd 2.
nxc_diagz:
  ST r15,r14,0
  ADDI r14,r14,9
  ST r1,r0,#NXC_G_ERRPTR
  CALL @nxc_strlen
  ADD r3,r1,r0
  LD r2,r0,#NXC_G_ERRPTR
  MOVI r1,2
  CALL @nxc_write_fd
  MOVI r1,0
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_fail r1=word string label -> diagnostic on fd 2, returns -1.
nxc_fail:
  ST r15,r14,0
  ADDI r14,r14,9
  SHL r1,r1,2
  CALL @nxc_diagz
  LA r1,0xFFFFFFFF
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_usage -> usage diagnostic, returns 1.
nxc_usage:
  ST r15,r14,0
  ADDI r14,r14,9
  LA r1,@nxc_s_usage
  CALL @nxc_fail
  MOVI r1,1
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; nxc_reader_error -> report the error recorded by readline/read_all, return -1.
nxc_reader_error:
  ST r15,r14,0
  ADDI r14,r14,9
  LD r1,r0,#NXC_G_ERRK
  MOVI r2,1
  CMP r1,r2
  JMP[EQ] @nxc_re_large
  MOVI r2,3
  CMP r1,r2
  JMP[EQ] @nxc_re_long
  LA r1,@nxc_s_io
  CALL @nxc_fail
  JMP @nxc_re_done
nxc_re_large:
  LA r1,@nxc_s_large
  CALL @nxc_fail
  JMP @nxc_re_done
nxc_re_long:
  LA r1,@nxc_s_long
  CALL @nxc_fail
nxc_re_done:
  ADDI r14,r14,-9
  LD r15,r14,0
  RET

; ---------------------------------------------------------------------------
nxc_s_usage:
.str "nixcmds: usage\n"
nxc_s_open:
.str "nixcmds: cannot open\n"
nxc_s_io:
.str "nixcmds: I/O error\n"
nxc_s_large:
.str "nixcmds: input too large (32768-byte limit)\n"
nxc_s_long:
.str "nixcmds: line too long (32768-byte limit)\n"
