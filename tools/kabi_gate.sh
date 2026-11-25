#!/bin/sh
# tools/kabi_gate.sh - kernel ABI v0.1 gate.
# 1. portable C oracle: core suite + the ABI frame/region/timer tests
# 2. primary target: x86_64 bare-metal ABI-mechanics slice under QEMU
# 3. assembler/disassembler: named INL/SVC/SVCRET round-trip
set -e; cd "$(dirname "$0")/.."; export LC_ALL=C
make -s -C aarch64/android test
sh tools/kabi64_gate.sh
sh tools/kabi_asm_gate.sh
echo "kabi: PASS (oracle + x86_64 slice + assembler)"
