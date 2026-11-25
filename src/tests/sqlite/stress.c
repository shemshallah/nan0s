/* SQLite stress suite for the NaN16 port: multi-page tables, indexes,
   overflow blobs, GROUP BY, UPDATE/DELETE, VACUUM, close/reopen.  Compiled
   natively and with tcc0; every output word must match. */
#include "sqlite3.h"
#include <string.h>
#ifndef GUEST
#include <stdio.h>
#endif

static unsigned out[256];
static char msgbuf[200];
static unsigned char bigblob[5000];
static unsigned char smallblob[64];

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

static unsigned hashblob(const void *p, int n)
{
    const unsigned char *b = (const unsigned char *)p;
    unsigned h = 0;
    int i;
    for (i = 0; i < n; i++) h = h * 33u + b[i];
    return h;
}

static void mkname(char *b, int i)
{
    int n = 0, d;
    char tmp[12];
    b[n++] = 'r'; b[n++] = 'o'; b[n++] = 'w'; b[n++] = '-';
    d = 0;
    do { tmp[d++] = (char)('0' + i % 10); i /= 10; } while (i);
    while (d) b[n++] = tmp[--d];
    b[n] = 0;
}

int main(void)
{
    sqlite3 *db = 0;
    sqlite3_stmt *st = 0;
    char *err = 0;
    char name[32];
    int rc, i, n, g;

    memset(out, 0, sizeof(out));
    msgbuf[0] = 0;
    for (i = 0; i < (int)sizeof(bigblob); i++)
        bigblob[i] = (unsigned char)((i * 131 + 17) & 0xFF);
    for (i = 0; i < (int)sizeof(smallblob); i++)
        smallblob[i] = (unsigned char)(i + 1);

    rc = sqlite3_open("stress.db", &db);
    out[0] = (unsigned)rc;
    if (rc) { setmsg(sqlite3_errmsg(db)); goto done; }

    rc = sqlite3_exec(db,
        "CREATE TABLE s(id INTEGER PRIMARY KEY, grp INT, val INT,"
        " txt TEXT, data BLOB)", 0, 0, &err);
    out[1] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_exec(db, "BEGIN", 0, 0, &err);
    out[2] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db,
        "INSERT INTO s VALUES(?,?,?,?,?)", -1, &st, 0);
    out[3] = (unsigned)rc;
    if (rc) { setmsg(sqlite3_errmsg(db)); goto done; }

    for (i = 0; i < 500; i++) {
        mkname(name, i);
        sqlite3_bind_int(st, 1, i + 1);
        sqlite3_bind_int(st, 2, i % 7);
        sqlite3_bind_int(st, 3, (i * 37) % 1000);
        sqlite3_bind_text(st, 4, name, -1, SQLITE_STATIC);
        if (i % 50 == 0)
            sqlite3_bind_blob(st, 5, bigblob, (int)sizeof(bigblob), SQLITE_STATIC);
        else
            sqlite3_bind_blob(st, 5, smallblob, (i % 32) + 1, SQLITE_STATIC);
        rc = sqlite3_step(st);
        if (i == 0) out[4] = (unsigned)rc;
        if (i == 249) out[5] = (unsigned)rc;
        if (i == 499) out[6] = (unsigned)rc;
        if (rc != SQLITE_DONE) {
            setmsg(sqlite3_errmsg(db));
            sqlite3_finalize(st);
            goto done;
        }
        sqlite3_reset(st);
    }
    sqlite3_finalize(st);
    st = 0;

    rc = sqlite3_exec(db, "COMMIT", 0, 0, &err);
    out[7] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_exec(db, "CREATE INDEX s_grp ON s(grp)", 0, 0, &err);
    out[8] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_exec(db, "CREATE INDEX s_txt ON s(txt)", 0, 0, &err);
    out[9] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db,
        "SELECT count(*),sum(val),min(id),max(id) FROM s", -1, &st, 0);
    out[10] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[11] = (unsigned)rc;
        out[12] = (unsigned)sqlite3_column_int(st, 0);
        out[13] = (unsigned)sqlite3_column_int(st, 1);
        out[14] = (unsigned)sqlite3_column_int(st, 2);
        out[15] = (unsigned)sqlite3_column_int(st, 3);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_prepare_v2(db,
        "SELECT count(*),sum(val) FROM s WHERE grp=3", -1, &st, 0);
    out[16] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[17] = (unsigned)rc;
        out[18] = (unsigned)sqlite3_column_int(st, 0);
        out[19] = (unsigned)sqlite3_column_int(st, 1);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_prepare_v2(db,
        "SELECT id FROM s WHERE id BETWEEN 100 AND 111 ORDER BY id",
        -1, &st, 0);
    out[20] = (unsigned)rc;
    if (!rc) {
        n = 0;
        while (sqlite3_step(st) == SQLITE_ROW && n < 12) {
            out[21 + n] = (unsigned)sqlite3_column_int(st, 0);
            n++;
        }
        out[33] = (unsigned)n;
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_prepare_v2(db,
        "SELECT txt FROM s WHERE txt='row-250'", -1, &st, 0);
    out[34] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[35] = (unsigned)rc;
        out[36] = text4(sqlite3_column_text(st, 0));
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_prepare_v2(db,
        "SELECT grp,count(*),sum(val) FROM s GROUP BY grp ORDER BY grp",
        -1, &st, 0);
    out[37] = (unsigned)rc;
    if (!rc) {
        n = 0;
        while (sqlite3_step(st) == SQLITE_ROW && n < 7) {
            out[38 + 3 * n] = (unsigned)sqlite3_column_int(st, 0);
            out[39 + 3 * n] = (unsigned)sqlite3_column_int(st, 1);
            out[40 + 3 * n] = (unsigned)sqlite3_column_int(st, 2);
            n++;
        }
        out[59] = (unsigned)n;
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_prepare_v2(db,
        "SELECT length(data),data FROM s WHERE id=51", -1, &st, 0);
    out[60] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[61] = (unsigned)rc;
        out[62] = (unsigned)sqlite3_column_int(st, 0);
        n = sqlite3_column_bytes(st, 1);
        out[63] = (unsigned)n;
        out[64] = hashblob(sqlite3_column_blob(st, 1), n);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_exec(db, "UPDATE s SET val=val+1 WHERE grp=0", 0, 0, &err);
    out[65] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db,
        "SELECT sum(val) FROM s WHERE grp=0", -1, &st, 0);
    out[66] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[67] = (unsigned)rc;
        out[68] = (unsigned)sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_exec(db, "DELETE FROM s WHERE id%10=0", 0, 0, &err);
    out[69] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM s", -1, &st, 0);
    out[70] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[71] = (unsigned)rc;
        out[72] = (unsigned)sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_prepare_v2(db, "PRAGMA freelist_count", -1, &st, 0);
    out[73] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[74] = (unsigned)rc;
        out[75] = (unsigned)sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_exec(db, "VACUUM", 0, 0, &err);
    out[76] = (unsigned)rc;
    if (rc) { setmsg(err ? err : sqlite3_errmsg(db)); goto done; }
    sqlite3_free(err); err = 0;

    rc = sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &st, 0);
    out[77] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[78] = (unsigned)rc;
        out[79] = sqlite3_column_text(st, 0)
                ? ((unsigned)sqlite3_column_text(st, 0)[0]
                   | ((unsigned)sqlite3_column_text(st, 0)[1] << 8)) : 0;
        sqlite3_finalize(st);
        st = 0;
    }

    out[80] = (unsigned)sqlite3_close(db);
    db = 0;
    rc = sqlite3_open("stress.db", &db);
    out[81] = (unsigned)rc;
    if (rc) { setmsg(sqlite3_errmsg(db)); goto done; }

    rc = sqlite3_prepare_v2(db,
        "SELECT count(*),sum(val) FROM s", -1, &st, 0);
    out[82] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[83] = (unsigned)rc;
        out[84] = (unsigned)sqlite3_column_int(st, 0);
        out[85] = (unsigned)sqlite3_column_int(st, 1);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_prepare_v2(db,
        "SELECT length(data) FROM s WHERE id=51", -1, &st, 0);
    out[86] = (unsigned)rc;
    if (!rc) {
        rc = sqlite3_step(st);
        out[87] = (unsigned)rc;
        out[88] = (unsigned)sqlite3_column_int(st, 0);
        sqlite3_finalize(st);
        st = 0;
    }

    rc = sqlite3_prepare_v2(db,
        "SELECT id FROM s ORDER BY val,id LIMIT 5", -1, &st, 0);
    out[89] = (unsigned)rc;
    if (!rc) {
        n = 0;
        while (sqlite3_step(st) == SQLITE_ROW && n < 5) {
            out[90 + n] = (unsigned)sqlite3_column_int(st, 0);
            n++;
        }
        out[95] = (unsigned)n;
        sqlite3_finalize(st);
        st = 0;
    }

done:
    out[255] = 0x444E4521u;
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
