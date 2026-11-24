/*
 * tclNan16Notfy.c -- single-threaded notifier for NaN16.
 *
 * There is no select() and no file-event source in the guest yet.  Timers
 * work: TclpSetTimer records the next deadline and TclpWaitForEvent sleeps on
 * the guest monotonic clock.  File handlers are accepted but never fire.
 */
#include "tclInt.h"

static int notifierToken;
static int timerActive;
static Tcl_Time timerTime;

void *
TclpInitNotifier(void)
{
    return &notifierToken;
}

void
TclpFinalizeNotifier(
    TCL_UNUSED(void *))
{
    timerActive = 0;
}

void
TclpAlertNotifier(
    TCL_UNUSED(void *))
{
}

void *
TclpNotifierData(void)
{
    return &notifierToken;
}

void
TclpSetTimer(
    const Tcl_Time *timePtr)
{
    if (timePtr == NULL) {
	timerActive = 0;
    } else {
	timerTime = *timePtr;
	timerActive = 1;
    }
}

int
TclpWaitForEvent(
    const Tcl_Time *timePtr)
{
    if (timePtr != NULL) {
	Tcl_Time now;
	long long usec;

	Tcl_GetTime(&now);
	usec = ((long long)timePtr->sec - (long long)now.sec) * 1000000LL
		+ ((long long)timePtr->usec - (long long)now.usec);
	if (usec > 0) {
	    Tcl_Sleep((int)((usec + 999) / 1000));
	}
	return 0;
    }

    /*
     * No fd events exist.  If a timer is pending, sleep to its deadline and
     * report a timeout so the generic event loop can dispatch the timer.
     */
    if (timerActive) {
	int fired = 0;
	Tcl_Time now;

	Tcl_GetTime(&now);
	if (timerTime.sec > now.sec
		|| (timerTime.sec == now.sec && timerTime.usec > now.usec)) {
	    long long usec = ((long long)timerTime.sec - (long long)now.sec)
		    * 1000000LL
		    + ((long long)timerTime.usec - (long long)now.usec);
	    Tcl_Sleep((int)((usec + 999) / 1000));
	    fired = 1;
	}
	timerActive = 0;
	if (fired) {
	    return 0;
	}
    }
    return 0;
}

void
TclpCreateFileHandler(
    TCL_UNUSED(int),
    TCL_UNUSED(int),
    TCL_UNUSED(Tcl_FileProc *),
    TCL_UNUSED(void *))
{
}

void
TclpDeleteFileHandler(
    TCL_UNUSED(int))
{
}

void
TclpFinalizePipes(void)
{
}

void
TclpFinalizeSockets(void)
{
}

void
TclpServiceModeHook(
    TCL_UNUSED(int))
{
}
