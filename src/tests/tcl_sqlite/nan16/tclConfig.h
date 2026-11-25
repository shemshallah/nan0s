/*
 * tclConfig.h -- hand-written NaN16 configuration for Tcl 9.0.3.
 *
 * The NaN16 guest has no autoconf and no host libc.  This header lists only
 * features the guest libc actually provides; everything absent stays
 * undefined so Tcl falls back to its portable path.
 */
#ifndef _TCLCONFIG
#define _TCLCONFIG

/* Headers present in third_party/nan16-libc/include. */
#define HAVE_SYS_TYPES_H	1
#define HAVE_SYS_TIME_H		1
#define HAVE_UNISTD_H		1
#define HAVE_STDINT_H		1
#define HAVE_INTTYPES_H		1
#define HAVE_STDIO_H		1
#define HAVE_STDLIB_H		1
#define HAVE_STRING_H		1
#define HAVE_SYS_STAT_H		1
#define HAVE_CTYPE_H		1
#define HAVE_ERRNO_H		1
#define HAVE_FCNTL_H		1
#define HAVE_LIMITS_H		1
#define HAVE_FLOAT_H		1

/* struct stat fields in third_party/nan16-libc/include/sys/stat.h. */
#define HAVE_STRUCT_STAT_ST_BLOCKS	1
#define HAVE_STRUCT_STAT_ST_BLKSIZE	1
#define HAVE_STRUCT_STAT_ST_RDEV	1
#define HAVE_BLKCNT_T			1

/* NaN16 char is signed, like the compiler's default. */
#define HAVE_SIGNED_CHAR		1

/* Needed by generic code that probes for these. */
#define HAVE_GETCWD			1
#define HAVE_CAST_TO_UNION		1
#define HAVE_INTPTR_T			1
#define HAVE_UINTPTR_T			1

#define TCL_CFGVAL_ENCODING		"utf-8"
#define TCL_SHLIB_EXT			".so"
#define STATIC_BUILD			1

/*
 * Tcl 9 only supports the UCS-4 UTF-8 core.  tcl.h rejects TCL_UTF_MAX=3
 * with BUILD_tcl; the port stays UTF-8-only by never registering any other
 * encoding (no encoding files are loaded).
 */
#ifndef TCL_UTF_MAX
#define TCL_UTF_MAX			4
#endif

/* Milestone 1 is deliberately single-threaded. */
#ifndef TCL_THREADS
#define TCL_THREADS			0
#endif

/* Tcl 9 always links its own libtommath and zlib for the built-in targets. */
#define TCL_WITH_INTERNAL_ZLIB		1

/*
 * No shared-object loading and no memory-mapped loaders in the guest.  The
 * [load] command remains present and fails through TclpDlopen.
 */
#define TCL_UNLOAD_DLLS			0

/* Default library installation path inside the guest VFS. */
#define TCL_NAN16_LIBRARY		"/usr/lib/tcl9.0"

/* Embedded TIP 59 configuration paths. */
#define CFG_RUNTIME_LIBDIR		"/usr/lib"
#define CFG_RUNTIME_BINDIR		"/usr/bin"
#define CFG_RUNTIME_SCRDIR		TCL_NAN16_LIBRARY
#define CFG_RUNTIME_INCDIR		"/usr/include"
#define CFG_RUNTIME_DOCDIR		"/usr/share/doc"
#define CFG_INSTALL_LIBDIR		"/usr/lib"
#define CFG_INSTALL_BINDIR		"/usr/bin"
#define CFG_INSTALL_SCRDIR		TCL_NAN16_LIBRARY
#define CFG_INSTALL_INCDIR		"/usr/include"
#define CFG_INSTALL_DOCDIR		"/usr/share/doc"
#define TCL_CFG_OPTIMIZED		1

#endif /* _TCLCONFIG */
