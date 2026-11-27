# ngold - F18 source-derived GOLD without a C producer

Status: **implemented and gated**. `tools/source_gold_gate.sh` prints exactly
`O` as its final marker. The GOLD for `src/native/nan16_x86.nan` is rebuilt by
nasm1 on the native NaN16 core under bare QEMU; a second, independent path runs
nasm1 under the raw-NaN `n16i` interpreter and reproduces the 512-byte boot
region byte-for-byte. `nan_cli` is an optional byte comparator only; it is
never the producer.

The stale xgold row count is fixed: at the F18 baseline (commit `592df0e`) the
checked-in GOLD has 32 boot rows and **620** kernel rows for a 9913-byte
kernel, not the old 532 rows (532 x 16 = 8512 bytes, an older kernel).
`tools/xgold_gate.sh` and `tools/source_gold_gate.sh` now derive the count
from the GOLD header (`ceil(kernel_bytes/16)`) instead of pinning a constant.
That derivation follows the source: the concurrent F16 manifest work in the
shared worktree grows the same kernel to 11701 bytes, i.e. 732 rows.

## What is source-derived

### 1. Full 32-bit GOLD: `src/native/nan16_x86.nan`

`tools/xgold.sh` stages `x86/boot/kboot0.xa` and `src/native/kan16.xa` as
nasm1 inputs, boots the checked-in GOLD boot sector + native kan16 core on
QEMU (`qemu-system-i386`), reads the emitted bytes from COM1, and writes the
GOLD text. There is no C compiler, no Python and no `nan_cli` in this path.

The gate regenerates the GOLD and requires byte equality with the checked-in
files:

```
; NaN16 gold: boot 512 + kernel 9913 bytes (native S1 rebuild)
sha256 c9a657b98d3c76079d3f7224469032d364f200d5866b45f8a2432b53f4a4c82e
32 boot rows + 620 kernel rows; 512 + 9913 = 10425 bytes
```

`src/native/nan16_x86.nan` and `x86/native/nan16_x86.nan` are identical.

### 2. Raw n16i boot slice: nasm1 under `src/tools/n16i.nas`

The same nasm1 source (`src/prog/nasm1.nas`) and the same input
(`x86/boot/kboot0.xa`) are staged as a guest. A NaN driver embeds
`src/tools/n16i.nas`, relocates the nasm1 guest to word 0x21000 and calls
`n16i_run` with guest base 0x21000 and mask 0x3FFFF. The driver itself runs on
the native kan16 core under QEMU; n16i interprets nasm1 entirely in NaN.

The boot sector path is:

```
x86/boot/kboot0.xa (1870 bytes)
  -> nasm1 (NaN) under n16i (NaN) under native kan16 (QEMU i386, no C)
  -> 'Y' '\n' + 512 emitted bytes + 'OK' '\n'
```

Results:

```
inner guest: nasm1 + kboot0.xa at 0x20000, 131540 words
n16i driver: 266708 words; interpreted guest base word 135168
n16i slice: 512/512 boot GOLD bytes match
slice sha256 872cf951bed4e046c838f5e11fab60d0e62684cdad0d7d4672485dc6bf5ff5c6
517-byte serial stream (2 + 512 + 3); marker OK
native n16i vs nan_cli comparator: MATCH (517/517 bytes)
```

The slice takes about 36 s on this Termux host (QEMU TCG, `-m 64`). The full
9913-byte kernel is not run under n16i in the gate; the honest blocker is
measurement, not an opcode gap. nasm1 uses only n16i-covered core opcodes, and
the full `src/native/kan16.xa` run under n16i (inside the C outer box, used only
to count) emits exactly the GOLD kernel:

```
inner full kernel guest 144248 words
driver 279416 words
oracle serial 9918 bytes
outer steps 1125205921          # 1.125B native steps for the full kernel
oracle full kernel: MATCH
slice sha256 7ec62a2aad0d95807a4462b8638a3d5b5ed6557b5d3c34114490b6b451efb8c3
```

