; NaN/0S shell (round 18) - exhibit cartridge loader.
; Entry: word 0 JMPs here (shell_entry at word 512).
; r0=0, r13=1, r14=SP, r15=link.

.equ SLOT 8192
.equ TOC_BASE 22000
.equ STR_BASE 2048
.equ BABY_STORE 3072

shell_entry:
MOVI r13,1
; ---- 1. Fill jump-vector table ----
; v_puts -> lib_vputs
MOVI r1,@lib_vputs
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_puts
MOVI r3,15
STW r1,r2,r3

; v_hex -> lib_vhex
MOVI r1,@lib_vhex
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_hex
MOVI r3,15
STW r1,r2,r3

; v_dec -> lib_vdec
MOVI r1,@lib_vdec
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_dec
MOVI r3,15
STW r1,r2,r3

; v_cls -> lib_vcls
MOVI r1,@lib_vcls
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_cls
MOVI r3,15
STW r1,r2,r3

; v_key -> lib_key
MOVI r1,@lib_key
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_key
MOVI r3,15
STW r1,r2,r3

; v_keyq -> lib_keyq
MOVI r1,@lib_keyq
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_keyq
MOVI r3,15
STW r1,r2,r3

; v_tick -> lib_tick
MOVI r1,@lib_tick
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_tick
MOVI r3,15
STW r1,r2,r3

; v_putc -> lib_putc
MOVI r1,@lib_putc
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_putc
MOVI r3,15
STW r1,r2,r3

; v_bcopy -> lib_bcopy
MOVI r1,@lib_bcopy
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_bcopy
MOVI r3,15
STW r1,r2,r3

; v_seal_verify -> lib_seal_verify
MOVI r1,@lib_seal_verify
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_seal_verify
MOVI r3,15
STW r1,r2,r3

; v_seal_show -> lib_seal_show
MOVI r1,@lib_seal_show
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_seal_show
MOVI r3,15
STW r1,r2,r3

; v_scroll -> lib_vscroll (general 80x25 text scroll)
MOVI r1,@lib_vscroll
MOVI r8,10
SHL r8,r8,24
BOOL.14 r1,r1,r8
MOVI r2,@v_scroll
MOVI r3,15
STW r1,r2,r3

; ---- cold boot: snapshot the catalog, then run the system cart (GUI desktop)
; when the builder declared one. The snapshot survives a large cart loaded at 8192.
CALL @sh_snap_toc
LA r10,@boot_rec
LD r1,r10,0
CMP r1,r0
JMP[EQ] @sh_redraw
JMP @sh_run

; ---- 2. Clear screen and display menu ----
sh_redraw:
CALL @v_cls

sh_menu:
MOVI r1,@sh_banner
MOVI r2,0
MOVI r3,0x1F00
MOVI r5,0
MOVI r6,0
CALL @v_puts

; ---- count visible entries, derive pages, clamp page ----
MOVI r10,#TOC_BASE
MOVI r8,0
shc_loop:
LD r1,r10,0
CMP r1,r0
JMP[EQ] @shc_done
LD r1,r10,7
MOVI r4,1
BOOL.8 r1,r1,r4
CMP r1,r0
JMP[NE] @shc_next
ADDI r8,r8,1
shc_next:
MOVI r4,16
ADD r10,r10,r4
JMP @shc_loop
shc_done:
ADDI r1,r8,8
MOVI r2,9
DIVU r1,r1,r2
CMP r1,r0
JMP[NE] @shc_pages
MOVI r1,1
shc_pages:
ST r1,r0,@sh_pages
LD r1,r0,@sh_page
LD r2,r0,@sh_pages
CMP r1,r2
JMP[LT] @shc_clamped
SUB r2,r2,r13
ST r2,r0,@sh_page
shc_clamped:
LD r1,r0,@sh_page
MOVI r2,9
MUL r1,r1,r2
ST r1,r0,@sh_pstart
ADDI r1,r1,9
ST r1,r0,@sh_pend

; ---- TOC-driven page: entry = 16 words (see TOC layout below); ends at id 0 ----
MOVI r10,#TOC_BASE
MOVI r11,324
ST r0,r0,@sh_visidx
shm_loop:
LD r1,r10,0
CMP r1,r0
JMP[EQ] @shm_done
LD r2,r10,7
MOVI r4,1
BOOL.8 r2,r2,r4
CMP r2,r0
JMP[NE] @shm_hidden
LD r2,r0,@sh_pstart
LD r9,r0,@sh_visidx
CMP r9,r2
JMP[LT] @shm_skip
LD r2,r0,@sh_pend
LD r9,r0,@sh_visidx
CMP r9,r2
JMP[GE] @shm_done
LD r2,r0,@sh_pstart
LD r9,r0,@sh_visidx
SUB r1,r9,r2
ADDI r1,r1,1
MOVI r4,0x0F5B
VPOKE r4,r11
ADD r2,r11,r13
MOVI r3,0x0F00
CALL @v_dec
MOVI r4,0x0F5D
ADD r2,r11,r13
ADD r2,r2,r13
VPOKE r4,r2
LD r1,r10,1
MOVI r2,5
ADD r2,r2,r11
MOVI r3,0x0E00
CALL @v_dec
LD r1,r10,3
MOVI r2,10
ADD r2,r2,r11
MOVI r3,0x0F00
MOVI r5,0
MOVI r6,0
CALL @v_puts
LD r4,r10,6
LD r1,r4,@sh_btab
MOVI r2,90
ADD r2,r2,r11
MOVI r3,0x0B00
MOVI r5,0
MOVI r6,0
CALL @v_puts
MOVI r4,160
ADD r11,r11,r4
LD r1,r0,@sh_visidx
ADDI r1,r1,1
ST r1,r0,@sh_visidx
JMP @shm_next
shm_skip:
LD r1,r0,@sh_visidx
ADDI r1,r1,1
ST r1,r0,@sh_visidx
shm_hidden:
shm_next:
MOVI r4,16
ADD r10,r10,r4
JMP @shm_loop
shm_done:
MOVI r1,@sh_more
MOVI r2,1760
MOVI r3,0x0800
MOVI r5,0
MOVI r6,0
CALL @v_puts
LD r1,r0,@sh_page
ADDI r1,r1,1
MOVI r2,1816
MOVI r3,0x0800
CALL @v_dec

