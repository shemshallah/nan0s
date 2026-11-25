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
#include <stdio.h>

double atof(const char *s) { return strtod(s, 0); }

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

long
sysconf(int name)
{
    (void)name;
    return 1;
}


int
chown(const char *path, unsigned int uid, unsigned int gid)
{
    (void)path; (void)uid; (void)gid;
    errno = EOPNOTSUPP;
    return -1;
}


int
fchmod(int fd, unsigned int mode)
{
    (void)fd; (void)mode;
    errno = EOPNOTSUPP;
    return -1;
}



void
rewind(FILE *stream)
{
    if (stream) {
	fseek(stream, 0L, SEEK_SET);
	clearerr(stream);
    }
}

size_t
strftime(char *s, size_t max, const char *format, const struct tm *tm)
{
    static const char *const wday[] = {
	"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
	"Friday", "Saturday"
    };
    static const char *const mon[] = {
	"January", "February", "March", "April", "May", "June",
	"July", "August", "September", "October", "November", "December"
    };
    size_t out = 0;
    const char *p;

#define PUTCHAR(c) do { if (out + 1 < max) s[out] = (char)(c); out++; } while (0)
    for (p = format; *p; p++) {
	char tmp[64];
	int n = 0;
	if (*p != '%') {
	    PUTCHAR(*p);
	    continue;
	}
	p++;
	switch (*p) {
	case 'Y': n = snprintf(tmp, sizeof(tmp), "%d", tm->tm_year + 1900); break;
	case 'y': n = snprintf(tmp, sizeof(tmp), "%02d", (tm->tm_year + 1900) % 100); break;
	case 'm': n = snprintf(tmp, sizeof(tmp), "%02d", tm->tm_mon + 1); break;
	case 'd': n = snprintf(tmp, sizeof(tmp), "%02d", tm->tm_mday); break;
	case 'e': n = snprintf(tmp, sizeof(tmp), "%2d", tm->tm_mday); break;
	case 'H': n = snprintf(tmp, sizeof(tmp), "%02d", tm->tm_hour); break;
	case 'k': n = snprintf(tmp, sizeof(tmp), "%2d", tm->tm_hour); break;
	case 'I': {
	    int h = tm->tm_hour % 12;
	    if (h == 0) h = 12;
	    n = snprintf(tmp, sizeof(tmp), "%02d", h);
	    break;
	}
	case 'l': {
	    int h = tm->tm_hour % 12;
	    if (h == 0) h = 12;
	    n = snprintf(tmp, sizeof(tmp), "%2d", h);
	    break;
	}
	case 'M': n = snprintf(tmp, sizeof(tmp), "%02d", tm->tm_min); break;
	case 'S': n = snprintf(tmp, sizeof(tmp), "%02d", tm->tm_sec); break;
	case 'j': n = snprintf(tmp, sizeof(tmp), "%03d", tm->tm_yday + 1); break;
	case 'w': n = snprintf(tmp, sizeof(tmp), "%d", tm->tm_wday); break;
	case 'u': n = snprintf(tmp, sizeof(tmp), "%d", tm->tm_wday ? tm->tm_wday : 7); break;
	case 'A': n = snprintf(tmp, sizeof(tmp), "%s", wday[(tm->tm_wday + 7) % 7]); break;
	case 'a': n = snprintf(tmp, sizeof(tmp), "%.3s", wday[(tm->tm_wday + 7) % 7]); break;
	case 'B': n = snprintf(tmp, sizeof(tmp), "%s", mon[(tm->tm_mon + 12) % 12]); break;
	case 'b':
	case 'h': n = snprintf(tmp, sizeof(tmp), "%.3s", mon[(tm->tm_mon + 12) % 12]); break;
	case 'p': n = snprintf(tmp, sizeof(tmp), "%s", tm->tm_hour < 12 ? "AM" : "PM"); break;
	case 'P': n = snprintf(tmp, sizeof(tmp), "%s", tm->tm_hour < 12 ? "am" : "pm"); break;
	case 'U': {
	    int yd = tm->tm_yday, wd = tm->tm_wday;
	    int wk = (yd - wd + 7) / 7;
	    n = snprintf(tmp, sizeof(tmp), "%02d", wk);
	    break;
	}
	case 'W': {
	    int yd = tm->tm_yday, mon0 = (tm->tm_wday + 6) % 7;
	    int wk = (yd - mon0 + 7) / 7;
	    n = snprintf(tmp, sizeof(tmp), "%02d", wk);
	    break;
	}
	case 'V':
	case 'G':
	case 'g': {
	    int y = tm->tm_year + 1900, yd = tm->tm_yday;
	    int mon0 = (tm->tm_wday + 6) % 7;
	    int thu = yd + (3 - mon0);
	    int yl;
	    if (thu < 0) {
		y--;
		yl = ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 366 : 365;
		thu += yl;
	    } else {
		yl = ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 366 : 365;
		if (thu >= yl) { thu -= yl; y++; }
	    }
	    if (*p == 'V') n = snprintf(tmp, sizeof(tmp), "%02d", thu / 7 + 1);
	    else if (*p == 'G') n = snprintf(tmp, sizeof(tmp), "%04d", y);
	    else n = snprintf(tmp, sizeof(tmp), "%02d", y % 100);
	    break;
	}
	case 'C': n = snprintf(tmp, sizeof(tmp), "%02d", (tm->tm_year + 1900) / 100); break;
	case 'D': n = snprintf(tmp, sizeof(tmp), "%02d/%02d/%02d", tm->tm_mon + 1, tm->tm_mday, (tm->tm_year + 1900) % 100); break;
	case 's': {
	    int y = tm->tm_year + 1900, m = tm->tm_mon + 1;
	    long era, days;
	    unsigned yoe, doy, doe;
	    y -= m <= 2;
	    era = (y >= 0 ? y : y - 399) / 400;
	    yoe = (unsigned)(y - era * 400);
	    doy = (153u * (unsigned)(m + (m > 2 ? -3 : 9)) + 2u) / 5u
		+ (unsigned)tm->tm_mday - 1u;
	    doe = yoe * 365u + yoe / 4u - yoe / 100u + doy;
	    days = era * 146097L + (long)doe - 719468L;
	    n = snprintf(tmp, sizeof(tmp), "%lld",
		(long long)days * 86400LL + tm->tm_hour * 3600L
		+ tm->tm_min * 60L + tm->tm_sec);
	    break;
	}
	case 'x': n = snprintf(tmp, sizeof(tmp), "%02d/%02d/%02d", tm->tm_mon + 1, tm->tm_mday, (tm->tm_year + 1900) % 100); break;
	case 'X': n = snprintf(tmp, sizeof(tmp), "%02d:%02d:%02d", tm->tm_hour, tm->tm_min, tm->tm_sec); break;
	case 'z': n = snprintf(tmp, sizeof(tmp), "+0000"); break;
	case 'Z': n = snprintf(tmp, sizeof(tmp), "UTC"); break;
	case 'F': n = snprintf(tmp, sizeof(tmp), "%04d-%02d-%02d", tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday); break;
	case 'T': n = snprintf(tmp, sizeof(tmp), "%02d:%02d:%02d", tm->tm_hour, tm->tm_min, tm->tm_sec); break;
	case 'R': n = snprintf(tmp, sizeof(tmp), "%02d:%02d", tm->tm_hour, tm->tm_min); break;
	case '%': tmp[0] = '%'; n = 1; break;
	case 'n': tmp[0] = '\n'; n = 1; break;
	case 't': tmp[0] = '\t'; n = 1; break;
	case '\0': p--; continue;
	default:
	    PUTCHAR('%');
	    PUTCHAR(*p);
	    continue;
	}
	{
	    int i;
	    for (i = 0; i < n; i++) PUTCHAR(tmp[i]);
	}
    }
#undef PUTCHAR
    if (max) s[out < max ? out : max - 1] = 0;
    return out;
}
