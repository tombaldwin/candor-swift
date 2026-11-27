#!/usr/bin/env python3
"""ident_census.py PROBE_DIR [POOL] [--entry-filter a,b] [--samples N]

Reads CANDOR_IDENT_PROBE stderr (written by tools/identity-census.sh from a candor-swift with the identity probe; the probe is off by default) (one file per pool entry, `<entry>.probe`) from a scratch candor-swift build whose
probes print every binder record (IDG globals, IDF fields, IDL locals, IDR scoped member/free returns, IDS simple
returns), every use-site canonicalTypeRef answer (IDU) and each file's declarations/imports (IDD).

For each binder record it computes two answers for the recorded type spelling S:
  ENGINE  - an emulation of CallCollector.canonicalTypeRef over the PACKAGE-WIDE simple-name set (strip an imported
            module qualifier first, then `localTypes.contains`); validated against IDU on the locals (same file).
  SWIFT   - Swift's lexical rule from the SPELLING's own scope: enclosing type path outward, then the declaring
            file's module top level, then top-level types of OWN modules the file imports (one -> it, >1 -> ambiguous),
            else a non-scan type (dependency / platform).  A generic parameter in scope is not a type.
and classifies the conjunction a resolver change acts on:
  X1  engine binds a SCAN type, Swift sees NO scan type of that spelling (dependency/platform): wrong-type binding
  X2  engine binds scan type(s) not containing Swift's scan type                    : wrong scan type
  X3  engine binds a scan type, Swift is ambiguous / a generic parameter
  M3  engine binds nothing, Swift resolves to a scan type                           : missed resolution (not a silence)
Known blind spots (emulated Swift rule): nested types reached through INHERITANCE, types declared inside function
bodies, and member typealiases are not modelled; every X1 sample is printed for reading.
"""
import collections, glob, os, re, sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
pdir = args[0]
pool = args[1] if len(args) > 1 else None
nsamp = int(opts.get("samples", "6"))
FOUNDATION_REEXPORTED = {"Darwin", "Glibc", "Musl", "ucrt", "WASILibc", "Android"}

def leaf(p): return p.split(".")[-1]

