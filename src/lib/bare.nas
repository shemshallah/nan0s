; bare.nas - minimal machine interface table (raw NaN16).
; The table is the single boundary between the C runtime and a platform
; adapter. Defaults use the NaN16 console/keyboard/tick/ATA primitives; a
; platform can replace any slot at boot without touching the C ABI.
;
; slot 0  version        -> r1 = interface version
; slot 1  con_putc(c)
; slot 2  con_getc()     -> byte or -1
; slot 3  key_poll()     -> byte or 0
; slot 4  tick_ms()      -> milliseconds
; slot 5  rtc_get(fields)-> 0/1
; slot 6  block_read(lba, buf)
; slot 7  block_write(lba, buf)
; slot 8  fs_open(path, mode)
; slot 9  fs_read(h, buf, n)
; slot 10 fs_write(h, buf, n)
; slot 11 fs_seek(h, off, whence)
; slot 12 fs_close(h)
; slot 13 fs_remove(path)
; slot 14 fs_rename(old, new)
; slot 15 entropy_u32()  -> word
; slot 16 halt(code)

.equ BARE_VERSION 1
.equ BARE_TAB 11024000

bare_version:
MOVI r1,#BARE_VERSION
RET

bare_con_putc:
ST r15,r14,0
ADD r14,r14,r13
PUTC r1
SUB r14,r14,r13
LD r15,r14,0
RET

bare_con_getc:
KEYQ r1
RET

bare_key_poll:
KEYQ r1
RET

bare_tick_ms:
TICK r1
RET

bare_rtc_get:
; the clock adapter owns the real-time clock; the guest time code currently
; reads CMOS directly. Return 0 until an adapter supplies fields.
MOVI r1,0
RET

bare_block_read:
JMP @ata_read28

bare_block_write:
JMP @ata_write28

bare_fs_open:
LA r1,0xFFFFFFFF
RET
bare_fs_read:
LA r1,0xFFFFFFFF
RET
bare_fs_write:
LA r1,0xFFFFFFFF
RET
bare_fs_seek:
LA r1,0xFFFFFFFF
RET
bare_fs_close:
LA r1,0xFFFFFFFF
RET
bare_fs_remove:
MOVI r1,0
RET
bare_fs_rename:
MOVI r1,0
RET

bare_entropy:
ST r15,r14,0
ADD r14,r14,r13
TICK r1
LD r2,r0,#W_RAND
MUL r2,r2,r2
ADD r1,r1,r2
ST r1,r0,#W_RAND
SUB r14,r14,r13
LD r15,r14,0
RET

bare_halt:
HALT

; the interface table; adapters patch these words at boot
bare_table:
.word @bare_version
.word @bare_con_putc
.word @bare_con_getc
.word @bare_key_poll
.word @bare_tick_ms
.word @bare_rtc_get
.word @bare_block_read
.word @bare_block_write
.word @bare_fs_open
.word @bare_fs_read
.word @bare_fs_write
.word @bare_fs_seek
.word @bare_fs_close
.word @bare_fs_remove
.word @bare_fs_rename
.word @bare_entropy
.word @bare_halt
