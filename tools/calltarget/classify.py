"""The one classification of a (cell, gated fn) measurement, shared by analyze.py and compare.py."""

def classify(res, g):
    p = res["per"][g]; gt = res["gt"][g]; ran = res["ran"][g]
    g1, g2 = p["g1"]["rc"], p["g2"]["rc"]
    row = p["row"] or {}
    inv = bool(row.get("invisible")) or bool(row.get("incomplete"))
    if not ran:
        return "NOTRUN"
    if gt:
        if g1 == 1: return "CHARGED"
        if g1 == 2 or g2 in (1, 2): return "DISCLOSED"
        if inv: return "DISC_INVISIBLE_ONLY"
        # SPEC §4 ⟨0.39⟩ obligation 1: the producer's own row for a dispatch whose only effectful implementor is
        # UNSEEN (lives in a consumer) — the member is named on the wire, the producer's scan cannot see the body.
        if row.get("dispatchesOn") and p.get("side") == "lib": return "UNSEEN_KEYED"
        return "SILENT"
    else:
        if g1 == 1:
            # over-approximation: an effectful implementor of the abstraction exists and is live elsewhere
            if res["group"] == "D" and res["mult"] == "M3": return "OVER_CHA"
            if res["group"] == "H" and res["mult"] == "MD" and res["name"].endswith("_gen") and g == "callerFn": return "OVER_CHA"
            return "FABRICATED"
        if g2 in (1, 2): return "DISC_SPURIOUS"
        return "CLEAN"
