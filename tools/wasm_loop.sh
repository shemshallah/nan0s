#!/bin/sh
# One-command local rapid test: assemble raw NaN16, build complete boot image,
# run the REAL v86/WASM emulator. No GitHub push, no QEMU.
set -eu
cd "$(dirname "$0")/.."
sh tools/build.sh
exec node tools/wasm_fastcheck.mjs "$@"
