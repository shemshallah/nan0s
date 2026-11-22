#!/usr/bin/env python3
# gen_x64_mem.py - append LDN/STW/BSWAPM emitters to x86_64.nas.

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

CLASS_NEAR = (
    EI('89 CF') +        # mov edi,ecx
    EI('C1 EF 03') +     # shr edi,3
    EI('83 E7 01') +     # and edi,1
    EI('D1 E7') +        # shl edi,1
    EI('89 CE') +        # mov esi,ecx
    EI('C1 EE 0F') +     # shr esi,15
    EI('83 E6 01') +     # and esi,1
    EI('09 F7'))         # or edi,esi

CLASS_FAR = (
    EI('89 D6') +        # mov esi,edx
    EI('C1 EE 03') +     # shr esi,3
    EI('83 E6 01') +
    EI('D1 E6') +
    EI('41 89 D0') +     # mov r8d,edx
    EI('41 C1 E8 0F') +  # shr r8d,15
    EI('41 83 E0 01') +
    EI('44 09 C6'))      # or esi,r8d

VALID_NEAR = (
    EI('41 89 C8') +     # mov r8d,ecx
    EI('41 81 E0 F0 7F 00 00') +
    EI('41 81 F8 F0 7F 00 00') +
    EI('41 0F 94 C0') +  # sete r8b
    EI('45 0F B6 C0') +  # movzx r8d,r8b
    EI('41 89 C9') +     # mov r9d,ecx
    EI('41 83 E1 0F') +
    EI('41 83 F9 01') +
    EI('41 0F 94 C1') +  # sete r9b
    EI('45 0F B6 C9') +
    EI('45 09 C8') +     # or r8d,r9d
    EI('41 89 C9') +
    EI('41 83 E1 0F') +
    EI('41 83 F9 08') +
    EI('41 0F 94 C1') +
    EI('45 0F B6 C9') +
    EI('45 09 C8'))

VALID_FAR = (
    EI('41 89 D1') +     # mov r9d,edx
    EI('41 81 E1 F0 7F 00 00') +
    EI('41 81 F9 F0 7F 00 00') +
    EI('41 0F 94 C1') +  # sete r9b
    EI('45 0F B6 C9') +
    EI('41 89 D2') +     # mov r10d,edx
    EI('41 83 E2 0F') +
    EI('41 83 FA 01') +
    EI('41 0F 94 C2') +  # sete r10b
    EI('45 0F B6 D2') +
    EI('45 09 D1') +     # or r9d,r10d
    EI('41 89 D2') +
    EI('41 83 E2 0F') +
    EI('41 83 FA 08') +
    EI('41 0F 94 C2') +
    EI('45 0F B6 D2') +
    EI('45 09 D1'))

add = '''
; 8B 14 25 addr : edx = R[d]
x64_load_edx_r:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r2,0x8B
  CALL @x64_8
  MOVI r2,0x14
  CALL @x64_8
  MOVI r2,0x25
  CALL @x64_8
  ADD r6,r5,r0
  CALL @x64_addr
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; LDN d,a,imm: header-class nibble or 0xFFFFFFFF
x64_ldn:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r5,r0
  MOVI r5,0
  CALL @x64_addr_word
'''
add += EI('0F B7 48 06')   # movzx ecx,word [rax+6]
add += EI('31 D2')          # xor edx,edx
add += EI('8A 10')          # mov dl,[rax]
add += EI('C1 E2 08')       # shl edx,8
add += EI('0F B6 70 01')    # movzx esi,byte [rax+1]
add += EI('09 F2')          # or edx,esi
add += CLASS_NEAR
add += CLASS_FAR
add += VALID_NEAR
add += VALID_FAR
add += EI('45 21 C8')       # and r8d,r9d
add += EI('C1 E7 02')       # shl edi,2
add += EI('09 F7')          # or edi,esi
add += EI('89 F8')          # mov eax,edi
add += EI('41 BA FF FF FF FF')
add += EI('45 85 C0')       # test r8d,r8d
add += EI('41 0F 44 C2')    # cmove eax,r10d
add += '''  ADD r5,r11,r0
  CALL @x64_store_eax_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; STW d,a,b: word[A] = mkword(R[d], R[b]&15)
x64_stw:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r5,0
  CALL @x64_addr_word
  ADD r11,eax,r0
  ADD r5,r5,r0
  ; reload d from the caller's saved value
  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''

# STW is hand-assembled below; replace the placeholder with the real body.
STW = '''
; STW d,a,b: word[A] = mkword(R[d], R[b]&15)
; r5=d r6=a r8=b.  The driver calls x64_stw with d/a/b intact.
x64_stw:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r5,0
  CALL @x64_addr_word
