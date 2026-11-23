# Rapid local v86/WASM development loop

NaN/0S now has a **local WebAssembly-first guest test harness**. This avoids a
GitHub push or an Actions queue on every iteration. The host harness is Node.js,
but the booted operating system, keyboard handling, disk driver, and
`build nan0s` image generator execute inside the **raw NaN16** guest.

## Set up once

From the repository root, in Termux or another Node.js development environment:

```sh
# Node 22+ (prefer current Node 24); GNU awk and normal image build tools.
npm install --no-save --no-package-lock v86@0.5.473
sh tools/build.sh
```

The first run caches the **same SeaBIOS and VGA BIOS used by the web demo** in
`.cache/nan0s-wasm/`. Later runs reuse them. The v86 npm installation supplies
`v86.wasm` locally, so there is no CDN request inside the test loop.

## Each local iteration

```sh
# Recompile edited .nas source and generate build/nan0s.img:
sh tools/build.sh

# Quick boot/keyboard check (does not write an output image):
node tools/wasm_fastcheck.mjs --boot-only

# Real, full guest-owned self-replication test:
node tools/wasm_fastcheck.mjs
```

No GitHub invocation is required. The harness does all of the following in
the **same actual v86/WASM emulator used by the browser**:

1. Boots the full 1,474,560-byte image from a floppy + IDE master with 128 MiB
   guest RAM, precisely as the live web player does.
2. Sends actual PS/2 Set-1 scancodes for a bare `n`, `a`, then backspaces;
   verifies the emulator still executes instructions.
3. Types `build nan0s` + Enter through the guest keyboard.
4. Waits for the raw-NaN16 disk-builder success/failure event, subject to a
   timeout, with a **blank independent IDE slave** as output.
5. Compares all 1,474,560 bytes of the guest-written output against the source
   image, checks that the source IDE master remained unchanged, and prints the
   SHA-256 checksum.
6. Starts **a second v86/WASM machine** whose floppy and IDE master are both
   populated from the first guest's output disk, and requires a fresh NaN/0S
   boot banner.

A nonzero exit means the local gate has failed. It is suitable for very fast
inner-loop source work; GitHub CI should be used only after a candidate passes.

## Useful options

```sh
NAN0S_IMG=build/nan0s.img node tools/wasm_fastcheck.mjs
NAN0S_WASM_TIMEOUT=300000 node tools/wasm_fastcheck.mjs
NAN0S_WASM_CACHE=/path/to/cache node tools/wasm_fastcheck.mjs
```

The `--boot-only` check is a **smoke test**, not proof that typed characters
appeared on-screen. The full image gate proves a guest-generated, bootable
**sector-exact replica**; it does **not** demonstrate reconstruction of the
native boot sector, NaN kernel, and GUI from source. A source-recompiled
self-bootstrap requires a stronger fixed-point gate.

The Node/WASM path deliberately has no browser DOM. Use
`docs/index.html` in a real browser for mobile viewport, Gboard IME,
focus-scrolling, and graphical rendering checks. Both paths use the
same v86 core, but Node cannot prove touch layout correctness.

## If dependencies cannot be downloaded

The initial npm/BIOS download requires network access. If your environment
blocks GitHub and npm, you can install `v86@0.5.473` and copy the two BIOS
files into `.cache/nan0s-wasm/` on another machine. The per-iteration tests
then work fully offline, assuming `build/nan0s.img` can be regenerated locally.

Source: [tools/wasm_fastcheck.mjs](../tools/wasm_fastcheck.mjs)