def analyse(entry, path):
    unattributed = set()
    D = {}            # file -> (module, declared, localpaths, imports, aliases, gens)
    recs = []
    IDU = {}
    T = {}
    lines = [l.rstrip("\n").split("\t") for l in open(path, errors="replace")]
    for f in lines:
        if f[0] == "IDT" and len(f) >= 4 and f[3] != "xcode": T[f[1]] = f[2]
    for f in lines:
        if f[0] == "IDD" and len(f) >= 8:
            if f[1] not in T: unattributed.add(f[1]); continue
            D[f[1]] = (T[f[1]], set(x for x in f[3].split(",") if x), set(x for x in f[4].split(",") if x),
                       set(x for x in f[5].split(",") if x), set(x for x in f[6].split(",") if x), set(x for x in f[7].split(",") if x))
        elif f[0] == "IDU" and len(f) >= 6:
            IDU[(f[1], f[2], f[3])] = (f[4], f[5] == "true")
        elif f[0] in ("IDG", "IDF", "IDL", "IDR", "IDS"):
            need = {"IDG": 5, "IDF": 5, "IDL": 7, "IDR": 6, "IDS": 4}[f[0]]
            if len(f) >= need: recs.append(f)
    own = {v[0] for v in D.values()} - {""}
    declared = collections.defaultdict(set)      # module -> declared paths
    for fl, v in D.items(): declared[v[0]] |= v[1]
    allDecl = set().union(*declared.values()) if declared else set()
    leafPaths = collections.defaultdict(set)
    for m, ps in declared.items():
        for p in ps: leafPaths[leaf(p)].add((m, p))
    localNames = set()
    for v in D.values():
        localNames |= v[2]; localNames |= {leaf(p) for p in v[2]}
    aliasByModule = collections.defaultdict(set)
    for v in D.values(): aliasByModule[v[0]] |= v[4]
    allAliases = set().union(*aliasByModule.values()) if aliasByModule else set()
    allGens = set().union(*[v[5] for v in D.values()]) if D else set()
    # own-target @_exported re-exports
    reexp = collections.defaultdict(set)
    if pool:
        for fl, v in D.items():
            fp = os.path.join(pool, entry, fl)
            try: txt = open(fp, errors="replace").read()
            except OSError: continue
            for m in re.findall(r"@_exported\s+(?:public\s+|internal\s+|package\s+)?import\s+(?:(?:class|struct|enum|protocol|typealias|func|var|let)\s+)?(\w+)", txt):
                reexp[v[0]].add(m)
    def visible(fl):
        m, _, _, imps, _, _ = D.get(fl, ("", set(), set(), set(), set(), set()))
        out, q = {m}, [x for x in (imps | reexp.get(m, set())) if x in own]
        while q:
            x = q.pop()
            if x in out: continue
            out.add(x); q.extend(reexp.get(x, ()))
        return out
    def is_modq(head, fl):
        imps = D.get(fl, ("",) + (set(),) * 5)[3] | reexp.get(D.get(fl, ("",))[0], set())
        return (head in imps or (head in FOUNDATION_REEXPORTED)) and head not in own and head not in localNames
    def engine(S, fl):
        s = S
        for _ in range(8):
            if "." in s and is_modq(s.split(".")[0], fl): s = s.split(".", 1)[1]; continue
            break
        if s in allAliases and "." not in s: return ("alias", set())
        if s in localNames:
            if "." in s: tg = {(m, p) for (m, p) in leafPaths[leaf(s)] if p == s}
            else: tg = set(leafPaths[s])
            return ("local", tg)
        if "." in s:
            h, rest = s.split(".", 1)
            if h in own and h not in localNames and (rest in localNames):
                return ("local", {(h, p) for p in declared[h] if p == rest} or set(leafPaths[leaf(rest)]))
        return ("none", set())
    def swift(S, fl, encl, gens):
        m = D.get(fl, ("",))[0]
        imps = D.get(fl, ("",) + (set(),) * 5)[3] | reexp.get(D.get(fl, ("",))[0], set())
        vis = visible(fl)
        def bare(N):
            if N in gens: return ("generic", None)
            segs = encl.split(".") if encl and encl != "-" else []
            for i in range(len(segs), 0, -1):
                cand = ".".join(segs[:i] + [N])
                hits = [(mm, cand) for mm in declared if cand in declared[mm]]
                if hits: return ("scan", hits[0] if len(hits) == 1 else hits)
            # aliases AFTER the enclosing-type walk (Swift: innermost scope first). Alias names are not split by
            # nesting level in IDD, so a member typealias of an enclosing type is still judged here, after nested types.
            if N in aliasByModule[m] or any(N in aliasByModule[x] for x in vis): return ("alias", None)
            if N in declared[m]: return ("scan", (m, N))
            hits = [x for x in vis - {m} if N in declared[x]]
            if len(hits) == 1: return ("scan", (hits[0], N))
            if len(hits) > 1: return ("ambiguous", None)
            return ("nonscan", None)
        if "." not in S: return bare(S)
        head, rest = S.split(".", 1)
        if head in gens: return ("generic", None)
        r = bare(head)
        if r[0] == "scan" and isinstance(r[1], tuple):
            p = r[1][1] + "." + rest
            if p in declared[r[1][0]]: return ("scan", (r[1][0], p))
            hits = [(mm, p) for mm in declared if p in declared[mm] and (mm == m or mm in vis)] or [(mm, p) for mm in declared if p in declared[mm]]
            return ("scan", hits[0]) if len(hits) == 1 else (("scan-member-unknown", None) if not hits else ("ambiguous", None))
        if r[0] in ("generic", "alias", "ambiguous"): return (r[0] + "-head", None)
        # a nested type declared in an EXTENSION of a foreign type (`extension HTTPFields { struct Range }`)
        ext = [(mm, S) for mm in vis if S in declared[mm]]
        if len(ext) == 1: return ("scan", ext[0])
        if len(ext) > 1: return ("ambiguous", None)
        if head in own and (head == m or head in vis):
            return ("scan", (head, rest)) if rest in declared[head] else ("nonscan", None)
        if head in imps or head in FOUNDATION_REEXPORTED or head in ("Swift", "Foundation"): return ("dep:" + head, None)
        return ("nonscan", None)
    out = collections.Counter(); samples = collections.defaultdict(list); val = collections.Counter()
    # USE-SITE census: every canonicalTypeRef answer the engine gave (IDU), judged in the USE file's scope.
    for (fl, encl, S), (res, loc) in IDU.items():
        if fl not in D or not loc or not S[:1].isupper(): continue
        w, wp = swift(S, fl, encl, set())
        tg = {(m, p) for (m, p) in leafPaths[leaf(res)] if p == res or leaf(p) == res}
        if not tg: c = "U.ext-only"
        elif w == "scan": c = "U.agree"
        elif w == "nonscan" or w.startswith("dep:"): c = "U.X1-unique" if len(tg) == 1 else "U.X1-multi"
        else: c = "U." + w.split("-")[0]
        out[("use-site", c)] += 1
        if c.startswith("U.X1") and len(samples[("use-site", c)]) < nsamp:
            samples[("use-site", c)].append(f"{fl} | {encl} | {S} -> {res} {sorted(tg)[:2]} / swift {w}")
    for f in recs:
        kind = f[0]
        if kind == "IDG": fl, encl, S, gens, shape = f[1], "-", f[4], set(), "global." + f[3]
        elif kind == "IDF": fl, encl, S, gens, shape = f[1], f[2], f[4], set(x for x in (f[5] if len(f) > 5 else "").split(",") if x), "field" + (".R1896" if len(f) > 6 else "")
        elif kind == "IDL":
            fl, encl, S, gens, shape = f[1], f[2], f[5], set(x for x in f[6].split(",") if x), "local." + ("ann" if f[4] == "ann" else "init")
            if f[4].startswith("init:"):
                cal = re.sub(r"<[^>]*>", "", f[4][5:]).removesuffix(".init")
                if re.fullmatch(r"[A-Z_][\w]*(\.[A-Za-z_]\w*)*", cal) and cal.split(".")[-1][:1].isupper(): S = cal; shape = "local.ctor"
                else: continue   # factory / member result: its type is a RETURN record (IDS/IDR), resolved at the declaration

        elif kind == "IDR": fl, encl, S, gens, shape = f[1], (f[3] if f[3] != "-" else "-"), f[4], set(x for x in f[5].split(",") if x), "return.scoped"
        else: fl, encl, S, gens, shape = f[1], "-", f[3], set(), "return.simple"
        if fl not in D: out[(shape, "unattributed-file")] += 1; continue
        if not S or S == "-" or not S[0].isupper() and not S[0] == "_": continue
        if S in ("Self",): continue
        e, tg = engine(S, fl)
        w, wp = swift(S, fl, encl, gens)
        if kind == "IDL":
            u = IDU.get((fl, encl, S))
            if u is not None:
                val[(e == "local") == u[1]] += 1
                if (e == "local") != u[1] and len(samples[("VAL", "mismatch")]) < nsamp: samples[("VAL", "mismatch")].append(f"{fl} | {encl} | {S} emu={e} idu={u}")
        if e == "local" and tg:
            if w == "scan" and isinstance(wp, tuple) and wp in tg: c = "agree" if len(tg) == 1 else "agree-union"
            elif w == "scan" and isinstance(wp, list) and set(wp) <= tg: c = "agree-union"
            elif w == "scan": c = "X2"
            elif w in ("nonscan",) or w.startswith("dep:"):
                mods = {mm for mm, _ in tg}; vis = visible(fl)
                if shape == "return.simple": c = "X1.scopeless"
                elif len(tg) > 1: c = "X1.multi"
                else: c = None
                if c: pass
                elif "." in S and is_modq(S.split(".")[0], fl): c = "X1.qualdep"
                elif all("." in p for _, p in tg) and not any(mm in vis for mm, p in tg if "." not in p): c = "X1.nested"
                elif not (mods & vis): c = "X1.sibling"
                else: c = "X1.other"
            elif w.startswith("generic"): c = "X3.generic"
            elif w.startswith("ambiguous"): c = "X3.ambiguous"
            elif w.startswith("alias"): c = "alias"
            else: c = "X?." + w
        elif e == "local": c = "ext-only"
        elif e == "alias": c = "alias"
        else:
            c = "M3" if w == "scan" else "none"
        out[(shape, c)] += 1
        if c.startswith(("X1", "X2", "X3", "M3")) and len(samples[(shape, c)]) < nsamp:
            samples[(shape, c)].append(f"{fl} | {encl} | {S} -> engine {sorted(tg)[:3]} / swift {w} {wp}")
    return out, samples, val

