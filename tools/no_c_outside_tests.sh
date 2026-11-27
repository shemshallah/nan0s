#!/bin/sh
# no_c_outside_tests.sh - product source outside src/tests must be C-free.
#
# The native substrate is assembly (.S/.xa/.nas); C is allowed only in the
# test/oracle tree (src/tests), never in product source.  Host vendor trees
# (third_party/, aarch64/android/) and inert nanfs demo data are not product.
set -eu
cd "$(dirname "$0")/.."
bad=$(find src -path src/tests -prune -o -type f \
  \( -name '*.c' -o -name '*.h' -o -name '*.cc' -o -name '*.cpp' \) -print)
if [ -n "$bad" ]; then
  echo "no_c_outside_tests: FAIL (C outside src/tests)"
  printf '%s\n' "$bad"
  exit 1
fi
echo "no_c_outside_tests: PASS (src outside src/tests is C-free)"
