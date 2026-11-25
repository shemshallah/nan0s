/* nanfs_probe.c - SQLite persistence through the NaN16 machine filesystem.
 *
 * The database file lives in the NaN file store (not the libc VFS).  The
 * probe creates it, inserts rows, closes, reopens, updates and reopens again
 * so the pager and the NaN save/load boundary are both exercised.
 *
 * Results are 32-bit words at guest byte 0x03000000; the completion marker
 * at 0x02FFFFF0 is set last.
 */
#include "sqlite3.h"
#include <string.h>

static volatile unsigned out[16];
static char msgbuf[160];
#define NAN_TAB ((volatile unsigned *)0x00A59000u)
typedef int (*nan_size_fn)(const char *);
typedef int (*nan_load_fn)(const char *, void *, int);

static unsigned text4(const unsigned char *s)
{
    if (!s) return 0;
    return (unsigned)s[0] | ((unsigned)s[1] << 8)
         | ((unsigned)s[2] << 16) | ((unsigned)s[3] << 24);
}

static void setmsg(const char *s)
{
    int i = 0;
    while (s && s[i] && i < (int)sizeof(msgbuf) - 1) { msgbuf[i] = s[i]; i++; }
    msgbuf[i] = 0;
}

static int exec_sql(sqlite3 *db, const char *sql)
{
    char *err = 0;
    int rc = sqlite3_exec(db, sql, 0, 0, &err);
    if (rc && err) setmsg(err);
    sqlite3_free(err);
    return rc;
}

int main(void)
{
    sqlite3 *db = 0;
    sqlite3_stmt *st = 0;
    int rc = 0;

    memset((void *)out, 0, sizeof(out));
    out[3] = 0x53514C50u;
    out[5] = 0x444E4521u;

    /* ---- create and populate ---- */
    rc = sqlite3_open("nanfs.db", &db);
    if (rc) { out[4] = (unsigned)rc; setmsg(sqlite3_errmsg(db)); goto done; }
    rc = exec_sql(db,
        "CREATE TABLE t(x INTEGER, s TEXT);"
        "INSERT INTO t VALUES(1,'one');"
        "INSERT INTO t VALUES(2,'two');"
        "INSERT INTO t VALUES(3,'three');");
    if (rc) { out[4] = 0x100u | (unsigned)rc; goto done; }
    rc = sqlite3_prepare_v2(db, "SELECT sum(x),count(*),max(s) FROM t",
                            -1, &st, 0);
    if (rc) { out[4] = 0x200u | (unsigned)rc; goto done; }
    if (sqlite3_step(st) != SQLITE_ROW) { out[4] = 0x300u; goto done; }
    out[0] = (unsigned)sqlite3_column_int(st, 0);
    out[1] = (unsigned)sqlite3_column_int(st, 1);
    out[2] = text4(sqlite3_column_text(st, 2));
    sqlite3_finalize(st); st = 0;
    rc = sqlite3_close(db); db = 0;
    if (rc) { out[4] = 0x400u | (unsigned)rc; goto done; }

    /* ---- reopen: the rows must have survived the NaN save/load ---- */
    rc = sqlite3_open("nanfs.db", &db);
    if (rc) { out[4] = 0x500u | (unsigned)rc; goto done; }
    rc = sqlite3_prepare_v2(db, "SELECT count(*),sum(x) FROM t", -1, &st, 0);
    if (rc) { out[4] = 0x600u | (unsigned)rc; setmsg(sqlite3_errmsg(db)); goto done; }
    if (sqlite3_step(st) != SQLITE_ROW) { out[4] = 0x700u; goto done; }
    out[6] = (unsigned)sqlite3_column_int(st, 0);
    out[7] = (unsigned)sqlite3_column_int(st, 1);
    sqlite3_finalize(st); st = 0;
    if (out[6] != 3 || out[7] != 6) { out[4] = 0x800u; goto done; }

    rc = exec_sql(db, "UPDATE t SET x=10 WHERE x=1;"
                      "INSERT INTO t VALUES(4,'four');");
    if (rc) { out[4] = 0x900u | (unsigned)rc; goto done; }
    rc = sqlite3_close(db); db = 0;
    if (rc) { out[4] = 0xA00u | (unsigned)rc; goto done; }

    /* ---- second reopen: verify the update persisted ---- */
    rc = sqlite3_open("nanfs.db", &db);
    if (rc) { out[4] = 0xB00u | (unsigned)rc; goto done; }
    rc = sqlite3_prepare_v2(db, "SELECT count(*),sum(x) FROM t", -1, &st, 0);
    if (rc) { out[4] = 0xC00u | (unsigned)rc; goto done; }
    if (sqlite3_step(st) != SQLITE_ROW) { out[4] = 0xD00u; goto done; }
    out[8] = (unsigned)sqlite3_column_int(st, 0);
    out[9] = (unsigned)sqlite3_column_int(st, 1);
    sqlite3_finalize(st); st = 0;
    out[10] = (out[8] == 4 && out[9] == 19) ? 1u : 0u;
    if (!out[10]) out[4] = 0xE00u;

done:
    if (st) sqlite3_finalize(st);
    if (db) sqlite3_close(db);
    out[15] = (unsigned)strlen(msgbuf);
    {
        unsigned char hdr[16];
        int sz = ((nan_size_fn)(unsigned long)NAN_TAB[3])("nanfs.db");
        out[11] = (unsigned)sz;
        memset(hdr, 0, sizeof hdr);
        if (sz > 0)
            ((nan_load_fn)(unsigned long)NAN_TAB[0])("nanfs.db", hdr, 16);
        out[12] = text4(hdr);
        out[13] = (unsigned)hdr[15];
    }
    memcpy((void *)0x03000100u, msgbuf, strlen(msgbuf) + 1);
    memcpy((void *)0x03000000u, (const void *)out, sizeof(out));
    *(volatile unsigned *)0x02FFFFF0u = 1u;
    return 0;
}
