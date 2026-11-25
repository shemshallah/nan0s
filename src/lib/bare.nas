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
.equ W_BFL_PATH 0xF0703
.equ W_BFL_DST  0xF0704
.equ W_BFL_MAX  0xF0705
.equ W_BFL_LEN  0xF0706

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

; bare_fs_load: r1=path r2=dst byte ptr r3=max -> r1=bytes or -1
; Copies the stored bytes into the caller's buffer.  Used by guests that
; keep a working copy and persist it with bare_fs_save (SQLite VFS).
bare_fs_load:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFL_PATH
ST r2,r0,#W_BFL_DST
ST r3,r0,#W_BFL_MAX
CALL @nfs_ensure
LD r1,r0,#W_BFL_PATH
CALL @nfs_data
CMP r3,r0
JMP[EQ] @bfl_no
CMP r2,r0
JMP[EQ] @bfl_zero
LD r4,r0,#W_BFL_MAX
CMP r2,r4
JMP[LE] @bfl_len
ADD r2,r4,r0
bfl_len:
ST r2,r0,#W_BFL_LEN
SHL r1,r1,2
LD r5,r0,#W_BFL_DST
LD r6,r0,#W_BFL_LEN
bfl_l:
CMP r6,r0
JMP[EQ] @bfl_ok
LDB r7,r1,0
STB r7,r5,0
ADD r1,r1,r13
ADD r5,r5,r13
SUB r6,r6,r13
JMP @bfl_l
bfl_ok:
LD r1,r0,#W_BFL_LEN
JMP @bfl_d
bfl_zero:
MOVI r1,0
JMP @bfl_d
bfl_no:
LA r1,0xFFFFFFFF
bfl_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; bare_fs_save: r1=path r2=src byte ptr r3=bytes -> r1=entry or 0
; Replaces the file contents in one call (nfs_write creates/truncates).
bare_fs_save:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFL_PATH
ST r2,r0,#W_BFL_DST
ST r3,r0,#W_BFL_LEN
CALL @nfs_ensure
LD r1,r0,#W_BFL_PATH
LD r2,r0,#W_BFL_DST
SHR r2,r2,2
LD r3,r0,#W_BFL_LEN
CALL @nfs_write
SUB r14,r14,r13
LD r15,r14,0
RET

; bare_fs_size: r1=path -> r1=bytes or -1
bare_fs_size:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFL_PATH
CALL @nfs_ensure
LD r1,r0,#W_BFL_PATH
CALL @nfs_data
CMP r3,r0
JMP[EQ] @bfs_no
ADD r1,r2,r0
JMP @bfs_sz_d
bfs_no:
LA r1,0xFFFFFFFF
bfs_sz_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; ---- POSIX metadata over NPAF -------------------------------------
.equ W_BFD_DIR 0xF0707
.equ W_BFD_IDX 0xF0708
.equ W_BFD_BUF 0xF0709
.equ W_BFD_MAX 0xF070A
.equ W_BFD_TYP 0xF070B
.equ W_BFD_LEN 0xF070C
.equ W_BFD_P   0xF070D
.equ W_BFD_ENT 0xF070E
.equ W_BFT_H   0xF0710
.equ W_BFT_L   0xF0711
.equ W_BFT_D   0xF0712
.equ W_BFD_IDX0 0xF0720
.equ W_BFD_NAME 0xF0730