MOVI r1,@sh_foot
MOVI r2,1840
MOVI r3,0x0800
MOVI r5,0
MOVI r6,0
CALL @v_puts

; ---- 3. Wait for key ----
sh_key:
CALL @v_key
MOVI r4,255
BOOL.8 r1,r1,r4
MOVI r4,115
CMP r1,r4
JMP[EQ] @sh_sys
MOVI r4,27
CMP r1,r4
JMP[EQ] @sh_redraw
MOVI r4,93
CMP r1,r4
JMP[EQ] @sh_pgnext
MOVI r4,91
CMP r1,r4
JMP[EQ] @sh_pgprev
MOVI r4,48
CMP r1,r4
JMP[LT] @sh_key
MOVI r4,57
CMP r1,r4
JMP[GT] @sh_key
MOVI r4,48
SUB r1,r1,r4
SUB r1,r1,r13
LD r2,r0,@sh_page
MOVI r3,9
MUL r2,r2,r3
ADD r1,r1,r2
ST r1,r0,@sh_target
MOVI r10,#TOC_BASE
MOVI r8,0
shk_find:
LD r2,r10,0
CMP r2,r0
JMP[EQ] @sh_key
LD r3,r10,7
MOVI r4,1
BOOL.8 r3,r3,r4
CMP r3,r0
JMP[NE] @shk_skip
LD r3,r0,@sh_target
CMP r8,r3
JMP[EQ] @sh_run
ADDI r8,r8,1
shk_skip:
MOVI r4,16
ADD r10,r10,r4
JMP @shk_find
sh_pgnext:
LD r1,r0,@sh_page
LD r2,r0,@sh_pages
ADDI r3,r1,1
CMP r3,r2
JMP[GE] @sh_key
ST r3,r0,@sh_page
JMP @sh_redraw
sh_pgprev:
LD r1,r0,@sh_page
CMP r1,r0
JMP[EQ] @sh_key
SUB r1,r1,r13
ST r1,r0,@sh_page
JMP @sh_redraw

; ---- load + seal-check + run the cartridge whose TOC entry is at r10 ----
sh_run:
LD r1,r10,4
LD r2,r10,5
CALL @v_seal_verify
BOOL.12 r12,r1,r1
BOOL.12 r11,r2,r2
CMP r12,r13
JMP[EQ] @sh_seal_ok
MOVI r1,@sh_bad
MOVI r2,1600
MOVI r3,0x0C00
MOVI r5,0
MOVI r6,0
CALL @v_puts
LD r1,r12,@sh_rtab
MOVI r2,1680
MOVI r3,0x0E00
MOVI r5,0
MOVI r6,0
CALL @v_puts
CMP r12,r0
JMP[EQ] @sh_key
BOOL.12 r1,r11,r11
MOVI r2,1760
MOVI r3,0x0E00
CALL @v_dec
JMP @sh_key
sh_seal_ok:
MOVI r1,8192
LD r2,r10,4
LD r3,r10,5
CALL @v_bcopy
CALL 8192
; public program request: a desktop program can ask the shell to load a hidden slot
LA r10,@nsh_req
LD r1,r10,0
CMP r1,r0
JMP[EQ] @sh_after_prog
ST r0,r10,0
CALL @v_cls
MOVI r10,#TOC_BASE
shsr_find:
LD r2,r10,0
CMP r2,r0
JMP[EQ] @sh_after_prog
CMP r2,r1
JMP[EQ] @sh_run
MOVI r4,16
ADD r10,r10,r4
JMP @shsr_find
sh_after_prog:
MOVI r13,1
JMP @sh_redraw

sh_curator:
CALL @cu_entry
JMP @sh_redraw
sh_sys:
CALL @sys_menu
JMP @sh_redraw

