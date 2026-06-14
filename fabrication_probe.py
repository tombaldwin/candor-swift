#!/usr/bin/env python3
"""Fabrication probe for candor-swift — a precision regression guard (sibling of the soundness fuzzer
fuzz.py and the family probes candor-{java,rust}/soundness/fabrication_probe.{py}).

candor's CARDINAL SIN is FABRICATION: classifying a PURE function as effectful. candor-swift classifies
effect-bearing platform types by MEMBER (PROCESS_MEMBERS, the FileManager/URLSession/ProcessInfo tables),
so a pure accessor on an effectful type must NOT inherit the type's effect. This probe pins that down — it
is the over-report guard that complements fuzz.py's under-report (effect-threading) coverage.

For each effect-bearing type it emits two kinds of function:
  PURE  — reads a member that is PROVABLY free of I/O / entropy / time-read (an accessor on a PARAMETER
          receiver, so no handle is ever opened). candor MUST report it pure (omitted / empty inferred).
          If it reports an effect => FABRICATION.
  CTRL  — calls a genuinely-effectful member. candor MUST still report the effect. If it goes pure =>
          a LOST CONTROL (an under-report), the other failure direction this probe also guards.

candor-swift is SYNTACTIC (SwiftParser) — it resolves the receiver type from the parameter annotation and
classifies without compiling, so the probe needs no real frameworks and no build of the fixtures.

SAFETY DISCIPLINE (zero false alarms): a member is asserted PURE only when its Foundation semantics are
verified to do no I/O / read no clock / draw no entropy; when unsure it is left out (never asserted pure).

Usage:  fabrication_probe.py            # build candor-swift (if needed), run all cases, gate
        CS=/path/to/candor-swift fabrication_probe.py   # use a prebuilt binary
"""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.dirname(__file__))  # this probe lives at the repo root (beside fuzz.py)

# Each case: (id, receiver_decl, pure_exprs, ctrl_exprs, expect_effect)
#   receiver_decl : a function parameter holding the handle, so no effect is performed obtaining it.
#   pure_exprs    : accessor reads on that receiver that perform NO effect — must classify pure.
#   ctrl_exprs    : genuinely-effectful calls on it — must still classify expect_effect.
CASES = [
    # URLSession — the Net handle. Config/delegate/sessionDescription are pure property reads; the
    # dataTask/data/download/upload family is the wire.
    ("urlsession", "_ s: URLSession",
     ["s.configuration", "s.delegate", "s.sessionDescription"],
     ['s.dataTask(with: URL(string: "http://h")!)'], "Net"),
    # Process — the Exec handle. arguments/environment/executableURL/processIdentifier are config reads;
    # run()/launch() spawn.
    ("process", "_ p: Process",
     ["p.arguments", "p.environment", "p.executableURL", "p.currentDirectoryURL"],
     ["p.run()"], "Exec"),
    # FileManager — the Fs handle. delegate is a pure accessor; the contents/remove/create family touches
    # disk.
    ("filemanager", "_ fm: FileManager",
     ["fm.delegate"],
     ['fm.removeItem(atPath: "/x")'], "Fs"),
    # ProcessInfo — the Env handle. processName/processIdentifier/hostName-less metadata are pure; the
    # environment subscript reads the OS environment.
    ("processinfo", "_ pi: ProcessInfo",
     ["pi.processName", "pi.arguments", "pi.processIdentifier"],
     ['pi.environment["P"]'], "Env"),
]


def fixture():
    """One Swift file: a pure fn and a control fn per case."""
    out = ["import Foundation"]
    expect = {}  # fn name -> expected effect ("" for pure)
    for cid, recv, pures, ctrls, eff in CASES:
        for i, e in enumerate(pures):
            name = f"{cid}_pure{i}"
            out.append(f"func {name}({recv}) {{ _ = {e} }}")
            expect[name] = ""
        for i, e in enumerate(ctrls):
            name = f"{cid}_ctrl{i}"
            out.append(f"func {name}({recv}) {{ try? {e} }}")
            expect[name] = eff
    return "\n".join(out) + "\n", expect


def candor_bin():
    if os.environ.get("CS"):
        return os.environ["CS"]
    for variant in ("release", "debug"):
        p = os.path.join(ROOT, ".build", variant, "candor-swift")
        if os.path.exists(p):
            return p
    # build debug
    subprocess.run(["swift", "build"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return os.path.join(ROOT, ".build", "debug", "candor-swift")


def main():
    cs = candor_bin()
    src, expect = fixture()
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "Probe.swift")
        open(f, "w").write(src)
        prefix = os.path.join(d, "r")
        subprocess.run([cs, f, "--out", prefix], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        report = None
        for n in os.listdir(d):
            if n.startswith("r.") and n.endswith(".json") and "callgraph" not in n:
                report = os.path.join(d, n)
                break
        if not report:
            print("fabrication-probe: FAIL — candor-swift produced no report", file=sys.stderr)
            return 2
        fns = {e["fn"].split(".")[-1]: e.get("inferred", []) for e in json.load(open(report))["functions"]}

    failures = []
    n = 0
    for name, eff in expect.items():
        n += 1
        got = fns.get(name, [])
        if eff == "":  # PURE: must report no effect
            if got:
                failures.append(f"  FABRICATION {name} -> {got}  (a pure accessor must stay pure)")
        else:  # CTRL: must still fire
            if eff not in got:
                failures.append(f"  LOST CONTROL {name} -> {got or '(pure)'}  (expected {eff} — under-report)")

    print(f"fabrication-probe: {n} probe functions checked across {len(CASES)} types")
    if failures:
        print(f"fabrication-probe: {len(failures)} FAILURE(S):")
        for line in failures:
            print(line)
        return 1
    print("fabrication-probe: OK — no fabrication, no lost control")
    return 0


if __name__ == "__main__":
    sys.exit(main())
