/*
 * tclNan16TestStubs.c -- intentionally absent official testfixture modules.
 *
 * Milestone 2 compiles only the TESTSRC objects needed for test/select1.test.
 * test_tclsh.c still calls every official module initializer, so the modules
 * outside this slice get an empty TCL_OK initializer here.  No test command
 * is fabricated: if a later test file calls one of these commands, Tcl
 * reports "invalid command name", which the gate records as a real failure.
 */
#include "tcl.h"

#define EMPTY_INIT(name) \
    int name(Tcl_Interp *interp) { (void)interp; return TCL_OK; }

EMPTY_INIT(Sqlitetest3_Init)
EMPTY_INIT(Sqlitetest4_Init)
EMPTY_INIT(Sqlitetest5_Init)
EMPTY_INIT(Sqlitetest6_Init)
EMPTY_INIT(Sqlitetest8_Init)
EMPTY_INIT(Sqlitetest9_Init)
EMPTY_INIT(Sqlitetest_blob_Init)
EMPTY_INIT(Sqlitetest_demovfs_Init)
EMPTY_INIT(Sqlitetest_init_Init)
EMPTY_INIT(Sqlitetestschema_Init)
EMPTY_INIT(Sqlitetestsse_Init)
EMPTY_INIT(Sqlitetesttclvar_Init)
EMPTY_INIT(Sqlitetestfs_Init)
EMPTY_INIT(SqlitetestThread_Init)
EMPTY_INIT(SqlitetestOsinst_Init)
EMPTY_INIT(Sqlitetestbackup_Init)
EMPTY_INIT(Sqlitetestintarray_Init)
EMPTY_INIT(Sqlitetestrtree_Init)
EMPTY_INIT(Sqlitetestrtreedoc_Init)
EMPTY_INIT(Sqlitequota_Init)
EMPTY_INIT(Sqlitemultiplex_Init)
EMPTY_INIT(SqliteSuperlock_Init)
EMPTY_INIT(SqlitetestSyscall_Init)
EMPTY_INIT(Fts5tcl_Init)
EMPTY_INIT(SqliteRbu_Init)
EMPTY_INIT(Sqlitetesttcl_Init)
EMPTY_INIT(TestExpert_Init)
EMPTY_INIT(Sqlitetest_window_Init)
EMPTY_INIT(Sqlitetestvdbecov_Init)
EMPTY_INIT(TestRecover_Init)
EMPTY_INIT(Sqlitetestintck_Init)
EMPTY_INIT(Sqlitetestfts3_Init)

int
SqlitetestOnefile_Init(void)
{
    return TCL_OK;
}
