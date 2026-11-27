# nverify — F14 reproducible builds, translation validation, UTM/Coq gate

Status: **implemented and gated for the reproducible/translation checks**.
`tools/nverify_gate.sh` emits exactly `O` as its final marker. The gate is
deterministic and currently runs in about 10 s on the Termux host without
Coq. Coq is absent, so the UTM kernel branch prints `COQ SKIP`; no Coq
theorem is claimed here.

## What F14 actually verifies

### 1. Reproducible assembler emission

The gate emits `src/tests/xlate64_test.nas` three times: twice normally and
once under `env -i PATH=... LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1`. All three
`.nan` texts are byte-identical (sha256
`cfd7d8df87469ba3cca7d42afdd50fe7bd121ce0ea86e227b532eb887793451c`).
It also emits `src/tests/xlate64_prog.nas` twice; both are byte-identical
(sha256 `c916f7d5a8f1a9ac71194cd5f21cab83b73e1b2790c5a3feb1d44876e7254ded`).

The emitted text and translated bytes are scanned for date/time strings,
`/tmp/`/`TMPDIR`, `SOURCE_DATE_EPOCH`, `@NAME@` placeholders and
UUID-shaped strings. None are present in this fixture.

### 2. Translator determinism and small hand-derived goldens

`xlate64_test.nas` emits `MOVI r1,42; ADD r1,r1,r1; XPC=0; RET`. The gate
extracts exactly 46 bytes and compares them against a hand-derived x86-64
sequence:

```
c70425040005002a0000008b0425040005008b0c250400050001c8
89042504000500c704250008050000000000c3
```

The three-block `xlate64_prog.nas` image is emitted twice and compared
byte-for-byte. Blocks are trimmed at the last `RET` (the same rule as
`qgate64prog`): 34 / 133 / 12 bytes. Block0 (`MOVI r1,0; MOVI r2,3; XPC=2;
RET`) and block2 (`HALT`) are compared against hand-derived bytes. Block1 is
the loop block; its bytes are checked for determinism and pinned by sha256
`996819f00f969d21f11b299887a9e901fe1a540c28faa5b15a2e8e7598edf980`.
The combined translated image sha256 is
`08e4daaccdb147c3b03d4f767e932e27022611939c422f796c890e9e8b995f8d`.

### 3. Native NaN16 vs raw-NaN n16i differential (replay)

`src/tests/nverify_prog.nas` runs natively on the C core (mode 0) and under
the raw-NaN `src/tools/n16i.nas` interpreter (mode 1). The guest computes a
32-step integer series, writes 32 trace words at guest word 8256 and prints
`NV` plus the final 32-bit accumulator.

Both paths produce the same serial line and the same 32-word trace:

```
native: 500 steps | n16i: 25480 steps
serial/trace identical: NV795834D4
trace sha256 6bc85bd3dcdbc7d891bfc08c1fc6301e6f283b5a3ebef5d86e1916f0b79af743
```

The gate also checks that mode 1 took more steps than mode 0, so the
interpreter path was actually exercised rather than silently falling back.
The serial checksum is required to equal the last trace word. Each mode is
then replayed a second time and the complete stdout (serial + trace) must be
byte-identical.

### 4. Native block path

`tools/qgate64prog.sh` still emits `NAN64 CORE 00000003 XPC 00000005 OK` on
QEMU (`qgate64prog: PASS`). This is the x86-64 block-path check; it is a
different ISA from the n16i fixture, so no cross-ISA architectural
comparison is claimed.

### 5. Product image and source rule

- `build/nan0s.img` is checked by magic (`fa31c08e`), not ELF (`7f454c46`);
  `build/base.img` is checked the same way.
- `tools/no_c_outside_tests.sh` must print `PASS`.
- The translated block is also checked not to start with ELF magic.

### 6. Coq / UTM

Coq is **not installed** on this host (`coqc`, `coqtop`, `coqchk` and
`coq_makefile` are all absent). The gate prints:

```
COQ SKIP (no coqc/coq_makefile on PATH; formal/utm not kernel-checked here)
COQ not run: (cd formal/utm && make) ; make check
```

It then runs three Python anchors from `formal/utm`:

- `check_nan16_literal_image.py` — 11 checks pass; the generated Coq
  `literal_image` list is anchored to the assembled `.nan` image and the
  pinned word dump. This is a source/byte anchor, **not** a Coq kernel run.
- `check_minsky_table.py` — `184/184` Minsky table entries transcribed.
- `check_minsky_nan16_step.py` — source-text gate for the step/run theorem
  statements; it explicitly says it is not a VM refinement certificate.

If `coqc` and `coq_makefile` are present, the gate copies
`formal/utm/LiteralImageData.v` to a temporary directory and runs
`coqc -Q . NaNLM LiteralImageData.v`, i.e. a targeted kernel check of
`literal_image_length` only. That branch was **not exercised on this host**
because Coq is absent. It does **not** build the 115-module UTM cone and
does **not** claim `MinskyNaN16Universality` here.

## What is oracle-only

- The C core behind `nan_cli` is the execution oracle for the native mode.
  It is not verified. The n16i interpreter is raw NaN, but its equivalence to
  the C core is tested by this differential, not proved.
- The translator is not proved correct. Only the 46-byte test block and the
  two simple program blocks have hand-derived byte goldens; block1 is a
  regression pin, not a proof.
- `qgate64prog` is a QEMU execution check. It does not formally connect the
  NaN encoder to x86-64 semantics.
- The Python UTM checks are independent source/byte gates. They do not
  substitute for `coqc`/`coqchk`.
