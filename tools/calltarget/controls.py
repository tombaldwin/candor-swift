#!/usr/bin/env python3
"""controls.py OUTDIR BIN — the R764-shape controls for call-target round 1 (write BEFORE the change).

Three packages: A = the abstraction's OWNER, B = a second dependency, App = the consumer. Each fixture is
compiled and EXECUTED (ground truth: does `callerFn` reach an effect), then App is scanned with only the
packages named in `chained` supplied through CANDOR_DEPS. The property under test: a newly published key or
union must never turn a DISCLOSED (or charged) caller into a silent one — the R764 shape, where a chained
non-owner's entry hits a lookup and the owner's `invisible` disclosure vanishes.

Verdict per fixture: CHARGED (deny E callerFn exits 1), DISCLOSED (exit 2, or `deny E Unknown` exits non-0,
or the row carries `invisible`/`incomplete`), SILENT (effect executed, none of the above), CLEAN (no effect).
Prints one line per fixture and writes OUTDIR/controls.json.
"""
import json, os, pathlib, shutil, subprocess, sys

OUT = pathlib.Path(sys.argv[1]).resolve(); BIN = sys.argv[2]
SWIFTC = ["swiftc", "-Onone", "-suppress-warnings", "-module-cache-path", str(OUT / "mcache")]
def eff(tag, d): return f'_ = FileManager.default.createFile(atPath: "{d}/run/W_{tag}", contents: nil); print("EFF:{tag}")'
BEG = 'print("BEGIN:callerFn"); defer { print("END:callerFn") }'

