; nfs_persist_test.nas - same-disk NPAF boot/sync/reboot probe.
;
; Boot 1 (blank ATA disk): nfs_load fails, so format the RAM store, seed the
; committed nanfs/ root through the same rootfs_seed_all used by gui_cart,
; create /persist.txt, nfs_save, print PERSIST FIRST OK.
; Boot 2 (same disk): nfs_load succeeds, the seeded files and /persist.txt
; are read back from the snapshot, print the file then PERSIST REBOOT OK.
;
; The disk contract is src/lib/nfs2.nas: snapshot header at LBA 2048 and the
; NFS_BASE image at LBA 2049.  ATA is the machine's primary master.
.equ STACK 0x7000
.org 0
JMP @main

.include "../lib/nfs2.nas"
.include "../lib/ata.nas"

; bare.nas slot 6/7 are all nfs2 needs from the machine table.
bare_table:
.word 0,0,0,0,0,0,@ata_read28,@ata_write28
.word 0,0,0,0,0,0,0,0,0

; puts: r1 = word address of a packed NUL-terminated string
puts:
SHL r1,r1,2
puts_l:
LDB r2,r1,0
CMP r2,r0
JMP[EQ] @puts_d
PUTC r2
ADD r1,r1,r13
JMP @puts_l
puts_d:
RET

; putn: r1 = word address of packed bytes, r2 = byte count
putn:
SHL r1,r1,2
putn_l:
CMP r2,r0
JMP[EQ] @putn_d
LDB r3,r1,0
PUTC r3
ADD r1,r1,r13
SUB r2,r2,r13
JMP @putn_l
putn_d:
RET

; fs_seed: r1=path byte ptr, r2=packed source word ptr (gui_cart contract)
fs_seed:
ST r15,r14,0
ADD r14,r14,r13
ST r1,r0,@fs_p1
ST r2,r0,@fs_p2
SHL r1,r2,2
MOVI r3,0
fs_sd_l:
LDB r4,r1,0
CMP r4,r0
JMP[EQ] @fs_sd_d
ADD r1,r1,r13
ADD r3,r3,r13
JMP @fs_sd_l
fs_sd_d:
LD r1,r0,@fs_p1
LD r2,r0,@fs_p2
CALL @nfs_write
SUB r14,r14,r13
LD r15,r14,0
RET
fs_p1:
.word 0
fs_p2:
.word 0

.include "../nan/rootfs_seed.nas"

main:
MOVI r13,1
MOVI r14,#STACK
CALL @nfs_load
CMP r1,r0
JMP[NE] @second_boot

; ---- first boot: no valid snapshot ----
CALL @nfs_format
CALL @rootfs_seed_all
LA r1,@p_motd
SHL r1,r1,2
CALL @nfs_stat
CMP r3,r0
JMP[EQ] @fail_seed
LA r1,@p_persist
SHL r1,r1,2
LA r2,@tok
MOVI r3,15
CALL @nfs_write
CMP r1,r0
JMP[EQ] @fail_write
CALL @nfs_save
CMP r1,r0
JMP[NE] @fail_save
MOVI r1,@s_first
CALL @puts
HALT

; ---- second boot: the snapshot must survive the same disk ----
second_boot:
MOVI r1,@s_loaded
CALL @puts
LA r1,@p_motd
SHL r1,r1,2
CALL @nfs_stat
CMP r3,r0
JMP[EQ] @fail_seed
LA r1,@p_persist
SHL r1,r1,2
CALL @nfs_data
CMP r3,r0
JMP[EQ] @fail_missing
CMP r2,r0
JMP[EQ] @fail_missing
CALL @putn
MOVI r1,10
PUTC r1
MOVI r1,@s_reboot
CALL @puts
HALT

fail_seed:
MOVI r1,@s_fail_seed
CALL @puts
HALT
fail_write:
MOVI r1,@s_fail_write
CALL @puts
HALT
fail_save:
MOVI r1,@s_fail_save
CALL @puts
HALT
fail_missing:
MOVI r1,@s_fail_missing
CALL @puts
HALT

s_first:
.str "PERSIST FIRST OK\n"
s_loaded:
.str "PERSIST LOADED\n"
s_reboot:
.str "PERSIST REBOOT OK\n"
s_fail_seed:
.str "PERSIST FAIL seed\n"
s_fail_write:
.str "PERSIST FAIL write\n"
s_fail_save:
.str "PERSIST FAIL save\n"
s_fail_missing:
.str "PERSIST FAIL missing\n"
p_motd:
.str "/motd"
p_persist:
.str "/persist.txt"
tok:
.str "persist-ok-2026"
