#!/bin/sh
# nhost_guest_key.sh - source key for the native nhost product-guest cache.
#
# The native nhost stage1 output is a pure function of the guest source tree
# (the stage0 oracle only bootstraps nhost itself).  Key the cache by every
# product .nas source plus the nhost emitter scripts; a change to any of them
# forces a fresh native emit.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
{
  find src/lib src/gui src/nix src/prog src/tools src/nan -type f -name '*.nas' -print |
    LC_ALL=C sort |
    while IFS= read -r f; do
      printf '==== %s\n' "$f"
      cat "$f"
    done
  printf '==== tools\n'
  cat tools/nhost_emit_guest.sh tools/nhost_bundle.awk
} | sha256sum | awk '{print $1}'
