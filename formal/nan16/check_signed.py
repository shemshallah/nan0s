#!/usr/bin/env python3
"""Exhaustive bijection check for the S+/S- orientation model."""


def main() -> None:
    seen: set[tuple[int, int]] = set()
    upper_count = 0
    for a in range(256):
        for b in range(a + 1, 256):
            upper_count += 1
            positive = (a, b)
            negative = (b, a)
            assert positive != negative
            assert positive not in seen
            assert negative not in seen
            seen.add(positive)
            seen.add(negative)

    expected = {(a, b) for a in range(256) for b in range(256) if a != b}
    assert upper_count == 32640
    assert len(seen) == 65280
    assert seen == expected
    print("PASS: 32,640 canonical pairs x two signed orientations = 65,280 distinct cells")


if __name__ == "__main__":
    main()
