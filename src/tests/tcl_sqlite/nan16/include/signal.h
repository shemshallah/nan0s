/* Minimal signal.h: Tcl 9 non-threaded builds do not install handlers. */
#ifndef _SIGNAL_H
#define _SIGNAL_H
#define SIGINT	2
#define SIGTERM	15
#define SIGPIPE	13
#define SIGSEGV	11
#define SIGFPE	8
#define SIGABRT	6
#define SIG_DFL	((void (*)(int))0)
#define SIG_IGN	((void (*)(int))1)
typedef void (*sighandler_t)(int);
sighandler_t signal(int sig, sighandler_t handler);
int raise(int sig);
#endif