The boot slice executes about 25.6M outer steps in 36 s on native QEMU. The
full kernel was also run end-to-end under raw n16i on native QEMU with the same
construction now exposed as `SOURCE_GOLD_FULL_N16I=1`: it produced 9918 serial
bytes in **621 s** and matched the GOLD kernel 9913/9913 bytes
(sha256 `7ec62a2aad0d95807a4462b8638a3d5b5ed6557b5d3c34114490b6b451efb8c3`).
So the full translator is source-derived under n16i today; it is simply too
slow for the default gate (621 s vs the 36 s boot slice and the 300 s default
poll budget). The default gate uses the native-core producer for the full GOLD
and the n16i path for the boot 512-byte region; the full-kernel native n16i
path is an explicit optional run, not a correctness gap.

### 3. x86-64 GOLD (extra, same C-free producer shape)

`tools/xgold64.sh` previously executed nasm1 through `nan_cli`. It now uses the
same native QEMU path: the source-derived 32-bit GOLD boot sector + kan16 core
run nasm1, and the guest comes from IDE LBA 129. `nan_cli` remains only an
optional comparator that writes `$T/nc.ser`; the producer's serial is
`$T/ser`.

```
$ sh tools/xgold64.sh
xgold64: boot 512 + kernel 20038 bytes
sha256 be137593b3673a28b8711bb5b3ab05e92a34f73e1f0a9667bd9ee841daa7c77d
32 boot rows + 1253 kernel rows
```

The checked-in `src/native/nan16_x64.nan` is byte-identical to this rebuild.
This removes the last `nan_cli` producer from the GOLD build chain.

## What is oracle-only

- `nan_cli` is used in `tools/source_gold_gate.sh` (step 5) only to compare
  the native QEMU serial stream with the C oracle's stream. It is skipped when
  the binary is absent and can be disabled with `SOURCE_GOLD_NO_ORACLE=1`.
  It never writes the GOLD.
- `tools/xgold64.sh` keeps the same optional comparator (`$T/nc.ser`); a
  missing `nan_cli` skips it.
- The native kan16 core that executes nasm1 is itself part of the checked-in
  GOLD. `xgold.sh` is therefore a reproducible **fixpoint** check (the running
  core re-emits its own boot and kernel bytes), not a formal proof that the
  assembler is correct. The n16i slice adds a second execution path for the
  boot region; n16i equivalence to the native core is tested, not proved.
- No Coq theorem is claimed. No independent encoder yet cross-checks the
  emitted bytes; that is a frontier item.

## Shared-worktree note (F16 interference)

The shared worktree also carries concurrent, uncommitted F16 manifest work:
`src/native/kan16.xa` gained `man_verify_pre`/`man_verify_guest`, and
`tools/xgold.sh` now stages a manifest with `tools/manifest_build.sh`. At the
time of this F18 run that manifest check rejected synthetic guest images with
`!MAN` (the kernel digest covers the manifest sector itself), so the F18 gate
was run in a clean detached worktree at the dispatch baseline
`592df0e041feae8ce4a0267f566dc9e27993a012`. The gate itself is F16-aware: it
derives the row count from the header and calls `manifest_build.sh` when the
tool exists. The F16 kernel change does not change the boot 512 bytes, so the
F18 raw-n16i slice is unaffected once F16's manifest digest is corrected.

## Stale-count fix, exactly

`tools/xgold_gate.sh` used:

```
grep -c '; kernel+' ... -eq 532
```

At the F18 baseline the GOLD has 620 kernel rows. The old 532-row grid
corresponds to an 8512-byte kernel; the F18 kernel is 9913 bytes. The gate now
reads the kernel byte count from the first GOLD line, computes
`want=$(( (kernel_bytes + 15) / 16 ))`, and requires `have == want`. It also
verifies that the grid contains exactly `512 + kernel_bytes` bytes. A source
change therefore changes the expected row count automatically; the old 532
constant can never silently return. (The concurrent F16 work now derives 732
rows from 11701 bytes through the same rule.)

