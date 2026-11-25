# Naming: S1, nan_cli, nan0s

These are separate layers and must not share a name.

| name | what it is | may be C? | product acceptance? |
|---|---|---|---|
| S1 | machine/ISA model: fetch, gate, execute, traps, ports, timer, regions | yes, hardware emulator only | it is the execution substrate |
| `s1_runner.sh` / `s1_kabi.c` | runner around the S1 machine model | yes, machine only | yes, when running NaN code |
| `nan_cli` | C command-line **oracle** and host test bench | yes | **no**; oracle evidence only |
| `nan0s` | the product OS image: NaN S1 machine, NaN kernel, NaN services | guest code must be NaN | yes |

S1 is not a CLI. Calling the machine model `nancli` would confuse the
hardware/ISA layer with the host command-line oracle, and would make it easy
to report oracle runs as product acceptance.

Likewise, `nan_cli` is not the product. Any gate that uses it must print
`ORACLE` (or `ORACLE MATCH`) and must not print product `PASS`. Product gates
run the same NaN image on `tools/s1_runner.sh` (or bare metal) and compare the
exact transcript there.

Oracle labelling is enforced by:

- `tools/nanproc_gate.sh`: refuses `nan_cli` as its runner, prints
  `ORACLE MATCH` and exits 77 without an S1 runner.
- `tools/nanthr_gate.sh`: prints `ORACLE PASS` and leaves x86_64 acceptance
  pending unless `NANTHR_X64_RUNNER` is set.
- `tools/cbare_gate.sh` / `cbare_fs_gate.sh` / `cbare_sqlite_gate.sh`: C is a
  guest program compiled to NaN; the services it calls are NaN.
