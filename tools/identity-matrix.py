#!/usr/bin/env python3
"""tools/identity-matrix.py — print the type-identity cell table for a fixture, measured on a built candor-swift.

    identity-matrix.py --bin BINARY --work DIR [--edges] FIXTURE ...

Stages Tests/Fixtures/TypeIdentity into DIR, scans each fixture's consumer standalone (un), chained to its own dependency's
report (ch) and, where the fixture has an unreadable-dependency arm, standalone with the dependency named by an ABSOLUTE
`.package(path:)` (unr), and prints one row per executed cell in the format Tests/CandorCoreTests/TypeIdentityHarness.swift
reads:   fn  truth  un|ch[|unr]
Used to PIN a branch's readings (run it on main's binary) and to re-pin after a lane. It is not a comparator: it compares nothing.
"""
import argparse, glob, json, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FX = os.path.join(os.path.dirname(HERE), "Tests", "Fixtures", "TypeIdentity")
# name: (consumer dir, ground-truth file, dependency package dirs (chain order), the manifest spelling of the dependency, unr arm?)
SPEC = {
    "fx3":   ("fx3/App3",           "fx3/exec-ground-truth.txt",            ["fx/Guess"], "../../fx/Guess", True),
    "fx4":   ("fx4/App4",           "fx4/exec-ground-truth.txt",            ["fx/Guess"], "../../fx/Guess", True),
    "fx5":   ("fx5/App5",           "fx5/exec-ground-truth.txt",            ["fx/Guess"], "../../fx/Guess", True),
    "fx5nw": ("fx5nw/App5nw",       "fx5nw/exec-ground-truth.txt",          ["fx/Guess"], "../../fx/Guess", True),
    "fx6":   ("fx6/Pkg6",           "fx6/exec-ground-truth.txt",            [], None, False),
    "fx6c":  ("fx6/Pkg6c",          "fx6/exec-ground-truth-c.txt",          [], None, False),
    "fx7":   ("fx7/App7",           "fx7/exec-ground-truth.txt",            [], None, False),
    "fx8":   ("fx8/App8",           "fx8/exec-ground-truth.txt",            ["fx8/Dep8"], "../Dep8", True),
    "F1":    ("r1931/fx/App",       "r1931/fx/exec-ground-truth.txt",       ["r1931/fx/Guess"], "../Guess", False),
    "F2":    ("r1931/fx2/App2",     "r1931/fx2/exec-ground-truth.txt",      ["r1931/fx/Guess"], "../../fx/Guess", False),
    "R":     ("r1896/fx/App",       "r1896/fx/exec-ground-truth.txt",       ["r1896/fx/Guess", "r1896/fx/Dep2"], "../Guess", False),
    "Rp":    ("r1896/fxp/App",      "r1896/fxp/exec-ground-truth.txt",      ["r1896/fxp/Guess"], "../Guess", False),
    "RL":    ("r1896/fx3/App",      "r1896/fx3/exec-ground-truth.txt",      ["r1896/fx3/Guess"], "../Guess", False),
    "Rlog2": ("r1896/fxlog2/App",   "r1896/fxlog2/exec-ground-truth.txt",   ["r1896/fxlog2/swift-log"], "../swift-log", True),
    "fx9":   ("fx9/Pkg9",           "fx9/exec-ground-truth.txt",            ["fx9/Files"], "../Files", True),
    "fx9r":  ("fx9r/Pkg9r",         "fx9r/exec-ground-truth.txt",           [], None, False),
    "fx10":  ("fx10/Pkg10",         "fx10/exec-ground-truth.txt",           ["fx10/Guess10"], "../Guess10", True),
    "fx11":  ("fx11/App11",         "fx11/exec-ground-truth.txt",           ["fx11/Dep11"], "../Dep11", True),
    "fx12":  ("fx12/Pkg12",         "fx12/exec-ground-truth.txt",           [], None, False),
    "fx13":  ("fx13/Pkg13",         "fx13/exec-ground-truth.txt",           [], None, False),
}

def cell(r):
    if r is None: return "ABSENT"
    inf = r.get("inferred", []); s = "+".join(sorted(e for e in inf if e != "Unknown")) or "-"
    if "Unknown" in inf: s += "+U"
    if r.get("invisible"): s += "+inv"
    if r.get("incomplete"): s += "+inc"
    return s

def scan(binary, root, env, work, tag):
    out = os.path.join(work, tag)
    e = {k: v for k, v in os.environ.items() if k != "CANDOR_DEPS"}; e.update(env)
    p = subprocess.run([binary, root, "--out", out], env=e, capture_output=True, text=True)
    if p.returncode != 0: sys.exit(f"scan of {root} failed rc={p.returncode}: {p.stderr[-400:]}")
    rep = [f for f in glob.glob(out + ".*.Swift.json") if not f.endswith((".callgraph.json", ".hierarchy.json", ".locs.json"))][0]
    rows = {f["fn"].split("(")[0]: f for f in json.load(open(rep))["functions"]}
    cg = {}
    try: cg = json.load(open(rep[:-5] + ".callgraph.json"))
    except Exception: pass
    return rows, cg

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--bin", required=True); ap.add_argument("--work", required=True)
    ap.add_argument("--edges", action="store_true"); ap.add_argument("fixtures", nargs="+")
    a = ap.parse_args()
    stage = os.path.join(a.work, "stage")
    if os.path.exists(stage): shutil.rmtree(stage)
    shutil.copytree(FX, stage)
    for name in a.fixtures:
        app, gt, deps, spelling, unr = SPEC[name]
        truth = [l.split() for l in open(os.path.join(FX, gt)) if len(l.split()) == 2]
        work = os.path.join(a.work, "out-" + name); shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
        un, ucg = scan(a.bin, os.path.join(stage, app), {}, work, "un")
        ch, ccg = un, ucg
        if deps:
            dd = os.path.join(work, "dep"); os.makedirs(dd)
            for i, d in enumerate(deps):
                subprocess.run([a.bin, os.path.join(stage, d), "--out", os.path.join(dd, f"rDep{i}")], capture_output=True, check=True,
                               env={k: v for k, v in os.environ.items() if k != "CANDOR_DEPS"})
            for f in glob.glob(dd + "/*"):
                if f.endswith((".callgraph.json", ".hierarchy.json", ".locs.json")) or not f.endswith(".Swift.json"): os.remove(f)
            ch, ccg = scan(a.bin, os.path.join(stage, app), {"CANDOR_DEPS": dd}, work, "ch")
        ur = None
        if unr and deps:
            cp = os.path.join(stage, app + "-unr"); shutil.copytree(os.path.join(stage, app), cp)
            m = os.path.join(cp, "Package.swift"); t = open(m).read()
            assert f'"{spelling}"' in t, (name, spelling)
            open(m, "w").write(t.replace(f'"{spelling}"', '"' + os.path.join(stage, deps[0]) + '"'))
            ur, _ = scan(a.bin, cp, {}, work, "unr")
        print(f"## {name}  (consumer {app}; {'chained+' if deps else ''}{'unr' if ur is not None else 'standalone only'})")
        for fn, tr in truth:
            parts = [cell(un.get(fn))]
            if deps: parts.append(cell(ch.get(fn)))
            if ur is not None: parts.append(cell(ur.get(fn)))
            print(f"{fn} {tr} {'|'.join(parts)}")
            if a.edges: print(f"    edges un: {ucg.get(fn)}  ch: {ccg.get(fn)}")
main()
