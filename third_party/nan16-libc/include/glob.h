#ifndef _GLOB_H
#define _GLOB_H
#include <stddef.h>
typedef struct { size_t gl_pathc; char **gl_pathv; size_t gl_offs; } glob_t;
#define GLOB_ERR 1
#define GLOB_MARK 2
#define GLOB_NOSORT 4
#define GLOB_NOCHECK 8
#define GLOB_NOMATCH 16
int glob(const char *, int, int (*)(const char *, int), glob_t *);
void globfree(glob_t *);
#endif
