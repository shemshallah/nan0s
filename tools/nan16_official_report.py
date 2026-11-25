#!/usr/bin/env python3
"""Summarize a nan16_official_sweep.py result directory.

Usage:
  nan16_official_report.py --out DIR [--show-tail N] [--json FILE]

Prints per-status counts, official test/error totals, silent (top-level
return) files, and the first lines of each non-pass tail.  The JSON output
is stable for archiving.
"""
import argparse
import json
import os
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--show-tail", type=int, default=3)
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    d = os.path.join(args.out, "files")
    if not os.path.isdir(d):
        sys.exit("no files/ under %s" % args.out)
    results = {}
    for n in sorted(os.listdir(d)):
        if not n.endswith(".json"):
            continue
        try:
            r = json.load(open(os.path.join(d, n)))
        except ValueError:
            continue
        results[r.get("file", n[:-5])] = r

    counts = {}
    for r in results.values():
        counts[r.get("status", "?")] = counts.get(r.get("status", "?"), 0) + 1
    tests = sum(r.get("tests", 0) for r in results.values())
    errors = sum(r.get("errors", 0) for r in results.values())
    silent = [n for n, r in results.items() if r.get("status") == "silent"]
    not_pass = [n for n, r in results.items()
                if r.get("status") not in ("pass", "silent")]
    out = {
        "files": len(results),
        "counts": counts,
        "total_tests": tests,
        "total_errors": errors,
        "silent": silent,
        "not_pass": not_pass,
        "results": results,
    }
    if args.json:
        with open(args.json, "w") as f:
            json.dump(out, f, indent=1, sort_keys=True)

    print("files=%d tests=%d errors=%d" % (len(results), tests, errors))
    print("status: " + " ".join("%s=%d" % (k, counts[k])
                                for k in sorted(counts)))
    if silent:
        print("silent (%d, no harness summary; guest main 0): %s"
              % (len(silent), " ".join(silent)))
    if not not_pass:
        print("ALL PASS")
        return 0
    print("not pass (%d):" % len(not_pass))
    for n in not_pass:
        r = results[n]
        print("  %-32s %-7s tests=%s errors=%s main=%s steps=%s attempts=%s"
              % (n, r.get("status"), r.get("tests", "-"),
                 r.get("errors", "-"), r.get("main", "-"),
                 r.get("steps_used", r.get("steps", "-")),
                 r.get("attempts", "-")))
        tail = r.get("tail", "")
        for line in [x for x in tail.splitlines() if x.strip()][-args.show_tail:]:
            print("      " + line[:200])
    return 1


if __name__ == "__main__":
    sys.exit(main())