; ---- Curator Console: raw guest words, read-only. Secret key: ~ ----
cu_entry:
ST r15,r0,@cu_ret
MOVI r1,0
ST r1,r0,@cu_base
cu_redraw:
CALL @v_cls
MOVI r10,0
cu_row:
MOVI r4,24
CMP r10,r4
JMP[GE] @cu_key
LD r1,r0,@cu_base
MOVI r4,4
MUL r4,r10,r4
ADD r1,r1,r4
MOVI r2,80
MUL r2,r10,r2
MOVI r3,0x0E00
CALL @v_hex
MOVI r11,0
cu_word:
MOVI r4,4
CMP r11,r4
JMP[GE] @cu_next
LD r1,r0,@cu_base
MOVI r4,4
MUL r4,r10,r4
ADD r1,r1,r4
ADD r1,r1,r11
LD r1,r1,0
MOVI r2,10
MOVI r4,9
MUL r4,r11,r4
ADD r2,r2,r4
MOVI r4,80
MUL r4,r10,r4
ADD r2,r2,r4
MOVI r3,0x0F00
CALL @v_hex
ADD r11,r11,r13
JMP @cu_word
cu_next:
ADD r10,r10,r13
JMP @cu_row
cu_key:
MOVI r1,@cu_foot
MOVI r2,1920
MOVI r3,0x0800
MOVI r5,0
MOVI r6,0
CALL @v_puts
CALL @v_key
MOVI r4,255
BOOL.8 r1,r1,r4
MOVI r4,27
CMP r1,r4
JMP[EQ] @cu_exit
MOVI r4,0x80
CMP r1,r4
JMP[EQ] @cu_up
MOVI r4,0x81
CMP r1,r4
JMP[EQ] @cu_down
MOVI r4,0x82
CMP r1,r4
JMP[EQ] @cu_pgup
MOVI r4,0x83
CMP r1,r4
JMP[EQ] @cu_pgdn
JMP @cu_key
cu_up:
LD r1,r0,@cu_base
CMP r1,r0
JMP[EQ] @cu_key
SUB r1,r1,r13
ST r1,r0,@cu_base
JMP @cu_redraw
cu_down:
LD r1,r0,@cu_base
ADD r1,r1,r13
MOVI r2,32672
CMP r1,r2
JMP[LE] @cu_down_ok
ADD r1,r2,r0
cu_down_ok:
ST r1,r0,@cu_base
JMP @cu_redraw
cu_pgup:
LD r1,r0,@cu_base
MOVI r2,96
CMP r1,r2
JMP[LT] @cu_pgup0
SUB r1,r1,r2
JMP @cu_pgup_ok
cu_pgup0:
MOVI r1,0
cu_pgup_ok:
ST r1,r0,@cu_base
JMP @cu_redraw
cu_pgdn:
LD r1,r0,@cu_base
MOVI r2,96
ADD r1,r1,r2
MOVI r2,32672
CMP r1,r2
JMP[LE] @cu_pgdn_ok
ADD r1,r2,r0
cu_pgdn_ok:
ST r1,r0,@cu_base
JMP @cu_redraw
cu_exit:
LD r15,r0,@cu_ret
RET
cu_ret:
.word 0
cu_base:
.word 0
cu_title:
.str " CURATOR CONSOLE - RAW GUEST WORDS - 8 HEX ADDRESS + 4 PAYLOADS"
cu_foot:
.str "CURATOR CONSOLE  UP/DOWN word  LEFT/RIGHT page  ESC shell  key ~"

; ---- Data ----
sh_banner:
.str " NaN/0S  SYSTEM  -  NaN16                                           "
sh_more:
.str " PAGE "
sh_btab:
.word @sh_b0
.word @sh_b1
.word @sh_b2
sh_b0:
.str "EXACT: original program/data bit-for-bit"
sh_b1:
.str "RE-CREATION: same behaviour, rewritten"
sh_b2:
.str "INSPIRED: in the spirit of the original"
sh_rtab:
.word @sh_r0
.word @sh_r0
.word @sh_r2
.word @sh_r3
sh_r0:
.str "seal differs: near payload / far-face payload / class-nibble channel"
sh_r2:
.str "illegal head (gate fails) at cartridge word:"
sh_r3:
.str "mirror law broken (BSWAPM face != software swap) at cartridge word:"
sh_bad:
.str "SEAL MISMATCH - cartridge REFUSED (not loaded, not run)"
sh_foot:
.str "ring 0, no host OS. 1-9 run item; [ ] page; ESC redraw. NaN/0S v40\n"

; ---- System menu: settings, NaNNet, disk, memory, CPU ----
sys_menu:
  ST r15,r0,@sm_ret
  CALL @v_cls
  MOVI r1,@sm_title
  MOVI r2,0
  MOVI r3,0x1F00
  MOVI r5,0
  MOVI r6,0
  CALL @v_puts
  MOVI r1,@sm_body
  MOVI r2,160
  MOVI r3,0x0F00
  MOVI r5,0
  MOVI r6,0
  CALL @v_puts
  MOVI r1,@sm_foot
  MOVI r2,1840
  MOVI r3,0x0800
  MOVI r5,0
  MOVI r6,0
  CALL @v_puts
sm_key:
  CALL @v_key
  MOVI r4,255
  BOOL.8 r1,r1,r4
  MOVI r4,27
  CMP r1,r4
  JMP[EQ] @sm_exit
  MOVI r4,49
  CMP r1,r4
  JMP[EQ] @sm_settings
  MOVI r4,50
  CMP r1,r4
  JMP[EQ] @sm_net
  JMP @sm_key
