/*
 * tclNan16Chan.c -- file/std channels and pipe-file shims for NaN16.
 *
 * Channels wrap guest-VFS file descriptors.  There is no tty layer, no
 * socket layer and no file-event notifier: file handlers are accepted and
 * ignored (milestone 1 runs no event-driven channel consumers).
 */
#include "tclInt.h"

typedef struct Nan16FileState {
    int fd;
    int validMask;
    Tcl_Channel channel;
} Nan16FileState;

typedef struct TclFile_ {
    int fd;
} TclFile_;

static int	FileBlockModeProc(void *instanceData, int mode);
static int	FileCloseProc(void *instanceData, Tcl_Interp *interp,
		    int flags);
static int	FileGetHandleProc(void *instanceData, int direction,
		    void **handlePtr);
static int	FileGetOptionProc(void *instanceData, Tcl_Interp *interp,
		    const char *optionName, Tcl_DString *dsPtr);
static int	FileInputProc(void *instanceData, char *buf, int toRead,
		    int *errorCode);
static int	FileOutputProc(void *instanceData, const char *buf,
		    int toWrite, int *errorCode);
static int	FileTruncateProc(void *instanceData, long long length);
static long long FileWideSeekProc(void *instanceData, long long offset,
		    int mode, int *errorCode);
static void	FileWatchProc(void *instanceData, int mask);

static const Tcl_ChannelType fileChannelType = {
    "file",
    TCL_CHANNEL_VERSION_5,
    NULL,
    FileInputProc,
    FileOutputProc,
    NULL,
    NULL,
    FileGetOptionProc,
    FileWatchProc,
    FileGetHandleProc,
    FileCloseProc,
    FileBlockModeProc,
    NULL,
    NULL,
    FileWideSeekProc,
    NULL,
    FileTruncateProc
};

static int
FileBlockModeProc(
    TCL_UNUSED(void *),
    TCL_UNUSED(int))
{
    return 0;
}

static int
FileCloseProc(
    void *instanceData,
    TCL_UNUSED(Tcl_Interp *),
    int flags)
{
    Nan16FileState *fsPtr = (Nan16FileState *)instanceData;
    int errorCode = 0;

    if ((flags & (TCL_CLOSE_READ | TCL_CLOSE_WRITE)) != 0) {
	return EINVAL;
    }
    Tcl_DeleteFileHandler(fsPtr->fd);
    if (fsPtr->fd > 2 && close(fsPtr->fd) < 0) {
	errorCode = errno;
    }
    Tcl_Free(fsPtr);
    return errorCode;
}

static int
FileInputProc(
    void *instanceData,
    char *buf,
    int toRead,
    int *errorCodePtr)
{
    Nan16FileState *fsPtr = (Nan16FileState *)instanceData;
    ssize_t n;

    *errorCodePtr = 0;
    do {
	n = read(fsPtr->fd, buf, (size_t)toRead);
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
	*errorCodePtr = errno;
	return -1;
    }
    return (int)n;
}

static int
FileOutputProc(
    void *instanceData,
    const char *buf,
    int toWrite,
    int *errorCodePtr)
{
    Nan16FileState *fsPtr = (Nan16FileState *)instanceData;
    ssize_t n;

    *errorCodePtr = 0;
    if (toWrite == 0) {
	return 0;
    }
    n = write(fsPtr->fd, buf, (size_t)toWrite);
    if (n < 0) {
	*errorCodePtr = errno;
	return -1;
    }
    return (int)n;
}

static long long
FileWideSeekProc(
    void *instanceData,
    long long offset,
    int mode,
    int *errorCodePtr)
{
    Nan16FileState *fsPtr = (Nan16FileState *)instanceData;
    long long newLoc = (long long)lseek(fsPtr->fd, (off_t)offset, mode);

    *errorCodePtr = (newLoc == -1) ? errno : 0;
    return newLoc;
}

static void
FileWatchProc(
    TCL_UNUSED(void *),
    TCL_UNUSED(int))
{
}

static int
FileGetHandleProc(
    void *instanceData,
    int direction,
    void **handlePtr)
{
    Nan16FileState *fsPtr = (Nan16FileState *)instanceData;

    if (direction & fsPtr->validMask) {
	*handlePtr = INT2PTR(fsPtr->fd);
	return TCL_OK;
    }
    return TCL_ERROR;
}