; bare_fs_access: r1=path -> 1 present / 0 absent
bare_fs_access:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFS_PATH
CALL @nfs_ensure
LD r1,r0,#W_BFS_PATH
CALL @nfs_find
CMP r1,r0
JMP[EQ] @bfa_no
MOVI r1,1
JMP @bfa_d
bfa_no:
MOVI r1,0
bfa_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; bare_fs_mkdir: r1=path -> 0 ok / -1 error
bare_fs_mkdir:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFS_PATH
CALL @nfs_ensure
LD r1,r0,#W_BFS_PATH
CALL @nfs_find
CMP r1,r0
JMP[NE] @bfmk_err
LD r1,r0,#W_BFS_PATH
MOVI r2,1
CALL @nfs_create
CMP r1,r0
JMP[EQ] @bfmk_err
MOVI r1,0
JMP @bfmk_d
bfmk_err:
LA r1,0xFFFFFFFF
bfmk_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; bare_fs_rmdir: r1=path -> 0 ok / -1 error (must be an empty directory)
bare_fs_rmdir:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFS_PATH
CALL @nfs_ensure
LD r1,r0,#W_BFS_PATH
CALL @nfs_find
CMP r1,r0
JMP[EQ] @bfrm_err
LD r2,r1,#NF_E_DIR
CMP r2,r0
JMP[EQ] @bfrm_err
MOVI r2,0
ST r2,r0,#W_BFD_IDX0
LD r1,r0,#W_BFS_PATH
LA r2,#W_BFD_IDX0
LA r3,#W_BFD_NAME
MOVI r4,64
LA r5,#W_BFD_TYP
CALL @bare_fs_readdir
CMP r1,r0
JMP[NE] @bfrm_err
LD r1,r0,#W_BFS_PATH
CALL @nfs_delete
CMP r1,r0
JMP[EQ] @bfrm_err
MOVI r1,0
JMP @bfrm_d
bfrm_err:
LA r1,0xFFFFFFFF
bfrm_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; bare_fs_readdir: r1=dirpath r2=index word ptr r3=namebuf r4=max
;                  r5=type word ptr -> 1 entry / 0 end
bare_fs_readdir:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFD_DIR
ST r2,r0,#W_BFD_IDX
ST r3,r0,#W_BFD_BUF
ST r4,r0,#W_BFD_MAX
ST r5,r0,#W_BFD_TYP
; directory prefix length
LD r6,r0,#W_BFD_DIR
MOVI r7,0
brd_len:
LDB r8,r6,0
CMP r8,r0
JMP[EQ] @brd_len_d
ADD r6,r6,r13
ADD r7,r7,r13
JMP @brd_len
brd_len_d:
ST r7,r0,#W_BFD_LEN
; trim a trailing slash (but keep "/" itself)
MOVI r8,1
CMP r7,r8
JMP[LE] @brd_trim_d
ADDI r8,r6,-1
LDB r9,r8,0
MOVI r10,47
CMP r9,r10
JMP[NE] @brd_trim_d
SUB r7,r7,r13
ST r7,r0,#W_BFD_LEN
brd_trim_d:
LD r6,r0,#W_BFD_IDX
LD r6,r6,0
brd_loop:
MOVI r7,#NFS_MAX
CMP r6,r7
JMP[GE] @brd_none
ADD r1,r6,r0
CALL @nfs_entry
CMP r1,r0
JMP[EQ] @brd_next
ST r1,r0,#W_BFD_ENT
ADDI r2,r1,#NF_E_PATH
SHL r2,r2,2
ST r2,r0,#W_BFD_P
; compare the directory prefix
LD r7,r0,#W_BFD_LEN
LD r8,r0,#W_BFD_DIR
MOVI r9,0
brd_cmp:
CMP r9,r7
JMP[GE] @brd_prefix
LDB r10,r8,0
LDB r11,r2,0
CMP r10,r11
JMP[NE] @brd_next
ADD r8,r8,r13
ADD r2,r2,r13
ADD r9,r9,r13
JMP @brd_cmp
brd_prefix:
MOVI r10,1
CMP r7,r10
JMP[EQ] @brd_name
MOVI r10,47
LDB r11,r2,0
CMP r11,r10
JMP[NE] @brd_next
ADD r2,r2,r13
brd_name:
LDB r11,r2,0
CMP r11,r0
JMP[EQ] @brd_next
MOVI r10,47
CMP r11,r10
JMP[EQ] @brd_next
LD r3,r0,#W_BFD_BUF
LD r4,r0,#W_BFD_MAX
SUB r4,r4,r13
MOVI r9,0
brd_cp:
CMP r9,r4
JMP[GE] @brd_cp_d
LDB r11,r2,0
CMP r11,r0
JMP[EQ] @brd_cp_d
MOVI r10,47
CMP r11,r10
JMP[EQ] @brd_cp_d
STB r11,r3,0
ADD r2,r2,r13
ADD r3,r3,r13
ADD r9,r9,r13
JMP @brd_cp
brd_cp_d:
STB r0,r3,0
LD r3,r0,#W_BFD_IDX
ADD r6,r6,r13
ST r6,r3,0
LD r3,r0,#W_BFD_ENT
LD r4,r3,#NF_E_DIR
LD r3,r0,#W_BFD_TYP
ST r4,r3,0
MOVI r1,1
JMP @brd_d
brd_next:
ADD r6,r6,r13
JMP @brd_loop
brd_none:
LD r3,r0,#W_BFD_IDX
MOVI r4,#NFS_MAX
ST r4,r3,0
MOVI r1,0
brd_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; bare_fs_stat: r1=path r2=stat word ptr -> 0 ok / -1 error
; layout: 0 isdir, 1 size, 2 mode, 3 mtime_ms
bare_fs_stat:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFS_PATH
ST r2,r0,#W_BFD_BUF
CALL @nfs_ensure
LD r1,r0,#W_BFS_PATH
CALL @nfs_find
CMP r1,r0
JMP[EQ] @bfst_err
LD r3,r1,#NF_E_DIR
LD r4,r1,#NF_E_SIZE
MOVI r6,0x81A4
CMP r3,r0
JMP[EQ] @bfst_mode
MOVI r6,0x41ED
bfst_mode:
LD r5,r0,#W_BFD_BUF
ST r3,r5,0
ST r4,r5,1
ST r6,r5,2
TICK r7
ST r7,r5,3
MOVI r1,0
JMP @bfst_d
bfst_err:
LA r1,0xFFFFFFFF
bfst_d:
SUB r14,r14,r13
LD r15,r14,0
RET

; bare_fs_truncate: r1=path r2=new length -> 0 ok / -1 error
; Shrinking is supported; growing is rejected (the caller can rewrite).
bare_fs_truncate:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,#W_BFT_H
ST r2,r0,#W_BFT_L
CALL @nfs_ensure
LD r1,r0,#W_BFT_H
CALL @nfs_data
CMP r3,r0
JMP[EQ] @bft_err
ST r1,r0,#W_BFT_D
LD r4,r0,#W_BFT_L
CMP r4,r2
JMP[GT] @bft_err
CMP r4,r2
JMP[EQ] @bft_ok
LD r1,r0,#W_BFT_H
LD r2,r0,#W_BFT_D
LD r3,r0,#W_BFT_L
CALL @nfs_write
CMP r1,r0
JMP[EQ] @bft_err
bft_ok:
MOVI r1,0
JMP @bft_d
bft_err:
LA r1,0xFFFFFFFF
bft_d:
SUB r14,r14,r13
LD r15,r14,0
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
LA r3,#NFS_BASE
ADDI r3,r3,8
MOVI r4,#NFS_MAX
SHL r4,r4,4
ADD r3,r3,r4
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
