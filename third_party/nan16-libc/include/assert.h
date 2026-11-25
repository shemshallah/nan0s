#ifndef _ASSERT_H
#define _ASSERT_H
#include <stdlib.h>
#ifdef NAN16_ASSERT_DIAG
void __nan16_assert_fail(const char *, const char *, int);
#define assert(x) ((x) ? (void)0 : __nan16_assert_fail(#x, __FILE__, __LINE__))
#elif defined(NDEBUG)
#define assert(x) ((void)0)
#else
#define assert(x) ((x) ? (void)0 : abort())
#endif
#endif