sm_settings:
  MOVI r1,@st_title
  MOVI r2,@st_body
  CALL @sys_show
  JMP @sys_menu
sm_net:
  LA r10,@service_rec
  LD r1,r10,0
  CMP r1,r0
  JMP[NE] @sh_run
  MOVI r1,@net_title
  MOVI r2,@net_body
  CALL @sys_show
  JMP @sys_menu
sm_disk:
  MOVI r1,@disk_title
  MOVI r2,@disk_body
  CALL @sys_show
  JMP @sys_menu
sm_mem:
  MOVI r1,@mem_title
  MOVI r2,@mem_body
  CALL @sys_show
  JMP @sys_menu
sm_cpu:
  MOVI r1,@cpu_title
  MOVI r2,@cpu_body
  CALL @sys_show
  JMP @sys_menu
sm_exit:
  LD r15,r0,@sm_ret
  RET
sm_ret:
.word 0

sys_show:
  ST r15,r0,@ss_ret
  ST r2,r0,@ss_body
  CALL @v_cls
  MOVI r2,0
  MOVI r3,0x1F00
  MOVI r5,0
  MOVI r6,0
  CALL @v_puts
  LD r1,r0,@ss_body
  MOVI r2,160
  MOVI r3,0x0F00
  MOVI r5,0
  MOVI r6,0
  CALL @v_puts
  MOVI r1,@sys_foot
  MOVI r2,1840
  MOVI r3,0x0800
  MOVI r5,0
  MOVI r6,0
  CALL @v_puts
  CALL @v_key
  LD r15,r0,@ss_ret
  RET
ss_ret:
.word 0
ss_body:
.word 0

; Catalog: 16 words per entry, BUILT by tools/mkimg.awk from tools/carts.txt:
; [0] catalog id (0 = end of list) | [1] year | [2] hall | [3] title_ptr |
; [4] store addr | [5] len words | [6] badge (0 EXACT 1 RE-CREATION 2 INSPIRED) |
; [7] flags (bit0 hidden) | [8] seal A | [9] meta_ptr | [10] seal B | [11] seal C |
; [12-15] reserved. Titles live at 23600 (16 words each); the catalog is paged
; by the shell. Order and wording are edited in carts.txt only.
.equ TOC_BASE 22000
.equ BOOT_BASE 4784
.equ SERVICE_BASE 4816
; ---- TOC/title snapshot at 0x70000/0x72000 for the debugger ----
sh_snap_toc:
ST r15,r0,@sst_lnk
LA r1,0x70000
MOVI r2,#TOC_BASE
LA r3,1408
BCOPY r1,r2,r3
LA r1,0x72000
MOVI r2,23600
LA r3,1408
BCOPY r1,r2,r3
MOVI r4,0
LA r5,0x70000
sst_loop:
LD r6,r5,0
CMP r6,r0
JMP[EQ] @sst_done
MOVI r2,16
MUL r3,r4,r2
LA r1,0x72000
ADD r3,r3,r1
ST r3,r5,3
ADDI r5,r5,16
ADD r4,r4,r13
MOVI r2,87
CMP r4,r2
JMP[LT] @sst_loop
sst_done:
LD r15,r0,@sst_lnk
RET
sst_lnk:
.word 0

.org 4784
boot_rec:
; system cart record (the GUI desktop), same 16-word shape. [0]=0 -> boot to menu.
; NOT an exhibit slot: slot 9 is the Settings cart.
.org 4800
nsh_req:
.word 0
.org 4816
service_rec:
; slot-less service cart record (SYSTEM menu [2]), same 16-word shape.
.org 4864
sh_page:
.word 0
sh_pages:
.word 1
sh_pstart:
.word 0
sh_pend:
.word 9
sh_target:
.word 0
sh_visidx:
.word 0
.org 5376
sm_title:
.str " NaN/0S  SYSTEM"
sm_body:
.str " [1] SETTINGS\n [2] NANNET / BROWSER\n\n ESC returns to the main menu."
sm_foot:
.str "NaN/0S SYSTEM  1-2 open  ESC main menu"
sys_foot:
.str "NaN/0S  any key returns to the system menu"
st_title:
.str " NaN/0S  SETTINGS"
st_body:
.str " VISUAL MODES\n 80x25 text is current.\n 320x200 pixel is live for Sierpinski and Paradox.\n 1024x768 GUI is planned, VBE driver not yet.\n AArch64 phone, x86, and RISC-V layouts are planned.\n\n CONFIRMATION RULE\n A future visual mode change will show a 10 second countdown\n and revert to the previous mode if no key is pressed."
net_title:
.str " NaN/0S  NANNET"
net_body:
.str " CONNECT\n No NIC driver yet. No link.\n SETTINGS\n Node NaN-0001, transport serial/ATA, no network stack.\n Plan: NaN16 IPv4/UDP loopback over COM1, then a PCIe NIC\n driver with DMA and a NaNNet settings page."
disk_title:
.str " NaN/0S  DISK UTILITY"
disk_body:
.str " ATA primary master: read PASS (sector 0 = NAN0).\n ATA PIO write: C-core PASS (16-bit OUTW); QEMU/real pending.\n NaNFS RAM: format/alloc/write/read PASS.\n Image: 1.44 MB, guest 32,768 words.\n Next: QEMU/real write validation, then NaNFS on disk."
mem_title:
.str " NaN/0S  MEMORY UTILITY"
mem_body:
.str " Guest image: sized by the store header (up to 4M words).\n Runtime G window: 8 MB at 0x200000.\n nalloc heap and MEMQ/E820 discovery are planned.\n Current exhibits use fixed buffers below the store.\n Store: 3,072..14,516 words."
cpu_title:
.str " NaN/0S  CPU / ARCHITECTURE"
cpu_body:
.str " Native core: x86, 5,800 bytes.\n Guest ISA: NaN16 double-endian, 16 truth-table classes.\n Clock: PIT TICK, 1,000 Hz class.\n AArch64 and RISC-V native cores: planned.\n Android root detection: host-only, not bare metal."



