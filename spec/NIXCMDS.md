# NIXCMDS - POSIX-ish line utilities for NANIX

Status: implementation + standalone S1 gate.

`src/lib/nixcmds.nas` provides `head`, `tail`, `grep`, `sort` and `uniq` in
raw NaN16 on top of the NANIX fd ABI (`spec/NIX_FD.md`).  It is a library: it
calls `nfd_open`, `nfd_read`, `nfd_write` and `nfd_close`; the shell or a test
image supplies those symbols.  The standalone proof is
`src/tests/nixcmds_test.nas` and `tools/nixcmds_gate.sh`.

## Entry ABI

Registers: `r0=0`, `r13=1`, `r14` = software stack growing up, `r15` = link.

```
nxc_run   r1=command  r2=arg1  r3=arg2  r4=flags
          -> r1 = 0 success, -1 runtime/input error, 1 usage
```

| command | name | arg1 | arg2 | flags used |
|--:|---|---|---|---|
| 0 | head | input path, or 0 for fd 0 | line count | - |
| 1 | tail | input path, or 0 for fd 0 | line count | - |
| 2 | grep | fixed search string (required) | ignored | bit0 `-v`, bit1 `-n` |
| 3 | sort | input path, or 0 for fd 0 | ignored | - |
| 4 | uniq | input path, or 0 for fd 0 | ignored | bit2 `-c` |

`arg1` and `arg2` are **byte pointers** to NUL-terminated strings.  For
head/tail `arg2` accepts `N`, `-n N`, or `-nN`; a null pointer means the
default 10.  Counts are capped at 65,535.  `grep` always reads fd 0; its
`arg1` is the pattern, not a file name.  An empty grep pattern matches every
line.

Per-command entry points use the same convention without the command word:

```
nxc_head r1=arg1 r2=arg2 r3=flags
nxc_tail r1=arg1 r2=arg2 r3=flags
nxc_grep r1=pattern r2=ignored r3=flags
nxc_sort r1=arg1 r2=ignored r3=flags
nxc_uniq r1=arg1 r2=ignored r3=flags
```

All output goes to fd 1; diagnostics go to fd 2.  Input is fd 0 unless arg1
named a file, in which case the library opens it through `nfd_open` and closes
it before returning.  The library never closes fd 0.

Typical shell sequence:

```
; head -n 20 /etc/motd
LA r2,@path
SHL r2,r2,2                 ; byte pointer from a .str word label
LA r3,@n20
SHL r3,r3,2
MOVI r1,0                   ; head
MOVI r4,0
CALL @nxc_run
; r1 = 0, -1 or 1
```

### Flags word

| bit | value | meaning |
|---:|---:|---|
| 0 | 1 | grep `-v` (invert match) |
| 1 | 2 | grep `-n` (prefix `LINENO:`) |
| 2 | 4 | uniq `-c` (prefix run count) |

Unused bits are ignored.  Head/tail count parsing is independent of the flags
word.

## Command semantics

### head

Streams input and prints the first N lines (default 10).  It stops reading as
soon as N lines have been emitted, so it does not drain a pipe or a tty.
`head -n 0` prints nothing.  A final line without a newline is preserved
without adding one.

### tail

Buffers the whole input and prints the last N lines (default 10).  Line bytes
are preserved exactly, including a missing final newline.  `tail -n 0` prints
nothing.

### grep

Fixed-string substring search, not BRE or ERE.  There are no character
classes, anchors, alternation, backreferences or `-e`/`-f`.  Matching is
bytewise; the trailing newline of a line is available to the matcher but a
normal pattern cannot contain one.

- `-v` inverts the match.
- `-n` prefixes the **input line number** (1-based), including skipped lines,
  as `N:`.
- A matching final line without a newline is emitted with a newline, like
  POSIX grep.

### sort

C-locale bytewise lexicographic sort of newline-delimited lines.  A final line
without a newline is treated as newline-terminated for ordering and is
emitted with a newline.  The sort is not stable; equal lines may appear in any
order, but every emitted line is complete.  An in-place shell sort is used, so
there is no recursive stack growth; the 32 KiB input bound caps the work.

### uniq

Collapses only **adjacent** duplicate lines.  Lines are compared by exact
length and bytes.  `-c` prints the decimal run length followed by one space
before the line (for example `2 apple`).  A final line without a newline stays
without one.

## Limits and failure

| condition | result |
|---|---|
| tail/sort input > 32768 bytes | diagnostic, no output, return -1 |
| head/grep/uniq single line > 32768 bytes | diagnostic, return -1 |
| sort/tail cannot append a final newline (already 32768 bytes and not newline-terminated) | diagnostic, return -1 |
| invalid command/count, or grep without a pattern | usage diagnostic, return 1 |
| `nfd_open` failure | `nixcmds: cannot open`, return -1 |
| read/write failure | `nixcmds: I/O error`, return -1 |

Diagnostic strings on fd 2:

```
nixcmds: usage
nixcmds: cannot open
nixcmds: I/O error
nixcmds: input too large (32768-byte limit)
nixcmds: line too long (32768-byte limit)
```

The 32 KiB bound is per invocation and applies to the buffered whole input for
tail/sort.  The line index holds at most 32,768 entries; a 32 KiB input cannot
produce more lines than that.

## Memory map

All scratch is outside the shell's byte 0x1000000..0x1011600 window, the
terminal INB/FNB buffers, NPAF at byte 2,250,000, the NFD table at word
0x240000, and the shell stack at word 0x250000.

| symbol | address | size | use |
|---|---|---:|---|
| `NXC_BUF` | byte 0x1300000 | 32768 | line / whole-input buffer |
| `NXC_BUF2` | byte 0x1380000 | 32768 | uniq previous line |
| `NXC_IDXW` | word 0x4E0000 (byte 0x1380000) | 32768 words | line-start index for tail/sort, overlays `NXC_BUF2` |
| `NXC_RBUF` | byte 0x1280000 | 4096 | streaming read buffer |
| `NXC_DECBUF` | byte 0x1281000 | 16 | decimal conversion |
| `NXC_CH1` | byte 0x1281010 | 1 | single-character output |
| `NXC_G` | word 0x1000 | 33 used, block reserved to 0x107F | cross-call state |

### NaN16 addressing caution

`ST`/`LD rX,r0,#CONST` encode a 16-bit immediate.  An `.equ` above 0xFFFF is
silently truncated, so all direct word-global accesses in this library stay in
the low block at word 0x1000.  The high line/index buffers are only touched
after `LA rB,#BUFFER` (or `LA rB,#NXC_BUF`) plus a computed offset.  Do not add
direct `LD/ST ...,r0,#NXC_BUF`-style accesses: they would land in low
memory/code.  Word 0x3A0..0x3BB is reserved by nanobj/nantensor and is not
used here.

## Gate

`tools/nixcmds_gate.sh`:

1. emits `src/tests/nixcmds_test.nas` with `tools/nmk.awk CMD=emit`;
2. runs `CMD=check` and requires `check: 0 mismatches`;
3. runs the image on the x86_64 S1 runner with `--serial`;
4. byte-compares the transcript against 14 exact PASS lines.

The test links the real library against a four-entry in-memory fd shim.  It
covers a 12-line file for head/tail defaults and `-n`, a 5-line unsorted input
for grep `-v`/`-n`, empty patterns, sort, uniq and uniq `-c`, a named-file
path through `nfd_open`, and the 32,769-byte sort rejection.
