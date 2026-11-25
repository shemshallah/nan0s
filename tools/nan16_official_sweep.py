#!/usr/bin/env python3
"""Resumable official SQLite .test sweep on the NaN16 testfixture.

Each .test file runs in its own fresh testfixture process, exactly like the
official runner's process model.  Results are persisted per file so a server
restart resumes instead of repeating work.

Usage:
  nan16_official_sweep.py --img FIXTURE.bin --out DIR \
      [--test-dir sqlite-src/test] [--jobs 4] [--steps 10000000000]
      [--max-steps 100000000000] [--retry-factor 5] [--only GLOB]

Aggregator/helper .test files (all/quick/veryquick/full/...) are excluded;
run those explicitly with TCL_NAN16_TESTFIXTURE_TEST.  atof1 is 40,006 tests
and can be seeded from a prior complete run with --seed.
"""
import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

AGGREGATORS = {
    "all.test", "extraquick.test", "fts3.test", "full.test", "mallocAll.test",
    "memleak.test", "permutations.test", "quick.test", "rbu.test",
    "rtree.test", "session.test", "soak.test", "veryquick.test",
}
SUMMARY_RE = re.compile(r"(\d+) errors out of (\d+) tests")


def run_one(args, name):
    outdir = os.path.join(args.out, "files")
    os.makedirs(outdir, exist_ok=True)
    base = os.path.join(outdir, name)
    rerun = {x for x in args.rerun_status.split(",") if x}
    if os.path.exists(base + ".json") and not args.force:
        prev = json.load(open(base + ".json"))
        if prev.get("status") not in rerun:
            return name, prev
    guest = "/sqlite/test/" + name
    steps = args.steps
    attempts = []
    while True:
        tdir = os.path.join(args.out, "tmp", name + "." + str(os.getpid()))
        os.makedirs(tdir, exist_ok=True)
        stdout = os.path.join(tdir, "stdout")
        stderr = os.path.join(tdir, "stderr")
        peek = os.path.join(tdir, "peek")
        cmd = [args.img_runner, "--img", args.img, "--mem", str(args.mem),
               "--steps", str(steps), "--guest-script", guest,
               "--guest-stdout", stdout, "--guest-stderr", stderr,
               "--peek", "0x100:1"]
        t0 = time.time()
        rc = None
        run_err = ""
        try:
            with open(peek, "w") as pf:
                p = subprocess.run(cmd, stdout=pf, stderr=subprocess.PIPE,
                                   timeout=args.timeout)
            rc = p.returncode
            run_err = p.stderr.decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            rc = "timeout"
        text = ""
        if os.path.exists(stdout):
            text = open(stdout, errors="replace").read()
        m = None
        for m in SUMMARY_RE.finditer(text):
            pass
        result = {
            "file": name, "steps": steps, "rc": rc,
            "elapsed": round(time.time() - t0, 1),
        }
        msteps = re.search(r"words: (\d+) steps", run_err)
        if msteps:
            result["steps_used"] = int(msteps.group(1))
        main_word = ""
        if os.path.exists(peek):
            for line in open(peek, errors="replace"):
                if line.strip():
                    main_word = line.strip()
        result["main"] = main_word
        if m:
            result["errors"] = int(m.group(1))
            result["tests"] = int(m.group(2))
            result["status"] = "pass" if result["errors"] == 0 else "fail"
            if result["status"] == "fail":
                result["tail"] = text[-4000:]
        elif main_word == "00000000":
            # A top-level "return" (deliberately disabled file, e.g.
            # alias.test) ends the source without calling finish_test, so
            # the official harness prints no summary.  The guest main did
            # return 0; this is not a budget failure.
            result["status"] = "silent"
            result["errors"] = 0
            result["tests"] = 0
            result["note"] = "no summary; guest main returned 0"
        else:
            result["status"] = "budget" if rc == 0 else "error"
            result["tail"] = (text[-2000:] + (open(stderr, errors="replace").read()[-2000:]
                             if os.path.exists(stderr) else ""))
        attempts.append(result)
        if result["status"] in ("pass", "fail", "silent"):
            if result["status"] in ("pass", "silent"):
                shutil.rmtree(tdir, ignore_errors=True)
            break
        if steps >= args.max_steps:
            break
        steps = min(args.max_steps, steps * args.retry_factor)
    result["attempts"] = len(attempts)
    tmp = base + ".json.tmp"
    with open(tmp, "w") as f:
        json.dump(result, f, indent=1)
    os.replace(tmp, base + ".json")
    return name, result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img", required=True)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--img-runner", default=os.path.join(root, "aarch64/android/nan_cli"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--test-dir",
                    default=os.environ.get("SQLITE_TEST_DIR", ""))
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--mem", type=int, default=256)
    ap.add_argument("--steps", type=int, default=10_000_000_000)
    ap.add_argument("--max-steps", type=int, default=100_000_000_000)
    ap.add_argument("--retry-factor", type=int, default=5)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--rerun-status", default="",
                    help="comma list of cached statuses to rerun (e.g. budget,error,fail)")
    ap.add_argument("--seed", action="append", default=[],
                    help="NAME:errors:tests seed a known-good result")
    args = ap.parse_args()
    if not args.test_dir or not os.path.isdir(args.test_dir):
        sys.exit("set --test-dir or SQLITE_TEST_DIR to SQLITE_SRC/test")
    os.makedirs(args.out, exist_ok=True)

    for spec in args.seed:
        name, errors, tests = spec.split(":")
        d = os.path.join(args.out, "files")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name + ".json"), "w") as f:
            json.dump({"file": name, "errors": int(errors),
                       "tests": int(tests), "status": "pass",
                       "seeded": True}, f, indent=1)

    names = []
    for n in sorted(os.listdir(args.test_dir)):
        if not n.endswith(".test") or n in AGGREGATORS:
            continue
        if args.only and not any(fnmatch.fnmatch(n, p) for p in args.only):
            continue
        names.append(n)
    if not names:
        sys.exit("no test files selected")

    results = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(run_one, args, n): n for n in names}
        for i, fut in enumerate(as_completed(futs), 1):
            name, r = fut.result()
            results[name] = r
            print("%4d/%d %-32s %-6s errors=%s tests=%s steps=%s" % (
                i, len(names), name, r.get("status"), r.get("errors", "-"),
                r.get("tests", "-"), r.get("steps", "-")), flush=True)

    total = sum(r.get("tests", 0) for r in results.values())
    errors = sum(r.get("errors", 0) for r in results.values())
    bad = [n for n, r in results.items()
           if r.get("status") not in ("pass", "silent")]
    with open(os.path.join(args.out, "summary.json"), "w") as f:
        json.dump({"files": results, "total_tests": total,
                   "total_errors": errors, "not_pass": bad}, f, indent=1)
    print("TOTAL files=%d tests=%d errors=%d not_pass=%d" % (
        len(results), total, errors, len(bad)))
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()
