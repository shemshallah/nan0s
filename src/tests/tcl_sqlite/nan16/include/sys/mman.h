/* Minimal sys/mman.h for tclZipfs.c.  The guest libc has flat mmap only. */
#ifndef _SYS_MMAN_H
#define _SYS_MMAN_H
#include <stddef.h>
#include <sys/types.h>
#define PROT_READ	1
#define PROT_WRITE	2
#define MAP_PRIVATE	2
#define MAP_FILE	0
#define MAP_FAILED	((void *)-1)
void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
int munmap(void *addr, size_t len);
#endif
