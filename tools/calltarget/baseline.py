#!/usr/bin/env python3
"""baseline.py write OUT.tsv RESULTS.jsonl...      — the expected-verdict baseline from a run
   baseline.py check BASE.tsv RESULTS.jsonl...     — compare a run against it; exit 1 on any difference

A measurement is keyed by (batch, template, placement, multiplicity, effect, gated fn) — never by cell id, so
reordering the generator does not shift the baseline. The value is the classification (classify.py). A
difference is printed with both classes; `check` is the regression instrument (no difference = the engine
answers every executed cell exactly as the baseline's engine did)."""
import json, sys, os, collections
sys.path.insert(0, os.path.dirname(__file__))
from classify import classify

def rows(files):
    out = {}
    for f in files:
        batch = os.path.basename(f).split(".")[0]
        for l in open(f):
            r = json.loads(l)
            if r.get("status") != "OK":
                out[(batch, r["name"], r["place"], r["mult"], r["eff"], "-")] = r.get("status"); continue
            for g in r["gated"]:
                out[(batch, r["name"], r["place"], r["mult"], r["eff"], g)] = classify(r, g)
    return out

mode, path, files = sys.argv[1], sys.argv[2], sys.argv[3:]
cur = rows(files)
if mode == "write":
    with open(path, "w") as o:
        o.write("# batch\ttemplate\tplace\tmult\teff\tfn\tverdict\n")
        for k in sorted(cur): o.write("\t".join(k) + "\t" + cur[k] + "\n")
    print(f"wrote {len(cur)} measurements:", dict(collections.Counter(cur.values())))
    sys.exit(0)
base = {}
for l in open(path):
    if l.startswith("#"): continue
    *k, v = l.rstrip("\n").split("\t"); base[tuple(k)] = v
diff = [(k, base.get(k), cur.get(k)) for k in sorted(set(base) | set(cur)) if base.get(k) != cur.get(k)]
print(f"baseline {len(base)}  run {len(cur)}  differing {len(diff)}")
t = collections.Counter((b, c) for _, b, c in diff)
for (b, c), n in sorted(t.items(), key=lambda kv: -kv[1]): print(f"  {b} -> {c}: {n}")
for k, b, c in diff: print("  ", "\t".join(k), b, "->", c)
sys.exit(1 if diff else 0)
