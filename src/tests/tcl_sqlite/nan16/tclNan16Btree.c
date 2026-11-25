/*
 * tclNan16Btree.c -- register the SQLite btree test commands through the
 * object-command API.
 *
 * test3.c's command table is correct in the image, but Tcl_CreateCommand()
 * from that translation unit does not install the commands in the guest
 * (the object-command registration immediately afterwards does).  Include
 * the unmodified official source here so its static btree_* functions are
 * visible, then install each one with Tcl_CreateObjCommand and a small
 * argv bridge.  The official Sqlitetest3_Init is renamed and unused.
 */
#include "tcl.h"
#include "tclsqlite.h"
#include <stdlib.h>

#define Sqlitetest3_Init Sqlitetest3_Init_unused
#include "test3.c"
#undef Sqlitetest3_Init

typedef struct Nan16BtreeCmd Nan16BtreeCmd;
struct Nan16BtreeCmd {
    Tcl_CmdProc *proc;
};

static int Nan16BtreeBridge(
    void *clientData,
    Tcl_Interp *interp,
    int objc,
    Tcl_Obj *const objv[]
){
    Nan16BtreeCmd *p = (Nan16BtreeCmd *)clientData;
    const char **argv;
    int i, rc;
    argv = (const char **)malloc(sizeof(char *) * (size_t)(objc > 0 ? objc : 1));
    if (argv == 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("out of memory", -1));
        return TCL_ERROR;
    }
    for (i = 0; i < objc; i++) {
        argv[i] = Tcl_GetString(objv[i]);
    }
    rc = p->proc(0, interp, objc, argv);
    free((void *)argv);
    return rc;
}

int Sqlitetest3_Init(Tcl_Interp *interp){
    static struct {
        const char *zName;
        Tcl_CmdProc *xProc;
    } aCmd[] = {
        { "btree_open",              (Tcl_CmdProc*)btree_open              },
        { "btree_close",             (Tcl_CmdProc*)btree_close             },
        { "btree_begin_transaction", (Tcl_CmdProc*)btree_begin_transaction },
        { "btree_pager_stats",       (Tcl_CmdProc*)btree_pager_stats       },
        { "btree_cursor",            (Tcl_CmdProc*)btree_cursor            },
        { "btree_close_cursor",      (Tcl_CmdProc*)btree_close_cursor      },
        { "btree_next",              (Tcl_CmdProc*)btree_next              },
        { "btree_eof",               (Tcl_CmdProc*)btree_eof               },
        { "btree_payload_size",      (Tcl_CmdProc*)btree_payload_size      },
        { "btree_first",             (Tcl_CmdProc*)btree_first             },
        { "btree_varint_test",       (Tcl_CmdProc*)btree_varint_test       },
        { "btree_from_db",           (Tcl_CmdProc*)btree_from_db           },
        { "btree_ismemdb",           (Tcl_CmdProc*)btree_ismemdb           },
        { "btree_set_cache_size",    (Tcl_CmdProc*)btree_set_cache_size    }
    };
    int i;
    for (i = 0; i < (int)(sizeof(aCmd)/sizeof(aCmd[0])); i++) {
        Nan16BtreeCmd *p = (Nan16BtreeCmd *)malloc(sizeof(*p));
        if (p == 0) return TCL_ERROR;
        p->proc = aCmd[i].xProc;
        Tcl_CreateObjCommand(interp, aCmd[i].zName,
                             Nan16BtreeBridge, p, 0);
    }
    Tcl_CreateObjCommand(interp, "btree_insert", btree_insert, 0, 0);
    return TCL_OK;
}
