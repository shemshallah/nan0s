#!/usr/bin/env python3
"""Generate a >16 MiB flat NaN16 cartridge for the x86_64 S1 large-image gate.

The guest sums the payload of every word in a 20+ MiB data region and compares
the result with a host-computed constant before printing BIG PASS.  A partial
or corrupt load cannot pass.  Usage: s1_big_guest_gen.py OUT.bin
"""
import hashlib
import struct
import sys

HEADS = (0x7FF1, 0xFFF1, 0x7FF8, 0xFFF8)
DATA_START = 0x1000
DATA_WORDS = 0x288000


def mkword(payload, n=10):
    far = HEADS[n & 3]
    near = HEADS[(n >> 2) & 3]
    return bytes((far >> 8, far & 0xFF)) + struct.pack("<I", payload & 0xFFFFFFFF) + bytes((near & 0xFF, near >> 8))


def ins(op, d=0, a=0, imm=0, n=15):
    return mkword((op << 24) | (d << 20) | (a << 16) | (imm & 0xFFFF), n)


def build():
    code = []
    labels = {}

    def label(name):
        labels[name] = len(code)

    def emit(word):
        code.append(word)

    # Program words 0..: sum DATA_WORDS payloads.
    emit(ins(0x01, 13, 0, 1))                 # r13 = 1
    emit(ins(0x01, 5, 0, 0))                  # r5 = sum
    emit(ins(0x01, 1, 0, DATA_START))         # r1 = ptr
    emit(ins(0x01, 2, 0, DATA_WORDS & 0xFFFF))
    emit(ins(0x02, 2, 0, DATA_WORDS >> 16))   # r2 = count
    label("sum_loop")
    emit(ins(0x08, 3, 1, 0))                  # LD r3,[r1]
    emit(ins(0x03, 5, 5, 3))                  # ADD r5,r5,r3
    emit(ins(0x29, 1, 1, 1))                  # ADDI r1,r1,1
    emit(ins(0x29, 2, 2, 0xFFFF))             # ADDI r2,r2,-1
    emit(ins(0x07, 0, 2, 0))                  # CMP r2,r0
    emit(ins(0x0A, 0, 0, 0, 3))               # JMP[NE] sum_loop (patched)
    jump_ne = len(code) - 1

    expected = 0
    for i in range(DATA_START, DATA_START + DATA_WORDS):
        expected = (expected + ((i * 2654435761 + 0x9E3779B9) & 0xFFFFFFFF)) & 0xFFFFFFFF
    emit(ins(0x01, 4, 0, expected & 0xFFFF))
    emit(ins(0x02, 4, 0, expected >> 16))     # r4 = expected sum
    emit(ins(0x07, 0, 5, 4))                  # CMP r5,r4
    emit(ins(0x0A, 0, 0, 0, 3))               # JMP[NE] fail (patched)
    jump_fail = len(code) - 1

    label("pass")
    emit(ins(0x01, 1, 0, 0))                  # MOVI r1,msg_pass (patched)
    msg_pass_at = len(code) - 1
    emit(ins(0x05, 1, 1, 2))                  # SHL r1,r1,2 (byte address)
    label("print_pass")
    emit(ins(0x2A, 2, 1, 0))                  # LDB r2,[r1]
    emit(ins(0x07, 0, 2, 0))                  # CMP r2,r0
    emit(ins(0x0A, 0, 0, 0, 4))               # JMP[EQ] done_pass (patched)
    eq_pass = len(code) - 1
    emit(ins(0x15, 2, 0, 0))                  # PUTC r2
    emit(ins(0x03, 1, 1, 13))                 # ADD r1,r1,r13
    emit(ins(0x0A, 0, 0, 0))                  # JMP print_pass (patched)
    jmp_print_pass = len(code) - 1
    label("done_pass")
    emit(ins(0xFF, 0, 0, 0, 15))              # HALT

    label("fail")
    emit(ins(0x01, 1, 0, 0))                  # MOVI r1,msg_fail (patched)
    msg_fail_at = len(code) - 1
    emit(ins(0x05, 1, 1, 2))
    label("print_fail")
    emit(ins(0x2A, 2, 1, 0))
    emit(ins(0x07, 0, 2, 0))
    emit(ins(0x0A, 0, 0, 0, 4))               # JMP[EQ] done_fail (patched)
    eq_fail = len(code) - 1
    emit(ins(0x15, 2, 0, 0))
    emit(ins(0x03, 1, 1, 13))
    emit(ins(0x0A, 0, 0, 0))                  # JMP print_fail (patched)
    jmp_print_fail = len(code) - 1
    label("done_fail")
    emit(ins(0xFF, 0, 0, 0, 15))

    def msg(words):
        out = []
        for i in range(0, len(words), 4):
            chunk = words[i:i + 4].ljust(4, b"\0")
            out.append(mkword(chunk[0] | (chunk[1] << 8) | (chunk[2] << 16) | (chunk[3] << 24), 10))
        return out

    msg_pass = len(code)
    code += msg(b"BIG PASS\n")
    msg_fail = len(code)
    code += msg(b"BIG FAIL\n")

    def patch(addr, value):
        w = bytearray(code[addr])
        w[2:4] = struct.pack("<H", value & 0xFFFF)
        code[addr] = bytes(w)

    patch(jump_ne, labels["sum_loop"])
    patch(jump_fail, labels["fail"])
    patch(eq_pass, labels["done_pass"])
    patch(jmp_print_pass, labels["print_pass"])
    patch(eq_fail, labels["done_fail"])
    patch(jmp_print_fail, labels["print_fail"])
    patch(msg_pass_at, msg_pass)
    patch(msg_fail_at, msg_fail)
    return code, expected


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: s1_big_guest_gen.py OUT.bin")
    code, expected = build()
    zeros = [mkword(0, 10)] * (DATA_START - len(code))
    data = []
    for i in range(DATA_START, DATA_START + DATA_WORDS):
        data.append(mkword((i * 2654435761 + 0x9E3779B9) & 0xFFFFFFFF, 10))
    blob = b"".join(code) + b"".join(zeros) + b"".join(data)
    with open(sys.argv[1], "wb") as f:
        f.write(blob)
    print("words %d bytes %d expected %08X sha256 %s" %
          (len(blob) // 8, len(blob), expected,
           hashlib.sha256(blob).hexdigest()))


if __name__ == "__main__":
    main()
