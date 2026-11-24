/*
 * tclNan16TestEntry.c -- NaN16 entry wrapper for the official testfixture.
 *
 * tclsqlite.c is compiled with -DTCLSH_INIT_PROC=sqlite3TestInit and
 * -DTCLSH_MAIN=Sqlite3TestMain, so the official testfixture main() and its
 * Tcl script driver are used unchanged.  The NaN16 flat-cartridge ABI calls
 * main() with no argv, so this wrapper supplies the same argv a host shell
 * would: { "/testfixture", "/sqlite/test/select1.test" }.
 *
 * test_tclsh.c supplies the official sqlite3TestInit(); it is compiled with
 * -Dsqlite3TestInit=Sqlite3OfficialTestInit and wrapped here to:
 *   - initialize the real Tcl 9.0.3 library from /usr/lib/tcl9.0,
 *   - mirror Tcl [file delete] calls into the SQLite "nan16" VFS (the
 *     official tester's reset_db deletes test.db between test groups),
 *   - convert the guest's non-terminating exit() into a recorded status.
 */
#include "tcl.h"
#include "tclInt.h"
#include "sqlite3.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "tcl_nan16_fixture_pack.h"

extern int Sqlite3TestMain(int argc, char **argv);
extern const char *Sqlite3OfficialTestInit(Tcl_Interp *interp);

static int nan16_exit_code = -1;

static void
Nan16SqliteDeleteName(
    const char *name)
{
    sqlite3_vfs *vfs = sqlite3_vfs_find("nan16");

    if (vfs == NULL) {
	vfs = sqlite3_vfs_find(NULL);
    }
    if (vfs != NULL && vfs->xDelete != NULL) {
	(void)vfs->xDelete(vfs, name, 0);
    }
}

static int
Nan16SqliteDeleteCmd(
    void *clientData,
    Tcl_Interp *interp,
    int objc,
    Tcl_Obj *const objv[])
{
    int i;

    (void)clientData;
    (void)interp;
    for (i = 1; i < objc; i++) {
	const char *path = Tcl_GetString(objv[i]);
	const char *base;
	const char *slash;
	char rel[256];

	if (path[0] == '-') {
	    continue;
	}
	Nan16SqliteDeleteName(path);
	if (path[0] != '/') {
	    snprintf(rel, sizeof(rel), "./%s", path);
	    Nan16SqliteDeleteName(rel);
	}
	slash = strrchr(path, '/');
	base = slash ? slash + 1 : path;
	Nan16SqliteDeleteName(base);
	if (slash != NULL) {
	    snprintf(rel, sizeof(rel), "./%s", base);
	    Nan16SqliteDeleteName(rel);
	}
    }
    return TCL_OK;
}

static int
Nan16RecordExitCmd(
    void *clientData,
    Tcl_Interp *interp,
    int objc,
    Tcl_Obj *const objv[])
{
    int code = 0;

    (void)clientData;
    (void)interp;
    if (objc > 1) {
	if (Tcl_GetIntFromObj(interp, objv[1], &code) != TCL_OK) {
	    code = 1;
	}
    }
    nan16_exit_code = code;
    return TCL_OK;
}

const char *
sqlite3TestInit(
    Tcl_Interp *interp)
{
    Tcl_InitStubs(interp, "8.5-", 0);
    Tcl_SetVar2(interp, "tcl_library", NULL, "/usr/lib/tcl9.0",
	    TCL_GLOBAL_ONLY);
    if (Tcl_Init(interp) != TCL_OK) {
	fprintf(stderr, "testfixture: Tcl_Init: %s\n",
		Tcl_GetStringResult(interp));
    }
    (void)Sqlite3OfficialTestInit(interp);
    Tcl_CreateObjCommand(interp, "nan16_record_exit", Nan16RecordExitCmd,
	    NULL, NULL);
    Tcl_CreateObjCommand(interp, "nan16_sqlite_delete",
	    Nan16SqliteDeleteCmd, NULL, NULL);
    Tcl_Eval(interp,
	    "rename file nan16_file_orig\n"
	    "proc file {args} {\n"
	    "    set sub [lindex $args 0]\n"
	    "    if {[string match del* $sub]} {\n"
	    "        foreach p [lrange $args 1 end] {\n"
	    "            if {[string index $p 0] ne \"-\"} {\n"
	    "                catch {nan16_sqlite_delete $p}\n"
	    "            }\n"
	    "        }\n"
	    "    }\n"
	    "    uplevel 1 [linsert $args 0 nan16_file_orig]\n"
	    "}\n");
    /*
     * The guest libc's exit() cannot terminate the flat cartridge.  Record
     * the official exit status and turn it into a normal Tcl error so the
     * official testfixture main loop stops and this wrapper can return it.
     */
    Tcl_Eval(interp,
	    "rename exit nan16_original_exit\n"
	    "proc exit {args} {\n"
	    "    set code 0\n"
	    "    if {[llength $args]} {set code [lindex $args 0]}\n"
	    "    nan16_record_exit $code\n"
	    "    return -code error -errorcode {NAN16 EXIT} \"NAN16_EXIT $code\"\n"
	    "}\n");
    return 0;
}

int
main(void)
{
    static char *argv[] = { (char *)"/testfixture",
	    (char *)"/sqlite/test/select1.test", NULL };
    int rc;

    if (nan16_vfs_add_pack((const void *)GUEST_PACK_BASE, GUEST_PACK_LEN) < 0) {
	fprintf(stderr, "testfixture: cannot mount guest VFS pack\n");
	return 1;
    }
    rc = Sqlite3TestMain(2, argv);
    if (nan16_exit_code >= 0) {
	return nan16_exit_code ? 1 : 0;
    }
    return rc ? 1 : 0;
}
