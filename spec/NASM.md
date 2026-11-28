# nasm: one assembler, two modes

Status: merged 2026-11-27.

`src/prog/nasm.nas` is the single assembler implementation. The old
`nasm0.nas` and `nasm1.nas` names are compatibility aliases that include it.

## Modes

- **NaN mode (z0)**: caller sets `V_SRCB`, `V_OUTB`, `V_LABB`, `V_EXPB`,
  `V_EXPCB`, `V_PASS`; calls `run` twice. Used by the NANIX shell's `asm`
  command and the `nasm0` self-host tests. `V_*` stay at 6272.
- **x86 mode (x1)**: the image starts at 0 with `JMP @x1__start`; uses the
  fixed `SRC=0x20000`, `OUT=0x100000`, `LAB=0x140000`, `STACK=0x1F0000`
  layout and emits x86 bytes. Used by `xgold.sh`, `xgold64.sh`, `pae16_asm.sh`
  and the n16i source-gold slice.

The x86 backend is namespaced `x1_*`/`Z1_*`; the NaN backend keeps `run` and
`V_*` so existing self-host sources keep working.

## Verification

- x86 boot sector: byte-identical to the pre-merge nasm1 output.
- `tools/xgold.sh`: GOLD match, 18.3 s through the block cache.
- `tools/blockcache_gate.sh`: PASS, 3,913-word cache, boot 512/512 and kernel
  12,368/12,368.
- `tools/source_gold_gate.sh`: PASS in 73.7 s including the raw n16i slice.
- `tools/nhost_gate.sh`: PASS, three phases: the `nrun_test` tree (4,842
  words), nhost assembling itself (4,532 words, exact fixed point), and the
  full 51-file product guest (530,842 words, exact `nmk.awk` stream).
- `tools/nhost_product_gate.sh`: ORACLE MATCH; the nhost-emitted guest packs
  to the shipped `build/nan0s.img` byte-for-byte.
- `tools/native_nhost_gate.sh`: PASS phase 1, nhost self-host on the raw native
  NaN16 core in 17 s (QEMU, no `nan_cli`, no S1 KABI).  Phase 2 is the
  opt-in full 530,842-word native run (`NHOST_NATIVE_FULL=1`).
- `tools/nixsh_asm_gate.sh`: PASS, in-shell `asm` assembles an
  operand/.equ/#K/label source and n16i runs it.
- `src/tests/nrun_test.nas`: `HI` / `RUN PASS` after the merge.

## nhost and the full-guest label table (2026-11-27)

`src/prog/nhost.nas` expands `.include` correctly.  The bug was the second
word of the `.include` matcher: `0x65646C75` spells `ulde`, not `lude`.  With
`0x6564756C`, `tools/nhost_gate.sh` phase 1 matches the `nrun_test` tree.

The full `gui_sched_boot.nas` tree (51 files) is 530,842 words.  The old label
table stored one 32-bit djb2 hash plus a value, so two of the ~10k labels
collided and resolved to the wrong target.  The table is now three words per
entry: two independent 32-bit hashes (djb2 and `h2 = h2*129 + c`) and the
value.  `V_H2`/`V_H2S` carry the second hash through `.equ` expressions; the
static mnemonic/directive tables keep the cheap single-hash scan.

`nmk.awk` keys labels by full name, so a name defined twice keeps its **last**
definition.  `llook` now scans the label table newest-first to reproduce that
semantics without a second name buffer.  This exposed a real guest bug:
`tn_d` in `src/lib/libcx.nas` overwrote nasm's decimal-parser loop `tn_d`, so
`JMP[NE] @tn_d` landed in libcx's `DIV` and hung in-shell assembly on any
numeric operand.  The libcx loop is now `cx_tn_d`; the in-shell `asm` command
assembles operands and labels and runs the result.

Two encoder differences were also brought into line with `nmk.awk`:

- `LD`/`ST` with a `0xF0000..0xF0FFF` immediate and base `r0` become
  `LDS`/`STS` with the offset reduced by `0xF0000`.
- `JMP`/`CALL` with a target above 16 bits become `JMPF`/`CALLF`, carrying a
  24-bit `d:a:imm` target.

The full guest now assembles under `nhost` with 0 errors and is byte-identical
to `nmk.awk` (same 530,842 words, SHA-256 match, ~34 s).
`tools/nhost_bundle.awk` builds the flat `;@MAIN`/`;@FILE` disk bundle.

`nhost` also assembles its own source to the same 4,532-word image: stage0 is
built with `nmk.awk`, then stage1 is the fixed point.  `tools/nhost_emit_guest.sh`
runs stage0 -> stage1 -> guest; the default `tools/build.sh` path remains
hermetic, and `NHOST_BUILD=1` selects the nhost guest.  `nhost_product_gate.sh`
packs that guest and compares the result to `build/nan0s.img`.

`nan_cli` is still the fast bootstrap machine for the default build.  The
native core now runs the same nhost image directly: it boots the product boot
sector + GOLD kernel, loads nhost from LBA 129, and nhost reads the source
bundle from LBA 2048 after its LBA-0 probe finds boot sectors instead of
`;@MAIN`.  Native self-host is 17 s; the full guest is an opt-in long run.
Making the native core the default producer needs a faster full-guest path
(or a native in-product build), not a different assembler.
