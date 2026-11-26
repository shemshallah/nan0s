#!/bin/sh
# tools/rootfs_sync.sh - unpack an NPAF snapshot back into nanfs/.
#
# The on-disk contract is src/lib/nfs2.nas (nfs_save / nfs_load):
#   LBA 2048: 128 little-endian 32-bit words
#             [0]=0x4E465359 "NFSY", [1]=image words, [2]=0
#   LBA 2049: the image words, i.e. the live NFS_BASE region:
#             8 NPAF header words, NFS_MAX*16 entry words, arena words.
# ATA PIO transfers payload words only (4 bytes/word), so the disk image is
# a packed little-endian u32 stream.  A raw NaN16 RAM dump instead has the
# 8-byte word form (far head, payload LE32, near head); --mem decodes that.
#
# usage:
#   tools/rootfs_sync.sh --disk IMG [--out DIR] [--check|--list]
#   tools/rootfs_sync.sh --mem DUMP [--offset BYTES] [--out DIR] [--check|--list]
#
# The default output directory is nanfs/ (the committed fresh-root seed).
# Existing files are overwritten; files absent from the snapshot are not
# deleted.  Exit 0 on a valid snapshot, 1 on a malformed/short image.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
ROOT=$(pwd)
T="${TMPDIR:-$ROOT/tmp}/rootfs_sync.$$"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT INT TERM

usage() {
  echo "usage: $0 --disk IMG [--out DIR] [--check|--list]" >&2
  echo "       $0 --mem DUMP [--offset BYTES] [--out DIR] [--check|--list]" >&2
  exit 2
}

die() { echo "rootfs_sync: $*" >&2; exit 1; }

# le32_at FILE OFFSET -> unsigned 32-bit little-endian word.
le32_at() {
  od -An -v -tx1 -j "$2" -N 4 "$1" 2>/dev/null | awk '
    function hx(s, i, v, c) {
      v = 0
      for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        v = v * 16 + index("0123456789abcdef", c) - 1
      }
      return v
    }
    NF >= 4 { printf "%.0f\n", hx($4)*16777216 + hx($3)*65536 + hx($2)*256 + hx($1); f=1 }
    END { if (!f) print -1 }'
}

MODE=""; SRC=""; OUT=nanfs; ACTION=unpack; OFFSET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --disk) [ "$#" -ge 2 ] || usage; MODE=disk; SRC=$2; shift 2 ;;
    --mem) [ "$#" -ge 2 ] || usage; MODE=mem; SRC=$2; shift 2 ;;
    --offset) [ "$#" -ge 2 ] || usage; OFFSET=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; OUT=$2; shift 2 ;;
    --check) ACTION=check; shift ;;
    --list) ACTION=list; shift ;;
    -h|--help) usage ;;
    *) echo "rootfs_sync: unknown argument $1" >&2; usage ;;
  esac
done
[ -n "$MODE" ] || usage
[ -f "$SRC" ] || die "no such image: $SRC"
case "$OFFSET" in *[!0-9]*|"") die "bad --offset" ;; esac
[ $((OFFSET % 4)) -eq 0 ] || die "--offset must be a multiple of 4"

IMG="$T/image.bin"
COUNT=""

if [ "$MODE" = disk ]; then
  SZ=$(wc -c < "$SRC")
  [ "$SZ" -ge $((2049 * 512)) ] || die "disk image is shorter than LBA 2049"
  MAGIC=$(le32_at "$SRC" $((2048 * 512)))
  [ "$MAGIC" = "1313231705" ] || die "bad snapshot magic at LBA 2048 (0x$(printf %08x "$MAGIC" 2>/dev/null || echo '?'))"
  COUNT=$(le32_at "$SRC" $((2048 * 512 + 4)))
  [ "$COUNT" -ge 1032 ] 2>/dev/null || die "bad snapshot word count $COUNT"
  [ "$COUNT" -le 401032 ] || die "snapshot word count $COUNT exceeds nfs_load limit 401032"
  SECT=$(((COUNT + 127) / 128))
  [ "$SZ" -ge $(( (2049 + SECT) * 512 )) ] || die "disk image ends before the snapshot sectors"
  # ATA transfers 4 payload bytes per snapshot word.
  dd if="$SRC" bs=1 skip=$((2049 * 512)) count=$((COUNT * 4)) of="$IMG" 2>/dev/null
