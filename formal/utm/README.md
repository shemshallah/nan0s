# NaN0S formal UTM / NaN16 system proof

This tree is the consolidated NaN0S system-facing Coq development.  It is
the dependency cone of:

- `MinskyNaN16Universality.v` — the certified Coq NaN16 VM halting
  equivalence with the fixed 23x8 Minsky table;
- `MinskyNaN16LiteralRun.v` — the 21,025-instruction literal fixture run;
- `MinskyNaN16LiteralBridge.v` — the literal-image / Coq-VM table,
  control-cell and reset-relation bridge.

The full cone is 115 modules.  The fixed-UTM `UTMEquivalence.v` and the
research/memo files that are not in this dependency cone are intentionally
not copied.

## Build

Requires Coq 8.20 with `coq_makefile`:

```sh
cd formal/utm
make
make check
```

`make check` runs `coqchk` on the universality, literal-run and bridge
certificates.

## Data and gates

- `tests/minsky_table.inc` — frozen 184-row table;
- `mth/tests/mth_minsky_test.nas` and the encoded/compiler fixtures;
- `formal/utm/data/` — literal image dumps;
- `formal/utm/check_*.py` — independent source/byte gates (not proofs).

## Scope

This is a Coq proof of the modeled NaN0S/NaN16 system, not a proof of the
compiled C++ implementation.  The remaining system obligations are the
literal executor step simulation, the loader/assembler semantics, the
finite-memory/unbounded-tape bridge and the native allocator/runtime
refinement.
