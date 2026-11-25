# Raw NaN only

The shipped guest system is raw NaN16:

- `src/prog/` - programs, kernels, loaders, allocators
- `src/lib/` - runtime, filesystem, ATA, math, compiler support
- `src/museum/`, `src/exhibits/` - exhibits
- `src/dbg/` - debug core
- `src/tools/` - guest tools such as the disassembler

Those directories contain `.nas` source and generated `.nan` word text.
They must not gain C, C++, Python, Rust, or any other foreign-language
implementation. Kernel features, syscalls, scheduling, signals, loaders,
drivers, and process policy are implemented in NaN16 assembly and executed by
the VM.

Host-side C and Python are not guest system code:

- `aarch64/android/core/` is the portable conformance oracle.
- `aarch64/android/tests/` is the oracle test suite.
- `src/native64/s1_kabi.c` is a host-target ABI-mechanics slice.
- `tools/*.py` and the shell gates generate fixtures and verify transcripts.

These may be used to verify behavior, but they must not become the only
implementation of a system feature. Every new system feature needs its raw
NaN implementation and a gate that runs that implementation.

`tools/raw_only_gate.sh` enforces the source-directory boundary.
