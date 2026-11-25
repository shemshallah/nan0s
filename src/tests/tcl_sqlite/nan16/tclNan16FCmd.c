/*
 * tclNan16FCmd.c -- file command primitives for the NaN16 VFS.
 *
 * Copy/rename/delete/mkdir/rmdir are real.  Implicit VFS directories are
 * visible through stat/opendir.  File attributes and links are unsupported
 * and report errors rather than pretending to work.
 */
#include "tclInt.h"

static int
CopyRegularFile(
    const char *src,
    const char *dst)
{
    char buf[4096];
    int in, out, result = TCL_OK;

    in = open(src, O_RDONLY, 0);
    if (in < 0) {
	return TCL_ERROR;
    }
    out = open(dst, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (out < 0) {
	close(in);
	return TCL_ERROR;
    }
    for (;;) {
	ssize_t n = read(in, buf, sizeof(buf));
	ssize_t off = 0;

	if (n < 0) {
	    result = TCL_ERROR;
	    break;
	}
	if (n == 0) {
	    break;
	}
	while (off < n) {
	    ssize_t w = write(out, buf + off, (size_t)(n - off));
	    if (w < 0) {
		result = TCL_ERROR;
		break;
	    }
	    off += w;
	}
	if (result != TCL_OK) {
	    break;
	}
    }
    close(in);
    close(out);
    if (result == TCL_ERROR) {
	unlink(dst);
    }
    return result;
}

int
TclpObjRenameFile(
    Tcl_Obj *srcPathPtr,
    Tcl_Obj *destPathPtr)
{
    const char *src = (const char *)Tcl_FSGetNativePath(srcPathPtr);
    const char *dst = (const char *)Tcl_FSGetNativePath(destPathPtr);

    if (src == NULL || dst == NULL) {
	errno = ENOENT;
	return TCL_ERROR;
    }
    if (rename(src, dst) == 0) {
	return TCL_OK;
    }
    return TCL_ERROR;
}

int
TclpObjCopyFile(
    Tcl_Obj *srcPathPtr,
    Tcl_Obj *destPathPtr)
{
    const char *src = (const char *)Tcl_FSGetNativePath(srcPathPtr);
    const char *dst = (const char *)Tcl_FSGetNativePath(destPathPtr);
    Tcl_StatBuf sb;

    if (src == NULL || dst == NULL) {
	errno = ENOENT;
	return TCL_ERROR;
    }
    if (stat(src, &sb) != 0) {
	return TCL_ERROR;
    }
    if (S_ISDIR(sb.st_mode)) {
	errno = EISDIR;
	return TCL_ERROR;
    }
    if (stat(dst, &sb) == 0 && S_ISDIR(sb.st_mode)) {
	errno = EISDIR;
	return TCL_ERROR;
    }
    unlink(dst);
    return CopyRegularFile(src, dst);
}

int
TclpDeleteFile(
    const void *path)
{
    if (unlink((const char *)path) != 0) {
	return TCL_ERROR;
    }
    return TCL_OK;
}

int
TclpObjDeleteFile(
    Tcl_Obj *pathPtr)
{
    const char *path = (const char *)Tcl_FSGetNativePath(pathPtr);

    if (path == NULL) {
	errno = ENOENT;
	return TCL_ERROR;
    }
    return TclpDeleteFile(path);
}

int
TclpObjCreateDirectory(
    Tcl_Obj *pathPtr)
{
    const char *path = (const char *)Tcl_FSGetNativePath(pathPtr);

    if (path == NULL) {
	errno = ENOENT;
	return TCL_ERROR;
    }
    if (mkdir(path, 0777) != 0) {
	return TCL_ERROR;
    }
    return TCL_OK;
}

int
TclpCreateDirectory(
    Tcl_Obj *pathPtr)
{
    return TclpObjCreateDirectory(pathPtr);
}

static int
RemoveTree(
    const char *path,
    Tcl_Obj **errorPtr)
{
    Tcl_StatBuf sb;

    if (stat(path, &sb) != 0) {
	goto fail;
    }
    if (!S_ISDIR(sb.st_mode)) {
	if (unlink(path) != 0) {
	    goto fail;
	}
	return TCL_OK;
    }
    {
	TclDIR *d = opendir(path);
	Tcl_DirEntry *e;

	if (d == NULL) {
	    goto fail;
	}
	while ((e = readdir(d)) != NULL) {
	    char child[MAXPATHLEN + 1];

	    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) {
		continue;
	    }
	    if (strlen(path) + 1 + strlen(e->d_name) >= sizeof(child)) {
		errno = ENAMETOOLONG;
		closedir(d);
		goto fail;
	    }
	    if (!strcmp(path, "/")) {
		snprintf(child, sizeof(child), "/%s", e->d_name);
	    } else {
		snprintf(child, sizeof(child), "%s/%s", path, e->d_name);
	    }
	    if (RemoveTree(child, errorPtr) != TCL_OK) {
		closedir(d);
		return TCL_ERROR;
	    }
	}
	closedir(d);
    }
    if (rmdir(path) != 0) {
	goto fail;
    }
    return TCL_OK;
fail:
    if (errorPtr) {
	*errorPtr = Tcl_NewStringObj(path, TCL_INDEX_NONE);
	Tcl_IncrRefCount(*errorPtr);
    }
    return TCL_ERROR;
}

/*
 * Milestone 1 policy: removing a non-empty directory requires recursive=1;
 * without it, rmdir() reports an error exactly like POSIX.
 */
int
TclpObjRemoveDirectory(
    Tcl_Obj *pathPtr,
    int recursive,
    Tcl_Obj **errorPtr)
{
    const char *path = (const char *)Tcl_FSGetNativePath(pathPtr);
    Tcl_StatBuf sb;

    if (path == NULL || stat(path, &sb) != 0 || !S_ISDIR(sb.st_mode)) {
	errno = ENOTDIR;
	if (errorPtr) {
	    *errorPtr = pathPtr;
	    Tcl_IncrRefCount(*errorPtr);
	}
	return TCL_ERROR;
    }
    if (!recursive) {
	if (rmdir(path) != 0) {
	    if (errorPtr) {
		*errorPtr = pathPtr;
		Tcl_IncrRefCount(*errorPtr);
	    }
	    return TCL_ERROR;
	}
	return TCL_OK;
    }
    return RemoveTree(path, errorPtr);
}

int
TclpRemoveDirectory(
    Tcl_Obj *pathPtr,
    int recursive,
    Tcl_Obj **errorPtr)
{
    return TclpObjRemoveDirectory(pathPtr, recursive, errorPtr);
}

static int
CopyTree(
    const char *src,
    const char *dst,
    Tcl_Obj **errorPtr)
{
    Tcl_StatBuf sb;
    TclDIR *d;
    Tcl_DirEntry *e;

    if (stat(src, &sb) != 0) {
	goto fail;
    }
    if (!S_ISDIR(sb.st_mode)) {
	if (CopyRegularFile(src, dst) != TCL_OK) {
	    goto fail;
	}
	return TCL_OK;
    }
    if (mkdir(dst, 0777) != 0 && errno != EEXIST) {
	goto fail;
    }
    d = opendir(src);
    if (d == NULL) {
	goto fail;
    }
    while ((e = readdir(d)) != NULL) {
	char s[MAXPATHLEN + 1], t[MAXPATHLEN + 1];

	if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) {
	    continue;
	}
	if (strlen(src) + strlen(dst) + 2 * strlen(e->d_name) + 4
		>= sizeof(s)) {
	    errno = ENAMETOOLONG;
	    closedir(d);
	    goto fail;
	}
	snprintf(s, sizeof(s), "%s/%s", src, e->d_name);
	snprintf(t, sizeof(t), "%s/%s", dst, e->d_name);
	if (CopyTree(s, t, errorPtr) != TCL_OK) {
	    closedir(d);
	    return TCL_ERROR;
	}
    }
    closedir(d);
    return TCL_OK;
fail:
    if (errorPtr) {
	*errorPtr = Tcl_NewStringObj(src, TCL_INDEX_NONE);
	Tcl_IncrRefCount(*errorPtr);
    }
    return TCL_ERROR;
}

int
TclpObjCopyDirectory(
    Tcl_Obj *srcPathPtr,
    Tcl_Obj *destPathPtr,
    Tcl_Obj **errorPtr)
{
    const char *src = (const char *)Tcl_FSGetNativePath(srcPathPtr);
    const char *dst = (const char *)Tcl_FSGetNativePath(destPathPtr);

    if (src == NULL || dst == NULL) {
	errno = ENOENT;
	if (errorPtr) {
	    *errorPtr = srcPathPtr;
	    Tcl_IncrRefCount(*errorPtr);
	}
	return TCL_ERROR;
    }
    return CopyTree(src, dst, errorPtr);
}

Tcl_Obj *
TclpCreateTemporaryDirectory(
    Tcl_Obj *dirObj,
    Tcl_Obj *basenameObj)
{
    static unsigned counter;
    const char *dir = dirObj ? TclGetString(dirObj) : "/tmp";
    const char *base = basenameObj ? TclGetString(basenameObj) : "tcl";
    char path[MAXPATHLEN + 1];
    Tcl_StatBuf sb;

    if (access(dir, W_OK) != 0 || stat(dir, &sb) != 0
	    || !S_ISDIR(sb.st_mode)) {
	errno = EACCES;
	return NULL;
    }
    for (;;) {
	snprintf(path, sizeof(path), "%s/%s_%u", dir, base, ++counter);
	if (mkdir(path, 0777) == 0) {
	    return Tcl_NewStringObj(path, TCL_INDEX_NONE);
	}
	if (errno != EEXIST || counter > 1000) {
	    return NULL;
	}
    }
}

int
TclUnixCopyFile(
    const char *src,
    const char *dst,
    TCL_UNUSED(const Tcl_StatBuf *),
    TCL_UNUSED(int))
{
    unlink(dst);
    return CopyRegularFile(src, dst);
}

int
TclUnixOpenTemporaryFile(
    Tcl_Obj *dirObj,
    Tcl_Obj *basenameObj,
    Tcl_Obj *extensionObj,
    Tcl_Obj *resultingNameObj)
{
    static unsigned counter;
    const char *dir = dirObj ? TclGetString(dirObj) : "/tmp";
    const char *base = basenameObj ? TclGetString(basenameObj) : "tcl";
    const char *ext = extensionObj ? TclGetString(extensionObj) : "";
    char path[MAXPATHLEN + 1];
    int fd;

    for (;;) {
	snprintf(path, sizeof(path), "%s/%s_%u%s", dir, base, ++counter, ext);
	fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0600);
	if (fd >= 0 || counter > 1000) {
	    break;
	}
    }
    if (fd < 0) {
	return -1;
    }
    if (resultingNameObj != NULL) {
	Tcl_SetStringObj(resultingNameObj, path, TCL_INDEX_NONE);
    } else {
	unlink(path);
    }
    return fd;
}
