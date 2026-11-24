/* SQL probe for the self-hosted tcc1 SQLite gate.
 *
 * Contract (all values are 32-bit little-endian words at guest 0x03000000):
 *   0: sum(x)    = 6
 *   1: count(*)  = 3
 *   2: max(s)    = "two\0"
 *   3: magic     = 0x53514c50
 *   4: first failing rc, or 0
 *   5: done magic= 0x444e4521
 * The completion marker at 0x02fffff0 is 1.
 */
#include "sqlite3.h"
#include <string.h>
#ifndef GUEST
#include <stdio.h>
#endif

static unsigned out[8];

static unsigned text4(const unsigned char *s)
{
    if (!s) return 0;
    return (unsigned)s[0] | ((unsigned)s[1] << 8)
         | ((unsigned)s[2] << 16) | ((unsigned)s[3] << 24);
}

int main(void)
{
    sqlite3 *db = 0;
    sqlite3_stmt *st = 0;
    char *err = 0;
    int rc;

    memset(out, 0, sizeof(out));
    out[3] = 0x53514c50u;
    out[5] = 0x444e4521u;

    rc = sqlite3_open("probe.db", &db);
    if (rc) { out[4] = (unsigned)rc; goto done; }
    rc = sqlite3_exec(db,
        "CREATE TABLE t(x INTEGER, s TEXT);"
        "INSERT INTO t VALUES(1,'one');"
        "INSERT INTO t VALUES(2,'two');"
        "INSERT INTO t VALUES(3,'three');",
        0, 0, &err);
    if (rc) { out[4] = (unsigned)rc; goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db,
        "SELECT sum(x),count(*),max(s) FROM t", -1, &st, 0);
    if (rc) { out[4] = (unsigned)rc; goto done; }
    rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) { out[4] = (unsigned)rc; goto done; }
    out[0] = (unsigned)sqlite3_column_int(st, 0);
    out[1] = (unsigned)sqlite3_column_int(st, 1);
    out[2] = text4(sqlite3_column_text(st, 2));

done:
    if (st) sqlite3_finalize(st);
    if (db) sqlite3_close(db);
#ifdef GUEST
    memcpy((void *)0x03000000u, out, sizeof(out));
    *(volatile unsigned *)0x02fffff0u = 1;
#else
    fwrite(out, 1, sizeof(out), stdout);
    if (out[4]) fprintf(stderr, "probe: sqlite rc=%u\n", out[4]);
#endif
    return 0;
}
