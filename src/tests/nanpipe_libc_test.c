/* nanpipe_libc_test.c - POSIX pipe()/dup2()/read()/write()/close() over the
 * NaN16 np_* byte-pipe primitive.  Compiled by TCC to NaN and run by
 * tools/nanpipe_libc_gate.sh on x86_64 S1. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int pipe(int fds[2]);
int dup2(int oldfd, int newfd);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

static unsigned char a[3000];
static unsigned char b[1000];
static unsigned char r[4096];

static int all(unsigned char *p, int n, int c)
{
    int i;
    for (i = 0; i < n; i++)
        if (p[i] != (unsigned char)c) return 0;
    return 1;
}

int main(void)
{
    int p[2], q[2], fd, i;

    for (i = 0; i < 3000; i++) a[i] = 'A';
    for (i = 0; i < 1000; i++) b[i] = 'B';

    /* basic write/read */
    CHECK(pipe(p) == 0);
    CHECK(p[0] >= 0 && p[1] >= 0 && p[0] != p[1]);
    CHECK(write(p[1], "hello", 5) == 5);
    CHECK(read(p[0], r, 5) == 5);
    CHECK(memcmp(r, "hello", 5) == 0);
    CHECK(read(p[1], r, 1) == -1);       /* read end only */
    CHECK(write(p[0], "x", 1) == -1);    /* write end only */

    /* wrap the 4 KiB window: 3000 A, drain 1000, 1000 B, drain 3000 */
    CHECK(write(p[1], a, 3000) == 3000);
    CHECK(read(p[0], r, 1000) == 1000);
    CHECK(all(r, 1000, 'A'));
    CHECK(write(p[1], b, 1000) == 1000);
    CHECK(read(p[0], r, 3000) == 3000);
    CHECK(all(r, 2000, 'A'));
    CHECK(all(r + 2000, 1000, 'B'));

    /* EOF: closing the write end makes an empty pipe read 0 */
    CHECK(close(p[1]) == 0);
    CHECK(read(p[0], r, sizeof r) == 0);
    CHECK(read(p[0], r, 1) == 0);
    CHECK(close(p[0]) == 0);

    /* dup2 a read end, close the original, keep reading through the copy */
    CHECK(pipe(q) == 0);
    CHECK(write(q[1], "dup", 3) == 3);
    CHECK(dup2(q[0], 42) == 42);
    CHECK(close(q[0]) == 0);
    CHECK(read(42, r, 3) == 3);
    CHECK(memcmp(r, "dup", 3) == 0);
    CHECK(close(42) == 0);
    CHECK(close(q[1]) == 0);

    /* dup2 a write end: EOF only after the last writer is closed */
    CHECK(pipe(q) == 0);
    CHECK(write(q[1], "ab", 2) == 2);
    CHECK(dup2(q[1], 43) == 43);
    CHECK(close(q[1]) == 0);
    CHECK(write(43, "cd", 2) == 2);
    CHECK(read(q[0], r, 4) == 4);
    CHECK(memcmp(r, "abcd", 4) == 0);
    CHECK(close(43) == 0);
    CHECK(read(q[0], r, 1) == 0);
    CHECK(close(q[0]) == 0);

    puts("PIPE PASS");
    return 0;
}
