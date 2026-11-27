#!/bin/sh
# tasklist_append.sh <agent> <text> - serialized insert before AGENT-APPEND.
set -eu
cd "$(dirname "$0")/.."
[ $# -ge 2 ] || { echo "usage: tasklist_append.sh <agent> <text>"; exit 2; }
lock=spec/.tasklist.lock
i=0
while ! mkdir "$lock" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 120 ] || { echo "tasklist_append: lock timeout"; exit 1; }
  sleep 1
done
trap 'rmdir "$lock"' EXIT INT TERM
line="- [ ] ($1) $2"
awk -v line="$line" '/<!-- AGENT-APPEND -->/ { print line } { print }' \
  spec/MASTER_TASKLIST.md > spec/MASTER_TASKLIST.md.new
mv spec/MASTER_TASKLIST.md.new spec/MASTER_TASKLIST.md
echo "tasklist_append: $line"
