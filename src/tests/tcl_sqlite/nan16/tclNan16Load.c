/*
 * tclNan16Load.c -- dynamic loading and subprocess hooks.
 *
 * The guest has no ELF loader, no fork/exec and no pipe(2).  Every entry
 * point here fails explicitly with TCL_ERROR / NULL; nothing pretends to
 * load code or spawn a process.
 */
#include "tclInt.h"

int
TclpDlopen(
    Tcl_Interp *interp,
    Tcl_Obj *pathPtr,
    TCL_UNUSED(Tcl_LoadHandle *),
    TCL_UNUSED(Tcl_FSUnloadFileProc **),
    TCL_UNUSED(int))
{
    Tcl_SetObjResult(interp, Tcl_ObjPrintf(
	    "dynamic loading is not supported on NaN16: %s",
	    TclGetString(pathPtr)));
    Tcl_SetErrorCode(interp, "TCL", "LOAD", "UNSUPPORTED", (char *)NULL);
    errno = EINVAL;
    return TCL_ERROR;
}

int
TclpCreatePipe(
    TCL_UNUSED(TclFile *),
    TCL_UNUSED(TclFile *))
{
    errno = EINVAL;
    return 0;
}

int
TclUnixWaitForFile(
    int fd,
    int mask,
    int timeout)
{
    (void)fd; (void)timeout;
    /*
     * No select(2) in the guest.  VFS file descriptors are ordinary memory
     * files, so their requested readiness condition is always satisfied.
     */
    return mask & (TCL_READABLE | TCL_WRITABLE | TCL_EXCEPTION);
}

int
TclWinCPUID(
    TCL_UNUSED(int),
    TCL_UNUSED(int *))
{
    /* NaN16 has no x86 CPUID instruction. */
    return TCL_ERROR;
}

int
Tcl_JoinThread(
    Tcl_ThreadId threadId,
    int *result)
{
    (void)threadId;
    if (result) *result = 0;
    /* Single-threaded build: no joinable threads can exist. */
    return TCL_ERROR;
}

int
TclpCreateProcess(
    Tcl_Interp *interp,
    TCL_UNUSED(size_t),
    TCL_UNUSED(const char **),
    TCL_UNUSED(TclFile),
    TCL_UNUSED(TclFile),
    TCL_UNUSED(TclFile),
    TCL_UNUSED(Tcl_Pid *))
{
    Tcl_SetObjResult(interp, Tcl_NewStringObj(
	    "child processes are not supported on NaN16", -1));
    Tcl_SetErrorCode(interp, "TCL", "EXEC", "UNSUPPORTED", (char *)NULL);
    errno = EINVAL;
    return TCL_ERROR;
}

TCL_NORETURN void
TclpThreadExit(
    int status)
{
    exit(status);
}

static int mainThreadToken;

Tcl_ThreadId
Tcl_GetCurrentThread(void)
{
    return (Tcl_ThreadId)&mainThreadToken;
}

void
TclGetAndDetachPids(
    Tcl_Interp *interp,
    Tcl_Channel chan)
{
    (void)interp; (void)chan;
    /* No child processes can exist on NaN16. */
}

Tcl_Pid
Tcl_WaitPid(
    Tcl_Pid pid,
    int *statPtr,
    int options)
{
    (void)pid; (void)options;
    if (statPtr) *statPtr = 0;
    errno = ECHILD;
    return (Tcl_Pid)-1;
}

Tcl_Channel
TclpCreateCommandChannel(
    TclFile readFile,
    TclFile writeFile,
    TclFile errorFile,
    size_t numPids,
    Tcl_Pid *pidPtr)
{
    (void)readFile; (void)writeFile; (void)errorFile;
    (void)numPids; (void)pidPtr;
    errno = EOPNOTSUPP;
    return NULL;
}

int
Tcl_PidObjCmd(
    TCL_UNUSED(void *),
    Tcl_Interp *interp,
    int objc,
    Tcl_Obj *const objv[])
{
    if (objc > 2) {
	Tcl_WrongNumArgs(interp, 1, objv, "?channel?");
	return TCL_ERROR;
    }
    if (objc == 1) {
	Tcl_SetObjResult(interp, Tcl_NewWideIntObj((Tcl_WideInt)getpid()));
    } else {
	Tcl_Channel chan = Tcl_GetChannel(interp, TclGetString(objv[1]), NULL);
	if (chan == NULL) {
	    return TCL_ERROR;
	}
	/* No pipe channels exist; a non-pipe channel yields an empty list. */
	Tcl_SetObjResult(interp, Tcl_NewObj());
    }
    return TCL_OK;
}

int
Tcl_CreatePipe(
    Tcl_Interp *interp,
    Tcl_Channel *rchan,
    Tcl_Channel *wchan,
    int flags)
{
    (void)flags;
    if (rchan) *rchan = NULL;
    if (wchan) *wchan = NULL;
    Tcl_SetObjResult(interp, Tcl_NewStringObj(
	    "pipes are not supported on NaN16", -1));
    Tcl_SetErrorCode(interp, "TCL", "OPERATION", "PIPE", "UNSUPPORTED",
	    (char *)NULL);
    return TCL_ERROR;
}
