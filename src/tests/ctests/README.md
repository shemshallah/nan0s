# Vendored c-testsuite subset

This directory contains a curated, vendored subset of the
[c-testsuite](https://github.com/c-testsuite/c-testsuite)
`tests/single-exec` suite.  The harness is `tools/ncc_ctests.sh`.

Upstream revision: `5c7275656d751de0e68b2d340a95b5681858ed07`.

Each case is a self-contained C translation unit whose `main` returns 0 on
success.  `NAME.expected` is the exact stdout produced by a host `clang -w -O0`
build of the same source.  The guest execution path contains only the ncc
compiler and runtime running on NaN16; the host compiler is used only to make
the checked-in expected files.

## Layout

```
manifest.tsv        name, run/skip, expected exit status, step budget, note
NAME.c              upstream test source, verbatim
NAME.expected       exact expected stdout (checked in, often empty)
```

`tools/ncc_ctests.sh` rebuilds a small runner cartridge (the ncc compiler plus
a serial status marker), appends each C source at a fixed word address, runs it
on `aarch64/android/nan_cli`, strips the `@@NCC_EXIT@@` marker, and compares
stdout and the exit status.  A skipped case is reported but is not counted as
a pass or a failure.

## License and provenance

The c-testsuite runner interface and its own test cases are distributed under
the MIT license in `LICENSE.c-testsuite` (copied from the upstream repo).  The
individual test cases keep the license of their upstream project; the c-testsuite
`*.c.otags` files record the origin.  Vendored cases come from:

- `www.simple-cc.org` (scc, commit `355356a9836e487939cf5e98b5332a63e5264e27`,
  paths under `tests/scc/execute/`): 00002-00011, 00015, 00018, 00019,
  00024-00026, 00030-00032, 00034, 00042, 00043, 00045-00049, 00054, 00055,
  00057-00059, 00064, 00072, 00076-00078, 00081, 00082, 00086, 00087,
  00089-00092, 00104, 00125, 00130, 00143, 00149.
- `https://bellard.org/tcc/` (tinycc, commit
  `61ba9f229955f105af9d7dcdbfcc9c9effbe8af3`, paths under `tests/tests2/`):
  00056, 00158, 00164, 00168, 00170.
- 00001 has no upstream `.otag`; it is the c-testsuite baseline
  "empty main" case.

No upstream source is modified.  The only edits to this directory are the
generated `.expected` files and the manifest.

## Adding a case

1. Copy `NAME.c` from upstream `tests/single-exec/`.
2. Generate `NAME.expected` with `clang -w -O0 NAME.c -o /tmp/x && /tmp/x > NAME.expected`.
3. Add a manifest line.  Use `skip` with an honest reason if the case needs a
   documented ncc exclusion (for example object-like replacement-text macros
   or compound literals).
4. Run `tools/ncc_ctests.sh` and confirm the pass count does not drop.