; NANDBG resident ABI and demo target (word 5800+)
; The GUI terminal's `debug` command opens a second CLI that calls these
; trampolines. 5700..8191 is the gap between the shell's strings and the cart
; slot; the core lives below the slot and the target above it, so a debug
; session and a loaded cart never overwrite each other.
; =============================================================================
.org 5800
dbg_abi:
  JMP @nd_reset       ; 5800  reset target state
  JMP @nd_step        ; 5801  one instruction
  JMP @nd_run         ; 5802  max steps in r1
  JMP @dbg_begin      ; 5803  reset + demo target + guard window
  JMP @dbg_reg        ; 5804  r1=index -> value
  JMP @dbg_pc         ; 5805  -> pc
  JMP @dbg_status     ; 5806  -> status
  JMP @dbg_hist       ; 5807  -> r1=hist, r2=index
  JMP @dbg_stack      ; 5808  -> r1=cs, r2=depth
  JMP @dbg_counts     ; 5809  -> r1=counts
  JMP @dbg_break      ; 5810  r1=address (toggle)
  JMP @dbg_watch      ; 5811  r1=address
  JMP @dbg_rec        ; 5812  -> r1=record
  JMP @dbg_cart       ; 5813  r1=TOC entry -> load sealed cart into debug arena

dbg_begin:
  ST r15,r0,@dbg_begin_lnk
  CALL @nd_reset
  CALL @dbg_serclr
  MOVI r1,1
  ST r1,r0,@nd_urec
  MOVI r1,@dbg_target
  ST r1,r0,@nd_pc
  ST r0,r0,@nd_gb
  MOVI r1,0xFFFF
  ST r1,r0,@nd_mask
  ST r0,r0,@nd_map_lo
  ST r0,r0,@nd_map_hi
  ST r0,r0,@nd_map_dst
  MOVI r1,1
  ST r1,r0,@nd_iocap
  LA r1,0x60000
  ST r1,r0,@nd_tbuf
  MOVI r1,@dbg_target
  ST r1,r0,@nd_wlo
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_whi
  ST r1,r0,@nd_brk
  ST r1,r0,@nd_watch
  ST r0,r0,@nd_bpn
  ST r0,r0,@nd_wpn
  ST r0,r0,@nd_li
  LD r15,r0,@dbg_begin_lnk
  RET
dbg_begin_lnk:
.word 0

dbg_reg:
  LD r1,r1,@nd_regs
  RET
dbg_pc:
  LD r1,r0,@nd_pc
  RET
dbg_status:
  LD r1,r0,@nd_status
  RET
dbg_hist:
  MOVI r1,@nd_hist
  LD r2,r0,@nd_hi
  RET
dbg_stack:
  MOVI r1,@nd_cs
  LD r2,r0,@nd_cd
  RET
dbg_counts:
  MOVI r1,@nd_counts
  RET
dbg_break:
  LD r2,r0,@nd_brk
  CMP r1,r2
  JMP[EQ] @dbg_brk_off
  ST r1,r0,@nd_brk
  RET
dbg_brk_off:
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_brk
  RET
dbg_watch:
  ST r1,r0,@nd_watch
  RET
dbg_rec:
  MOVI r1,@nd_rec
  RET

; dbg_cart: r1 = TOC entry (word address). Copy its sealed payload to the
; debug arena, then map [8192, 8192+span) onto the arena and point pc at 8192.
; The store is never modified; the seal remains valid.
.equ DBG_ARENA 0x80000
.equ DBG_ARENA_SPAN 0x10000
dbg_cart:
  ST r15,r0,@dbg_cart_lnk
  ST r1,r0,@dbg_toc
  LD r2,r1,4            ; store word
  LD r3,r1,5            ; length words
  ST r2,r0,@dbg_store
  ST r3,r0,@dbg_len
  CMP r3,r0
  JMP[EQ] @dbg_cart_bad
  LA r1,#DBG_ARENA_SPAN
  CMP r3,r1
  JMP[GT] @dbg_cart_bad
  ; BCOPY d=dst, a=src, b=count
  LA r1,#DBG_ARENA
  LD r2,r0,@dbg_store
  LD r3,r0,@dbg_len
  BCOPY r1,r2,r3
  ; reset target registers/pc/flags/tables
  CALL @nd_reset
  CALL @dbg_serclr
  MOVI r1,1
  ST r1,r0,@nd_urec
  ; map the cart image window; 8192..8192+max(len, 0x8000)
  MOVI r1,8192
  ST r1,r0,@nd_map_lo
  LD r2,r0,@dbg_len
  ADD r2,r2,r1
  MOVI r3,40960
  CMP r2,r3
  JMP[GE] @dbg_cart_hi
  ADD r2,r3,r0
