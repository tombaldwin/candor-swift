#!/usr/bin/env python3
"""run.py CELLSDIR BIN [--only c0001,c0002] [--from N] [--out FILE] [--jobs N] [--env K=V]
Builds each cell's ground truth (compile + execute), scans with BIN, gates the gated functions,
classifies, appends a JSON line per cell to FILE (default CELLSDIR/results.jsonl, resumable).
--jobs N runs N cells at once (default 1; the shared machine allows 2). --env K=V is passed to every
SCAN (not to the build), e.g. --env CANDOR_R1415_OFF=1 for the same-binary kill-switch control."""
import json, os, subprocess, sys, pathlib, shutil, glob, re

cells_dir = pathlib.Path(sys.argv[1]).resolve()
BIN = sys.argv[2]
only = None; start = 0; outarg = None; jobs = 1; scan_env = {}
for i, a in enumerate(sys.argv):
    if a == "--only": only = set(sys.argv[i + 1].split(","))
    if a == "--from": start = int(sys.argv[i + 1])
    if a == "--out": outarg = sys.argv[i + 1]
    if a == "--jobs": jobs = int(sys.argv[i + 1])
    if a == "--env": k, v = sys.argv[i + 1].split("=", 1); scan_env[k] = v
S = cells_dir.parent
MC = S / "mcache"; MC.mkdir(exist_ok=True)
cells = json.load(open(cells_dir / "cells.json"))
outf = pathlib.Path(outarg).resolve() if outarg else cells_dir / ("results.jsonl" if not only else "results-only.jsonl")

def sh(cmd, cwd=None, env=None, timeout=300):
    try:
        r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -9, "", "TIMEOUT"

SWIFTC = ["swiftc", "-Onone", "-module-cache-path", str(MC), "-suppress-warnings"]

def build(meta, cd):
    run = cd / "run"; run.mkdir(exist_ok=True)
    lay = meta["layout"]
    if lay == "single":
        srcs = sorted(str(p) for p in cd.glob("*.swift"))
        rc, o, e = sh(SWIFTC + ["-o", str(run / "app")] + srcs)
        return rc, e, [str(run / "app")]
    if lay in ("pkg", "chain"):
        libsrc = sorted(glob.glob(str(cd / ("Sources/Lib/*.swift" if lay == "pkg" else "Lib/Sources/Lib/*.swift"))))
        appsrc = sorted(glob.glob(str(cd / ("Sources/App/*.swift" if lay == "pkg" else "App/Sources/App/*.swift"))))
        rc, o, e = sh(SWIFTC + ["-emit-library", "-static", "-emit-module", "-module-name", "Lib", "-parse-as-library",
                               "-o", str(run / "libLib.a"), "-emit-module-path", str(run / "Lib.swiftmodule")] + libsrc)
        if rc != 0: return rc, e, None
        rc, o, e = sh(SWIFTC + ["-I", str(run), "-L", str(run), "-lLib", "-o", str(run / "app")] + appsrc)
        return rc, e, [str(run / "app")]
    if lay == "pkgN":
        bp = S / "build" / meta["id"]
        rc, o, e = sh(["swift", "build", "-j", "2", "--scratch-path", str(bp)], cwd=str(cd), timeout=900)
        if rc != 0: return rc, e + o, None
        exe = [p for p in glob.glob(str(bp / "debug" / "*")) if os.access(p, os.X_OK) and os.path.isfile(p) and not p.endswith((".o", ".swiftmodule", ".json", ".a", ".dylib"))]
        names = {"multi3": "B", "multi3b": "App", "multi2": "B"}
        want = names[meta["pkg"]]
        exe = [p for p in exe if os.path.basename(p) == want]
        return (0 if exe else 1), "", exe

def ground_truth(stdout, gated):
    gt = {g: False for g in gated}
    ran = {g: False for g in gated}
    stack = []
    for line in stdout.splitlines():
        if line.startswith("BEGIN:"):
            stack.append(line[6:]); n = line[6:]
            if n in ran: ran[n] = True
        elif line.startswith("END:"):
            if stack: stack.pop()
        elif line.startswith("EFF:"):
            for f in stack:
                if f in gt: gt[f] = True
    return gt, ran

