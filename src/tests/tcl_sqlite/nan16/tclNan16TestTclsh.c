/*
 * tclNan16TestTclsh.c -- compile the official test_tclsh.c under a rename.
 *
 * The official testfixture init is used unchanged, but renamed to
 * Sqlite3OfficialTestInit so the NaN16 entry wrapper can install the guest
 * exit adapter and the real Tcl library path before returning.
 */
#define sqlite3TestInit Sqlite3OfficialTestInit
#include "test_tclsh.c"