tot = collections.Counter(); per = {}; allsamp = collections.defaultdict(list); vtot = collections.Counter()
flt = set(opts.get("entry-filter", "").split(",")) - {""}
for p in sorted(glob.glob(os.path.join(pdir, "*.probe"))):
    entry = os.path.basename(p)[:-6]
    if flt and entry not in flt: continue
    o, s, v = analyse(entry, p)
    per[entry] = o; tot.update(o); vtot.update(v)
    for k, xs in s.items():
        for x in xs:
            if len(allsamp[k]) < nsamp: allsamp[k].append(f"[{entry}] {x}")
shapes = sorted({k[0] for k in tot})
classes = ["agree", "agree-union", "ext-only", "alias", "M3", "X1.sibling", "X1.nested", "X1.qualdep", "X1.other", "X1.multi", "X1.scopeless", "X2", "X3.generic", "X3.ambiguous"]
print("shape".ljust(20) + "".join(c.rjust(12) for c in classes))
for sh in shapes:
    print(sh.ljust(20) + "".join(str(tot[(sh, c)]).rjust(12) for c in classes))
print("TOTAL".ljust(20) + "".join(str(sum(tot[(sh, c)] for sh in shapes)).rjust(12) for c in classes))
other = {k: v for k, v in tot.items() if k[1] not in classes and k[1] != "none"}
if other: print("other classes:", other)
print("use-site:", {k[1]: v for k, v in sorted(tot.items()) if k[0] == "use-site"})
print("none (engine and Swift both: no scan type):", sum(v for k, v in tot.items() if k[1] == "none"))
print(f"emulator validation on locals vs IDU (engine local? agrees): {dict(vtot)}")
print("\nper entry X1/X2/X3 (sites):")
for e, o in per.items():
    x = {c: sum(v for (sh, cc), v in o.items() if cc.startswith(c) and cc != "X1.scopeless") for c in ("X1", "X2", "X3")}
    if any(x.values()): print(f"  {e:34s} {x}")
print("\nsamples:")
for k in sorted(allsamp):
    print(f"-- {k}")
    for x in allsamp[k]: print("   ", x)
