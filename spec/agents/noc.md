# noc - F15 no-C product substrate

Status: **implemented and gated**. `tools/noc_product_gate.sh` prints exactly
`O` as its final marker. The gate is deterministic and runs in about 30 s on
the Termux host. No C was added outside `src/tests`; the product image is
still raw NaN16 + native assembly.

## What F15 proves

### 1. Product build closure

The image is produced by `tools/mkall.sh` from:

```
src/native/nan16_x86.nan     raw 32-bit boot sector + NaN16 native core
src/nan/nixsched.nan         raw NaN16 guest emitted from gui_sched_boot.nas
```

`tools/mkall.sh` is `gawk` + `cat` + `dd` + POSIX `sh`. The gate rejects a
non-comment `clang`/`gcc`/`cc`/`ld.lld`/`llvm-objcopy`/`python` invocation in
`mkall.sh`, `mkbase.sh`, `rootfs_seed.sh` or `build.sh`, and runs
`tools/no_c_outside_tests.sh` plus `tools/guest_raw_only_gate.sh`.

The image contains no ELF magic anywhere, no date/time/UUID/`/tmp/`/
`SOURCE_DATE_EPOCH` markers, and its first 512-byte boot sector is the raw
GOLD stream. Current image: **4,311,040 bytes**, sha256
`9378fb14baf11e7f0f47606380e3b739853d1fff8d9ef15833c598dfde33e07d`.

### 2. Hermetic two-build and staleness

Each build runs in its own temp dir with:

- `env -i PATH=<temp bin> LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=1`;
- a compiler-free `PATH` containing only `gawk`, `awk`, `cat`, `dd`, `wc`,
  `sed`, `ls`, `rm`, `mkdir`, `dirname`, `basename`, `tr`, `head`, `cmp`,
  `od`, `grep` symlinks;
- a fresh `nixsched.nan` emitted from `src/gui/gui_sched_boot.nas`;
- `NAN0S_IMG`/`NAN0S_GUEST` overrides in `tools/mkall.sh` so the tracked
  `build/nan0s.img` is never touched by the gate.

Both isolated builds are byte-identical (`9378fb14...`), match
`build/nan0s.img`, and match the checked-in `src/nan/nixsched.nan`. The gate
fails if either the generated guest or the published image is stale.

### 3. 32-bit product substrate boot

`src/tests/nan0s_boot_smoke.nas` is a 16-word raw NaN guest. The gate builds
it with the same GOLD boot sector/native core and boots it with no IDE and no
C harness. COM1 must contain:

```
NaN/0S SMOKE OK
```

This isolates the shipped boot sector + `kan16` native core from the large
GUI guest.

### 4. Raw 64-bit boot/page-table/AP/block runtime (no C linked)

`src/native64/raw64_smp_body.S` is the F15 64-bit product substrate. It is
linked with the existing raw `s1_boot.S` long-mode entry and `smp_tramp.S`
AP trampoline, plus one immutable 159-byte block emitted by the NaN translator
(`src/tests/xlate64_smpblock.nas`).

All of the following is assembly/NaN, with **no C object in the link**:

- 4-level roots for two CPUs; VA `0x50000` maps to a private 4 KiB state page
  per CPU, while `0x51000` (block) and `0x200000` (guest words) stay shared;
- RSDP/RSDT/MADT discovery, BSP APIC id selection, LAPIC init, INIT-SIPI-SIPI;
- AP entry, per-core CR3, shared immutable block execution;
- COM1 transcript and `isa-debug-exit`.

Exact QEMU `-smp 2` output:

```
NAN64 RAW SMP x86_64
RAW64 cpus=2
RAW64 core0 r1=00000011 slot=00000011 done=00000011
RAW64 core1 r1=00000021 slot=00000021 done=00000021
RAW64 PASS
```

Link audit: `s1_boot.o + raw64_smp_body.o + blob.o`; `llvm-nm -u` is empty;
BSS ends at `0x109cc` (below the page tables at `0x30000`). The block sha256
is `d3a0d31e5a655439154792c21d29b65d100150fccc66c2987047204438908875`,
kernel sha256
`ddeb8fc3a216f5121d5547675bb98738b551a89e78c9f85293c1b952872a97a4`.

The NaN translator is executed by the C `nan_cli` **oracle** at build time;
its bytes are linked, the C executable is not. This boundary is explicit.

### 5. Shipped full product image boot

The gate stages the first 1.44 MiB of `build/nan0s.img` as a boot floppy and
attaches the full raw image as the primary IDE disk, then boots it with no C
harness. COM1 must contain:

```
NaN/0S BOOT
NANIX SHELL READY
```

`NaN/0S BOOT` is printed by `gui_kernel_boot` before memory discovery; the
second line is printed after `nsch_spawn_desc` created PID 1/PID 2 and before
the first `SVC 0`. Both are raw NaN `PUTC` output added to
`src/gui/gui_sched_boot.nas` for this gate.

**Important QEMU finding:** a 4.3 MiB file attached with `if=floppy` is not
reliable (QEMU's floppy geometry does not match the boot sector's 18-sector
track assumption). The old `native_product_boot_gate.sh` failed for this
reason, not because the product image was broken. The fixed gate stages a
1.44 MiB boot floppy and uses the full image as IDE. `tools/qgate_gui.sh`
received the same staging fix.

## What is still C (test-only or build-time)

| file | role | product link? |
|---|---|---|
| `src/tests/native64/s1_kabi.c` | S1 trap/port/timer/region test bench | no |
| `src/tests/native64/s1_smp.c` | F1 C SMP/AP comparator | no |
| `src/tests/native64/core2.c` | per-core CR3 gate harness | no |
| `src/tests/native64/mem64.c` | max-map gate harness | no |
| `aarch64/android/core/nan16.c`, `nan_cli` | translator/conformance oracle | no |

