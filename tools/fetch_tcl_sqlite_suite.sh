#!/bin/sh
# tools/fetch_tcl_sqlite_suite.sh [DEST]
#
# Fetch and verify the pinned Tcl 9.0.3 and SQLite 3.54.1 source trees used by
# the official SQLite Tcl test suite.  DEST defaults to
# ${TMPDIR:-$PWD/build}/tcl-sqlite.  Nothing is written into the repository.
set -eu
cd "$(dirname "$0")/.."
DEST=${1:-${TMPDIR:-$PWD/build}/tcl-sqlite}
mkdir -p "$DEST"

fetch() { # fetch URL FILE SHA256
    url=$1; file=$2; sha=$3
    if [ -f "$DEST/$file" ] && [ "$(sha256sum "$DEST/$file" | cut -d' ' -f1)" = "$sha" ]; then
        echo "fetch: cached $file"
        return
    fi
    echo "fetch: $url"
    curl -L --fail -o "$DEST/$file.part" "$url"
    got=$(sha256sum "$DEST/$file.part" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || {
        echo "fetch: FAIL sha256 $file: got $got expected $sha" >&2
        rm -f "$DEST/$file.part"; exit 1; }
    mv "$DEST/$file.part" "$DEST/$file"
}

fetch https://prdownloads.sourceforge.net/tcl/tcl9.0.3-src.tar.gz \
      tcl9.0.3-src.tar.gz \
      2537ba0c86112c8c953f7c09d33f134dd45c0fb3a71f2d7f7691fd301d2c33a6
fetch https://www.sqlite.org/2026/sqlite-src-3540100.zip \
      sqlite-src-3540100.zip \
      387e7f6cad4797b17848c07d453dc6606917bb356a6cfe5a3abafd38c240c71b

[ -d "$DEST/tcl9.0.3" ] || {
    echo "fetch: extract tcl9.0.3"
    tar -xzf "$DEST/tcl9.0.3-src.tar.gz" -C "$DEST"
}
[ -d "$DEST/sqlite-src-3540100" ] || {
    echo "fetch: extract sqlite-src-3540100"
    unzip -q "$DEST/sqlite-src-3540100.zip" -d "$DEST"
}
echo "fetch: OK $DEST"