- The ELF check is a magic check, not a full image audit.
- The default gate does not rebuild the whole product image. The checked-in
  `build/nan0s.img` is `a55de56c...`; a manual double rebuild with
  `sh tools/mkall.sh` produced the same image sha256 twice at the time of
  this report
  (`46c8be476418d52d640ebbe029f4f428498b975fb8fa8313f9f154261596fd8b`),
  but that rewrites the tracked `build/nan0s.img`, so it is left out of the
  default gate and listed as a frontier item.

## Files

| file | role |
|---|---|
| `tools/nverify_gate.sh` | reproducible emission, translator goldens, native/n16i trace differential, block gate, Coq/UTM anchors, ELF + C-free checks |
| `src/tests/nverify_prog.nas` | deterministic NaN16 guest fixture (32-word trace + serial checksum) |
| `spec/agents/nverify.md` | this report |

Five `(nverify)` directives were appended to `spec/MASTER_TASKLIST.md` with
`sh tools/tasklist_append.sh nverify "..."`.

No C was added outside `src/tests`. No shared library was modified. No
`nspec`/`npaged` file was touched.

## Exact gate output

```
$ sh tools/nverify_gate.sh
== 1. reproducible nmk emission ==
xlate64_test.nan sha256 cfd7d8df87469ba3cca7d42afdd50fe7bd121ce0ea86e227b532eb887793451c (3 emissions identical)
xlate64_prog.nan sha256 c916f7d5a8f1a9ac71194cd5f21cab83b73e1b2790c5a3feb1d44876e7254ded (2 emissions identical)
== 2. timestamp/entropy marker scan ==
emitted NaN text: no date/time/tmp/UUID/build markers
== 3. translator re-emit and golden bytes ==
xlate64_test block: 46 bytes == hand-derived golden
blocks: 34/133/12 bytes; block0+block2 hand-derived, block1 sha256 996819f00f969d21f11b299887a9e901fe1a540c28faa5b15a2e8e7598edf980
translated image sha256 08e4daaccdb147c3b03d4f767e932e27022611939c422f796c890e9e8b995f8d (2 runs identical)
translated bytes: no timestamp/entropy markers
== 4. native vs n16i differential (nverify_prog) ==
native: 500 steps | n16i: 25480 steps | trace sha256 6bc85bd3dcdbc7d891bfc08c1fc6301e6f283b5a3ebef5d86e1916f0b79af743
serial/trace identical: NV795834D4
replay: native and n16i each byte-identical across 2 runs
== 5. native block path ==
blocks 34 133 12
qgate64prog: PASS (NaN 3-block loop -> native dispatch, r1=3, XPC=5)
== 6. Coq / UTM ==
COQ SKIP (no coqc/coq_makefile on PATH; formal/utm not kernel-checked here)
COQ not run: (cd formal/utm && make) ; make check
all 11 checks passed
MINSKY TABLE TRANSCRIPTION PASS (184/184 entries)
NAN16 STEP/RUN100 TRANSCRIPTION PASS (source-text gate only; not a VM refinement certificate)
== 7. product image and source rule ==
build/nan0s.img: 4311040 bytes, magic fa31c08e (not ELF)
build/base.img: 1474560 bytes, magic fa31c08e (not ELF)
product image: no timestamp/entropy markers
no_c_outside_tests: PASS (src outside src/tests is C-free)
nverify: PASS (reproducible emission, translator goldens, native/n16i trace, block gate, non-ELF image, C-free source)
O
```

## Regressions run

```
$ sh tools/qgate64core.sh
qgate64core: PASS (NaN translator -> x86-64 block -> native execution, r1=84)

$ sh tools/n16i_kabi_gate.sh
n16i_kabi: PASS (n16i custom NaN ABI: SVC/SVCRET, control words, guest kernel)

$ sh tools/nreplay_gate.sh
O
```

`tools/ngate_n16i.sh` was also run. Its suite and nested cases pass, but on
this HEAD its two trap cases report `MISMATCH`: the native bad-op case runs
to the 4e9-step cap (the fixture word is opcode `0x1C`, which the current
`nmk` table defines as `LDS`, while n16i traps it as `!O`), and the gate-trap
case reports trap/pc text `!G2158` natively versus `!G0158` under n16i. F14
does not touch `n16i.nas`, `n16i_test.nas` or their trap path; the mandated
F14 regression therefore uses `n16i_kabi_gate.sh`. The mismatch is recorded
here rather than hidden.

## Frontier ideas

1. **Translation validation, wider than two goldens.** Add an independent
   second encoder for the covered opcode subset (or a bit-vector/SMT block
   equivalence check) and randomized block fuzzing that compares emitted
   bytes and architectural results. Keep the current hand-derived 46-byte and
   block0/block2 goldens as anchors, and promote block1 from a sha pin to a
   checked sequence.
2. **Proof-carrying blocks.** Attach a small per-block certificate to each
   emitted image (starting with MOVI/ADD/ADDI/JMP/RET) and verify it at load
   or gate time. The certificate should state the exact source words, the
   emitted bytes and the asserted register/XPC effect; keep the scope
   explicit and fail closed when an opcode has no certificate.
3. **Reproducible model builds in the gate.** Run `tools/mkall.sh` twice in a
   hermetic environment, compare image hashes, and check that the tracked
   product image is fresh. This makes the current nmk/translator determinism
   check a full product-image reproducibility gate without relying on a
   checked-in artifact.
4. **UTM trace replay against the encoded image.** When `coqc` is available,
   build the `formal/utm` cone and `coqchk` the universality, literal-run and
   bridge certificates; separately, feed a real n16i trace through the
   literal-image/step model and require the trace head to match the encoded
   image. Keep the Python image/table/step anchors as pre-checks, never as a
   substitute for the kernel.
