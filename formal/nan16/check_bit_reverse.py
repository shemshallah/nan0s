#!/usr/bin/env python3
"""Exhaustive independent check of the physical 16-bit mirror encoding."""


def reverse_bits(x: int, width: int) -> int:
    y = 0
    for _ in range(width):
        y = (y << 1) | (x & 1)
        x >>= 1
    return y


def encode(a: int, b: int) -> int:
    return (a << 8) | reverse_bits(b, 8)


def main() -> None:
    encoded = set()
    fixed = 0
    for a in range(256):
        for b in range(256):
            physical = encode(a, b)
            encoded.add(physical)
            mirrored = reverse_bits(physical, 16)
            assert mirrored == encode(b, a), (a, b)
            assert reverse_bits(mirrored, 16) == physical
            fixed += mirrored == physical
    assert len(encoded) == 65536
    assert fixed == 256
    print("PASS: 16-bit reversal swaps coordinates; 65,536 bijective encodings, 256 fixed")


if __name__ == "__main__":
    main()
