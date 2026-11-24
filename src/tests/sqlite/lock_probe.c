#include "sqlite3.h"
#include <stdio.h>

static int lock_row(void *unused, int n, char **v, char **c)
{
    (void)unused; (void)c;
    if (n >= 2) printf("lockrow %s %s\n", v[0] ? v[0] : "", v[1] ? v[1] : "");
    return 0;
}

static int run(sqlite3 *db, const char *sql)
{
    char *err = 0;
    int rc = sqlite3_exec(db, sql, 0, 0, &err);
    printf("sql rc=%d %s\n", rc, err ? err : "");
    if (err) sqlite3_free(err);
    return rc;
}

int main(void)
{
    sqlite3 *a = 0, *b = 0;
    int rc;
    printf("openA rc=%d\n", sqlite3_open("lock.db", &a));
    run(a, "CREATE TABLE t(x)");
    run(a, "BEGIN IMMEDIATE");
    run(a, "INSERT INTO t VALUES(1)");
    printf("openB rc=%d\n", sqlite3_open("lock.db", &b));
    sqlite3_busy_timeout(b, 0);
    rc = run(b, "INSERT INTO t VALUES(2)");
    printf("second_insert_rc=%d\n", rc);
    run(a, "COMMIT");
    printf("after_commit_rc=%d\n", run(b, "INSERT INTO t VALUES(3)"));
    run(b, "COMMIT");
    sqlite3_close(b);
    {
        sqlite3 *c = 0, *d = 0;
        int nrc = sqlite3_open_v2("/nodir/nofile.x", &c,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, 0);
        printf("nodir_open_rc=%d\n", nrc);
        sqlite3_close(c);
        printf("readonly_open_rc=%d\n", sqlite3_open_v2("lock.db", &d,
                SQLITE_OPEN_READONLY, 0));
        printf("readonly_insert_rc=%d\n", run(d, "INSERT INTO t VALUES(4)"));
        sqlite3_close(d);
    }
    {
        sqlite3 *p = 0, *q = 0;
        sqlite3_open("pending.db", &p);
        run(p, "CREATE TABLE t(x)");
        sqlite3_open("pending.db", &q);
        run(p, "BEGIN IMMEDIATE");
        run(q, "BEGIN");
        run(q, "SELECT * FROM t");
        printf("pending_commit_rc=%d\n", run(p, "COMMIT"));
        sqlite3_exec(p, "PRAGMA lock_status", lock_row, 0, 0);
        run(q, "COMMIT");
        sqlite3_close(p);
        sqlite3_close(q);
    }
    sqlite3_close(a);
    printf("LOCK %s\n", (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) ? "PASS" : "FAIL");
    return 0;
}
