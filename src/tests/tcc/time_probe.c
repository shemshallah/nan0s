/* time_probe.c - guest time control block and calendar conversion. */
#include <stdio.h>
#include <time.h>
#include <sys/time.h>

int main(void)
{
    struct timeval a, b;
    struct timespec ts, before, after;
    struct tm *tm;
    time_t t;
    unsigned i;

    gettimeofday(&a, 0);
    for (i = 0; i < 1000000u; i++) {
        gettimeofday(&b, 0);
        if (b.tv_sec != a.tv_sec || b.tv_usec != a.tv_usec) break;
    }
    printf("advance=%d\n", b.tv_sec != a.tv_sec || b.tv_usec != a.tv_usec);

    t = 0;
    tm = gmtime(&t);
    printf("epoch=%d:%d:%d:%d:%d:%d:%d:%d\n", tm->tm_year + 1900,
           tm->tm_mon + 1, tm->tm_mday, tm->tm_hour, tm->tm_min,
           tm->tm_sec, tm->tm_wday, tm->tm_yday);

    t = 1700000000;
    tm = gmtime(&t);
    printf("date=%d:%d:%d:%d:%d:%d:%d:%d\n", tm->tm_year + 1900,
           tm->tm_mon + 1, tm->tm_mday, tm->tm_hour, tm->tm_min,
           tm->tm_sec, tm->tm_wday, tm->tm_yday);

    printf("clock=%d\n", clock() >= 0);
    clock_gettime(CLOCK_MONOTONIC, &before);
    ts.tv_sec = 0;
    ts.tv_nsec = 10000000L;
    nanosleep(&ts, 0);
    clock_gettime(CLOCK_MONOTONIC, &after);
    printf("sleep=%d\n", after.tv_sec > before.tv_sec ||
           (after.tv_sec == before.tv_sec && after.tv_nsec > before.tv_nsec));
    printf("TIME PASS\n");
    return 0;
}