dbg_cart_hi:
  ST r2,r0,@nd_map_hi
  LA r1,#DBG_ARENA
  ST r1,r0,@nd_map_dst
  ; guard the arena; the shell/core below it stay read-only
  ST r1,r0,@nd_wlo
  LD r2,r0,@nd_map_hi
  MOVI r3,8192
  SUB r2,r2,r3
  ADD r2,r2,r1
  ST r2,r0,@nd_whi
  ; capture cart display writes into the private text buffer
  MOVI r1,1
  ST r1,r0,@nd_iocap
  LA r1,0x60000
  ST r1,r0,@nd_tbuf
  ; guest return address: a HALT word, so the cart's final RET stops
  MOVI r1,@dbg_return
  MOVI r2,15
  ST r1,r2,@nd_regs
  MOVI r1,8192
  ST r1,r0,@nd_pc
  ST r0,r0,@nd_gb
  MOVI r1,0xFFFF
  ST r1,r0,@nd_mask
  LA r1,0xFFFFFFFF
  ST r1,r0,@nd_brk
  ST r1,r0,@nd_watch
  ST r0,r0,@nd_bpn
  ST r0,r0,@nd_wpn
  ST r0,r0,@nd_li
  MOVI r1,1
  LD r15,r0,@dbg_cart_lnk
  RET
dbg_cart_bad:
  MOVI r1,0
  LD r15,r0,@dbg_cart_lnk
  RET
dbg_cart_lnk:
.word 0
dbg_toc:
.word 0
dbg_store:
.word 0
dbg_len:
.word 0

dbg_return:
HALT

; clear the captured serial length for a new debug session
dbg_serclr:
  LA r1,0x61000
  ST r0,r1,0
  RET

.org 5950
dbg_abi2:
  JMP @dbg_mem_get    ; 5950  r1=guest word -> payload
  JMP @dbg_log        ; 5951  -> r1=ring, r2=next index
  JMP @dbg_mem_cls    ; 5952  r1=guest word -> class
  JMP @dbg_reg_set    ; 5953  r1=index r2=value
  JMP @dbg_mem_set    ; 5954  r1=guest word r2=value
  JMP @dbg_bp_list    ; 5955  -> r1=table r2=count
  JMP @dbg_bp_toggle  ; 5956  r1=pc -> r1=1 added / 0 removed
  JMP @dbg_wp_list    ; 5957  -> r1=table r2=count
  JMP @dbg_wp_toggle  ; 5958  r1=address -> r1=1 added / 0 removed
  JMP @dbg_pc_set     ; 5959  r1=pc
  JMP @dbg_tbuf       ; 5960  -> r1=target text buffer
  JMP @dbg_mem_geth   ; 5961  r1=host word -> payload
  JMP @dbg_mem_seth   ; 5962  r1=host word r2=payload r3=class
  JMP @dbg_usnap      ; 5963  -> r1=base r2=index r3=depth
  JMP @dbg_uinval     ; 5964  clear undo history
  JMP @dbg_udone      ; 5965  commit one undo -> r1=depth left
  JMP @dbg_state_set  ; 5966  r1=k r2=call depth
  JMP @dbg_state_get  ; 5967  -> r1=k r2=call depth
  JMP @dbg_upop       ; 5968  redo one undo-ring position
  JMP @dbg_mem_geth_cls ; 5969  r1=host word -> class
  JMP @dbg_ckpt_to    ; 5970  arena -> checkpoint buffer
  JMP @dbg_ckpt_from  ; 5971  checkpoint buffer -> arena
  JMP @dbg_map        ; 5972  guest word -> host word
.org 5973
dbg_mem_get:
  ST r15,r0,@dmg_lnk
  CALL @nd_addr
  LD r1,r1,0
  LD r15,r0,@dmg_lnk
  RET
dmg_lnk:
.word 0
dbg_log:
  LA r1,0x31000
  LD r2,r0,@nd_li
  RET

dbg_reg_set:
  ST r2,r1,@nd_regs
  RET
dbg_pc_set:
  ST r1,r0,@nd_pc
  RET
dbg_tbuf:
  LA r1,0x60000
  RET
dbg_mem_set:
  ST r15,r0,@dms_lnk
  ST r2,r0,@dms_v
  CALL @nd_addr
  LD r2,r0,@dms_v
  ST r2,r1,0
  LD r15,r0,@dms_lnk
  RET
dms_lnk:
.word 0
dms_v:
.word 0

dbg_bp_list:
  MOVI r1,@nd_bpt
  LD r2,r0,@nd_bpn
  RET
dbg_wp_list:
  MOVI r1,@nd_wpt
  LD r2,r0,@nd_wpn
  RET

; toggle a PC in the breakpoint table (16 entries, compact on remove)
dbg_bp_toggle:
  ST r15,r0,@dbt_lnk
  ST r1,r0,@dbt_v
  LD r2,r0,@nd_bpn
  MOVI r4,0
