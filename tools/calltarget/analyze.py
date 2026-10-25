#!/usr/bin/env python3
"""analyze.py RESULTS.jsonl [--md] — classify each (cell, gated fn) and print tables."""
import json, sys, collections

rows = [json.loads(l) for l in open(sys.argv[1])]
MD = "--md" in sys.argv

sys.path.insert(0, __import__("os").path.dirname(__file__))
from classify import classify

out = []
status = collections.Counter()
for r in rows:
    status[r["status"]] += 1
    if r["status"] != "OK": continue
    for g in r["gated"]:
        out.append(dict(id=r["id"], name=r["name"], group=r["group"], place=r["place"], mult=r["mult"], eff=r["eff"], fn=g,
                        side=r["per"][g]["side"], gt=r["gt"][g], cls=classify(r, g), row=r["per"][g]["row"],
                        g1=r["per"][g]["g1"]["rc"], g2=r["per"][g]["g2"]["rc"]))
print("cells by status:", dict(status))
print("measurements:", len(out), dict(collections.Counter(o["cls"] for o in out)))
nc = [r for r in rows if r["status"] == "NOCOMPILE"]
print("\nNOCOMPILE cells (pruned as not constructible):")
for k, v in sorted(collections.Counter((r["name"], r["place"]) for r in nc).items()):
    print("  ", k, v)

bad = [o for o in out if o["cls"] in ("SILENT", "DISC_INVISIBLE_ONLY", "FABRICATED")]
print("\nSILENT / DISC_INVISIBLE_ONLY / FABRICATED:")
for o in sorted(bad, key=lambda o: (o["cls"], o["name"], o["place"], o["mult"], o["fn"])):
    r = o["row"]
    rs = "ABSENT" if r is None else f"inf={r.get('inferred')} inv={r.get('invisible')} disp={r.get('dispatchesOn')}"
    print(f"  {o['cls']:20s} {o['id']} {o['name']:36s} {o['place']:4s} {o['mult']:3s} {o['eff']:4s} {o['fn']:9s}[{o['side']}] g={o['g1']}{o['g2']}  {rs[:150]}")

# pivot: per template x place, worst class on the gt=True measurements
print("\nPIVOT (gt=True measurements; S=silent, I=invisible-only, D=disclosed, C=charged; per mult M1/M2/M3/M0 or M1/MD; fn order callerFn,dispFn,crossFn/liveFn)")
pv = collections.defaultdict(list)
code = {"UNSEEN_KEYED": "k", "SILENT": "S", "DISC_INVISIBLE_ONLY": "I", "DISCLOSED": "D", "CHARGED": "C", "FABRICATED": "F", "OVER_CHA": "o", "CLEAN": ".", "DISC_SPURIOUS": "u", "NOTRUN": "?"}
for o in out:
    if o["eff"] != "Fs": continue
    pv[(o["name"], o["place"])].append((o["mult"], o["fn"], code[o["cls"]]))
places = ["L1", "L2", "L3a", "L3b", "L4a", "L4b", "-"]
names = sorted(set(k[0] for k in pv))
for n in names:
    line = f"  {n:36s}"
    for pl in places:
        v = pv.get((n, pl))
        if not v: line += f" {pl}:{'--':8s}"; continue
        s = "".join(c for _, _, c in v)
        line += f" {pl}:{s:8s}"
    print(line)
json.dump(out, open(sys.argv[1] + ".classified.json", "w"), indent=0)
