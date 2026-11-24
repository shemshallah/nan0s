/* Minimal sys/uio.h for SQLite's carray on the NaN16 guest. */
#ifndef _SYS_UIO_H
#define _SYS_UIO_H
#include <stddef.h>
struct iovec {
    void *iov_base;
    size_t iov_len;
};
#endif
