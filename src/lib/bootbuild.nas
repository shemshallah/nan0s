; bootbuild.nas - NaN16 full-image disk replication builder (no host command).
; The running guest itself streams 2880 x 512-byte sectors of the COMPLETE
; bootable 1.44 MiB system from ATA primary master to a separate secondary
; primary-channel IDE slave, reads the slave back, and checks every word.
; This is image-level self-replication (stage R2), not yet source recompilation
; of the native boot sector/kernel. A separate source-level S0-S5 builder is
; required before claiming a source-derived fixed point.
;
; ATA primary master 0xE0: current boot image (READ ONLY)
; ATA primary slave  0xF0: fresh independent output disk (WRITE/VERIFY)
; Never target the running primary master. Never use the floppy as output.
; The 512-byte sector buffers are outside GUI, NFS and ncc memory ranges.
.equ SB_SECTORS 2880
.equ SB_BUF 450000
.equ SB_CHECK 450128

; State is static guest words and survives nested NaN calls safely.
sb_lba:
.word 0
sb_bufp:
.word 0
sb_drive:
.word 0
sb_mode:
.word 0
sb_ok:
.word 0
sb_sector:
.word 0
sb_pos:
.word 0
sb_ret:
.word 0

sb_build:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,@tk_id
MOVI r2,@sb_start_msg
CALL @vc_puts
CALL @sb_redraw
; Require an actual second IDE device before writing a single sector.
MOVI r1,0x1F6
MOVI r2,0xB0
OUTB r2,r1
CALL @ata_delay
MOVI r1,0x1F7
INB r2,r1
MOVI r3,255
CMP r2,r3
JMP[EQ] @sb_missing
CMP r2,r0
JMP[EQ] @sb_missing
; Validate source boot signature before touching target.
MOVI r1,0
MOVI r2,#SB_BUF
MOVI r3,0xE0
MOVI r4,0
CALL @sb_io
CMP r1,r0
JMP[EQ] @sb_fail
MOVI r2,#SB_BUF+127
LD r2,r2,0
SHR r2,r2,16
MOVI r3,0xAA55
CMP r2,r3
JMP[NE] @sb_sigfail
; Source sector 0 validated. The copy is then checked sector-by-sector.
ST r0,r0,@sb_pos
sb_copy_loop:
LD r1,r0,@sb_pos
MOVI r2,#SB_SECTORS
CMP r1,r2
JMP[GE] @sb_success
MOVI r2,#SB_BUF
MOVI r3,0xE0
MOVI r4,0
CALL @sb_io
CMP r1,r0
JMP[EQ] @sb_fail
LD r1,r0,@sb_pos
MOVI r2,#SB_BUF
MOVI r3,0xF0
MOVI r4,1
CALL @sb_io
CMP r1,r0
JMP[EQ] @sb_fail
LD r1,r0,@sb_pos
MOVI r2,#SB_CHECK
MOVI r3,0xF0
MOVI r4,0
CALL @sb_io
CMP r1,r0
JMP[EQ] @sb_fail
MOVI r5,0
sb_cmp:
MOVI r6,128
CMP r5,r6
JMP[GE] @sb_cmp_ok
MOVI r6,#SB_BUF
ADD r6,r6,r5
LD r7,r6,0
MOVI r6,#SB_CHECK
ADD r6,r6,r5
LD r8,r6,0
CMP r7,r8
JMP[NE] @sb_mismatch
ADD r5,r5,r13
JMP @sb_cmp
sb_cmp_ok:
LD r1,r0,@sb_pos
ADD r1,r1,r13
ST r1,r0,@sb_pos
; Progress every 256 verified sectors (128 KiB), flushing the terminal UI.
MOVI r2,255
BOOL.8 r2,r1,r2
CMP r2,r0
JMP[NE] @sb_copy_loop
LD r1,r0,@tk_id
MOVI r2,@sb_dot
CALL @vc_puts
CALL @sb_redraw
JMP @sb_copy_loop
sb_success:
LD r1,r0,@tk_id
MOVI r2,@sb_ok_msg
CALL @vc_puts
CALL @sb_redraw
; The browser recognizes this guest-owned serial event to enable downloading
; the secondary image. It is emitted ONLY after 2880 read-back comparisons.
MOVI r1,@sb_serial_ok
CALL @sb_serial
MOVI r1,1
JMP @sb_done
sb_missing:
LD r1,r0,@tk_id
MOVI r2,@sb_missing_msg
CALL @vc_puts
JMP @sb_error
sb_sigfail:
LD r1,r0,@tk_id
MOVI r2,@sb_sig_msg
CALL @vc_puts
JMP @sb_error
sb_mismatch:
LD r1,r0,@tk_id
MOVI r2,@sb_mismatch_msg
CALL @vc_puts
JMP @sb_error
sb_fail:
LD r1,r0,@tk_id
MOVI r2,@sb_fail_msg
CALL @vc_puts
sb_error:
CALL @sb_redraw
MOVI r1,@sb_serial_fail
CALL @sb_serial
MOVI r1,0
sb_done:
SUB r14,r14,r13
LD r15,r14,0
RET

sb_redraw:
ST r15,r14,0
ADD r14,r14,r13
LD r1,r0,@tk_id
CALL @term_draw
SUB r14,r14,r13
LD r15,r14,0
RET

; sb_serial: r1=packed .str word pointer, PUTC each ASCII byte until NUL.
sb_serial:
ST r15,r14,0
ADD r14,r14,r13
SHL r1,r1,2
ST r1,r0,@sb_sector
sb_ser_l:
LD r1,r0,@sb_sector
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @sb_ser_end
PUTC r2
LD r1,r0,@sb_sector
ADD r1,r1,r13
ST r1,r0,@sb_sector
JMP @sb_ser_l
sb_ser_end:
SUB r14,r14,r13
LD r15,r14,0
RET

