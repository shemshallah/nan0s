/*
 * tclNan16Init.c -- process/interpreter platform initialization for NaN16.
 *
 * No signals, no users, no host environment.  The library path is the guest
 * VFS path /usr/lib/tcl9.0 (overridable by env(TCL_LIBRARY)).
 */
#include "tclInt.h"

static void NativeGetTime(Tcl_Time *timePtr, void *clientData);
static void NativeScaleTime(Tcl_Time *timePtr, void *clientData);

Tcl_GetTimeProc *tclGetTimeProcPtr = NativeGetTime;
Tcl_ScaleTimeProc *tclScaleTimeProcPtr = NativeScaleTime;
void *tclTimeClientData = NULL;

static void
NativeGetTime(
    Tcl_Time *timePtr,
    TCL_UNUSED(void *))
{
    struct timeval tv;

    gettimeofday(&tv, NULL);
    timePtr->sec = (long)tv.tv_sec;
    timePtr->usec = (long)tv.tv_usec;
}

static void
NativeScaleTime(
    TCL_UNUSED(Tcl_Time *),
    TCL_UNUSED(void *))
{
}

void
Tcl_GetTime(
    Tcl_Time *timePtr)
{
    tclGetTimeProcPtr(timePtr, tclTimeClientData);
}

void
Tcl_SetTimeProc(
    Tcl_GetTimeProc *getProc,
    Tcl_ScaleTimeProc *scaleProc,
    void *clientData)
{
    tclGetTimeProcPtr = getProc ? getProc : NativeGetTime;
    tclScaleTimeProcPtr = scaleProc ? scaleProc : NativeScaleTime;
    tclTimeClientData = clientData;
}

void
Tcl_QueryTimeProc(
    Tcl_GetTimeProc **getProc,
    Tcl_ScaleTimeProc **scaleProc,
    void **clientData)
{
    if (getProc) *getProc = tclGetTimeProcPtr;
    if (scaleProc) *scaleProc = tclScaleTimeProcPtr;
    if (clientData) *clientData = tclTimeClientData;
}

unsigned long long
TclpGetSeconds(void)
{
    return (unsigned long long)time(NULL);
}

long long
TclpGetMicroseconds(void)
{
    Tcl_Time t;
    Tcl_GetTime(&t);
    return (long long)t.sec * 1000000LL + (long long)t.usec;
}

unsigned long long
TclpGetClicks(void)
{
    Tcl_Time t;
    Tcl_GetTime(&t);
    return (unsigned long long)t.sec * 1000000ULL
	    + (unsigned long long)t.usec;
}

