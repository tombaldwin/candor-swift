#!/usr/bin/env python3
"""compare.py BEFORE.jsonl AFTER.jsonl [--quiet] — per (cell, gated fn) classification before -> after.
Cells are matched by id AND by (name, place, mult, eff), so two runs of different generators cannot pair up.
Prints the transition counts and every changed measurement; exit 0."""
import json, sys, collections
sys.path.insert(0, __import__("os").path.dirname(__file__))
from classify import classify

def load(f):
    out = {}
    for l in open(f):
        r = json.loads(l)
        if r.get("status") != "OK": continue
        for g in r["gated"]:
            out[(r["id"], r["name"], r["place"], r["mult"], r["eff"], g)] = (classify(r, g), r)
    return out
a, b = load(sys.argv[1]), load(sys.argv[2])
keys = sorted(set(a) & set(b))
print(f"paired measurements: {len(keys)}  (only-before {len(set(a)-set(b))}, only-after {len(set(b)-set(a))})")
print("before:", dict(collections.Counter(a[k][0] for k in keys)))
print("after: ", dict(collections.Counter(b[k][0] for k in keys)))
t = collections.Counter((a[k][0], b[k][0]) for k in keys if a[k][0] != b[k][0])
for (x, y), n in sorted(t.items(), key=lambda kv: -kv[1]): print(f"  {x:>20s} -> {y:<20s} {n}")
if "--quiet" not in sys.argv:
    for k in keys:
        if a[k][0] != b[k][0]:
            row = b[k][1]["per"][k[5]]["row"] or {}
            print(f"  {k[0]} {k[1]:36s} {k[2]:4s} {k[3]:3s} {k[4]:4s} {k[5]:9s} {a[k][0]:>12s} -> {b[k][0]:<12s} inf={row.get('inferred')} disp={row.get('dispatchesOn')}")