static Tcl_Obj *
StatOpenFile(
    Nan16FileState *fsPtr)
{
    Tcl_StatBuf sb;
    Tcl_Obj *dict;
    const char *type = "unknown";

    if (fstat(fsPtr->fd, &sb) < 0) {
	return NULL;
    }
    if (S_ISREG(sb.st_mode)) type = "file";
    else if (S_ISDIR(sb.st_mode)) type = "directory";
    TclNewObj(dict);
    TclDictPut(NULL, dict, "dev", Tcl_NewWideIntObj((Tcl_WideInt)sb.st_dev));
    TclDictPut(NULL, dict, "ino", Tcl_NewWideIntObj((Tcl_WideInt)sb.st_ino));
    TclDictPut(NULL, dict, "nlink",
	    Tcl_NewWideIntObj((Tcl_WideInt)sb.st_nlink));
    TclDictPut(NULL, dict, "uid", Tcl_NewWideIntObj((Tcl_WideInt)sb.st_uid));
    TclDictPut(NULL, dict, "gid", Tcl_NewWideIntObj((Tcl_WideInt)sb.st_gid));
    TclDictPut(NULL, dict, "size",
	    Tcl_NewWideIntObj((Tcl_WideInt)sb.st_size));
    TclDictPut(NULL, dict, "blocks",
	    Tcl_NewWideIntObj((Tcl_WideInt)sb.st_blocks));
    TclDictPut(NULL, dict, "blksize",
	    Tcl_NewWideIntObj((Tcl_WideInt)sb.st_blksize));
    TclDictPut(NULL, dict, "atime", Tcl_NewWideIntObj((Tcl_WideInt)sb.st_atime));
    TclDictPut(NULL, dict, "mtime", Tcl_NewWideIntObj((Tcl_WideInt)sb.st_mtime));
    TclDictPut(NULL, dict, "ctime", Tcl_NewWideIntObj((Tcl_WideInt)sb.st_ctime));
    TclDictPut(NULL, dict, "mode",
	    Tcl_NewWideIntObj((Tcl_WideInt)(unsigned short)sb.st_mode));
    TclDictPut(NULL, dict, "type", Tcl_NewStringObj(type, -1));
    return dict;
}

static int
FileGetOptionProc(
    void *instanceData,
    Tcl_Interp *interp,
    const char *optionName,
    Tcl_DString *dsPtr)
{
    Nan16FileState *fsPtr = (Nan16FileState *)instanceData;
    size_t len = optionName ? strlen(optionName) : 0;

    if (optionName == NULL) {
	return TCL_OK;
    }
    if (len > 1 && !strncmp(optionName, "-stat", len)) {
	Tcl_Obj *dict = StatOpenFile(fsPtr);
	const char *s;
	Tcl_Size n;

	if (dict == NULL) {
	    Tcl_SetObjResult(interp, Tcl_ObjPrintf(
		    "couldn't read file channel status: %s",
		    Tcl_PosixError(interp)));
	    return TCL_ERROR;
	}
	s = TclGetStringFromObj(dict, &n);
	Tcl_DStringAppend(dsPtr, s, n);
	Tcl_DecrRefCount(dict);
	return TCL_OK;
    }
    return Tcl_BadChannelOption(interp, optionName, "stat");
}

static int
FileTruncateProc(
    void *instanceData,
    long long length)
{
    Nan16FileState *fsPtr = (Nan16FileState *)instanceData;

    if (length < 0) {
	return EINVAL;
    }
    if (ftruncate(fsPtr->fd, (off_t)length) != 0) {
	return errno;
    }
    return 0;
}

Tcl_Channel
Tcl_MakeFileChannel(
    void *handle,
    int mode)
{
    Nan16FileState *fsPtr;
    char name[32];
    int fd = (int)PTR2INT(handle);

    if (mode == 0) {
	return NULL;
    }
    fsPtr = (Nan16FileState *)Tcl_Alloc(sizeof(Nan16FileState));
    fsPtr->fd = fd;
    fsPtr->validMask = mode | TCL_EXCEPTION;
    snprintf(name, sizeof(name), "file%d", fd);
    fsPtr->channel = Tcl_CreateChannel(&fileChannelType, name, fsPtr, mode);
    return fsPtr->channel;
}

Tcl_Channel
TclpOpenFileChannel(
    Tcl_Interp *interp,
    Tcl_Obj *pathPtr,
    int mode,
    TCL_UNUSED(int))
{
    const char *native = (const char *)Tcl_FSGetNativePath(pathPtr);
    int fd, permissions;

    if (native == NULL) {
	if (interp) {
	    Tcl_SetObjResult(interp, Tcl_ObjPrintf(
		    "couldn't open \"%s\": filename is invalid on this platform",
		    TclGetString(pathPtr)));
	}
	return NULL;
    }
    switch (mode & O_ACCMODE) {
    case O_RDONLY: permissions = TCL_READABLE; break;
    case O_WRONLY: permissions = TCL_WRITABLE; break;
    case O_RDWR:   permissions = TCL_READABLE | TCL_WRITABLE; break;
    default:
	Tcl_Panic("TclpOpenFileChannel: invalid mode value");
	return NULL;
    }
    fd = open(native, mode, 0666);
    if (fd < 0) {
	if (interp) {
	    Tcl_SetObjResult(interp, Tcl_ObjPrintf(
		    "couldn't open \"%s\": %s",
		    TclGetString(pathPtr), Tcl_PosixError(interp)));
	}
	return NULL;
    }
    return Tcl_MakeFileChannel(INT2PTR(fd), permissions);
}

