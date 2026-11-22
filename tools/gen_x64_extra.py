#!/usr/bin/env python3
# gen_x64_extra.py - append the DIV/MOD and scalar FP emitters to x86_64.nas.
# Kept in-tree so the long hand-written byte sequences are reproducible.

import sys

def EI(hexs):
    b = bytes.fromhex(hexs.replace(' ', ''))
    out = ''
    for off in range(0, len(b), 4):
        c = b[off:off + 4]
        v = int.from_bytes(c, 'little')
        out += '  MOVI r2,0x%04X\n' % (v & 0xFFFF)
        out += '  MOVHI r2,0x%04X\n' % ((v >> 16) & 0xFFFF)
        out += '  MOVI r3,%d\n' % len(c)
        out += '  CALL @x64_emitn\n'
    return out

def CHK(reg):
    return (EI('89 C2' if reg == 'eax' else '89 F2') +
            EI('81 E2 00 00 80 7F') +
            EI('81 FA 00 00 80 7F') +
            EI('0F 94 C2') +
            EI('89 C1' if reg == 'eax' else '89 F1') +
            EI('81 E1 FF FF 7F 00') +
            EI('0F 95 C1') +
            EI('20 CA') +
            EI('0F B6 D2'))

add = '''
; emit r3 bytes from r2 (LSB first)
x64_emitn:
  ST r15,r14,0
  ADD r14,r14,r13
x64_emitn_loop:
  CMP r3,r0
  JMP[EQ] @x64_emitn_done
  STB r2,r1,0
  SHR r2,r2,8
  ADDI r1,r1,1
  SUB r3,r3,r13
  JMP @x64_emitn_loop
x64_emitn_done:
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; DIV/MOD/DIVU/MODU: r5=d r6=a r8=b r9=opcode.
; Branchless special cases: B==0 and B==-1 use divisor 1 and select the
; architectural result afterwards.  k=3 when B==0.
x64_divmod:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r8,r0
  CALL @x64_load_ecx_r
'''
add += EI('89 C6')
add += EI('89 CF')
add += EI('41 89 C8')
add += EI('41 BA 01 00 00 00')
add += EI('83 F9 00')
add += EI('45 0F 44 C2')
add += '''  MOVI r11,0x23
  CMP r9,r11
  JMP[EQ] @x64_div_signed
  MOVI r11,0x24
  CMP r9,r11
  JMP[EQ] @x64_div_signed
  JMP @x64_div_unsigned
x64_div_signed:
'''
add += EI('83 F9 FF')
add += EI('45 0F 44 C2')
add += EI('99')
add += EI('41 F7 F8')
add += '''  JMP @x64_div_select
x64_div_unsigned:
'''
add += EI('31 D2')
add += EI('41 F7 F0')
add += '''x64_div_select:
  MOVI r11,0x23
  CMP r9,r11
  JMP[EQ] @x64_div_q
  MOVI r11,0x25
  CMP r9,r11
  JMP[EQ] @x64_div_q
'''
add += EI('41 89 D1')
add += '''  JMP @x64_div_special
x64_div_q:
'''
add += EI('41 89 C1')
add += '''x64_div_special:
'''
add += EI('41 89 F3')
add += EI('41 F7 DB')
add += EI('45 31 D2')
add += '''  MOVI r11,0x23
  CMP r9,r11
  JMP[NE] @x64_div_trymod
'''
add += EI('83 FF 00')
add += EI('45 0F 44 CA')
add += EI('83 F9 FF')
add += EI('45 0F 44 CB')
add += '''  JMP @x64_div_store
x64_div_trymod:
  MOVI r11,0x24
  CMP r9,r11
  JMP[NE] @x64_div_trydivu
'''
add += EI('83 FF FF')
add += EI('45 0F 44 CB')
add += EI('83 FF 00')
add += EI('44 0F 44 CE')
add += '''  JMP @x64_div_store
x64_div_trydivu:
  MOVI r11,0x25
  CMP r9,r11
  JMP[NE] @x64_div_modu
'''
add += EI('83 FF 00')
add += EI('45 0F 44 CA')
add += '''  JMP @x64_div_store
x64_div_modu:
'''
add += EI('83 FF 00')
add += EI('44 0F 44 CE')
add += '''x64_div_store:
'''
add += EI('44 89 0C 25')
add += '''  ADD r6,r10,r0
  CALL @x64_addr
'''
add += EI('45 85 C9')
add += EI('0F 94 C2')
add += EI('0F B6 D2')
add += EI('01 D2')
add += EI('B8 01 00 00 00')
add += EI('89 D1')
add += EI('D3 E0')
add += EI('83 FF 00')
add += EI('B9 08 00 00 00')
add += EI('0F 44 C1')
add += EI('89 04 25')
add += '''  LA r2,#X64_FLAGM
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; store eax to R[d] (d in r10) and set FLAGM=1 (k=0)
x64_fp_store_flag1:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r5,r10,r0
  CALL @x64_store_eax_r
  MOVI r2,0xC7
  CALL @x64_8
  MOVI r2,0x04
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  LA r2,#X64_FLAGM
  CALL @x64_32
  MOVI r2,1
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; scalar FP: r5=d r6=a r8=b r9=opcode (0x30..0x37)
x64_fp:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r5,r0
  ADD r5,r6,r0
  CALL @x64_load_eax_r
  ADD r5,r8,r0
  CALL @x64_load_ecx_r
'''
add += EI('66 0F 6E C0')
add += EI('66 0F 6E C9')
add += EI('89 C6')
add += EI('89 CF')
add += '''  MOVI r11,0x35
  CMP r9,r11
  JMP[EQ] @x64_fp_cmp
  MOVI r11,0x36
  CMP r9,r11
  JMP[EQ] @x64_fp_cvtif
  MOVI r11,0x37
  CMP r9,r11
  JMP[EQ] @x64_fp_cvtfi
  MOVI r11,0x34
  CMP r9,r11
  JMP[EQ] @x64_fp_sqrt
  MOVI r11,0x30
  CMP r9,r11
  JMP[EQ] @x64_fp_add
  MOVI r11,0x31
  CMP r9,r11
  JMP[EQ] @x64_fp_sub
  MOVI r11,0x32
  CMP r9,r11
  JMP[EQ] @x64_fp_mul
  JMP @x64_fp_div
x64_fp_add:
'''
add += EI('F3 0F 58 C1')
add += '  JMP @x64_fp_arith_done\nx64_fp_sub:\n'
add += EI('F3 0F 5C C1')
add += '  JMP @x64_fp_arith_done\nx64_fp_mul:\n'
add += EI('F3 0F 59 C1')
add += '''  JMP @x64_fp_arith_done
x64_fp_div:
'''
add += EI('F3 0F 5E C1')
add += EI('66 0F 7E C0')
add += CHK('eax')
add += EI('89 F9')
add += EI('81 E1 FF FF FF 7F')
add += EI('85 C9')
add += EI('0F 94 C1')
add += EI('0F B6 C9')
add += EI('21 CA')
add += EI('B9 00 00 C0 7F')
add += EI('85 D2')
add += EI('0F 45 C1')
add += '''  JMP @x64_fp_arith_store
x64_fp_sqrt:
'''
add += EI('F3 0F 51 C0')
add += EI('66 0F 7E C0')
add += CHK('eax')
add += EI('B9 00 00 C0 7F')
add += EI('85 D2')
add += EI('0F 45 C1')
add += '''  JMP @x64_fp_arith_store
x64_fp_arith_done:
'''
add += EI('66 0F 7E C0')
add += '''x64_fp_arith_store:
  CALL @x64_fp_store_flag1
  JMP @x64_fp_done

x64_fp_cvtif:
'''
add += EI('F3 0F 2A C0')
add += EI('66 0F 7E C0')
add += '''  CALL @x64_fp_store_flag1
  JMP @x64_fp_done

x64_fp_cvtfi:
'''
add += EI('F3 0F 2C C0')
add += CHK('esi')
add += EI('41 89 C0')
add += EI('3D 00 00 00 80')
add += EI('41 0F 94 C0')
add += EI('45 0F B6 C0')
add += EI('89 F1')
add += EI('C1 E9 1F')
add += EI('83 F1 01')
add += EI('41 21 C8')
add += EI('B9 FF FF FF 7F')
add += EI('45 85 C0')
add += EI('0F 45 C1')
add += EI('31 C9')
add += EI('85 D2')
add += EI('0F 45 C1')
add += '''  ADD r5,r10,r0
  CALL @x64_store_eax_r
'''
add += EI('85 C0')
add += '''  CALL @x64_flags_z
  JMP @x64_fp_done

x64_fp_cmp:
'''
add += EI('0F 2E C1')
add += EI('0F 94 C2')
add += EI('0F 92 C1')
add += EI('0F 9A C0')
add += EI('0F B6 D2')
add += EI('0F B6 C9')
add += EI('0F B6 C0')
add += EI('01 D2')
add += EI('01 CA')
add += EI('BF 01 00 00 00')
add += EI('89 D1')
add += EI('D3 E7')
add += EI('85 C0')
add += EI('B9 08 00 00 00')
add += EI('0F 45 F9')
add += EI('89 3C 25')
add += '''  LA r2,#X64_FLAGM
  CALL @x64_32

x64_fp_done:
  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''

p = 'src/translate/x86_64.nas'
s = open(p).read()
if 'x64_emitn:' not in s:
    s += add
open(p, 'w').write(s)
print('appended %d lines' % len(add.splitlines()))
