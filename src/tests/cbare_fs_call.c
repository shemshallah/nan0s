/* cbare_fs_call.c - C-port guest using the NaN16 machine filesystem. */
typedef int (*fn2)(const char *, int);
typedef int (*fn3)(int, const void *, int);
typedef int (*fn1)(int);
#define TAB ((volatile unsigned *)0x00081000u) /* word 0x20400 * 4 */
#define MARK ((volatile unsigned *)0x00100000u) /* word 0x40000 * 4 */

int main(void) {
    fn2 open = (fn2)TAB[0];
    fn3 write = (fn3)TAB[1];
    fn3 read = (fn3)TAB[2];
    fn1 close = (fn1)TAB[3];
    char buf[8];
    int fd;

    *MARK = 101;
    if (((fn2)(void *)TAB[4])(20, 22) != 42) { *MARK = 102; return 0; }
    *MARK = 103;
    fd = open("/cb.txt", 1);
    if (!fd) { *MARK = 104; return 0; }
    *MARK = 105;
    if (write(fd, "hello", 5) != 5) { *MARK = 106; return 0; }
    *MARK = 107;
    close(fd);
    *MARK = 108;
    fd = open("/cb.txt", 0);
    if (!fd) { *MARK = 109; return 0; }
    *MARK = 110;
    if (read(fd, buf, 5) != 5) { *MARK = 111; return 0; }
    *MARK = 112;
    close(fd);
    *MARK = (buf[0] == 'h' && buf[1] == 'e' && buf[2] == 'l' &&
             buf[3] == 'l' && buf[4] == 'o') ? 42 : 5;
    return 0;
}
