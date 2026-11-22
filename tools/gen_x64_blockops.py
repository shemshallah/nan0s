#!/usr/bin/env python3
# gen_x64_blockops.py - append BCOPY/BFILL emitters to x86_64.nas.

G = 0x200000
MASK = 0x50404

def build(items):
    code = bytearray()
    labels = {}
    fix = []
    for it in items:
        if it[0] == 'b':
            code += it[1]
        elif it[0] == 'l':
            labels[it[1]] = len(code)
        elif it[0] == 'j':
            code += it[1]
            fix.append((len(code), it[2]))
            code += b'\0\0\0\0'
    for pos, target in fix:
        d = labels[target] - (pos + 4)
        assert -0x80000000 <= d < 0x80000000, (target, d)
        code[pos:pos + 4] = (d & 0xFFFFFFFF).to_bytes(4, 'little')
    return bytes(code)

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

def loadptr():
    return '  MOVI r2,0x8B\n  CALL @x64_8\n  MOVI r2,0x04\n  CALL @x64_8\n  MOVI r2,0x25\n  CALL @x64_8\n  CALL @x64_addr\n'

# BCOPY: esi=src edi=dst ecx=cnt.  memmove-safe, masks after every step.
bcopy = build([
    ('b', bytes.fromhex('23 34 25') + MASK.to_bytes(4, 'little')),
    ('b', bytes.fromhex('23 3c 25') + MASK.to_bytes(4, 'little')),
    ('b', bytes.fromhex('85 c9')),
    ('j', b'\x0f\x84', 'done'),
    ('b', bytes.fromhex('89 f8 29 f0')),
    ('b', bytes.fromhex('23 04 25') + MASK.to_bytes(4, 'little')),
    ('b', bytes.fromhex('39 c8')),
    ('j', b'\x0f\x82', 'back'),
    ('l', 'fwd'),
    ('b', bytes.fromhex('89 f0 c1 e0 03 05') + G.to_bytes(4, 'little')),
    ('b', bytes.fromhex('48 8b 10')),
    ('b', bytes.fromhex('89 f8 c1 e0 03 05') + G.to_bytes(4, 'little')),
    ('b', bytes.fromhex('48 89 10')),
    ('b', bytes.fromhex('ff c6 ff c7 ff c9')),
    ('b', bytes.fromhex('23 34 25') + MASK.to_bytes(4, 'little')),
    ('b', bytes.fromhex('23 3c 25') + MASK.to_bytes(4, 'little')),
    ('j', b'\x0f\x85', 'fwd'),
    ('j', b'\xe9', 'done'),
    ('l', 'back'),
    ('b', bytes.fromhex('8d 44 0e ff 89 c6')),
    ('b', bytes.fromhex('8d 44 0f ff 89 c7')),
    ('b', bytes.fromhex('23 34 25') + MASK.to_bytes(4, 'little')),
    ('b', bytes.fromhex('23 3c 25') + MASK.to_bytes(4, 'little')),
    ('l', 'bwd'),
    ('b', bytes.fromhex('89 f0 c1 e0 03 05') + G.to_bytes(4, 'little')),
    ('b', bytes.fromhex('48 8b 10')),
    ('b', bytes.fromhex('89 f8 c1 e0 03 05') + G.to_bytes(4, 'little')),
    ('b', bytes.fromhex('48 89 10')),
    ('b', bytes.fromhex('ff ce ff cf ff c9')),
    ('b', bytes.fromhex('23 34 25') + MASK.to_bytes(4, 'little')),
    ('b', bytes.fromhex('23 3c 25') + MASK.to_bytes(4, 'little')),
    ('j', b'\x0f\x85', 'bwd'),
    ('l', 'done'),
])

# BFILL: edi=dst ecx=cnt eax=value; writes mkword(value,10).
bfill = build([
    ('b', bytes.fromhex('23 3c 25') + MASK.to_bytes(4, 'little')),
    ('b', bytes.fromhex('85 c9')),
    ('j', b'\x0f\x84', 'done'),
    ('l', 'loop'),
    ('b', bytes.fromhex('89 c2')),
    ('b', bytes.fromhex('89 fe c1 e6 03')),
    ('b', bytes.fromhex('81 c6') + G.to_bytes(4, 'little')),
    ('b', bytes.fromhex('66 c7 06 7f f8')),
    ('b', bytes.fromhex('89 56 02')),
    ('b', bytes.fromhex('66 c7 46 06 f8 7f')),
    ('b', bytes.fromhex('ff c7 ff c9')),
    ('b', bytes.fromhex('23 3c 25') + MASK.to_bytes(4, 'little')),
    ('j', b'\x0f\x85', 'loop'),
    ('l', 'done'),
])

real = '''
; BCOPY d,a,b: copy R[b] words from R[a] to R[d], memmove-safe.
; r5=d r6=a r8=b.  esi=src edi=dst ecx=cnt.
x64_bcopy:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r5,r0
  ADD r10,r6,r0
  ADD r9,r8,r0
  ADD r5,r10,r0
  CALL @x64_load_eax_r
'''
real += EI('89 C6')
real += '''  ADD r5,r11,r0
  CALL @x64_load_eax_r
'''
real += EI('89 C7')
real += '''  ADD r5,r9,r0
  CALL @x64_load_eax_r
'''
real += EI('89 C1')
real += EI(bcopy)
real += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET

; BFILL d,a,b: fill R[b] words at R[d] with mkword(R[a],10)
x64_bfill:
  ST r15,r14,0
  ADD r14,r14,r13
  ADD r11,r5,r0
  ADD r10,r6,r0
  ADD r9,r8,r0
  ADD r5,r11,r0
  CALL @x64_load_eax_r
'''
real += EI('89 C7')
real += '''  ADD r5,r9,r0
  CALL @x64_load_eax_r
'''
real += EI('89 C1')
real += '''  ADD r5,r10,r0
  CALL @x64_load_eax_r
'''
real += EI(bfill)
real += '''  SUB r14,r14,r13
  LD r15,r14,0
  RET
'''

p = 'src/translate/x86_64.nas'
s = open(p).read()
if 'x64_bcopy:' not in s:
    s += real
open(p, 'w').write(s)
print('appended %d lines' % len(real.splitlines()))