'''
STW += EI('41 89 C0')       # mov r8d,eax (save address)
STW += '''  ADD r5,r11,r0
  CALL @x64_load_edx_r
  ADD r5,r8,r0
  CALL @x64_load_ecx_r
'''
STW += EI('83 E1 0F')       # and ecx,15
# far head: 0x7FF1 + (kf>=2 ? 7:0) + (kf&1 ? 0x8000:0), kf=ecx&3
STW += EI('89 CE')          # mov esi,ecx
STW += EI('83 E6 03')       # and esi,3
STW += EI('89 F7')          # mov edi,esi
STW += EI('83 E7 02')       # and edi,2
STW += EI('D1 EF')          # shr edi,1
STW += EI('6B FF 07')       # imul edi,edi,7
STW += EI('81 C7 F1 7F 00 00')  # add edi,0x7FF1
STW += EI('89 CE')          # mov esi,ecx
STW += EI('83 E6 01')       # and esi,1
STW += EI('C1 E6 0F')       # shl esi,15
STW += EI('09 F7')          # or edi,esi  (far head)
STW += EI('89 FE')          # mov esi,edi
STW += EI('81 E6 FF 00 00 00')  # and esi,0xFF
STW += EI('C1 E6 08')       # shl esi,8
STW += EI('C1 EF 08')       # shr edi,8
STW += EI('09 F7')          # or edi,esi  (bswap16 far in edi)
# near head: kn=(n>>2)&3, same formula
STW += EI('41 89 C9')       # mov r9d,ecx
STW += EI('41 C1 E9 02')    # shr r9d,2
STW += EI('41 83 E1 03')    # and r9d,3
STW += EI('44 89 CE')       # mov esi,r9d
STW += EI('41 89 F2')       # mov r10d,esi
STW += EI('41 83 E2 02')    # and r10d,2
STW += EI('41 D1 EA')       # shr r10d,1
STW += EI('45 6B D2 07')    # imul r10d,r10d,7
STW += EI('41 81 C2 F1 7F 00 00')  # add r10d,0x7FF1
STW += EI('44 89 CE')       # mov esi,r9d
STW += EI('83 E6 01')       # and esi,1
STW += EI('C1 E6 0F')       # shl esi,15
STW += EI('41 09 F2')       # or r10d,esi (near head)
STW += EI('44 89 D6')       # mov esi,r10d
# stores
STW += EI('44 89 C0')       # mov eax,r8d
STW += EI('66 89 38')       # mov [rax],di
STW += EI('89 50 02')       # mov [rax+2],edx
STW += EI('66 89 70 06')    # mov [rax+6],si
STW += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET

; BSWAPM a,imm: byte-swap the full 8-byte NaN word at (R[a]+imm)&M
x64_bswapm:
  ST r15,r14,0
  ADD r14,r14,r13
  MOVI r5,0
  CALL @x64_addr_word
'''
STW += EI('48 89 C2')       # mov rdx,rax
STW += EI('48 8B 02')       # mov rax,[rdx]
STW += EI('48 0F C8')       # bswap rax
STW += EI('48 89 02')       # mov [rdx],rax
STW += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''

# Cut the placeholder and insert the real STW.
cut = add.index('; STW d,a,b: word[A] = mkword(R[d], R[b]&15)\nx64_stw:')
add = add[:cut] + STW

p = 'src/translate/x86_64.nas'
s = open(p).read()
if 'x64_ldn:' not in s:
    s += add
open(p, 'w').write(s)
print('appended %d lines' % len(add.splitlines()))
