; nankernel.nas - minimal NaN16 kernel SVC file service.
;
; The S1 trap frame is at KFRAME (24 words).  SVC 4..8 follow
; spec/KERNEL_ABI.md: r1..r4 are in frame[1..4], the number is frame[20],
; and the return value goes to frame[21].  The handlers call the NPAF
; machine filesystem in bare.nas, so the file service itself is raw NaN.
;
; Boot code must program the ports before entering user code:
;   0x4E00 = @kentry, 0x4E01 = KFRAME, 0x4E03 = KSTACK.
.equ KFRAME 0x2F1000
.equ KSTACK 0x2F0000

kentry:
  MOVI r13,1
  LA r10,#KFRAME
  LD r1,r10,20
  MOVI r2,4
  CMP r1,r2
  JMP[EQ] @ksvc_open
  MOVI r2,5
  CMP r1,r2
  JMP[EQ] @ksvc_read
  MOVI r2,6
  CMP r1,r2
  JMP[EQ] @ksvc_write
  MOVI r2,7
  CMP r1,r2
  JMP[EQ] @ksvc_seek
  MOVI r2,8
  CMP r1,r2
  JMP[EQ] @ksvc_close
  ; Unknown syscall: return -1.
  LA r1,0xFFFFFFFF
  JMP @ksvc_ret

ksvc_open:
  LD r1,r10,1
  LD r2,r10,2
  SHL r2,r2,31
  SHR r2,r2,31
  CALL @bare_fs_open
  JMP @ksvc_ret
ksvc_read:
  LD r1,r10,1
  LD r2,r10,2
  LD r3,r10,3
  CALL @bare_fs_read
  JMP @ksvc_ret
ksvc_write:
  LD r1,r10,1
  LD r2,r10,2
  LD r3,r10,3
  CALL @bare_fs_write
  JMP @ksvc_ret
ksvc_seek:
  LD r1,r10,1
  LD r2,r10,2
  LD r3,r10,3
  CALL @bare_fs_seek
  JMP @ksvc_ret
ksvc_close:
  LD r1,r10,1
  CALL @bare_fs_close
  JMP @ksvc_ret

ksvc_ret:
  LA r10,#KFRAME
  ST r1,r10,21
  SVCRET
