#!/usr/bin/env python3
"""Apply the NaN16 no-pipe adaptation to the official lock_common.tcl.

The flat cartridge cannot fork/exec or create pipes.  do_multiclient_test()
otherwise aborts the whole aggregate when busy2.test calls
launch_testfixture().  When pipe creation fails, run only the same-interpreter
variant (tn==2), which still opens two connections and exercises locking.

Usage: nan16_patch_lock_common.py SQLITE_SRC/test/lock_common.tcl
"""
import sys

p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "NaN16 port: the flat cartridge cannot spawn" in s:
    sys.exit(0)
old = "  foreach {tn code} [list 1 {\n    if {[info exists ::G(valgrind)]}"
new = (
    "  foreach {tn code} [list 1 {\n"
    "    # NaN16 port: the flat cartridge cannot spawn a child testfixture (no\n"
    "    # fork/exec/pipes).  Probe pipe creation and run only the\n"
    "    # same-interpreter variant (tn==2) instead of aborting the aggregate.\n"
    "    if {[catch {set ::nan16_probe_chan [open \"|true\" r+]}]} { continue }\n"
    "    catch {close $::nan16_probe_chan}\n"
    "    if {[info exists ::G(valgrind)]}"
)
if old not in s:
    sys.exit("lock_common.tcl: do_multiclient_test pattern not found")
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