; sb_io r1=LBA r2=word buffer r3=0xE0 master/0xF0 slave
; r4=0 read / 1 write; returns r1=1 success, 0 fail.
; Handles errors and timeouts; this path does not rely on unbounded ata_wait.
sb_io:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,@sb_lba
ST r2,r0,@sb_bufp
ST r3,r0,@sb_drive
ST r4,r0,@sb_mode
; Never allow writes to the source master or an unknown drive.
CMP r4,r0
JMP[EQ] @sb_io_select
MOVI r5,0xF0
CMP r3,r5
JMP[NE] @sb_io_bad
sb_io_select:
MOVI r1,0x1F6
LD r2,r0,@sb_drive
LD r3,r0,@sb_lba
SHR r3,r3,24
MOVI r4,15
BOOL.8 r3,r3,r4
BOOL.14 r2,r2,r3
OUTB r2,r1
CALL @ata_delay
MOVI r1,0x1F2
MOVI r2,1
OUTB r2,r1
MOVI r1,0x1F3
LD r3,r0,@sb_lba
MOVI r4,255
BOOL.8 r2,r3,r4
OUTB r2,r1
MOVI r1,0x1F4
SHR r3,r3,8
BOOL.8 r2,r3,r4
OUTB r2,r1
MOVI r1,0x1F5
SHR r3,r3,8
BOOL.8 r2,r3,r4
OUTB r2,r1
MOVI r1,0x1F7
LD r2,r0,@sb_mode
CMP r2,r0
JMP[EQ] @sb_io_readcmd
MOVI r2,0x30
JMP @sb_io_cmd
sb_io_readcmd:
MOVI r2,0x20
sb_io_cmd:
OUTB r2,r1
CALL @sb_wait_drq
CMP r1,r0
JMP[EQ] @sb_io_bad
LD r10,r0,@sb_bufp
MOVI r11,128
MOVI r12,0x1F0
sb_io_words:
LD r1,r0,@sb_mode
CMP r1,r0
JMP[EQ] @sb_io_read
LD r3,r10,0
MOVI r4,0xFFFF
BOOL.8 r2,r3,r4
OUTW r2,r12
SHR r3,r3,16
BOOL.8 r2,r3,r4
OUTW r2,r12
JMP @sb_io_next
sb_io_read:
INW r2,r12
INW r3,r12
SHL r3,r3,16
BOOL.14 r2,r2,r3
ST r2,r10,0
sb_io_next:
ADD r10,r10,r13
SUB r11,r11,r13
JMP[NE] @sb_io_words
LD r1,r0,@sb_mode
CMP r1,r0
JMP[EQ] @sb_io_ok
; Flush to stable emulated media before reading back.
MOVI r1,0x1F7
MOVI r2,0xE7
OUTB r2,r1
CALL @sb_wait_ready
CMP r1,r0
JMP[EQ] @sb_io_bad
sb_io_ok:
MOVI r1,1
JMP @sb_io_done
sb_io_bad:
MOVI r1,0
sb_io_done:
SUB r14,r14,r13
LD r15,r14,0
RET

; Bound a busy wait to 2 seconds; detect error/drive fault/absent bus.
; sb_wait_drq returns 1 only after BSY=0, DRQ=1, ERR/DF=0.
sb_wait_drq:
ST r15,r14,0
ADD r14,r14,r13
TICK r6
sb_drq_loop:
MOVI r1,0x1F7
INB r2,r1
MOVI r3,0xFF
CMP r2,r3
JMP[EQ] @sb_wait_bad
MOVI r3,0x21
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[NE] @sb_wait_bad
MOVI r3,0x88
BOOL.8 r4,r2,r3
MOVI r5,0x08
CMP r4,r5
JMP[EQ] @sb_wait_ok
TICK r7
SUB r7,r7,r6
MOVI r8,2000
CMP r7,r8
JMP[LT] @sb_drq_loop
JMP @sb_wait_bad

sb_wait_ready:
ST r15,r14,0
ADD r14,r14,r13
TICK r6
sb_ready_loop:
MOVI r1,0x1F7
INB r2,r1
MOVI r3,0xFF
CMP r2,r3
JMP[EQ] @sb_wait_bad
MOVI r3,0x21
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[NE] @sb_wait_bad
MOVI r3,0x80
BOOL.8 r4,r2,r3
CMP r4,r0
JMP[EQ] @sb_wait_ok
TICK r7
SUB r7,r7,r6
MOVI r8,2000
CMP r7,r8
JMP[LT] @sb_ready_loop
sb_wait_bad:
MOVI r1,0
JMP @sb_wait_done
sb_wait_ok:
MOVI r1,1
sb_wait_done:
SUB r14,r14,r13
LD r15,r14,0
RET

sb_start_msg:
.str "build nan0s: complete 1.44MB boot disk -> IDE slave\n"
sb_dot:
.str "."
sb_ok_msg:
.str "\nNANBUILD OK: 2880 sectors written + read-back verified.\n"
sb_missing_msg:
.str "\nBUILD ERROR: no separate IDE slave output disk.\n"
sb_sig_msg:
.str "\nBUILD ERROR: invalid source boot signature.\n"
sb_mismatch_msg:
.str "\nBUILD ERROR: verification mismatch on output disk.\n"
sb_fail_msg:
.str "\nBUILD ERROR: ATA I/O failed or timed out.\n"
sb_serial_ok:
.str "NANBUILD OK\n"
sb_serial_fail:
.str "NANBUILD FAIL\n"
