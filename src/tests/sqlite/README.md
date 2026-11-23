# SQLite differential tests

`tools/tcc_sqlite.sh` compiles these programs twice:

- with the host C compiler (native reference), and
- with `tcc0` targeting NaN16, linked against the vendored SQLite 3.54.1
  amalgamation, `third_party/sqlite/nan16_vfs.c`, and the guest libc.

Both runs execute the same SQL against the same deterministic in-memory VFS.
Every result word must match.

## Output contract

Guest builds write results to fixed guest memory so `nan_cli` can dump them:

- `0x03000000`: result words (`suite.c`: 96 x 32-bit, `stress.c`: 256 x 32-bit)
- `0x03001000`: a 200-byte error message (empty on success)
- `0x02FFFFF0`: completion marker `1` (the assert hook uses `0xAB0B0000`)

Native builds write the result words to stdout and errors to stderr.

## Coverage

`suite.c` covers schema creation, bound parameters, all storage classes,
aggregates, an index lookup, a join, UPDATE/DELETE, transaction rollback and
commit, close/reopen persistence, an expected prepare error, and
`PRAGMA integrity_check`.

`stress.c` inserts 500 rows in one transaction, creates two indexes, checks
multi-page table scans, range and index lookups, `GROUP BY`, 5 KB overflow
blobs, UPDATE/DELETE, freelist accounting, `VACUUM`, integrity, close/reopen,
and an `ORDER BY ... LIMIT` scan.

The gate also builds `suite.c` with `SQLITE_DEBUG` and
`NAN16_ASSERT_DIAG`, so any failing SQLite assertion halts with its
expression/file/line in the diagnostic area instead of silently diverging.