The 64-bit block translator is executed by `nan_cli` at gate/build time. It
is an oracle, not product runtime; the emitted bytes are raw and the raw64
link contains no C object. Replacing that execution with raw `n16i` is a
frontier item.

## Real gaps

- The gate claims COM1 banner/shell startup for the full product image, not
  the GUI framebuffer. A manual `screendump` on this host stayed at 720x400
  after boot, so the desktop/VBE path still needs its own gate. The old
  `qgate_gui.sh` also depends on `ffprobe`, which is absent here.
- The raw 64-bit path is one immutable block on two CPUs. It does not yet
  have per-AP TSS/IST, AP-local timers/IPIs, per-core block caches, or a
  4096-core scale path; `s1_smp.c` remains the richer C comparator.
- The 32-bit guest still carries the C-compatibility libc/VFS helpers in the
  guest source tree; they are compiled to NaN for guests, not linked into the
  product image.
- The GOLD stream `src/native/nan16_x86.nan` is checked in and regenerated by
  `tools/xgold.sh`; `xgold_gate.sh` currently fails its stale grid count
  (620 kernel rows vs the expected 532), so this gate does not regenerate or
  re-pin the GOLD.

## Commands and exact results

```
$ sh tools/noc_product_gate.sh
== 1. product build and link audit ==
no_c_outside_tests: PASS (src outside src/tests is C-free)
guest_raw_only: PASS (guest sources .nas/.nan/.xa; carts .nan; no ELF in images)
guest_raw_only: root seed has 7 inert C/header demo file(s) for ncc (data, not OS code)
product build: sh/gawk/cat/dd only; GOLD is raw .nan; no C compiler step
build/nan0s.img: 4311040 bytes, magic fa31c08e (not ELF)
product image: no timestamp/entropy markers
== 2. hermetic two-build and staleness ==
hermetic image sha256 9378fb14baf11e7f0f47606380e3b739853d1fff8d9ef15833c598dfde33e07d (2 isolated builds identical, compiler-free PATH)
build/nan0s.img matches the hermetic rebuild
boot sector 512 bytes; no object link is part of the image
== 3. product substrate boot (32-bit boot sector + native core, no C) ==
32-bit substrate: NaN/0S SMOKE OK on COM1 (raw .nan guest, no C harness)
== 4. raw 64-bit product path (no C linked) ==
raw64 block 159 bytes
raw64 link: s1_boot.S + raw64_smp_body.S + smp_tramp.S + NaN block; no C object, no undefined symbols
NAN64 RAW SMP x86_64
RAW64 cpus=2
RAW64 core0 r1=00000011 slot=00000011 done=00000011
RAW64 core1 r1=00000021 slot=00000021 done=00000021
RAW64 PASS
raw64 block sha256 d3a0d31e5a655439154792c21d29b65d100150fccc66c2987047204438908875; kernel sha256 ddeb8fc3a216f5121d5547675bb98738b551a89e78c9f85293c1b952872a97a4
raw64 PASS: boot + page roots + MADT/INIT-SIPI-SIPI AP + one immutable block, no C
== 5. shipped full product image boot (full guest + IDE, no C harness) ==
shipped full image: NaN/0S BOOT + NANIX SHELL READY on COM1 (raw NaN guest, no C)
noc_product_gate: PASS (no-C product build audit, hermetic image, full product boot, raw 64-bit AP/block runtime)
O
```

Regressions:

```
$ sh tools/nverify_gate.sh
... nverify: PASS (reproducible emission, translator goldens, native/n16i trace, block gate, non-ELF image, C-free source)
O

$ sh tools/qgate64core.sh
qgate64core: PASS (NaN translator -> x86-64 block -> native execution, r1=84)

$ sh tools/qgate64smpblock.sh
BLOCK SMP core0 r1=0x11 slot=0x11 done=0x11
BLOCK SMP core1 r1=0x21 slot=0x21 done=0x21
BLOCK SMP PASS
qgate64smpblock: PASS (2 real CPUs, one immutable 159-byte NaN-emitted block, per-core CR3 state, shared guest memory)

$ sh tools/no_c_outside_tests.sh
no_c_outside_tests: PASS (src outside src/tests is C-free)

$ sh tools/native_product_boot_gate.sh
native_boot: PASS (native boot sector + NaN16 core + full guest .nan; no C harness)
```

## Frontier ideas

1. **Raw AP startup beyond two CPUs.** Extend `raw64_smp_body.S` with per-AP
   TSS/IST, AP-local LAPIC timers and reschedule IPIs, a per-core block cache,
   and x2APIC/4096-core discovery. That would retire the `s1_smp.c` comparator
   for the F1/F4 paths and make the 64-bit substrate a real product runtime.
2. **Signed product image.** Define a deterministic manifest over boot +
   kernel + guest, sign it offline, and verify it in the boot sector/kernel
   before the first guest fetch. Fail closed on a bad signature and add a
   gate that mutates one byte in each region.
3. **Source-derived GOLD + C-free translator execution.** Run the NaN
   translator under raw `n16i` (or a self-hosted equivalent) in the gate,
   compare its emitted bytes to `nan_cli`, then regenerate `nan16_x86.nan`
   with `xgold.sh` and assert the checked-in GOLD is current. This closes the
   remaining build-time C oracle.
4. **COM1 shell transcript, not just startup.** Make the NANIX shell echo a
   deterministic command transcript (`mkdir/write/cat/ls/stat/rm`) to COM1
   without a GUI, so the full product image's service path is gated headlessly
   and the GUI/VBE path can be tested separately.
