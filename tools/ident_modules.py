#!/usr/bin/env python3
"""ident_modules.py PROBE_DIR [POOL]

L1 (SOUNDNESS R1938): per pool entry, how the engine's MANIFEST module answer (`moduleOf`: the SwiftPM target or the unique Xcode
target) compares with its path heuristic (`swiftModuleOf`: the segment after `Sources/`), and how many files have NO manifest
answer (the attribution gap) and why. Reads the IDM / IDX / IDMS records of the engine's CANDOR_IDENT_PROBE trace, one
`<entry>.probe` file per entry.

  agree          moduleOf == swiftModuleOf
  disagree       both answer and differ (a target with `path:`; Kingfisher's single target is `Image`/`General`/`Utility`/`Views`)
  unattributed   moduleOf is nil: the reason is the `via` field (none:no-manifest, none:manifest-unclaimed:<dir>, manifest-ambiguous-target,
                 xcode-ambiguous:…)

With POOL (a directory holding each entry's checkout) it also CROSS-CHECKS the engine's `visibleModules` against an independent
reading: a regex over the sources for `@_exported import`, closed module-wide, over the entry's own modules. A disagreement there
is a defect in one of the two and is printed.
"""
import collections, glob, os, re, sys

pdir = sys.argv[1]
pool = sys.argv[2] if len(sys.argv) > 2 else None
EXPORTED = re.compile(r"@_exported\s+(?:public\s+|internal\s+|package\s+)?import\s+(?:(?:class|struct|enum|protocol|typealias|func|var|let)\s+)?(\w+)")

tot = collections.Counter(); reasons_tot = collections.Counter(); rows = []
miv_tot = collections.Counter()
for p in sorted(glob.glob(os.path.join(pdir, "*.probe"))):
    entry = os.path.basename(p)[:-6]
    L = [l.rstrip("\n").split("\t") for l in open(p, errors="replace")]
    idm = [f for f in L if f[0] == "IDM" and len(f) >= 8]
    idx = [f for f in L if f[0] == "IDX" and len(f) >= 6]
    idd = {f[1]: f for f in L if f[0] == "IDD" and len(f) >= 8}
    c = collections.Counter(f[5] for f in idm)
    reasons = collections.Counter(f[3].split(":")[0] + (":" + f[3].split(":")[1] if f[3].startswith("none:") else "") for f in idm if f[5] == "unattributed")
    pairs = collections.Counter((f[2], f[4]) for f in idm if f[5] == "disagree")
    for f in idx: miv_tot[f[5]] += 1
    xcheck = None
    if pool:
        own = {f[2] for f in idm if f[2] != "-"}
        byfile = {f[1]: f for f in idm if f[2] != "-"}
        direct = collections.defaultdict(set)
        for rel, f in byfile.items():
            try: txt = open(os.path.join(pool, entry, rel), errors="replace").read()
            except OSError: continue
            for m in EXPORTED.findall(txt): direct[f[2]].add(m)
        def close(seed):
            out, q = set(), list(seed)
            while q:
                x = q.pop()
                if x in out: continue
                out.add(x); q.extend(direct.get(x, ()))
            return out
        bad = 0; samples = []
        for rel, f in byfile.items():
            imps = set(x for x in (idd[rel][5].split(",") if rel in idd else []) if x)
            mine = close(imps | {f[2]} | direct.get(f[2], set())) & own
            theirs = set(x for x in f[7].split(",") if x) & own
            if mine != theirs:
                bad += 1
                if len(samples) < 3: samples.append((rel, sorted(mine ^ theirs)))
        xcheck = (bad, len(byfile), samples)
    rows.append((entry, len(idm), c["agree"], c["disagree"], c["unattributed"], reasons, pairs, xcheck))
    tot.update(files=len(idm), agree=c["agree"], disagree=c["disagree"], unattributed=c["unattributed"])
    reasons_tot.update(reasons)

print(f"{'entry':34s} {'files':>7s} {'agree':>7s} {'disagree':>9s} {'unattrib':>9s}  reasons / disagreement pairs")
for entry, n, a, d, u, reasons, pairs, xc in rows:
    extra = []
    if u: extra.append("gap: " + ", ".join(f"{k}={v}" for k, v in reasons.most_common(3)))
    if d: extra.append("differ: " + ", ".join(f"{m}!={s}x{k}" for (m, s), k in pairs.most_common(3)))
    if xc and xc[0]: extra.append(f"VISIBLE-XCHECK {xc[0]}/{xc[1]} files differ e.g. {xc[2]}")
    print(f"{entry:34s} {n:7d} {a:7d} {d:9d} {u:9d}  " + "; ".join(extra))
print(f"{'TOTAL':34s} {tot['files']:7d} {tot['agree']:7d} {tot['disagree']:9d} {tot['unattributed']:9d}")
print("attribution gap reasons:", dict(reasons_tot))
print("MemberImportVisibility over own modules:", dict(miv_tot))
if pool:
    bad = sum(r[7][0] for r in rows if r[7]); n = sum(r[7][1] for r in rows if r[7])
    print(f"visible-set cross-check (engine vs regex @_exported closure, own modules): {bad} of {n} attributed files differ")
