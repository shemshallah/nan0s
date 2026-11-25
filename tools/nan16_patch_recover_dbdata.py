#!/usr/bin/env python3
"""Bound sqlite_dbdata() payload buffers by the input database size.

recovercorrupt3.test feeds a 3.8 KiB fuzz database whose page-1 cells
declare a ~196 MiB b-tree payload.  sqlite_dbdata() sizes its record buffer
from that declared payload before following the (invalid) overflow chain, so
on the 160 MiB NaN16 heap sqlite3_recover_step() fails with SQLITE_NOMEM
even though the whole input file is only a few KiB.

A record payload can never be larger than the input database, so clamp it to
pagesize*page_count.  A single-page scan (WHERE pgno=?) also needs the page
count, so fetch it for getpage()-style schemas there too.  The overflow loop
then stops at the first page that does not exist and pCsr->nRec ends up with
exactly the same bytes as an unpatched build; only the transient allocation
is smaller.

Usage: nan16_patch_recover_dbdata.py SQLITE_SRC/ext/recover/dbdata.c
"""
import sys

MARK = "NaN16 port: bound a corrupt payload"

OLD_FILTER = """  if( idxNum & 0x02 ){
    pCsr->iPgno = sqlite3_value_int(argv[(idxNum & 0x01)]);
    pCsr->bOnePage = 1;
  }else{
    rc = dbdataDbsize(pCsr, zSchema);
  }
"""

NEW_FILTER = """  if( idxNum & 0x02 ){
    pCsr->iPgno = sqlite3_value_int(argv[(idxNum & 0x01)]);
    pCsr->bOnePage = 1;
    /* NaN16 port: even a single-page scan needs szDb so that a corrupt
    ** cell payload can be bounded by the size of the input database. */
    if( dbdataIsFunction(zSchema)>0 ){
      rc = dbdataDbsize(pCsr, zSchema);
    }
  }else{
    rc = dbdataDbsize(pCsr, zSchema);
  }
"""

OLD_PAYLOAD = """            iOff += dbdataGetVarintU32(&pCsr->aPage[iOff], &nPayload);
            if( nPayload>0x7fffff00 ) nPayload &= 0x3fff;
            if( nPayload==0 ) nPayload = 1;
"""

NEW_PAYLOAD = """            iOff += dbdataGetVarintU32(&pCsr->aPage[iOff], &nPayload);
            if( nPayload>0x7fffff00 ) nPayload &= 0x3fff;
            if( nPayload==0 ) nPayload = 1;
            /* NaN16 port: bound a corrupt payload by what the input
            ** database can actually contain.  A 4 KiB fuzz file must not
            ** trigger a multi-hundred-MiB transient allocation. */
            if( pCsr->szDb>0
             && nPayload>(sqlite3_int64)pCsr->szDb*(sqlite3_int64)pCsr->nPage
            ){
              nPayload = (sqlite3_int64)pCsr->szDb*(sqlite3_int64)pCsr->nPage;
            }
"""


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: nan16_patch_recover_dbdata.py DBData.c")
    p = sys.argv[1]
    s = open(p, encoding="utf-8").read()
    if MARK in s:
        return
    for old in (OLD_FILTER, OLD_PAYLOAD):
        if old not in s:
            sys.exit("dbdata.c: expected SQLite 3.54.1 code not found")
    s = s.replace(OLD_FILTER, NEW_FILTER, 1)
    s = s.replace(OLD_PAYLOAD, NEW_PAYLOAD, 1)
    open(p, "w", encoding="utf-8").write(s)


if __name__ == "__main__":
    main()