def scan_targets(meta, cd):
    """returns dict side -> (scan dir, env)"""
    env = dict(os.environ); env.update(scan_env)
    if meta["layout"] == "chain":
        libout = cd / "libout"; deps = cd / "deps"
        for d in (libout, deps):
            if d.exists(): shutil.rmtree(d)
            d.mkdir()
        rc, o, e = sh([BIN, str(cd / "Lib"), "--out", str(libout / "Lib")], cwd=str(cd), env=env)
        for f in libout.glob("*.Swift.json"):
            shutil.copy(f, deps / f.name)
        env2 = dict(env); env2["CANDOR_DEPS"] = str(deps)
        return {"lib": (cd / "Lib", env, libout), "app": (cd / "App", env2, None)}, rc
    return {"app": (cd, env, None)}, 0

def row_of(rep, fn):
    for f in rep.get("functions", []):
        if f.get("fn") == fn: return f
    return None

def one(meta):
    cd = cells_dir / meta["id"]
    res = dict(meta)
    rc, err, exe = build(meta, cd)
    if rc != 0 or not exe:
        res["status"] = "NOCOMPILE"; res["err"] = err[-1500:]
        return res, f'{meta["id"]} {meta["name"]} {meta["place"]} {meta["mult"]} NOCOMPILE'
    rrc, so, se = sh(exe, cwd=str(cd / "run"), timeout=60)
    gt, ran = ground_truth(so, meta["gated"])
    res["run_rc"] = rrc; res["stdout"] = so[-3000:]
    res["gt"] = gt; res["ran"] = ran
    sides, librc = scan_targets(meta, cd)
    res["lib_scan_rc"] = librc
    per = {}
    for g in meta["gated"]:
        side = "lib" if (meta["layout"] == "chain" and meta["gated_where"].get(g) == "lib") else "app"
        sdir, env, _ = sides[side]
        rcj, oj, ej = sh([BIN, str(sdir), "--json"], cwd=str(cd), env=env)
        try: rep = json.loads(oj)
        except Exception: rep = {}
        row = row_of(rep, g)
        eff = meta["eff"]
        gates = {}
        for pol in (f"deny {eff} {g}", f"deny {eff} Unknown {g}"):
            pf = cd / f"pol.{g}.{len(gates)}.txt"; pf.write_text(pol + "\n")
            grc, go, ge = sh([BIN, str(sdir), "--policy", str(pf), "--json"], cwd=str(cd), env=env)
            gates[pol] = dict(rc=grc, nomatch=("matched NO function" in ge or "matched no function" in ge.lower()))
        per[g] = dict(side=side, row={k: row.get(k) for k in ("inferred", "invisible", "incomplete", "dispatchesOn", "unknownWhy", "unknownReasons", "calls")} if row else None,
                      g1=gates[f"deny {eff} {g}"], g2=gates[f"deny {eff} Unknown {g}"])
    res["per"] = per
    res["status"] = "OK"
    return res, (f'{meta["id"]} {meta["name"]} {meta["place"]} {meta["mult"]} {meta["eff"]} ' +
                 " ".join(f"{g}:gt={int(gt[g])}/{per[g]['g1']['rc']}{per[g]['g2']['rc']}" for g in meta["gated"]))

def main():
    done = set()
    if outf.exists():
        for l in open(outf):
            try: done.add(json.loads(l)["id"])
            except Exception: pass
    todo = [m for idx, m in enumerate(cells) if idx >= start and (not only or m["id"] in only) and m["id"] not in done]
    from concurrent.futures import ThreadPoolExecutor
    with open(outf, "a") as out, ThreadPoolExecutor(max_workers=jobs) as ex:
        for res, line in ex.map(one, todo):
            out.write(json.dumps(res) + "\n"); out.flush(); print(line, flush=True)

if __name__ == "__main__":
    main()