## Exact commands and results

The traces below were run in a clean detached worktree at the dispatch
baseline `592df0e041feae8ce4a0267f566dc9e27993a012`, because the shared
worktree carried the concurrent F16 manifest changes described above. The
gate files are identical in both worktrees.

Full source-derived gate (regenerates the GOLD, runs the n16i slice):

```
$ sh tools/source_gold_gate.sh
== 1. producer provenance (no C oracle in the GOLD path) ==
producer: tools/xgold.sh + tools/mkimg.awk + QEMU native kan16 only; nan_cli/compiler/Python absent
xgold64 producer: native QEMU nasm1; nan_cli only writes the optional nc.ser comparator
== 2. full GOLD regeneration (nasm1 on native kan16, QEMU) ==
xgold: boot 512 + kernel 9913 bytes (no C/Python)
checked-in GOLD == native xgold.sh rebuild: c9a657b98d3c76079d3f7224469032d364f200d5866b45f8a2432b53f4a4c82e
== 3. GOLD grid and the stale row-count fix ==
GOLD grid: 32 boot + 620 kernel rows (9913 kernel bytes; old 532 expectation removed)
== 4. raw n16i slice: nasm1 assembles x86/boot/kboot0.xa under n16i ==
inner guest: nasm1 + kboot0.xa at 0x20000, 131540 words
n16i driver: 266708 words; interpreted guest base word 135168
n16i slice: 512/512 boot GOLD bytes match; slice sha256 872cf951bed4e046c838f5e11fab60d0e62684cdad0d7d4672485dc6bf5ff5c6; marker OK
== 5. optional nan_cli comparator ==
nan_cli comparator: MATCH (517/517 bytes; oracle only, not a producer)
source_gold_gate: PASS (raw n16i assembles the 512-byte boot GOLD; native xgold.sh reproduces the checked-in 512+9913 GOLD; rows 32+620)
O
```

Fast form (skips the 6-minute native xgold.sh rebuild, still runs the raw n16i
slice and the GOLD grid checks):

```
$ SOURCE_GOLD_FAST=1 sh tools/source_gold_gate.sh
== 1. producer provenance (no C oracle in the GOLD path) ==
producer: tools/xgold.sh + tools/mkimg.awk + QEMU native kan16 only; nan_cli/compiler/Python absent
xgold64 producer: native QEMU nasm1; nan_cli only writes the optional nc.ser comparator
== 2. full GOLD regeneration (nasm1 on native kan16, QEMU) ==
SKIP tools/xgold.sh (SOURCE_GOLD_FAST=1): checked-in GOLD used as-is, not re-derived
== 3. GOLD grid and the stale row-count fix ==
GOLD grid: 32 boot + 620 kernel rows (9913 kernel bytes; old 532 expectation removed)
== 4. raw n16i slice: nasm1 assembles x86/boot/kboot0.xa under n16i ==
inner guest: nasm1 + kboot0.xa at 0x20000, 131540 words
n16i driver: 266708 words; interpreted guest base word 135168
n16i slice: 512/512 boot GOLD bytes match; slice sha256 872cf951bed4e046c838f5e11fab60d0e62684cdad0d7d4672485dc6bf5ff5c6; marker OK
== 5. optional nan_cli comparator ==
nan_cli comparator: MATCH (517/517 bytes; oracle only, not a producer)
source_gold_gate: PASS (raw n16i assembles the 512-byte boot GOLD; checked-in GOLD grid 32+620; full xgold.sh skipped by SOURCE_GOLD_FAST=1)
O
```

x86-64 GOLD rebuild:

```
$ sh tools/xgold64.sh
words 131540
image: boot 512 kernel 9913 guest 131540 words
words 144841
image: boot 512 kernel 9913 guest 144841 words
xgold64: boot 512 + kernel 20038 bytes
```