def fixtures(d):
    E = lambda t: eff(t, d)
    return {
        # K1: protocol subscript requirement owned by an UNCHAINED A; chained B implements it purely
        # (B publishes a union under A's key); App's own conformer is the effectful one.
        "K1_subscript_req_unchained_owner": dict(
            A="public protocol P { subscript(i: Int) -> Int { get } }\n",
            B="import A\npublic struct BImpl: P { public init() {}\n  public subscript(i: Int) -> Int { return i } }\n",
            App=("import A\nimport B\nstruct Mine: P { subscript(i: Int) -> Int { %s; return i } }\n"
                 "func dispFn(_ p: any P) -> Int { return p[0] }\n"
                 "func callerFn() { %s; _ = dispFn(Mine()); _ = BImpl()[1] }\ncallerFn()\n") % (E("Mine.sub"), BEG),
            chained=["B"]),
        # K2: an operator on an UNCHAINED A's concrete type whose `==` performs the effect.
        "K2_operator_unchained_owner": dict(
            A=("import Foundation\npublic struct AT: Equatable { public init() {}\n"
               "  public static func == (a: AT, b: AT) -> Bool { %s; return true } }\n") % E("AT.=="),
            B="import A\npublic func bTouch() -> AT { AT() }\n",
            App="import A\nimport B\nfunc callerFn() { %s; _ = AT() == bTouch() }\ncallerFn()\n" % BEG,
            chained=["B"]),
        # K3: open class owned by UNCHAINED A, dispatch site in chained B (foreign owner), App's subclass effectful.
        "K3_open_class_unchained_owner": dict(
            A="open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") } }\n",
            B="import A\npublic func dispFn(_ b: Base) { b.m() }\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: Base { override func m() { %s } }\n"
                 "func callerFn() { %s; dispFn(Mine()) }\ncallerFn()\n") % (E("Mine.m"), BEG),
            chained=["B"]),
        # K4: open class and dispatch site in CHAINED A (the C change publishes `A#Base.m` on dispFn); the
        # effectful subclass lives in UNCHAINED B. The App's own disclosure of B must survive the new hit.
        "K4_open_class_effect_in_unchained_third": dict(
            A="open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") } }\npublic func dispFn(_ b: Base) { b.m() }\n",
            B=("import Foundation\nimport A\npublic final class BSub: Base { public override init() {}\n"
               "  public override func m() { %s } }\n") % E("BSub.m"),
            App="import A\nimport B\nfunc callerFn() { %s; dispFn(BSub()) }\ncallerFn()\n" % BEG,
            chained=["A"]),
        # K5: K4 with A UNCHAINED and B chained: B's subclass override is visible to App only through B's report.
        "K5_open_class_owner_unchained_sub_chained": dict(
            A="open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") } }\npublic func dispFn(_ b: Base) { b.m() }\n",
            B=("import Foundation\nimport A\npublic final class BSub: Base { public override init() {}\n"
               "  public override func m() { %s } }\n") % E("BSub.m"),
            App="import A\nimport B\nfunc callerFn() { %s; dispFn(BSub()) }\ncallerFn()\n" % BEG,
            chained=["B"]),
        # K6: K4 with BOTH chained — the change should CHARGE here (the effect is visible in B's report).
        "K6_open_class_both_chained": dict(
            A="open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") } }\npublic func dispFn(_ b: Base) { b.m() }\n",
            B=("import Foundation\nimport A\npublic final class BSub: Base { public override init() {}\n"
               "  public override func m() { %s } }\n") % E("BSub.m"),
            App="import A\nimport B\nfunc callerFn() { %s; dispFn(BSub()) }\ncallerFn()\n" % BEG,
            chained=["A", "B"]),
        # K7: the C key on an ACCESSOR row. `Base.v` calls the open `m()`, so the new producer row is `Base.v []`
        # + `dispatchesOn A#Base.m` where it used to be ABSENT; App's property read `b.v` now HITS it (before: a
        # miss, and the ⟨0.40⟩ surface walk). App's own subclass overrides `m`.
        "K7_open_accessor_row_hit_consumer_sub": dict(
            A="open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") }\n  public var v: Int { m(); return 0 } }\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: Base { override func m() { %s } }\n"
                 "func f(_ b: Base) -> Int { return b.v }\nfunc callerFn() { %s; _ = f(Mine()) }\ncallerFn()\n") % (E("Mine.m"), BEG),
            chained=["A", "B"]),
        # K8: K7 with the effectful override in UNCHAINED B: the hit must not delete B's disclosure.
        "K8_open_accessor_row_hit_unchained_sub": dict(
            A="open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") }\n  public var v: Int { m(); return 0 } }\n",
            B=("import Foundation\nimport A\npublic final class BSub: Base { public override init() {}\n"
               "  public override func m() { %s } }\n") % E("BSub.m"),
            App="import A\nimport B\nfunc f(_ b: Base) -> Int { return b.v }\nfunc callerFn() { %s; _ = f(BSub()) }\ncallerFn()\n" % BEG,
            chained=["A"]),
        # K9: K1 with B's implementor EFFECTFUL, so B DOES publish a union under A's key and the new subscript
        # lookup HITS it while A stays unchained: A's disclosure must survive the hit.
        "K9_subscript_req_hit_unchained_owner": dict(
            A="public protocol P { subscript(i: Int) -> Int { get } }\n",
            B=("import Foundation\nimport A\npublic struct BImpl: P { public init() {}\n"
               "  public subscript(i: Int) -> Int { %s; return i } }\n") % E("BImpl.sub"),
            App=("import A\nimport B\nstruct Mine: P { subscript(i: Int) -> Int { return i } }\n"
                 "func dispFn(_ p: any P) -> Int { return p[0] }\n"
                 "func callerFn() { %s; _ = dispFn(BImpl()) }\ncallerFn()\n") % BEG,
            chained=["B"]),
    }

def pkg(dir_, name, deps, src):
    (dir_ / "Sources" / name).mkdir(parents=True, exist_ok=True)
    dl = ", ".join(f'.package(path: "../{x}")' for x in deps)
    td = ", ".join(f'.product(name: "{x}", package: "{x}")' for x in deps)
    kind = "executableTarget" if name == "App" else "target"
    prod = "" if name == "App" else f'products: [.library(name: "{name}", targets: ["{name}"])], '
    (dir_ / "Package.swift").write_text(
        f'// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "{name}", {prod}'
        f'dependencies: [{dl}], targets: [.{kind}(name: "{name}", dependencies: [{td}], path: "Sources/{name}")])\n')
    (dir_ / "Sources" / name / ("main.swift" if name == "App" else f"{name}.swift")).write_text("import Foundation\n" + src)