void
Tcl_Sleep(
    int ms)
{
    struct timespec ts;

    if (ms <= 0) {
	return;
    }
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

extern int (*nan16_digits_hook)(double, char *, int *);
static int
Nan16DoubleDigits(
    double value,
    char *digits,
    int *exponent)
{
    int decpt, sign, i;
    char *end, *s;

    s = TclDoubleDigits(value, -1, TCL_DD_SHORTEST, &decpt, &sign, &end);
    if (s == NULL) {
	return -1;
    }
    for (i = 0; i < 17; i++) {
	digits[i] = (s + i < end) ? s[i] : '0';
    }
    *exponent = decpt;
    Tcl_Free(s);
    return 0;
}

void
TclpInitPlatform(void)
{
    /*
     * tclPlatform is statically TCL_PLATFORM_UNIX.  The guest has no
     * signals to arrange; fd 0/1/2 are emulated by the libc console.
     */
    nan16_digits_hook = Nan16DoubleDigits;
}

void
TclpInitLock(void)
{
}

void
TclpInitUnlock(void)
{
}

void
TclpGlobalLock(void)
{
}

void
TclpGlobalUnlock(void)
{
}

void
TclFinalizeLock(void)
{
}

static int allocMutexToken;

Tcl_Mutex *
Tcl_GetAllocMutex(void)
{
    return (Tcl_Mutex *)&allocMutexToken;
}

void
TclpFindExecutable(
    const char *argv0)
{
    if (argv0 != NULL && argv0[0] != '\0') {
	TclSetObjNameOfExecutable(Tcl_NewStringObj(argv0, TCL_INDEX_NONE),
		NULL);
    } else {
	TclSetObjNameOfExecutable(Tcl_NewStringObj("/tclsh", TCL_INDEX_NONE),
		NULL);
    }
}

const char *
TclpGetUserHome(
    TCL_UNUSED(const char *),
    TCL_UNUSED(Tcl_DString *))
{
    /* No passwd database in the guest. */
    return NULL;
}

const char *
TclpGetCwd(
    Tcl_Interp *interp,
    Tcl_DString *bufferPtr)
{
    char buffer[MAXPATHLEN + 1];

    if (getcwd(buffer, sizeof(buffer)) == NULL) {
	if (interp != NULL) {
	    Tcl_SetObjResult(interp, Tcl_ObjPrintf(
		    "error getting working directory name: %s",
		    Tcl_PosixError(interp)));
	}
	return NULL;
    }
    Tcl_DStringAppend(bufferPtr, buffer, TCL_INDEX_NONE);
    return Tcl_DStringValue(bufferPtr);
}

Tcl_Size
TclpFindVariable(
    const char *name,
    Tcl_Size *lengthPtr)
{
    Tcl_Size i, result = -1;
    size_t len = strlen(name);

    for (i = 0; environ[i] != NULL; i++) {
	if (!strncmp(environ[i], name, len) && environ[i][len] == '=') {
	    *lengthPtr = (Tcl_Size)len;
	    result = i;
	    goto done;
	}
    }
    *lengthPtr = i;
done:
    return result;
}

void
TclpInitLibraryPath(
    char **valuePtr,
    TCL_HASH_TYPE *lengthPtr,
    Tcl_Encoding *encodingPtr)
{
    Tcl_Obj *pathPtr = Tcl_NewObj();
    const char *env = getenv("TCL_LIBRARY");
    const char *str;
    Tcl_Size len;

    if (env != NULL && env[0] != '\0') {
	Tcl_ListObjAppendElement(NULL, pathPtr, Tcl_NewStringObj(env, -1));
    }
    Tcl_ListObjAppendElement(NULL, pathPtr,
	    Tcl_NewStringObj(TCL_NAN16_LIBRARY, -1));
    Tcl_IncrRefCount(pathPtr);
    str = TclGetStringFromObj(pathPtr, &len);
    *valuePtr = (char *)Tcl_Alloc(len + 1);
    memcpy(*valuePtr, str, len + 1);
    *lengthPtr = (TCL_HASH_TYPE)len;
    *encodingPtr = Tcl_GetEncoding(NULL, NULL);
    Tcl_DecrRefCount(pathPtr);
}

const char *
Tcl_GetEncodingNameFromEnvironment(
    Tcl_DString *bufPtr)
{
    Tcl_DStringInit(bufPtr);
    Tcl_DStringAppend(bufPtr, "utf-8", 5);
    return Tcl_DStringValue(bufPtr);
}

void
TclpSetInitialEncodings(void)
{
    Tcl_SetSystemEncoding(NULL, "utf-8");
}

void
TclpSetVariables(
    Tcl_Interp *interp)
{
    Tcl_Obj *pkgList = Tcl_NewObj();

    Tcl_ListObjAppendElement(NULL, pkgList,
	    Tcl_NewStringObj(TCL_NAN16_LIBRARY, -1));
    Tcl_ObjSetVar2(interp, Tcl_NewStringObj("tcl_pkgPath", -1), NULL,
	    pkgList, TCL_GLOBAL_ONLY);

    Tcl_SetVar2(interp, "tcl_platform", "platform", "unix", TCL_GLOBAL_ONLY);
    Tcl_SetVar2(interp, "tcl_platform", "os", "NaN16", TCL_GLOBAL_ONLY);
    Tcl_SetVar2(interp, "tcl_platform", "osVersion", "1.0", TCL_GLOBAL_ONLY);
    Tcl_SetVar2(interp, "tcl_platform", "machine", "nan16", TCL_GLOBAL_ONLY);
    Tcl_SetVar2(interp, "tcl_platform", "user", "guest", TCL_GLOBAL_ONLY);
    Tcl_SetVar2(interp, "tcl_platform", "pathSeparator", ":", TCL_GLOBAL_ONLY);
}