dbt_scan:
  CMP r4,r2
  JMP[GE] @dbt_add
  LD r5,r4,@nd_bpt
  LD r6,r0,@dbt_v
  CMP r5,r6
  JMP[EQ] @dbt_del
  ADD r4,r4,r13
  JMP @dbt_scan
dbt_del:
  ADD r7,r4,r0
dbt_shift:
  ADDI r7,r7,1
  CMP r7,r2
  JMP[GE] @dbt_dec
  LD r5,r7,@nd_bpt
  SUB r6,r7,r13
  ST r5,r6,@nd_bpt
  JMP @dbt_shift
dbt_dec:
  SUB r2,r2,r13
  ST r2,r0,@nd_bpn
  MOVI r1,0
  LD r15,r0,@dbt_lnk
  RET
dbt_add:
  MOVI r3,16
  CMP r2,r3
  JMP[GE] @dbt_full
  LD r6,r0,@dbt_v
  ST r6,r2,@nd_bpt
  ADD r2,r2,r13
  ST r2,r0,@nd_bpn
  MOVI r1,1
  LD r15,r0,@dbt_lnk
  RET
dbt_full:
  MOVI r1,0
  LD r15,r0,@dbt_lnk
  RET
dbt_lnk:
.word 0
dbt_v:
.word 0

; toggle an address in the watchpoint table (8 entries)
dbg_wp_toggle:
  ST r15,r0,@dwt_lnk
  ST r1,r0,@dwt_v
  LD r2,r0,@nd_wpn
  MOVI r4,0
dwt_scan:
  CMP r4,r2
  JMP[GE] @dwt_add
  LD r5,r4,@nd_wpt
  LD r6,r0,@dwt_v
  CMP r5,r6
  JMP[EQ] @dwt_del
  ADD r4,r4,r13
  JMP @dwt_scan
dwt_del:
  ADD r7,r4,r0
dwt_shift:
  ADDI r7,r7,1
  CMP r7,r2
  JMP[GE] @dwt_dec
  LD r5,r7,@nd_wpt
  SUB r6,r7,r13
  ST r5,r6,@nd_wpt
  JMP @dwt_shift
dwt_dec:
  SUB r2,r2,r13
  ST r2,r0,@nd_wpn
  MOVI r1,0
  LD r15,r0,@dwt_lnk
  RET
dwt_add:
  MOVI r3,8
  CMP r2,r3
  JMP[GE] @dwt_full
  LD r6,r0,@dwt_v
  ST r6,r2,@nd_wpt
  ADD r2,r2,r13
  ST r2,r0,@nd_wpn
  MOVI r1,1
  LD r15,r0,@dwt_lnk
  RET
dwt_full:
  MOVI r1,0
  LD r15,r0,@dwt_lnk
  RET
dwt_lnk:
.word 0
dwt_v:
.word 0

dbg_mem_cls:
  ST r15,r0,@dmc_lnk
  CALL @nd_addr
  LDN r1,r1,0
  LD r15,r0,@dmc_lnk
  RET
dmc_lnk:
.word 0

; host-word access for the undo ring and restore path
dbg_mem_geth:
  LD r1,r1,0
  RET
dbg_mem_seth:
  STW r2,r1,r3
  RET
dbg_usnap:
  LD r1,r0,@nd_ui
  LD r2,r0,@nd_ud
  RET
dbg_uinval:
  ST r0,r0,@nd_ud
  RET
dbg_udone:
  LD r1,r0,@nd_ui
  SUB r1,r1,r13
  MOVI r2,31
  BOOL.8 r1,r1,r2
  ST r1,r0,@nd_ui
  LD r1,r0,@nd_ud
  CMP r1,r0
  JMP[EQ] @du_ret
  SUB r1,r1,r13
  ST r1,r0,@nd_ud
  LD r1,r0,@nd_steps
  CMP r1,r0
  JMP[EQ] @du_ret
  SUB r1,r1,r13
  ST r1,r0,@nd_steps
  ST r0,r0,@nd_status
du_ret:
  LD r1,r0,@nd_ud
  RET
dbg_state_set:
  ST r1,r0,@nd_k
  ST r2,r0,@nd_cd
  RET

; ---- undo recording ---------------------------------------------------------
; Called at the start of each guest step. Saves 16 regs, pc, condition, shadow
; call depth and two write-log slots in a 32-word record at 0x30000 + ui*32.
nd_usave:
  ST r15,r0,@nd_ealnk
  LD r2,r0,@nd_urec
  CMP r2,r0
  JMP[EQ] @us_done
  LD r1,r0,@nd_ui
  SHL r1,r1,5
  LA r2,0x30000
  ADD r1,r1,r2
  ST r1,r0,@nd_ubase
  MOVI r2,0
us_l:
  LD r3,r2,@nd_regs
  ADD r4,r1,r2
  ST r3,r4,0
  ADD r2,r2,r13
  MOVI r3,16
  CMP r2,r3
  JMP[LT] @us_l
  LD r3,r0,@nd_pc
  ST r3,r1,16
  LD r3,r0,@nd_k
  ST r3,r1,17
  LD r3,r0,@nd_cd
  ST r3,r1,18
  ST r0,r1,19
  ST r0,r1,20
  LD r1,r0,@nd_ui
  ADD r1,r1,r13
  MOVI r2,31
  BOOL.8 r1,r1,r2
  ST r1,r0,@nd_ui
  LD r2,r0,@nd_ud
  MOVI r3,32
  CMP r2,r3
  JMP[GE] @us_done
  ADD r2,r2,r13
  ST r2,r0,@nd_ud
