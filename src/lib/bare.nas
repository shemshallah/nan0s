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

; ni_bare_tick: call the machine-interface millisecond tick (slot 4)
ni_bare_tick:
ST r15,r14,0
ADD r14,r14,r13
LA r2,@bare_table
LD r2,r2,4
CALLR r2
SUB r14,r14,r13
LD r15,r14,0
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

; ---- path filesystem adapter (NPAF-backed) -------------------------
; Handles are opaque STTAB entry addresses.  The adapter works without a
; prior ncc_compile call by lazily initializing the C heap.
.equ W_BFS_PATH 0xF06FE
.equ W_BFS_MODE 0xF06FF
.equ W_BFS_ENT  0xF0700
.equ W_BFS_TMP  0xF0701
.equ W_BFS_OFF  0xF0702

bare_fs_open:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFS_PATH
ST r2,r0,#W_BFS_MODE
LD r1,r0,#W_HEAP
CMP r1,r0
JMP[NE] @bfo_heap
LA r1,#C_HEAP
ST r1,r0,#W_HEAP
bfo_heap:
CALL @nfs_ensure
CALL @st_alloc
CMP r1,r0
JMP[EQ] @bfo_fail
ST r1,r0,#W_BFS_ENT
LD r1,r0,#W_BFS_PATH
CALL @st_strdup
LD r2,r0,#W_BFS_ENT
ST r1,r2,1
LD r1,r0,#W_BFS_MODE
CMP r1,r0
JMP[NE] @bfo_write
; read mode: snapshot the current NPAF data into the stream buffer
MOVI r2,1
LD r3,r0,#W_BFS_ENT
ST r2,r3,6
LD r1,r0,#W_BFS_PATH
CALL @nfs_find
CMP r1,r0
JMP[EQ] @bfo_bad
LD r1,r0,#W_BFS_PATH
CALL @nfs_data
ST r2,r0,#W_BFS_TMP
SHL r1,r1,2
LD r2,r0,#W_BFS_ENT
ST r1,r2,2
LD r3,r0,#W_BFS_TMP
ST r3,r2,3
ST r3,r2,4
ST r0,r2,5
ST r0,r2,7
ST r0,r2,8
JMP @bfo_ok
bfo_write:
; write mode: create/truncate, then let st_write_buf grow the buffer
MOVI r2,2
LD r3,r0,#W_BFS_ENT
ST r2,r3,6
LD r1,r0,#W_BFS_PATH
MOVI r2,0
CALL @nfs_create
CMP r1,r0
JMP[EQ] @bfo_bad
LD r2,r0,#W_BFS_ENT
ST r0,r2,2
ST r0,r2,3
ST r0,r2,4
ST r0,r2,5
MOVI r3,1
ST r3,r2,7
ST r0,r2,8
bfo_ok:
LD r1,r0,#W_BFS_ENT
JMP @bfo_d
bfo_bad:
LD r1,r0,#W_BFS_ENT
ST r0,r1,0
bfo_fail:
MOVI r1,0
bfo_d:
SUB r14,r14,r13
LD r15,r14,0
RET

bare_fs_read:
CMP r1,r0
JMP[EQ] @bfr_read0
JMP @st_read_buf
bfr_read0:
MOVI r1,0
RET

bare_fs_write:
CMP r1,r0
JMP[EQ] @bfw_zero
JMP @st_write_buf
bfw_zero:
MOVI r1,0
RET

bare_fs_seek:
ST r15,r14,0
ADD r14,r14,r13
CMP r1,r0
JMP[EQ] @bfs_err
ST r1,r0,#W_BFS_ENT
; r2=offset r3=whence
CMP r3,r0
JMP[EQ] @bfs_set
MOVI r4,1
CMP r3,r4
JMP[EQ] @bfs_cur
MOVI r4,2
CMP r3,r4
JMP[EQ] @bfs_end
JMP @bfs_err
bfs_set:
ADD r4,r2,r0
JMP @bfs_store
bfs_cur:
LD r4,r1,5
ADD r4,r4,r2
JMP @bfs_store
bfs_end:
LD r4,r1,3
ADD r4,r4,r2
bfs_store:
CMPS r4,r0
JMP[LT] @bfs_err
ST r4,r1,5
ST r0,r1,8
MOVI r1,0
JMP @bfs_d
bfs_err:
LA r1,0xFFFFFFFF
bfs_d:
SUB r14,r14,r13
LD r15,r14,0
RET

bare_fs_close:
ST r15,r14,0
ADD r14,r14,r13
CMP r1,r0
JMP[EQ] @bfc_err
ST r1,r0,#W_BFS_ENT
CALL @st_flush
LD r2,r0,#W_BFS_ENT
ST r0,r2,0
MOVI r1,0
JMP @bfc_d
bfc_err:
LA r1,0xFFFFFFFF
bfc_d:
SUB r14,r14,r13
LD r15,r14,0
RET

bare_fs_remove:
ST r15,r14,0
ADD r14,r14,r13
CALL @nfs_delete
CMP r1,r0
JMP[EQ] @bfrm_n
MOVI r1,0
JMP @bfrm_d
bfrm_n:
LA r1,0xFFFFFFFF
bfrm_d:
SUB r14,r14,r13
LD r15,r14,0
RET

bare_fs_rename:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFS_PATH
ST r2,r0,#W_BFS_TMP
CALL @nfs_find
CMP r1,r0
JMP[EQ] @bfrn_n
LD r2,r1,#NF_E_SIZE
ST r2,r0,#W_BFS_OFF
LD r2,r1,#NF_E_OFF
LA r3,#NFS_ARENA
ADD r3,r3,r2
LD r1,r0,#W_BFS_TMP
ADD r2,r3,r0
LD r3,r0,#W_BFS_OFF
CALL @nfs_write
CMP r1,r0
JMP[EQ] @bfrn_n
LD r1,r0,#W_BFS_PATH
CALL @nfs_delete
MOVI r1,0
JMP @bfrn_d
bfrn_n:
LA r1,0xFFFFFFFF
bfrn_d:
SUB r14,r14,r13
LD r15,r14,0
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
