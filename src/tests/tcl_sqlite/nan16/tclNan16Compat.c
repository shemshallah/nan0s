/*
 * tclNan16Compat.c -- libc gaps and fixed C locale for the NaN16 Tcl port.
 *
 * These are real, small implementations (or explicit failures) for the few
 * POSIX calls generic Tcl uses that the guest libc does not provide.  The
 * locale is always the C locale and has no numeric side effects.
 */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include <sys/types.h>
#include <errno.h>
#include <locale.h>
#include <utime.h>
#include <signal.h>

char *strndup(const char *s, size_t n)
{
    size_t len = 0;
    char *d;
    while (len < n && s[len]) len++;
    d = (char *)malloc(len + 1);
    if (!d) return NULL;
    memcpy(d, s, len);
    d[len] = 0;
    return d;
}

int strcasecmp(const char *a, const char *b)
{
    unsigned char ca, cb;
    while (*a && *b) {
	ca = (unsigned char)*a++;
	cb = (unsigned char)*b++;
	if (ca >= 'A' && ca <= 'Z') ca += 'a' - 'A';
	if (cb >= 'A' && cb <= 'Z') cb += 'a' - 'A';
	if (ca != cb) return (int)ca - (int)cb;
    }
    return (unsigned char)*a - (unsigned char)*b;
}

int strncasecmp(const char *a, const char *b, size_t n)
{
    unsigned char ca, cb;
    while (n && *a && *b) {
	ca = (unsigned char)*a++;
	cb = (unsigned char)*b++;
	if (ca >= 'A' && ca <= 'Z') ca += 'a' - 'A';
	if (cb >= 'A' && cb <= 'Z') cb += 'a' - 'A';
	if (ca != cb) return (int)ca - (int)cb;
	n--;
    }
    if (!n) return 0;
    return (unsigned char)*a - (unsigned char)*b;
}

char *setlocale(int category, const char *locale)
{
    (void)category;
    if (locale && strcmp(locale, "C") && strcmp(locale, "POSIX")
	    && strcmp(locale, "")) {
	return NULL;
    }
    return (char *)"C";
}

struct lconv *localeconv(void)
{
    static struct lconv c = {
	".", "", "", "", "", "", "", "", "", "",
	127, 127, 0, 0, 0, 0, 0, 0
    };
    return &c;
}

struct tm *gmtime_r(const time_t *t, struct tm *out)
{
    struct tm *p = gmtime(t);
    if (!p) return NULL;
    *out = *p;
    return out;
}

struct tm *localtime_r(const time_t *t, struct tm *out)
{
    struct tm *p = localtime(t);
    if (!p) return NULL;
    *out = *p;
    return out;
}

/* Days since 1970-01-01 for a proleptic Gregorian date. */
static long civil_days(int y, int m, int d)
{
    long era, yoe, doy, doe;
    y -= m <= 2;
    era = (y >= 0 ? y : y - 399) / 400;
    yoe = y - era * 400;
    doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

time_t mktime(struct tm *tm)
{
    long days;
    if (!tm) { errno = EINVAL; return (time_t)-1; }
    days = civil_days(tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday);
    return (time_t)(days * 86400L + tm->tm_hour * 3600L
	    + tm->tm_min * 60L + tm->tm_sec);
}

void tzset(void)
{
}

double difftime(time_t a, time_t b)
{
    return (double)a - (double)b;
}

int utime(const char *path, const struct utimbuf *times)
{
    (void)path; (void)times;
    errno = EACCES;
    return -1;
}

sighandler_t signal(int sig, sighandler_t handler)
{
    (void)sig; (void)handler;
    return SIG_DFL;
}

int raise(int sig)
{
    (void)sig;
    return 0;
}

int getuid(void) { return 0; }
int geteuid(void) { return 0; }
int getgid(void) { return 0; }
int getegid(void) { return 0; }
