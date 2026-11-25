# Do not use the C model as the system

`aarch64/android/core/nan16.c` — and the `nan_cli` binary built from it — is a
**host C conformance/oracle model** of NaN16. It is useful, but it is **not**
the raw NaN/0S system and must never be used as a substitute for it.

## Allowed

- Running a raw NaN16 cartridge through `nan_cli` for fast functional
  triage, differential testing, fuzzing, or as an oracle.
- Comparing `nan_cli` output with the authoritative S1 run to find compiler,
  ABI, kernel, or VFS differences.
- Labeling such a result explicitly as **oracle**, never as product
  acceptance.

## Forbidden

- Treating `nan_cli` as the product runtime or as evidence for x86_64 S1
  bare-metal acceptance.
- Implementing missing NaN/0S, kernel, VFS, or device semantics first in
  `nan16.c` instead of the native/S1 implementation.
- Special-casing tests or cartridges in the C model so a product gate passes.
- Replacing an S1 gate with a `nan_cli` gate because the C model is easier to
  run.

## Authoritative execution

- Semantics: `spec/NANVM_SPEC.md` and the native/S1 implementation.
- Product gate: `tools/s1_runner.sh` running the **exact raw cartridge** on
  x86_64 S1 (QEMU S1 is the CI stand-in for S1 hardware).
- The SQLite/Tcl fixture is raw NaN16; host `tcc0` only compiles it.

If you are an AI agent: before using `nan_cli` for anything that will be
reported as a pass, check this file and say which engine produced the result.
