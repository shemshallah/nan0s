#!/usr/bin/env python3
# gen_x64_vec.py - append the 512-bit vector-register emitters to x86_64.nas.
# Vector file: X64_V = 0x60000, 16 registers x 64 bytes.
# Vector indexes are static at translation time, so each address is emitted
# as `mov eax, V + 64*index`.

V = 0x60000

def EI(b):
    if isinstance(b, str):
        b = bytes.fromhex(b.replace(' ', ''))
    out = ''
    for off in range(0, len(b), 4):
        c = b[off:off + 4]
        v = int.from_bytes(c, 'little')
        out += '  MOVI r2,0x%04X\n' % (v & 0xFFFF)
        out += '  MOVHI r2,0x%04X\n' % ((v >> 16) & 0xFFFF)
        out += '  MOVI r3,%d\n' % len(c)
        out += '  CALL @x64_emitn\n'
    return out

def vmac(off, xmm, base, store=False):
    base_n = {'r8': 0, 'r9': 1, 'r10': 2}[base]
    mod = 0x00 if off == 0 else 0x40
    modrm = bytes([mod | (xmm << 3) | base_n])
    op = b'\xf3\x41\x0f\x7f' if store else b'\xf3\x41\x0f\x6f'
    return EI(op + modrm + (b'' if off == 0 else bytes([off])))

def vaddr_nan(reg):
    return '''  ADD r9,%s,r0
  CALL @x64_vaddr_const
''' % reg

vec = '''
; emit mov eax, X64_V + 64*r9
x64_vaddr_const:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r10,r9,r0
  SHL r10,r10,6
  MOVI r2,0x0000
  MOVHI r2,0x0006
  ADD r10,r10,r2
  MOVI r2,0xB8
  CALL @x64_8
  ADD r2,r10,r0
  CALL @x64_32
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; VZERO d
x64_vzero:
  ST r15,r14,0
  ADD r14,r14,r13
'''
vec += vaddr_nan('r5')
vec += EI('66 0F EF C0')
for off in (0x00, 0x10, 0x20, 0x30):
    vec += EI(bytes.fromhex('f3 0f 7f 40') + bytes([off]))
vec += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET

; VBCAST d,a
x64_vbcast:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r6,r0
'''
vec += vaddr_nan('r5')
vec += EI('41 89 C0')       # mov r8d,eax
vec += '''  ADD r5,r11,r0
  CALL @x64_load_eax_r
'''
vec += EI('66 0F 6E C0')
vec += EI('66 0F 70 C0 00')
vec += EI('44 89 C0')
for off in (0x00, 0x10, 0x20, 0x30):
    vec += EI(bytes.fromhex('f3 0f 7f 40') + bytes([off]))
vec += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET

; VGET d,a,lane (lane in r7, static)
x64_vget:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r5,r0
'''
vec += vaddr_nan('r6')
vec += EI('05')
vec += '''  ADD r9,r7,r0
  SHL r9,r9,2
  ADD r2,r9,r0
  CALL @x64_32
'''
vec += EI('8B 08')          # mov ecx,[rax]
vec += '''  ADD r5,r11,r0
  CALL @x64_store_ecx_r
  SUB r14,r14,r13
  LD r15,r14,0
  RET

; VSET d,a,lane
x64_vset:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r6,r0
'''
vec += vaddr_nan('r5')
vec += EI('05')
vec += '''  ADD r9,r7,r0
  SHL r9,r9,2
  ADD r2,r9,r0
  CALL @x64_32
'''
vec += EI('41 89 C0')       # mov r8d,eax
vec += '''  ADD r5,r11,r0
  CALL @x64_load_ecx_r
'''
vec += EI('44 89 C0')       # mov eax,r8d
vec += EI('89 08')          # mov [rax],ecx
vec += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''

def vbin(name, opbytes):
    s = '''
; %s d,a,b
x64_%s:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r5,r0
  ADD r12,r6,r0
''' % (name, name)
    s += vaddr_nan('r11')
    s += EI('41 89 C0')     # mov r8d,eax
    s += vaddr_nan('r12')
    s += EI('41 89 C1')     # mov r9d,eax
    s += vaddr_nan('r8')
    s += EI('41 89 C2')     # mov r10d,eax
    for off in (0, 0x10, 0x20, 0x30):
        s += vmac(off, 0, 'r9')
        s += vmac(off, 1, 'r10')
        s += EI(opbytes)
        s += vmac(off, 0, 'r8', store=True)
    s += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''
    return s


# VLOAD/VSTORE: 64 bytes in payload space, arbitrary alignment.
BODY_PRO = bytes.fromhex('44 89 C8 89 C2 83 E2 03 C1 E8 02 23 04 25') + (0x50404).to_bytes(4,'little') + bytes.fromhex('C1 E0 03 05') + (0x200000).to_bytes(4,'little')
VLOAD_BODY = BODY_PRO + bytes.fromhex('0F B6 4C 10 02 41 88 08 41 FF C0 41 FF C1 FF CE')
VSTORE_BODY = BODY_PRO + bytes.fromhex('41 8A 08 88 4C 10 02 41 FF C0 41 FF C1 FF CE')
def loop(body):
    return body + bytes([0x75, (-len(body) - 2) & 0xFF])
VLOAD_LOOP = loop(VLOAD_BODY)
VSTORE_LOOP = loop(VSTORE_BODY)

