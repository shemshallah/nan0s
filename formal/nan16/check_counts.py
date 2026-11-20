#!/usr/bin/env python3
"""Independent computational check of the finite-lattice claims."""

from itertools import product


def main() -> None:
    n = 256
    cells = set(product(range(n), repeat=2))
    diagonals = {(a, a) for a in range(n)}
    pairs = {(a, b) for a in range(n) for b in range(a + 1, n)}
    canonical = pairs | diagonals
    mirror = lambda p: (p[1], p[0])

    assert len(cells) == 65536
    assert len(diagonals) == 256
    assert len(pairs) == 32640
    assert len(canonical) == 32896
    assert all(mirror(mirror(p)) == p for p in cells)
    assert {p for p in cells if mirror(p) == p} == diagonals
    assert pairs.isdisjoint({mirror(p) for p in pairs})
    assert cells == pairs | {mirror(p) for p in pairs} | diagonals
    assert len({256 * a + b for a, b in cells}) == 65536
    print("PASS: 65,536 cells, 256 diagonal, 32,640 mirror pairs, 32,896 canonical")


if __name__ == "__main__":
    main()