us_done:
  LD r15,r0,@nd_ealnk
  RET

; r1 = host word address; logs the pre-write word and class for the current step
nd_uwr:
  ST r15,r0,@nd_ealnk
  LD r2,r0,@nd_urec
  CMP r2,r0
  JMP[EQ] @uw_done
  LD r2,r0,@nd_ubase
  LD r3,r2,19
  CMP r3,r0
  JMP[NE] @uw_done
  LD r3,r2,20
  MOVI r4,2
  CMP r3,r4
  JMP[GE] @uw_full
  MOVI r4,3
  MUL r4,r4,r3
  MOVI r5,21
  ADD r4,r4,r5
  ADD r5,r2,r4
  ST r1,r5,0
  LD r4,r1,0
  ST r4,r5,1
  LDN r4,r1,0
  ST r4,r5,2
  ADD r3,r3,r13
  ST r3,r2,20
  JMP @uw_done
uw_full:
  MOVI r1,1
  ST r1,r2,19
  ST r0,r0,@nd_ud
uw_done:
  LD r15,r0,@nd_ealnk
  RET

; a bulk or vector step changes state the ring does not snapshot
nd_ubulk:
  ST r15,r0,@nd_ealnk
  LD r1,r0,@nd_urec
  CMP r1,r0
  JMP[EQ] @ub_done
  LD r1,r0,@nd_ubase
  MOVI r2,1
  ST r2,r1,19
  ST r0,r0,@nd_ud
ub_done:
  LD r15,r0,@nd_ealnk
  RET

.org 6200
.include "../dbg/core.nas"

.org 8100
dbg_target:
  MOVI r13,1
  MOVI r1,0
dbt_loop:
  ADD r1,r1,r13
  MOVI r2,10
  CMP r1,r2
  JMP[LT] @dbt_loop
  MOVI r3,0xAA
  HALT

; ---- captured serial output -------------------------------------------------
; PUTC from the target: while a debug session is active, append one character
; per word at 0x61000 (length) .. 0x61001+. Otherwise pass through to COM1.
nd_putc_cap:
  LD r1,r0,@nd_iocap
  CMP r1,r0
  JMP[EQ] @npc_pass
  LD r4,r5,@nd_regs
  LA r1,0x61000
  LD r2,r1,0
  MOVI r3,4094
  CMP r2,r3
  JMP[GE] @nd_loop
  ADD r3,r2,r13
  ADD r3,r1,r3
  ST r4,r3,0
  ADD r2,r2,r13
  ST r2,r1,0
  JMP @nd_loop
npc_pass:
  LD r4,r5,@nd_regs
  PUTC r4
  JMP @nd_loop

; return the target condition and shadow-call depth
dbg_state_get:
  LD r1,r0,@nd_k
  LD r2,r0,@nd_cd
  RET

; redo restored the post-step state: re-expose the undo record it consumed
dbg_upop:
  LD r1,r0,@nd_ui
  ADD r1,r1,r13
  MOVI r2,31
  BOOL.8 r1,r1,r2
  ST r1,r0,@nd_ui
  LD r1,r0,@nd_ud
  MOVI r2,32
  CMP r1,r2
  JMP[GE] @up_done
  ADD r1,r1,r13
  ST r1,r0,@nd_ud
up_done:
  LD r1,r0,@nd_steps
  ADD r1,r1,r13
  ST r1,r0,@nd_steps
  ST r0,r0,@nd_status
  ST r0,r0,@nd_reason
  RET

dbg_mem_geth_cls:
  LDN r1,r1,0
  RET

; ---- checkpoint arena and capture copies (64K words + 8K) -------------
; The GUI saves registers and the header; these helpers move the 64K cart
; arena and the captured screen/serial window at 0x60000..0x62000.
dbg_ckpt_to:
  ST r15,r0,@nd_ealnk
  LA r1,0x91000
  LA r2,0x80000
  LA r3,0x10000
  BCOPY r1,r2,r3
  LA r1,0xA1000
  LA r2,0x60000
  LA r3,0x2000
  BCOPY r1,r2,r3
  MOVI r1,1
  LD r15,r0,@nd_ealnk
  RET

dbg_ckpt_from:
  ST r15,r0,@nd_ealnk
  LA r1,0x80000
  LA r2,0x91000
  LA r3,0x10000
  BCOPY r1,r2,r3
  LA r1,0x60000
  LA r2,0xA1000
  LA r3,0x2000
  BCOPY r1,r2,r3
  MOVI r1,1
  LD r15,r0,@nd_ealnk
  RET

dbg_map:
  ST r15,r0,@nd_ealnk
  CALL @nd_addr
  LD r15,r0,@nd_ealnk
  RET

.include "../dbg/ndr_stub.nas"

; ---- paged cartridge catalog area (builder writes 16-word entries at 22000) ----

; ---- paged cartridge catalog area (builder writes 16-word entries at 22000) ----
.org 22000
toc:
