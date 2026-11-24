/*
 * tclNan16File.c -- native filesystem/path layer over the NaN16 VFS.
 *
 * The VFS is a flat namespace with implicit directories derived from pack
 * prefixes.  Symbolic links are MemFile targets in the libc VFS; hard links
 * and passwd entries are not supported.
 */
#include "tclInt.h"
#include "tclFileSystem.h"

const char *const tclpFileAttrStrings[] = { NULL };
const TclFileAttrProcs tclpFileAttrProcs[] = { { NULL, NULL } };

int
TclpObjAccess(
    Tcl_Obj *pathPtr,
    int mode)
{
    const char *path = (const char *)Tcl_FSGetNativePath(pathPtr);

    if (path == NULL) {
	return -1;
    }
    return access(path, mode);
}

int
TclpObjChdir(
    Tcl_Obj *pathPtr)
{
    const char *path = (const char *)Tcl_FSGetNativePath(pathPtr);

    if (path == NULL) {
	return -1;
    }
    return chdir(path);
}

int
TclpObjLstat(
    Tcl_Obj *pathPtr,
    Tcl_StatBuf *bufPtr)
{
    const char *path = (const char *)Tcl_FSGetNativePath(pathPtr);

    if (path == NULL) {
	return -1;
    }
    return stat(path, bufPtr);
}

int
TclpObjStat(
    Tcl_Obj *pathPtr,
    Tcl_StatBuf *bufPtr)
{
    const char *path = (const char *)Tcl_FSGetNativePath(pathPtr);

    if (path == NULL) {
	return -1;
    }
    return stat(path, bufPtr);
}

void *
TclpGetNativeCwd(
    void *clientData)
{
    char buffer[MAXPATHLEN + 1];

    if (getcwd(buffer, sizeof(buffer)) == NULL) {
	return NULL;
    }
    if (clientData == NULL || strcmp(buffer, (const char *)clientData)) {
	char *newCd = (char *)Tcl_Alloc(strlen(buffer) + 1);
	strcpy(newCd, buffer);
	return newCd;
    }
    return clientData;
}

char *
TclpReadlink(
    TCL_UNUSED(const char *),
    TCL_UNUSED(Tcl_DString *))
{
    errno = EINVAL;
    return NULL;
}

Tcl_Obj *
TclpFilesystemPathType(
    TCL_UNUSED(Tcl_Obj *))
{
    return NULL;
}

Tcl_Obj *
TclpNativeToNormalized(
    void *clientData)
{
    return Tcl_NewStringObj((const char *)clientData, TCL_INDEX_NONE);
}

void *
TclNativeCreateNativeRep(
    Tcl_Obj *pathPtr)
{
    const char *s = TclGetString(pathPtr);
    size_t n = strlen(s);
    char *copy = (char *)Tcl_Alloc(n + 1);

    memcpy(copy, s, n + 1);
    return copy;
}

void *
TclNativeDupInternalRep(
    void *clientData)
{
    const char *s = (const char *)clientData;
    size_t n;
    char *copy;

    if (s == NULL) {
	return NULL;
    }
    n = strlen(s) + 1;
    copy = (char *)Tcl_Alloc(n);
    memcpy(copy, s, n);
    return copy;
}

int
TclpObjNormalizePath(
    Tcl_Interp *interp,
    Tcl_Obj *pathPtr,
    TCL_UNUSED(int))
{
    char buf[MAXPATHLEN + 1];
    size_t out = 0;
    const char *s = TclGetString(pathPtr);
    int absolute = (s[0] == '/');

    if (strlen(s) >= sizeof(buf)) {
	if (interp) {
	    Tcl_SetObjResult(interp, Tcl_NewStringObj("path too long", -1));
	}
	return 0;
    }
    if (absolute) {
	buf[out++] = '/';
	while (*s == '/') s++;
    }
    while (*s) {
	const char *start;
	size_t clen;

	while (*s == '/') s++;
	if (!*s) break;
	start = s;
	while (*s && *s != '/') s++;
	clen = (size_t)(s - start);
	if (clen == 1 && start[0] == '.') {
	    continue;
	}
	if (clen == 2 && start[0] == '.' && start[1] == '.') {
	    size_t comp = out;
	    int lastDotDot = 0;

	    if (comp > 0 && buf[comp - 1] == '/') {
		comp--;
	    }
	    {
		size_t begin = comp;
		while (begin > 0 && buf[begin - 1] != '/') begin--;
		if (comp - begin == 2 && buf[begin] == '.'
			&& buf[begin + 1] == '.') {
		    lastDotDot = 1;
		}
	    }
	    if (out > 0 && !(absolute && out == 1) && !lastDotDot) {
		while (out > 0 && buf[out - 1] != '/') out--;
		if (out > 0) out--;
		continue;
	    }
	    if (!absolute) {
		if (out > 0 && buf[out - 1] != '/') {
		    buf[out++] = '/';
		}
		memcpy(buf + out, start, 2);
		out += 2;
	    }
	    continue;
	}
	if (out > 0 && buf[out - 1] != '/') {
	    buf[out++] = '/';
	}
	if (out + clen >= sizeof(buf)) {
	    if (interp) {
		Tcl_SetObjResult(interp, Tcl_NewStringObj(
			"path too long", -1));
	    }
	    return 0;
	}
	memcpy(buf + out, start, clen);
	out += clen;
    }
    if (out == 0 && absolute) {
	buf[out++] = '/';
    }
    buf[out] = '\0';
    Tcl_SetStringObj(pathPtr, buf, (Tcl_Size)out);
    return (int)out;
}

static int
MatchType(
    const char *native,
    Tcl_GlobTypeData *types)
{
    Tcl_StatBuf sb;

    if (types == NULL) {
	return 1;
    }
    if (types->type == TCL_GLOB_TYPE_MOUNT) {
	return 0;
    }
    if (stat(native, &sb) != 0) {
	return 0;
    }
    if (types->type != 0) {
	int ok = 0;

	if ((types->type & TCL_GLOB_TYPE_FILE) && S_ISREG(sb.st_mode)) ok = 1;
	if ((types->type & TCL_GLOB_TYPE_DIR) && S_ISDIR(sb.st_mode)) ok = 1;
	if (!ok) return 0;
    }
    if (types->perm != 0) {
	if ((types->perm & TCL_GLOB_PERM_RONLY) && access(native, W_OK) == 0) {
	    return 0;
	}
	if ((types->perm & TCL_GLOB_PERM_R) && access(native, R_OK) != 0) {
	    return 0;
	}
	if ((types->perm & TCL_GLOB_PERM_W) && access(native, W_OK) != 0) {
	    return 0;
	}
	if ((types->perm & TCL_GLOB_PERM_X) && access(native, X_OK) != 0) {
	    return 0;
	}
    }
    return 1;
}

int
TclpMatchInDirectory(
    Tcl_Interp *interp,
    Tcl_Obj *resultPtr,
    Tcl_Obj *pathPtr,
    const char *pattern,
    Tcl_GlobTypeData *types)
{
    Tcl_Obj *fileNamePtr;
    const char *dirName;
    Tcl_Size dirLength;
    TclDIR *d;
    Tcl_DirEntry *entryPtr;
    char full[MAXPATHLEN + 1];
    int matchHidden;

    if (types != NULL && types->type == TCL_GLOB_TYPE_MOUNT) {
	return TCL_OK;
    }
    if (pattern == NULL || pattern[0] == '\0') {
	const char *native = (const char *)Tcl_FSGetNativePath(pathPtr);
	if (native != NULL && MatchType(native, types) == 1) {
	    Tcl_ListObjAppendElement(interp, resultPtr, pathPtr);
	}
	return TCL_OK;
    }

    fileNamePtr = Tcl_FSGetTranslatedPath(interp, pathPtr);
    if (fileNamePtr == NULL) {
	return TCL_ERROR;
    }
    dirName = TclGetStringFromObj(fileNamePtr, &dirLength);
    if (dirLength == 0) {
	dirName = "/";
    } else if (dirName[dirLength - 1] == '/') {
	dirLength--;
    }
    if ((size_t)dirLength >= sizeof(full)) {
	Tcl_DecrRefCount(fileNamePtr);
	Tcl_SetObjResult(interp, Tcl_NewStringObj("directory name too long",
		-1));
	return TCL_ERROR;
    }
    memcpy(full, dirName, (size_t)dirLength);
    full[dirLength] = '\0';

    d = opendir(full[0] ? full : "/");
    if (d == NULL) {
	Tcl_DecrRefCount(fileNamePtr);
	return TCL_OK;
    }
    matchHidden = (pattern[0] == '.')
	    || (types && (types->perm & TCL_GLOB_PERM_HIDDEN));
    while ((entryPtr = readdir(d)) != NULL) {
	char child[MAXPATHLEN + 1];
	size_t nlen = strlen(entryPtr->d_name);

	if (entryPtr->d_name[0] == '.') {
	    if (!matchHidden) {
		continue;
	    }
	}
	if (!Tcl_StringCaseMatch(entryPtr->d_name, pattern, 0)) {
	    continue;
	}
	if (strlen(full) + 1 + nlen >= sizeof(child)) {
	    continue;
	}
	if (strcmp(full, "/") == 0) {
	    snprintf(child, sizeof(child), "/%s", entryPtr->d_name);
	} else {
	    snprintf(child, sizeof(child), "%s/%s", full, entryPtr->d_name);
	}
	if (MatchType(child, types) == 1) {
	    Tcl_ListObjAppendElement(interp, resultPtr,
		    TclNewFSPathObj(pathPtr, entryPtr->d_name,
			    (Tcl_Size)nlen));
	}
    }
    closedir(d);
    Tcl_DecrRefCount(fileNamePtr);
    return TCL_OK;
}

Tcl_Obj *
TclpObjListVolumes(void)
{
    Tcl_Obj *resultPtr;

    TclNewLiteralStringObj(resultPtr, "/");
    Tcl_IncrRefCount(resultPtr);
    return resultPtr;
}

Tcl_Obj *
TclpObjLink(
    Tcl_Obj *pathPtr,
    Tcl_Obj *toPtr,
    int linkAction)
{
    const char *src = (const char *)Tcl_FSGetNativePath(pathPtr);

    if (src == NULL) {
	return NULL;
    }
    if (toPtr != NULL) {
	const char *target = (const char *)Tcl_FSGetNativePath(toPtr);
	if (target == NULL) {
	    return NULL;
	}
	if (access(src, F_OK) != -1) {
	    errno = EEXIST;
	    return NULL;
	}
	if (access(target, F_OK) == -1) {
	    errno = ENOENT;
	    return NULL;
	}
	if (linkAction & TCL_CREATE_SYMBOLIC_LINK) {
	    if (symlink(target, src) != 0) {
		return NULL;
	    }
	    return toPtr;
	}
	errno = EPERM;              /* hard links are not supported */
	return NULL;
    } else {
	char link[1024];
	ssize_t length = readlink(src, link, sizeof link);
	Tcl_Obj *linkPtr;

	if (length < 0) {
	    return NULL;
	}
	linkPtr = Tcl_NewStringObj(link, (Tcl_Size)length);
	Tcl_IncrRefCount(linkPtr);
	return linkPtr;
    }
}

int
TclpUtime(
    Tcl_Obj *pathPtr,
    struct utimbuf *tval)
{
    (void)pathPtr; (void)tval;
    errno = EACCES;
    return -1;
}
