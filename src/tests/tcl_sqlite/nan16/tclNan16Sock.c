/*
 * tclNan16Sock.c -- explicit socket stubs for NaN16 milestone 1.
 *
 * The guest has no socket system calls.  These functions fail with a clear
 * TCL_ERROR instead of fabricating a channel.  The Tcl-level [socket] command
 * is not installed (its Unix implementation is not part of this port yet).
 */
#include "tclInt.h"

int
TclSockGetPort(
    Tcl_Interp *interp,
    const char *string,
    const char *proto,
    int *portPtr)
{
    (void)proto;
    /* Numeric ports are still parsed; service names are unsupported. */
    if (Tcl_GetInt(interp, string, portPtr) == TCL_OK) {
	if (*portPtr > 0xFFFF) {
	    Tcl_SetObjResult(interp, Tcl_NewStringObj(
		    "couldn't open socket: port number too high", -1));
	    return TCL_ERROR;
	}
	return TCL_OK;
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(
	    "network sockets are not supported on NaN16", -1));
    Tcl_SetErrorCode(interp, "TCL", "SOCKET", "UNSUPPORTED", (char *)NULL);
    return TCL_ERROR;
}

const char *
Tcl_GetHostName(void)
{
    return "nan16";
}

int
TclSockMinimumBuffers(    void *sock,
    Tcl_Size size)
{
    (void)sock; (void)size;
    errno = EOPNOTSUPP;
    return -1;
}

Tcl_Channel
Tcl_MakeTcpClientChannel(
    void *tcpSocket)
{
    (void)tcpSocket;
    errno = EOPNOTSUPP;
    return NULL;
}

Tcl_Channel
Tcl_OpenTcpClient(
    Tcl_Interp *interp,
    int port,
    const char *address,
    const char *myaddr,
    int myport,
    int async)
{
    (void)port; (void)address; (void)myaddr; (void)myport; (void)async;
    Tcl_SetObjResult(interp, Tcl_NewStringObj(
	    "network sockets are not supported on NaN16", -1));
    Tcl_SetErrorCode(interp, "TCL", "SOCKET", "UNSUPPORTED", (char *)NULL);
    return NULL;
}

Tcl_Channel
Tcl_OpenTcpServer(
    Tcl_Interp *interp,
    int port,
    const char *host,
    Tcl_TcpAcceptProc *acceptProc,
    void *callbackData)
{
    (void)port; (void)host; (void)acceptProc; (void)callbackData;
    Tcl_SetObjResult(interp, Tcl_NewStringObj(
	    "network sockets are not supported on NaN16", -1));
    Tcl_SetErrorCode(interp, "TCL", "SOCKET", "UNSUPPORTED", (char *)NULL);
    return NULL;
}

Tcl_Channel
Tcl_OpenTcpServerEx(
    Tcl_Interp *interp,
    const char *service,
    const char *host,
    unsigned int flags,
    int backlog,
    Tcl_TcpAcceptProc *acceptProc,
    void *callbackData)
{
    (void)service; (void)host; (void)flags; (void)backlog;
    (void)acceptProc; (void)callbackData;
    Tcl_SetObjResult(interp, Tcl_NewStringObj(
	    "network sockets are not supported on NaN16", -1));
    Tcl_SetErrorCode(interp, "TCL", "SOCKET", "UNSUPPORTED", (char *)NULL);
    return NULL;
}
