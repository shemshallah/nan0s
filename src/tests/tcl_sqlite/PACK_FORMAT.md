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

Default mapping for the official suite:

| host tree | guest prefix |
| --- | --- |
| `tcl9.0.3/library` | `/usr/lib/tcl9.0` |
| `sqlite-src-3540100/test` | `/sqlite/test` |

`testfixture` then runs as `/sqlite/test/veryquick.test`, with
`TCL_LIBRARY=/usr/lib/tcl9.0`.

## Flat-cartridge encoding

An N16PACK1 image is a **byte stream**, but a NaN16 memory word is eight host
bytes with the 32-bit payload at bits 16..47, and guest byte address `A` reads
payload byte `A & 3` of word `A >> 2`. Appending raw pack bytes to a flat
cartridge would therefore not be visible to guest `LDB`. The packer
`tools/nan16_pack_image.py` encodes four archive bytes per 32-bit payload with
`nan16_mkword(payload, 10)` and places the words at a configured guest byte
base. The guest `nan16_vfs_add_pack()` reads the decoded byte stream and
registers data pointers into it.

The default low base is `0x01000000`, so the 25,806,592-byte suite pack spans
guest bytes `0x01000000..0x0289c700` (below the `0x03000000` output copy) and
occupies 51,613,184 encoded host-image bytes. The image file is
`0x02000000` bytes of word padding plus that encoded stream. A large pack may
use a higher base, but `nan16_pack_image.py` checks the guest end, the compiler
image/stack floor, the output-copy regions, the heap and the host image budget;
it refuses overlapping layouts. The current gate uses `--mem 192` with a
128 MiB heap at guest `0x04000000` and the low pack base.