The run takes about 6m15s on this host (two QEMU assembly stages). The
checked-in file's sha256 is unchanged:
`be137593b3673a28b8711bb5b3ab05e92a34f73e1f0a9667bd9ee841daa7c77d`.

The optional gate branch that rebuilds it (fast 32-bit path, then x86-64):

```
$ SOURCE_GOLD_FAST=1 SOURCE_GOLD_64=1 sh tools/source_gold_gate.sh
...
== 6. x86-64 GOLD regeneration (nasm1 on native kan16, QEMU) ==
xgold64: boot 512 + kernel 20038 bytes
checked-in x86-64 GOLD == native xgold64.sh rebuild: be137593b3673a28b8711bb5b3ab05e92a34f73e1f0a9667bd9ee841daa7c77d
source_gold_gate: PASS (raw n16i assembles the 512-byte boot GOLD; checked-in GOLD grid 32+620; full xgold.sh skipped by SOURCE_GOLD_FAST=1)
O
```

Regressions:

```
$ sh tools/nverify_gate.sh
...
qgate64prog: PASS (NaN 3-block loop -> native dispatch, r1=3, XPC=5)
...
no_c_outside_tests: PASS (src outside src/tests is C-free)
nverify: PASS (reproducible emission, translator goldens, native/n16i trace, block gate, non-ELF image, C-free source)
O

$ sh tools/n16i_kabi_gate.sh
n16i_kabi: PASS (n16i custom NaN ABI: SVC/SVCRET, control words, guest kernel)

$ sh tools/qgate64core.sh
qgate64core: PASS (NaN translator -> x86-64 block -> native execution, r1=84)

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/xgold_gate.sh
...
xgold: boot 512 + kernel 9913 bytes (no C/Python)
xgold_gate: PASS (native S1 assembles the gold core; no C, no Python)
```

## Frontier ideas

1. **Proof-carrying GOLD.** Add a manifest that hash-chains the boot, kernel
   and guest regions, signs it, and verifies it in the native boot path before
   the first guest fetch. Gate a one-byte mutation in each region and fail
   closed before any code runs.
2. **Raw n16i self-host for the full kernel.** The full path now exists as
   `SOURCE_GOLD_FULL_N16I=1`: nasm1 over all of `src/native/kan16.xa` under
   n16i matched 9913/9913 bytes in 621 s on native QEMU. Decide whether that
   ~10-minute path becomes the default proof or the 36 s boot slice stays the
   default, and shrink the nested-interpreter overhead so the full path fits a
   normal gate budget.
3. **Deterministic, parallel-safe GOLD builds.** Replace the fixed
   `src/prog/_xgold_h.nas` / `_xgold64_h.nas` staging names with unique
   temporaries, add a lock around QEMU serial capture, and gate two concurrent
   reconstructions to byte-identical GOLD. The current QEMU runs idle until
   `timeout`; polling the serial file (as `source_gold_gate.sh` does) also cuts
   the gate wall time.
4. **Independent encoder.** Cross-check the boot sector with a second NaN
   emitter (nasm0 or a table-driven encoder) or a bit-vector equivalence
   checker, so the GOLD is validated against something other than the same
   nasm1 source and the optional C oracle.

## Commands

```
sh tools/source_gold_gate.sh                       # full, ~7 min
SOURCE_GOLD_FAST=1 sh tools/source_gold_gate.sh    # ~36 s, no xgold.sh
SOURCE_GOLD_FULL_N16I=1 sh tools/source_gold_gate.sh  # + full kernel under n16i, ~621 s
SOURCE_GOLD_64=1 sh tools/source_gold_gate.sh      # also rebuilds x86-64 GOLD
sh tools/xgold64.sh                                # native x86-64 GOLD rebuild
sh tools/xgold_gate.sh                             # native xgold row/grid gate
```
