# N16PACK1 guest suite format

The official Tcl/SQLite test tree must be a guest object, not host files.
`tools/nan16_suite_pack.py` builds one flat archive; the NaN guest VFS
registers each entry as a read-only file pointing directly into the archive.

All integers are little-endian.

```
offset 0   char[8]  "N16PACK1"
offset 8   u32      count
then count entries:
  u16 name_len       (1..127)
  u16 flags          (0)
  u32 data_len
  u8  name[name_len] (no NUL; ASCII/UTF-8 relative path with leading '/')
  u8  data[data_len]
```

- Names are absolute guest paths, sorted bytewise, unique.
- Data is not padded; the guest VFS reads bytes, so no alignment is required.
- `flags` is reserved for future compression/executable bits; v1 writers set 0.
- A parser must reject a bad magic, a truncated entry, `name_len==0`, or
  `name_len >= 128`.
- The archive is ROM-backed in the cartridge or loaded as a sealed suite
  image. The guest never sees host paths.

## Guest VFS capacity

Capacity is not a fixed array. The libc file table starts as a pointer table
and doubles on demand:

| directive | meaning |
| --- | --- |
| `-DNAN16_VFS_INIT_CAP=N` | initial slots (default 16) |
| `-DNAN16_VFS_MAXFILES=N` | optional hard cap; omitted means unbounded growth |

`nan16_vfs_add_pack` reserves `vfs_used + count` slots once, then appends each
entry directly, so registering a 2,133-file suite (or much larger archives) is
linear rather than quadratic. `tools/nan16_vfs_capacity_gate.sh` registers a
synthetic 5,000-file pack with `INIT_CAP=2` and checks that a build with
`MAXFILES=4096` rejects it without changing the table.

Because the loader appends without deduplication, names in one archive must be
unique, as required above. Runtime `nan16_vfs_add_ro`/`nan16_vfs_add` still
look up an existing name and update that entry.

Default mapping for the official suite:

| host tree | guest prefix |
| --- | --- |
| `tcl9.0.3/library` | `/usr/lib/tcl9.0` |
| `sqlite-src-3540100/test` | `/sqlite/test` |

`testfixture` then runs as `/sqlite/test/veryquick.test`, with
`TCL_LIBRARY=/usr/lib/tcl9.0`.