def vldst(name, body):
    s = f'''
; {name} d,a
x64_{name}:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r6,r0
'''
    s += vaddr_nan('r5')
    s += EI('41 89 C0')
    s += '''  ADD r5,r11,r0
  CALL @x64_load_eax_r
'''
    s += EI('41 89 C1')       # mov r9d,eax
    s += EI('BE 40 00 00 00') # mov esi,64
    s += EI(body)
    s += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''
    return s

vec += vldst('vload', VLOAD_LOOP)
vec += vldst('vstore', VSTORE_LOOP)


def vdp4b():
    s = '''
; vdp4b d,a,b: per dword, dot of 4 signed bytes
x64_vdp4b:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r5,r0
  ADD r12,r6,r0
'''
    s += vaddr_nan('r11')
    s += EI('41 89 C0')
    s += vaddr_nan('r12')
    s += EI('41 89 C1')
    s += vaddr_nan('r8')
    s += EI('41 89 C2')
    for i in range(16):
        d = 4 * i
        if d == 0:
            s += EI('41 8B 01')      # mov eax,[r9]
            s += EI('41 8B 12')      # mov edx,[r10]
        else:
            s += EI(bytes.fromhex('41 8B 41') + bytes([d]))
            s += EI(bytes.fromhex('41 8B 52') + bytes([d]))
        s += EI('31 FF')             # xor edi,edi
        for k in range(4):
            s += EI('0F BE C8')      # movsx ecx,al
            s += EI('0F BE F2')      # movsx esi,dl
            s += EI('0F AF CE')      # imul ecx,esi
            s += EI('01 CF')         # add edi,ecx
            if k != 3:
                s += EI('C1 E8 08')  # shr eax,8
                s += EI('C1 EA 08')  # shr edx,8
        if d == 0:
            s += EI('41 89 38')      # mov [r8],edi
        else:
            s += EI(bytes.fromhex('41 89 78') + bytes([d]))
    s += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''
    return s

vec += vdp4b()


def vdp4b4():
    s = '''
; vdp4b4 d,a,b: Q4 weights V[a] x int8 V[b],V[b+1]
x64_vdp4b4:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r5,r0
  ADD r12,r6,r0
'''
    s += vaddr_nan('r11')
    s += EI('41 89 C0')          # dest
    s += vaddr_nan('r12')
    s += EI('41 89 C1')          # weights
    s += vaddr_nan('r8')
    s += EI('41 89 C2')          # a0 = b
    s += '''  ADDI r10,r8,1
  MOVI r2,15
  BOOL.8 r10,r10,r2
  ADD r9,r10,r0
  CALL @x64_vaddr_const
'''
    s += EI('41 89 C3')          # a1 = b+1
    for i in range(16):
        d = 4 * i
        if d == 0:
            s += EI('41 8B 01')      # mov eax,[r9]
            s += EI('41 8B 12')      # mov edx,[r10]
        else:
            s += EI(bytes.fromhex('41 8B 41') + bytes([d]))
            s += EI(bytes.fromhex('41 8B 52') + bytes([d]))
        s += EI('31 FF')             # xor edi,edi
        for half in (0, 1):
            for j in range(4):
                s += EI('89 C1')     # mov ecx,eax
                s += EI('83 E1 0F')  # and ecx,15
                s += EI('C1 E1 1C')  # shl ecx,28
                s += EI('C1 F9 1C')  # sar ecx,28
                s += EI('0F BE F2')  # movsx esi,dl
                s += EI('0F AF CE')  # imul ecx,esi
                s += EI('01 CF')     # add edi,ecx
                if not (half == 1 and j == 3):
                    s += EI('C1 E8 04')  # shr eax,4
                    s += EI('C1 EA 08')  # shr edx,8
            if half == 0:
                if d == 0:
                    s += EI('41 8B 13')  # mov edx,[r11]
                else:
                    s += EI(bytes.fromhex('41 8B 53') + bytes([d]))
        if d == 0:
            s += EI('41 89 38')
        else:
            s += EI(bytes.fromhex('41 89 78') + bytes([d]))
    s += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''
    return s

vec += vdp4b4()

vec += vbin('vadd8', '66 0F FC C1')
vec += vbin('vsub8', '66 0F F8 C1')
vec += vbin('vadd32', '66 0F FE C1')
vec += vbin('vsub32', '66 0F FA C1')
def vmul32_scalar():
    s = '''
; vmul32 d,a,b (scalar lanes, baseline x86)
x64_vmul32:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r5,r0
  ADD r12,r6,r0
'''
    s += vaddr_nan('r11')
    s += EI('41 89 C0')
    s += vaddr_nan('r12')
    s += EI('41 89 C1')
    s += vaddr_nan('r8')
    s += EI('41 89 C2')
    for i in range(16):
        d = 4 * i
        if d == 0:
            s += EI('41 8B 01')         # mov eax,[r9]
            s += EI('41 0F AF 02')      # imul eax,[r10]
            s += EI('41 89 00')         # mov [r8],eax
        else:
            s += EI(bytes.fromhex('41 8B 41') + bytes([d]))
            s += EI(bytes.fromhex('41 0F AF 42') + bytes([d]))
            s += EI(bytes.fromhex('41 89 40') + bytes([d]))
    s += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''
    return s

vec += vmul32_scalar()

p = 'src/translate/x86_64.nas'
s = open(p).read()
# Remove any previous vector section before re-appending.
mark = '\n; emit mov eax, X64_V + 64*r9'
if mark in s:
    s = s[:s.find(mark)]
if 'x64_vaddr_const:' not in s:
    s += vec
open(p, 'w').write(s)
print('appended %d lines' % len(vec.splitlines()))
