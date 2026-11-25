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
 * -Dsqlite3TestInit=Sqlite3OfficialTestInit and wrapped here to initialize
 * the real Tcl 9.0.3 library from /usr/lib/tcl9.0, register the libc-backed
 * SQLite VFS on every slave interpreter, and adapt the guest's
 * non-terminating exit() into a recorded status.  The script path comes from
 * the 0x03EFF020 guest control block written by nan_cli/s1_runner.
 */
#include "tcl.h"
#include "tclInt.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "tcl_nan16_fixture_pack.h"

extern int Sqlite3TestMain(int argc, char **argv);
extern const char *Sqlite3OfficialTestInit(Tcl_Interp *interp);
const char *sqlite3TestInit(Tcl_Interp *interp);

static int nan16_exit_code = -1;
static char nan16_script_path[1024] = "/sqlite/test/select1.test";

static const char *
Nan16GuestScriptPath(void)
{
    unsigned n = *(volatile unsigned *)0x03EFF020u;

    if (n == 0 || n >= sizeof(nan16_script_path)) {
	return "/sqlite/test/select1.test";
    }
    memcpy(nan16_script_path, (const void *)0x03EFF024u, n);
    nan16_script_path[n] = 0;
    return nan16_script_path;
}

static int
Nan16LoadExtensionsCmd(
    void *clientData,
    Tcl_Interp *interp,
    int objc,
    Tcl_Obj *const objv[])
{
    Tcl_Interp *slave;

    (void)clientData;
    if (objc != 2) {
	Tcl_WrongNumArgs(interp, 1, objv, "SLAVE");
	return TCL_ERROR;
    }
    slave = Tcl_GetChild(interp, Tcl_GetString(objv[1]));
    if (slave == NULL) {
	return TCL_ERROR;
    }
    (void)sqlite3TestInit(slave);
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
    int isSlave = (Tcl_GetParent(interp) != NULL);

    Tcl_InitStubs(interp, "8.5-", 0);
    if (!isSlave) {
	Tcl_SetVar2(interp, "tcl_library", NULL, "/usr/lib/tcl9.0",
		TCL_GLOBAL_ONLY);
	if (Tcl_Init(interp) != TCL_OK) {
	    fprintf(stderr, "testfixture: Tcl_Init: %s\n",
		    Tcl_GetStringResult(interp));
	}
    }
    (void)Sqlite3OfficialTestInit(interp);
    Tcl_CreateObjCommand(interp, "load_testfixture_extensions",
	    Nan16LoadExtensionsCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "nan16_record_exit", Nan16RecordExitCmd,
	    NULL, NULL);
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
    static char *argv[] = { (char *)"/testfixture", NULL, NULL };
    int rc;

    if (nan16_vfs_add_pack((const void *)GUEST_PACK_BASE, GUEST_PACK_LEN) < 0) {
	fprintf(stderr, "testfixture: cannot mount guest VFS pack\n");
	return 1;
    }
    argv[1] = (char *)Nan16GuestScriptPath();
    rc = Sqlite3TestMain(2, argv);
    if (nan16_exit_code >= 0) {
	return nan16_exit_code ? 1 : 0;
    }
    return rc ? 1 : 0;
}
