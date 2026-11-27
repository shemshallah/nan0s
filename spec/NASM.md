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
- `tools/xgold.sh`: GOLD match, 15.4 s through the block cache.
- `tools/blockcache_gate.sh`: PASS, 3,817-word cache, boot 512/512 and kernel
  12,368/12,368.
- `tools/source_gold_gate.sh`: PASS in 73.7 s including the raw n16i slice.
- `src/tests/nrun_test.nas`: `HI` / `RUN PASS` after the merge.

The in-shell `asm` command remains experimental: it assembles a `HALT`-only
source, but operand-bearing sources still hang in the shell process context.

## nhost and the full-guest label limit (2026-11-27)

`src/prog/nhost.nas` now expands `.include` correctly.  The bug was the second
word of the `.include` matcher: `0x65646C75` spells `ulde`, not `lude`.  With
`0x6564756C`, `tools/nhost_gate.sh` PASSES: the `nrun_test` tree assembles to
the exact 4,746-word stream `nmk.awk` produces.

The full `gui_sched_boot.nas` tree (51 files) assembles under `nhost` to
530,842 words, 0 errors, in 34 s.  It diverges from `nmk.awk` at guest word
1152.  The cause is the NaN label table: `nasm0` stores only a 32-bit djb2
hash plus value, and the full guest has 10,251 labels.  The first hash
collision resolves to the wrong label, so `JMP[NE]` targets 0x0485 instead of
0x54DC.

The next assembler change is a collision-proof label table: either the label
name (pointer/length and compare on hash hit) or a 64-bit hash stored beside
the value.  The static mnemonic/directive tables can keep the 32-bit hash
because their entries are unique; the source-label table cannot.
