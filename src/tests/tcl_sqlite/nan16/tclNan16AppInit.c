/*
 * tclNan16AppInit.c -- tclsh entry point for the NaN16 guest.
 *
 * The NaN16 flat-cartridge ABI enters main() with no argv.  The guest script
 * is therefore a VFS path, /test.tcl, supplied by the cartridge pack.  A
 * minimal /usr/lib/tcl9.0/init.tcl must also be present for Tcl_Init.
 */
#include "tclInt.h"
#include "tcl_nan16_pack.h"

int
main(void)
{
    Tcl_Interp *interp;

    if (nan16_vfs_add_pack(tcl_nan16_pack, tcl_nan16_pack_len) < 0) {
	fprintf(stderr, "tclsh: cannot mount guest VFS pack\n");
	return 1;
    }
    Tcl_FindExecutable("/tclsh");
    interp = Tcl_CreateInterp();
    if (interp == NULL) {
	fprintf(stderr, "tclsh: cannot create interpreter\n");
	return 1;
    }
    Tcl_SetVar2(interp, "tcl_library", NULL, TCL_NAN16_LIBRARY,
	    TCL_GLOBAL_ONLY);
    if (Tcl_Init(interp) != TCL_OK) {
	fprintf(stderr, "tclsh: %s\n", Tcl_GetStringResult(interp));
	return 1;
    }
    if (Tcl_EvalFile(interp, "/test.tcl") != TCL_OK) {
	fprintf(stderr, "%s\n", Tcl_GetStringResult(interp));
	return 1;
    }
    return 0;
}
