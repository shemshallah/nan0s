/* Differential SQLite suite: compile natively and with tcc0.  Every result
   is stored as a 32-bit word; the two builds must produce identical bytes. */
#include "sqlite3.h"
#include <string.h>
#ifndef GUEST
#include <stdio.h>
#endif

static unsigned out[96];
static char msgbuf[200];

static void setmsg(const char *s)
{
    int i = 0;
    while (s && s[i] && i < (int)sizeof(msgbuf) - 1) {
        msgbuf[i] = s[i];
        i++;
    }
    msgbuf[i] = 0;
}

static unsigned text4(const unsigned char *s)
{
    if (!s) return 0;
    return (unsigned)s[0] | ((unsigned)s[1] << 8)
         | ((unsigned)s[2] << 16) | ((unsigned)s[3] << 24);
}

static void putd(int idx, double d)
{
    unsigned char *p = (unsigned char *)&out[idx];
    memcpy(p, &d, 8);
}

int main(void)
{
    sqlite3 *db = 0;
    sqlite3_stmt *st = 0;
    char *err = 0;
    static const unsigned char blob1[3] = {0xDE, 0xAD, 0xBE};
    static const unsigned char blob2[2] = {0x01, 0x02};
    static const char *names[3] = {"alpha", "beta", "gamma"};
    int rc, i, n;

    memset(out, 0, sizeof(out));
    msgbuf[0] = 0;

    rc = sqlite3_open("suite.db", &db);
    out[0] = (unsigned)rc;
    if (rc) { setmsg(sqlite3_errmsg(db)); goto done; }

    rc = sqlite3_exec(db,
        "CREATE TABLE t(a INTEGER PRIMARY KEY, b REAL, c TEXT, d BLOB, e INT)",
        0, 0, &err);
    out[1] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db,
        "INSERT INTO t VALUES(?,?,?,?,?)", -1, &st, 0);
    out[2] = (unsigned)rc;
    if (rc) { setmsg(sqlite3_errmsg(db)); goto done; }

    for (i = 0; i < 3; i++) {
        sqlite3_bind_int(st, 1, i + 1);
        sqlite3_bind_double(st, 2, i == 0 ? 1.5 : i == 1 ? 2.5 : -3.25);
        sqlite3_bind_text(st, 3, names[i], -1, SQLITE_STATIC);
        if (i == 0) sqlite3_bind_blob(st, 4, blob1, 3, SQLITE_STATIC);
        else if (i == 1) sqlite3_bind_blob(st, 4, blob2, 2, SQLITE_STATIC);
        else sqlite3_bind_null(st, 4);
        if (i == 0) sqlite3_bind_null(st, 5);
        else sqlite3_bind_int(st, 5, i == 1 ? 7 : 9);
        rc = sqlite3_step(st);
        out[3 + i] = (unsigned)rc;
        if (rc != SQLITE_DONE) {
            setmsg(sqlite3_errmsg(db));
            sqlite3_finalize(st);
            goto done;
        }
        sqlite3_reset(st);
    }
    sqlite3_finalize(st);
    st = 0;

    rc = sqlite3_prepare_v2(db,
        "SELECT count(*), sum(a), avg(b), min(c), max(e) FROM t",
        -1, &st, 0);
    out[10] = (unsigned)rc;
    if (rc) { setmsg(sqlite3_errmsg(db)); goto done; }
    rc = sqlite3_step(st);
    out[11] = (unsigned)rc;
    out[12] = (unsigned)sqlite3_column_int(st, 0);
    out[13] = (unsigned)sqlite3_column_int(st, 1);
    putd(14, sqlite3_column_double(st, 2));
    out[16] = text4(sqlite3_column_text(st, 3));
    out[17] = (unsigned)sqlite3_column_int(st, 4);
    sqlite3_finalize(st);
    st = 0;

    rc = sqlite3_exec(db, "CREATE INDEX idx_t_a ON t(a)", 0, 0, &err);
    out[18] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db,
        "SELECT a FROM t INDEXED BY idx_t_a WHERE a=2", -1, &st, 0);
    out[19] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[20] = (unsigned)rc;
        out[21] = (unsigned)sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_exec(db,
        "CREATE TABLE u(id INTEGER, label TEXT);"
        "INSERT INTO u VALUES(2,'two');"
        "INSERT INTO u VALUES(3,'three');", 0, 0, &err);
    out[22] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db,
        "SELECT t.a, u.label FROM t JOIN u ON t.a=u.id ORDER BY t.a",
        -1, &st, 0);
    out[23] = (unsigned)rc;
    if (!rc) {
        n = 0;
        while (sqlite3_step(st) == SQLITE_ROW && n < 4) {
            out[24 + 2 * n] = (unsigned)sqlite3_column_int(st, 0);
            out[25 + 2 * n] = text4(sqlite3_column_text(st, 1));
            n++;
        }
        out[32] = (unsigned)n;
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_exec(db, "UPDATE t SET b=b+1 WHERE a=1", 0, 0, &err);
    out[33] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db, "SELECT b FROM t WHERE a=1", -1, &st, 0);
    out[34] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[35] = (unsigned)rc;
        putd(36, sqlite3_column_double(st, 0));
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_exec(db, "DELETE FROM t WHERE a=3", 0, 0, &err);
    out[38] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM t", -1, &st, 0);
    out[39] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[40] = (unsigned)rc;
        out[41] = (unsigned)sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_exec(db,
        "BEGIN;"
        "INSERT INTO t VALUES(3,'rollback',1.0,'x',1);"
        "ROLLBACK;", 0, 0, &err);
    out[42] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_exec(db,
        "BEGIN;"
        "INSERT INTO t VALUES(3,'committed',1.0,'x',1);"
        "COMMIT;", 0, 0, &err);
    out[43] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db, "SELECT count(*), max(a) FROM t", -1, &st, 0);
    out[44] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[45] = (unsigned)rc;
        out[46] = (unsigned)sqlite3_column_int(st, 0);
        out[47] = (unsigned)sqlite3_column_int(st, 1);
        sqlite3_finalize(st);
        st = 0;
    }

    sqlite3_close(db);
    db = 0;
    rc = sqlite3_open("suite.db", &db);
    out[48] = (unsigned)rc;
    if (rc) { setmsg(sqlite3_errmsg(db)); goto done; }

    rc = sqlite3_prepare_v2(db,
        "SELECT a,b,c,d,e FROM t WHERE a=1", -1, &st, 0);
    out[49] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[50] = (unsigned)rc;
        out[51] = (unsigned)sqlite3_column_type(st, 0);
        out[52] = (unsigned)sqlite3_column_int(st, 0);
        out[53] = (unsigned)sqlite3_column_type(st, 1);
        putd(54, sqlite3_column_double(st, 1));
        out[56] = (unsigned)sqlite3_column_type(st, 2);
        out[57] = text4(sqlite3_column_text(st, 2));
        out[58] = (unsigned)sqlite3_column_bytes(st, 2);
        out[59] = (unsigned)sqlite3_column_type(st, 3);
        out[60] = (unsigned)sqlite3_column_bytes(st, 3);
        if (sqlite3_column_blob(st, 3)) {
            const unsigned char *p = (const unsigned char *)sqlite3_column_blob(st, 3);
            out[61] = (unsigned)p[0] | ((unsigned)p[1] << 8) | ((unsigned)p[2] << 16);
        }
        out[62] = (unsigned)sqlite3_column_type(st, 4);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_prepare_v2(db, "SELECT * FROM no_such_table", -1, &st, 0);
    out[63] = (unsigned)rc;
    out[64] = (unsigned)strlen(sqlite3_errmsg(db));
    if (st) { sqlite3_finalize(st); st = 0; }

    rc = sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &st, 0);
    out[65] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[66] = (unsigned)rc;
        out[67] = 0;
        if (sqlite3_column_text(st, 0)) {
            const unsigned char *z = sqlite3_column_text(st, 0);
            out[67] = (unsigned)z[0] | ((unsigned)z[1] << 8);
        }
        sqlite3_finalize(st);
        st = 0;
    }

done:
    out[95] = 0x444E4521u;
    if (st) sqlite3_finalize(st);
    if (db) sqlite3_close(db);
#ifdef GUEST
    memcpy((void *)0x03000000u, out, sizeof(out));
    memcpy((void *)0x03001000u, msgbuf, sizeof(msgbuf));
    *(volatile unsigned *)0x02FFFFF0u = 1;
#else
    fwrite(out, 1, sizeof(out), stdout);
    if (msgbuf[0]) fprintf(stderr, "msg=%s\n", msgbuf);
#endif
    return 0;
}