int
Tcl_GetOpenFile(
    Tcl_Interp *interp,
    const char *chanID,
    int forWriting,
    int checkUsage,
    void **filePtr)
{
    (void)chanID; (void)forWriting; (void)checkUsage; (void)filePtr;
    Tcl_SetObjResult(interp, Tcl_NewStringObj(
	    "stdio FILE* access to channels is not supported on NaN16", -1));
    Tcl_SetErrorCode(interp, "TCL", "OPERATION", "GETOPENFILE",
	    "UNSUPPORTED", (char *)NULL);
    return TCL_ERROR;
}

Tcl_Channel
TclpGetDefaultStdChannel(
    int type)
{
    Tcl_Channel channel;
    int fd, mode;
    const char *bufMode;

    switch (type) {
    case TCL_STDIN:  fd = 0; mode = TCL_READABLE; bufMode = "line"; break;
    case TCL_STDOUT: fd = 1; mode = TCL_WRITABLE; bufMode = "line"; break;
    case TCL_STDERR: fd = 2; mode = TCL_WRITABLE; bufMode = "none"; break;
    default:
	Tcl_Panic("TclpGetDefaultStdChannel: unexpected channel type");
	return NULL;
    }
    channel = Tcl_MakeFileChannel(INT2PTR(fd), mode);
    if (channel == NULL) {
	return NULL;
    }
    Tcl_SetChannelOption(NULL, channel, "-translation", "auto");
    Tcl_SetChannelOption(NULL, channel, "-buffering", bufMode);
    return channel;
}

/* ---- pipe-file layer: enough for [open |...] error paths --------------- */

static TclFile
MakeFile(
    int fd)
{
    TclFile file = (TclFile)Tcl_Alloc(sizeof(TclFile_));
    file->fd = fd;
    return file;
}

TclFile
TclpMakeFile(
    Tcl_Channel channel,
    int direction)
{
    void *data = NULL;

    if (Tcl_GetChannelHandle(channel, direction, &data) != TCL_OK) {
	return NULL;
    }
    return MakeFile((int)PTR2INT(data));
}

TclFile
TclpOpenFile(
    const char *fname,
    int mode)
{
    int fd = open(fname, mode, 0666);

    if (fd < 0) {
	return NULL;
    }
    if ((mode & O_WRONLY) && !(mode & O_APPEND)) {
	lseek(fd, 0, SEEK_END);
    }
    return MakeFile(fd);
}

int
TclpCloseFile(
    TclFile file)
{
    int fd, result = 0;

    if (file == NULL) {
	return -1;
    }
    fd = file->fd;
    if (fd > 2 && close(fd) < 0) {
	result = errno;
    }
    Tcl_Free(file);
    return result;
}

static unsigned tempCounter;

static void
TempName(
    char *buf,
    size_t size)
{
    static const char *dirs[] = { "/tmp", "/", NULL };
    int i;

    for (i = 0; dirs[i]; i++) {
	snprintf(buf, size, "%s/tcltmp%d", dirs[i], (int)++tempCounter);
	if (access(dirs[i], W_OK) == 0) {
	    break;
	}
    }
}

TclFile
TclpCreateTempFile(
    const char *contents)
{
    char name[MAXPATHLEN + 1];
    int fd;

    TempName(name, sizeof(name));
    fd = open(name, O_CREAT | O_RDWR | O_TRUNC, 0600);
    if (fd < 0) {
	return NULL;
    }
    if (contents != NULL) {
	size_t n = strlen(contents);
	if (write(fd, contents, n) != (ssize_t)n) {
	    close(fd);
	    return NULL;
	}
	lseek(fd, 0, SEEK_SET);
    }
    return MakeFile(fd);
}

Tcl_Obj *
TclpTempFileName(void)
{
    char name[MAXPATHLEN + 1];

    TempName(name, sizeof(name));
    return Tcl_NewStringObj(name, -1);
}

Tcl_Obj *
TclpTempFileNameForLibrary(
    Tcl_Interp *interp,
    TCL_UNUSED(Tcl_Obj *))
{
    Tcl_Obj *retval = TclpTempFileName();

    if (retval == NULL && interp != NULL) {
	Tcl_SetObjResult(interp, Tcl_ObjPrintf(
		"couldn't create temporary file: %s",
		Tcl_PosixError(interp)));
    }
    return retval;
}

Tcl_Channel
TclpOpenTemporaryFile(
    TCL_UNUSED(Tcl_Obj *),
    TCL_UNUSED(Tcl_Obj *),
    TCL_UNUSED(Tcl_Obj *),
    Tcl_Obj *resultingNameObj)
{
    char name[MAXPATHLEN + 1];
    Tcl_Obj *path;

    TempName(name, sizeof(name));
    path = Tcl_NewStringObj(name, -1);
    Tcl_IncrRefCount(path);
    if (resultingNameObj != NULL) {
	Tcl_SetObjLength(resultingNameObj, 0);
	Tcl_AppendToObj(resultingNameObj, name, -1);
    }
    {
	Tcl_Channel chan = TclpOpenFileChannel(NULL, path,
		O_CREAT | O_RDWR | O_TRUNC, 0600);
	Tcl_DecrRefCount(path);
	return chan;
    }
}