else
  SZ=$(wc -c < "$SRC")
  [ "$SZ" -ge $((OFFSET + 8)) ] || die "memory dump is too short"
  PACKED=$(le32_at "$SRC" "$OFFSET")
  if [ "$PACKED" = "1313882438" ]; then
    # Packed 4-byte logical words (same stream as the ATA snapshot).
    TOP=$(le32_at "$SRC" $((OFFSET + 8)))
    COUNT=$((1032 + TOP))
    [ "$SZ" -ge $((OFFSET + COUNT * 4)) ] || die "memory dump ends inside the packed NPAF image"
    dd if="$SRC" bs=1 skip="$OFFSET" count=$((COUNT * 4)) of="$IMG" 2>/dev/null
  else
    # Raw NaN16 words: payload is bytes 2..5 of each 8-byte word.
    MAGIC=$(le32_at "$SRC" $((OFFSET + 2)))
    [ "$MAGIC" = "1313882438" ] || die "memory dump has no NPAF magic at byte $OFFSET"
    TOP=$(le32_at "$SRC" $((OFFSET + 2 * 8 + 2)))
    COUNT=$((1032 + TOP))
    [ "$SZ" -ge $((OFFSET + COUNT * 8)) ] || die "memory dump ends inside the NPAF image"
    dd if="$SRC" bs=1 skip="$OFFSET" count=$((COUNT * 8)) 2>/dev/null |
      od -An -v -tx1 | awk '{
        for (w = 0; w + 7 < NF; w += 8)
          printf "%s%s%s%s", $(w + 3), $(w + 4), $(w + 5), $(w + 6)
      }' | xxd -r -p > "$IMG"
  fi
fi

# ---- validate and unpack the NPAF image ----
MAGIC=$(le32_at "$IMG" 0)
[ "$MAGIC" = "1313882438" ] || die "bad NPAF magic 0x$(printf %08x "$MAGIC" 2>/dev/null || echo '?')"
ENTRIES=$(le32_at "$IMG" 4)
TOP=$(le32_at "$IMG" 8)
CAP=$(le32_at "$IMG" 12)
MAX=$(le32_at "$IMG" 16)
[ "$MAX" -ge 1 ] && [ "$MAX" -le 4096 ] || die "bad entry limit $MAX"
[ "$ENTRIES" -le "$MAX" ] || die "entry count $ENTRIES exceeds limit $MAX"
[ "$TOP" -le "$CAP" ] || die "arena top $TOP exceeds capacity $CAP"
[ "$CAP" -le 67108864 ] || die "implausible arena capacity $CAP"
WANT=$((1032 + TOP))
if [ "$MODE" = disk ]; then
  [ "$COUNT" = "$WANT" ] || die "header count $COUNT != 1032 + arena $TOP"
fi
SZ=$(wc -c < "$IMG")
[ "$SZ" -ge $((WANT * 4)) ] || die "short NPAF image ($SZ < $((WANT * 4)) bytes)"

if [ "$ACTION" = check ]; then
  echo "rootfs_sync: OK magic=NPAF entries=$ENTRIES arena=$TOP/$CAP max=$MAX words=$WANT"
  exit 0
fi

if [ "$ACTION" = unpack ]; then
  mkdir -p "$OUT"
fi
NFILE=0; NDIR=0; NBYTES=0
I=0
while [ "$I" -lt "$MAX" ]; do
  B=$((32 + I * 64))
  USED=$(le32_at "$IMG" "$B")
  [ "$USED" = 0 ] && { I=$((I + 1)); continue; }
  DIR=$(le32_at "$IMG" $((B + 4)))
  SIZE=$(le32_at "$IMG" $((B + 8)))
  OFFW=$(le32_at "$IMG" $((B + 12)))
  PLEN=$(le32_at "$IMG" $((B + 16)))
  [ "$PLEN" -ge 1 ] && [ "$PLEN" -le 31 ] || die "entry $I has bad path length $PLEN"
  PATHB=$(dd if="$IMG" bs=1 skip=$((B + 20)) count="$PLEN" 2>/dev/null | tr -d '\000')
  [ "${#PATHB}" -eq "$PLEN" ] || die "entry $I has a NUL inside its path"
  case "$PATHB" in
    /*) ;;
    *) die "entry $I path is not absolute: '$PATHB'" ;;
  esac
  case "$PATHB" in
    *"/../"*|*"/.."|*"/./"*|*"/."|*"//"*) die "entry $I has unsafe path '$PATHB'" ;;
    *"
"*) die "entry $I has a newline in its path" ;;
  esac
  REL=${PATHB#/}
  [ -z "$REL" ] && { I=$((I + 1)); continue; }
  NEED=$((OFFW + (SIZE + 3) / 4))
  [ "$NEED" -le "$TOP" ] || die "entry $I data runs past the arena ($NEED > $TOP)"
  if [ "$ACTION" = list ]; then
    if [ "$DIR" = 1 ]; then echo "d $SIZE $PATHB"; else echo "f $SIZE $PATHB"; fi
  elif [ "$DIR" = 1 ]; then
    mkdir -p "$OUT/$REL"
    NDIR=$((NDIR + 1))
  else
    mkdir -p "$(dirname "$OUT/$REL")"
    dd if="$IMG" bs=1 skip=$(((1032 + OFFW) * 4)) count="$SIZE" \
       of="$OUT/$REL" 2>/dev/null
    chmod 644 "$OUT/$REL" 2>/dev/null || true
    NFILE=$((NFILE + 1))
    NBYTES=$((NBYTES + SIZE))
  fi
  I=$((I + 1))
done

if [ "$ACTION" = unpack ]; then
  echo "rootfs_sync: unpacked $NFILE files ($NBYTES bytes), $NDIR dirs, arena $TOP/$CAP words -> $OUT"
else
  echo "rootfs_sync: entries=$ENTRIES arena=$TOP/$CAP max=$MAX"
fi
