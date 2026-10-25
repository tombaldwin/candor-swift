import json, sys, collections
def cause(o):
    n, pl = o["name"], o["place"]
    if n.startswith("U"): return "E unit identity"
    if pl == "L4a" and n in ("D01_class_virtual","D07_class_property_override","D19_class_super_chain","D25_class_subscript_override","D23_refined_csc_interp","D22_refined_csc_property"):
        return "C producer leg: unseen implementor, no key/disclosure"
    if pl == "L4b" and n.startswith(("H","S","D")): return "B chained: consumer never asks the dependency for a non-method hook/accessor"
    if n.endswith("_gen"): return "D generic body over stdlib bound: hook not modelled at generic site"
    if n == "H45_enum_payload_synth_eq": return "A' operand untyped (enum case constructor)"
    if n == "D15_composition": return "F cross-module composition (R866 residual)"
    return "A no site: hook/accessor never becomes a call question"
rows = []
for f in sys.argv[1:]:
    rows += [dict(o, batch=__import__("os").path.basename(f).split(".")[0]) for o in json.load(open(f))]
sil = [o for o in rows if o["cls"] in ("SILENT", "DISC_INVISIBLE_ONLY")]
keyed = [o for o in rows if o["cls"] == "UNSEEN_KEYED"]
fab = [o for o in rows if o["cls"] == "FABRICATED"]
print("total measurements", len(rows), "gt=True", sum(o["gt"] for o in rows), "silent", len(sil), "unseen-keyed", len(keyed), "fabricated", len(fab))
c = collections.Counter(cause(o) for o in sil)
cells = collections.defaultdict(set); fns = collections.defaultdict(set); tmpl = collections.defaultdict(set)
for o in sil:
    cells[cause(o)].add((o["batch"], o["id"])); tmpl[cause(o)].add(o["name"] + "@" + o["place"])
for k, v in sorted(c.items()):
    print(f"{v:4d} meas {len(cells[k]):4d} cells  {k}")
    print("        ", ", ".join(sorted(tmpl[k])))
print("callers only (fn=callerFn/crossFn/liveFn/use*/...):", sum(1 for o in sil if o["fn"] != "dispFn"))
for o in fab: print("FAB", o["batch"], o["id"], o["name"], o["fn"])