def sh(cmd, env=None, cwd=None):
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=cwd); return r.returncode, r.stdout, r.stderr

def main():
    OUT.mkdir(parents=True, exist_ok=True); res = {}
    for name in fixtures("X"):
        d = OUT / name
        if d.exists(): shutil.rmtree(d)
        d.mkdir(parents=True); (d / "run").mkdir()
        fx = fixtures(str(d))[name]
        pkg(d / "A", "A", [], fx["A"]); pkg(d / "B", "B", ["A"], fx["B"]); pkg(d / "App", "App", ["A", "B"], fx["App"])
        run = d / "run"
        ok = True
        for m, deps in (("A", []), ("B", ["A"])):
            rc, _, e = sh(SWIFTC + ["-emit-library", "-static", "-emit-module", "-parse-as-library", "-module-name", m,
                                    "-I", str(run), "-o", str(run / f"lib{m}.a"), "-emit-module-path", str(run / f"{m}.swiftmodule"),
                                    str(d / m / "Sources" / m / f"{m}.swift")])
            if rc: print(name, "NOCOMPILE", m, e[-400:]); ok = False; break
        if not ok: continue
        rc, _, e = sh(SWIFTC + ["-I", str(run), "-L", str(run), "-lA", "-lB", "-o", str(run / "app"), str(d / "App/Sources/App/main.swift")])
        if rc: print(name, "NOCOMPILE App", e[-400:]); continue
        rc, so, _ = sh([str(run / "app")])
        gt, inside = False, False
        for l in so.splitlines():
            if l.startswith("BEGIN:callerFn"): inside = True
            elif l.startswith("END:callerFn"): inside = False
            elif l.startswith("EFF:") and inside: gt = True
        deps = d / "deps"; deps.mkdir()
        # each chained dependency is scanned with its own chained dependencies (A before B)
        for m in ("A", "B"):
            if m not in fx["chained"]: continue
            env = dict(os.environ)
            mine = [str(p) for p in deps.glob("*.json")]
            if mine: env["CANDOR_DEPS"] = " ".join(mine)
            sh([BIN, str(d / m), "--out", str(d / f"out_{m}" / m)], env=env)
            for f in (d / f"out_{m}").glob("*.Swift.json"): shutil.copy(f, deps / f.name)
        env = dict(os.environ); env["CANDOR_DEPS"] = " ".join(str(p) for p in deps.glob("*.json"))
        _, oj, _ = sh([BIN, str(d / "App"), "--json"], env=env)
        try: row = next((x for x in json.loads(oj)["functions"] if x["fn"] == "callerFn"), None)
        except Exception: row = None
        g = {}
        for pol in ("deny Fs callerFn", "deny Fs Unknown callerFn"):
            (d / "pol").write_text(pol + "\n")
            g[pol], _, _ = sh([BIN, str(d / "App"), "--policy", str(d / "pol"), "--json"], env=env)
        g1, g2 = g["deny Fs callerFn"], g["deny Fs Unknown callerFn"]
        inv = bool(row and (row.get("invisible") or row.get("incomplete")))
        if gt: v = "CHARGED" if g1 == 1 else ("DISCLOSED" if g1 == 2 or g2 in (1, 2) or inv else "SILENT")
        else: v = "FABRICATED" if g1 == 1 else "CLEAN"
        res[name] = dict(gt=gt, g1=g1, g2=g2, verdict=v, row={k: row.get(k) for k in ("inferred", "invisible", "incomplete", "unknownWhy")} if row else None)
        print(f"{name:45s} gt={int(gt)} g={g1}{g2} {v:10s} {res[name]['row']}")
    json.dump(res, open(OUT / "controls.json", "w"), indent=1)

main()
