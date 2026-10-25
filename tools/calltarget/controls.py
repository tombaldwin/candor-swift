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
        # K10 (FABRICATION control, from the corpus A/B): a self-dispatching template method run on an EXACT
        # receiver the library constructs itself. App's own subclass's effect must NOT be charged to `callerFn`.
        "K10_self_key_exact_receiver_no_join": dict(
            A=("open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n"
               "public final class Gen: V { public override init() {} }\npublic func run() { Gen().walk() }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: V { override func visit() { %s } }\n"
                 "func liveFn() { Mine().walk() }\nfunc callerFn() { %s; run() }\ncallerFn(); liveFn()\n") % (E("Mine.visit"), BEG),
            chained=["A", "B"]),
        # K11: the same template method reached through a HELD VALUE typed by the open class: App's subclass runs.
        "K11_self_key_held_value_joins": dict(
            A=("open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n"
               "public func format(using v: V) { v.walk() }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: V { override func visit() { %s } }\n"
                 "func callerFn() { %s; format(using: Mine()) }\ncallerFn()\n") % (E("Mine.visit"), BEG),
            chained=["A", "B"]),
        # ── call-target ROUND 2 controls (written and run on published 0.40.17 BEFORE the R1436 change) ──
        # K12 (FABLE-REVIEW §1.3, the RE-KEY leg): the held value is typed by an open SUBCLASS `W` the consumer
        # does not subclass; the self-key must be re-keyed to `W`, so App's `Mine: V` (a sibling of W) never runs.
        "K12_rekey_open_subclass_no_join": dict(
            A=("open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n"
               "open class W: V { public override init() {} }\npublic func format(using w: W) { w.walk() }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: V { override func visit() { %s } }\n"
                 "func liveFn() { Mine().walk() }\nfunc callerFn() { %s; format(using: W()) }\ncallerFn(); liveFn()\n") % (E("Mine.visit"), BEG),
            chained=["A", "B"]),
        # K12p: the positive twin — App subclasses W itself, so its override DOES run.
        "K12p_rekey_open_subclass_joins": dict(
            A=("open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n"
               "open class W: V { public override init() {} }\npublic func format(using w: W) { w.walk() }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class MineW: W { override func visit() { %s } }\n"
                 "func callerFn() { %s; format(using: MineW()) }\ncallerFn()\n") % (E("MineW.visit"), BEG),
            chained=["A", "B"]),
        # K13: N-hop through a STORED PROPERTY: the open-typed held value is a field of a final holder, two calls
        # away from the consumer. App's subclass runs (positive).
        "K13_nhop_stored_property_joins": dict(
            A=("open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n"
               "public final class Holder { let v: V\n  public init(_ v: V) { self.v = v }\n  public func go() { v.walk() } }\n"
               "public func run(_ h: Holder) { h.go() }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: V { override func visit() { %s } }\n"
                 "func callerFn() { %s; run(Holder(Mine())) }\ncallerFn()\n") % (E("Mine.visit"), BEG),
            chained=["A", "B"]),
        # K13n: K13's negative — the stored field is typed by the open subclass W; App's `Mine: V` cannot be it.
        "K13n_nhop_stored_property_rekey_no_join": dict(
            A=("open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n"
               "open class W: V { public override init() {} }\n"
               "public final class Holder { let w: W\n  public init(_ w: W) { self.w = w }\n  public func go() { w.walk() } }\n"
               "public func run(_ h: Holder) { h.go() }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: V { override func visit() { %s } }\n"
                 "func liveFn() { Mine().walk() }\nfunc callerFn() { %s; run(Holder(W())) }\ncallerFn(); liveFn()\n") % (E("Mine.visit"), BEG),
            chained=["A", "B"]),
        # K14 (R1436, the SwiftLint `SuperfluousElseRule.Rewriter.modify` shape; wx_unrelated_override's sibling-
        # SUBTREE form): a consumer-LOCAL subclass `Indent` of the dependency's open class, held in a stored field,
        # runs the template method; a SIBLING local subclass `Other` overrides with an effect. Must stay CLEAN.
        "K14_sibling_subtree_field_no_join": dict(
            A="open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nclass Indent: V { override func visit() { print(\"RAN:Indent.visit\") } }\n"
                 "final class Other: V { override func visit() { %s } }\n"
                 "struct Rule { let indenter = Indent()\n  func modify() { indenter.walk() } }\n"
                 "func liveFn() { Other().walk() }\nfunc callerFn() { %s; Rule().modify() }\ncallerFn(); liveFn()\n") % (E("Other.visit"), BEG),
            chained=["A", "B"]),
        # K14l: K14 with a local `let` receiver instead of a field.
        "K14l_sibling_subtree_local_no_join": dict(
            A="open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nclass Indent: V { override func visit() { print(\"RAN:Indent.visit\") } }\n"
                 "final class Other: V { override func visit() { %s } }\n"
                 "func liveFn() { Other().walk() }\nfunc callerFn() { %s; let i = Indent(); i.walk() }\ncallerFn(); liveFn()\n") % (E("Other.visit"), BEG),
            chained=["A", "B"]),
        # K14p: the positive twin inside the receiver's SUBTREE — a subclass of `Indent` is what the field holds.
        "K14p_subtree_subclass_joins": dict(
            A="open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nclass Indent: V { override func visit() { print(\"RAN:Indent.visit\") } }\n"
                 "final class SubIndent: Indent { override func visit() { %s } }\n"
                 "struct Rule { let indenter: Indent = SubIndent()\n  func modify() { indenter.walk() } }\n"
                 "func callerFn() { %s; Rule().modify() }\ncallerFn()\n") % (E("SubIndent.visit"), BEG),
            chained=["A", "B"]),
        # K14a: the positive twin on the ANCESTOR path — the receiver's own class inherits a local Mid's override.
        "K14a_ancestor_override_joins": dict(
            A="open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nclass Mid: V { override func visit() { %s } }\n"
                 "final class Leaf: Mid {}\nfinal class Other: V { override func visit() { print(\"RAN:Other.visit\") } }\n"
                 "func liveFn() { Other().walk() }\nfunc callerFn() { %s; let l = Leaf(); l.walk() }\ncallerFn(); liveFn()\n") % (E("Mid.visit"), BEG),
            chained=["A", "B"]),
        # K14h: the HELD-VALUE collision the scoping must not cut: the dependency's template method dispatches on
        # ANOTHER value of its own class (`other.visit()`), so a sibling's override runs whatever `self` is.
        "K14h_heldvalue_same_class_joins": dict(
            A=("open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n"
               "  public func walk(_ other: V) { other.visit() } }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nclass Indent: V { override func visit() { print(\"RAN:Indent.visit\") } }\n"
                 "final class Other: V { override func visit() { %s } }\n"
                 "func callerFn() { %s; let i = Indent(); i.walk(Other()) }\ncallerFn()\n") % (E("Other.visit"), BEG),
            chained=["A", "B"]),
        # K15 (wx_unrelated_override): App overrides `m` on a class UNRELATED to the dispatched receiver's type.
        "K15_unrelated_class_override_no_join": dict(
            A=("open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") } }\n"
               "open class Unrel { public init() {}\n  open func m() { print(\"RAN:Unrel.m\") } }\n"
               "public func dispFn(_ b: Base) { b.m() }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class O2: Unrel { override func m() { %s } }\n"
                 "func liveFn() { O2().m() }\nfunc callerFn() { %s; dispFn(Base()) }\ncallerFn(); liveFn()\n") % (E("O2.m"), BEG),
            chained=["A", "B"]),
        # K16 (wx_exact_producer): dispatch on a value of a FINAL subclass; App subclasses the base.
        "K16_final_receiver_no_join": dict(
            A=("open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  public func walk() { visit() } }\n"
               "public final class F: V { public override init() {} }\npublic func run(_ f: F) { f.walk() }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: V { override func visit() { %s } }\n"
                 "func liveFn() { Mine().walk() }\nfunc callerFn() { %s; run(F()) }\ncallerFn(); liveFn()\n") % (E("Mine.visit"), BEG),
            chained=["A", "B"]),
        # K17: an INDIRECT consumer subclass (`Mine: Mid: Base`) of a dependency's open class, through a held-value
        # key: one tree charges it (`subtypesOf` is transitive); the chained join asked only DIRECT subclasses.
        "K17_indirect_subclass_heldvalue_joins": dict(
            A="open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") } }\npublic func dispFn(_ b: Base) { b.m() }\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nclass Mid: Base {}\nfinal class Mine: Mid { override func m() { %s } }\n"
                 "func callerFn() { %s; dispFn(Mine()) }\ncallerFn()\n") % (E("Mine.m"), BEG),
            chained=["A", "B"]),
        # K18: the protocol twin — a consumer class conforms, its SUBCLASS overrides the witness (R867 in one tree).
        "K18_protocol_conformer_subclass_joins": dict(
            A="public protocol P { func m() }\npublic func dispFn(_ p: any P) { p.m() }\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nclass Mid: P { func m() { print(\"RAN:Mid.m\") } }\n"
                 "final class Mine: Mid { override func m() { %s } }\n"
                 "func callerFn() { %s; dispFn(Mine()) }\ncallerFn()\n") % (E("Mine.m"), BEG),
            chained=["A", "B"]),
        # K19 (R1446's BOUND): 13 indirect overriding subclasses under one direct one — past SPEC §4's 12 UNITS the
        # transitive additions must DISCLOSE, not union (SwiftLint: a few direct `SyntaxRewriter` subclasses, 261
        # `visit` overrides below them). Executed: the effectful one runs.
        "K19_indirect_subclasses_past_bound_disclose": dict(
            A="open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") } }\npublic func dispFn(_ b: Base) { b.m() }\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nclass Mid: Base {}\n"
                 "final class Mine: Mid { override func m() { %s } }\n"
                 + "".join("final class P%d: Mid { override func m() { print(\"RAN:P%d\") } }\n" % (i, i) for i in range(12))
                 + "func callerFn() { %s; dispFn(Mine()) }\ncallerFn()\n") % (E("Mine.m"), BEG),
            chained=["A", "B"]),
        # ── R1437 residuals (FABLE-REVIEW §1.3 a–d), executed, positive: the effect DOES run ──
        # R1437a: an `open` member that self-dispatches carries no self-key.
        "R1437a_open_member_self_dispatch": dict(
            A=("open class V { public init() {}\n  open func visit() { print(\"RAN:V.visit\") }\n  open func walk() { visit() } }\n"
               "public func format(using v: V) { v.walk() }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: V { override func visit() { %s } }\n"
                 "func callerFn() { %s; format(using: Mine()) }\ncallerFn()\n") % (E("Mine.visit"), BEG),
            chained=["A", "B"]),
        # R1437b: a property-read key two hops out in the producer.
        "R1437b_property_key_two_hops": dict(
            A=("open class V { public init() {}\n  open func m() { print(\"RAN:V.m\") }\n  public var v: Int { m(); return 0 } }\n"
               "public func f(_ b: V) -> Int { return b.v }\npublic func g(_ b: V) -> Int { return f(b) }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: V { override func m() { %s } }\n"
                 "func callerFn() { %s; _ = g(Mine()) }\ncallerFn()\n") % (E("Mine.m"), BEG),
            chained=["A", "B"]),
        # R1437b2: the formatting twin — `"\\(c)"` on a local protocol refining CustomStringConvertible, two hops out.
        "R1437b2_format_key_two_hops": dict(
            A=("public protocol Conv: CustomStringConvertible {}\n"
               "public func f(_ c: any Conv) -> String { return \"\\(c)\" }\npublic func g(_ c: any Conv) -> String { return f(c) }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nstruct Mine: Conv { var description: String { %s; return \"\" } }\n"
                 "func callerFn() { %s; _ = g(Mine()) }\ncallerFn()\n") % (E("Mine.description"), BEG),
            chained=["A", "B"]),
        # R1437c: the `super.` filter strips a HELD-VALUE key whose class is a supertype of the caller's class.
        "R1437c_super_strips_heldvalue_key": dict(
            A=("open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") }\n"
               "  open func run(_ other: Base) { other.m() } }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Eff: Base { override func m() { %s } }\n"
                 "final class Sub: Base { override func run(_ o: Base) { super.run(o) } }\n"
                 "func callerFn() { %s; Sub().run(Eff()) }\ncallerFn()\n") % (E("Eff.m"), BEG),
            chained=["A", "B"]),
        # R1437d: a consumer `super.run()` into a base body that self-dispatches to the consumer's own override.
        "R1437d_super_into_self_dispatch": dict(
            A=("open class V { public init() {}\n  open func hook() { print(\"RAN:V.hook\") }\n"
               "  open func run() { hook() } }\n"),
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfinal class Mine: V { override func hook() { %s }\n"
                 "  override func run() { super.run() } }\n"
                 "func callerFn() { %s; Mine().run() }\ncallerFn()\n") % (E("Mine.hook"), BEG),
            chained=["A", "B"]),
        # ── the NON-INVOKING LOOK-ALIKE axis (round 2 brief): executed, no effect at the caller → CLEAN ──
        "N1_closure_stored_never_applied": dict(
            A=("public func make() -> () -> Void { return { %s } }\n") % E("closure"),
            B="import A\npublic func bTouch() {}\n",
            App="import A\nimport B\nfunc callerFn() { %s; let c = make(); _ = c }\ncallerFn()\n" % BEG,
            chained=["A", "B"]),
        "N2_keypath_stored_never_applied": dict(
            A="public func aTouch() {}\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nstruct S { var p: Int { %s; return 0 } }\n"
                 "func callerFn() { %s; let k = \\S.p; _ = k }\ncallerFn()\n") % (E("S.p"), BEG),
            chained=["A", "B"]),
        "N3_array_literal_no_compare": dict(
            A="public func aTouch() {}\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nstruct S: Equatable { static func == (a: S, b: S) -> Bool { %s; return true } }\n"
                 "func callerFn() { %s; let x = S(); let a = [x]; _ = a }\ncallerFn()\n") % (E("S.=="), BEG),
            chained=["A", "B"]),
        "N3p_array_contains_compares": dict(
            A="public func aTouch() {}\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nstruct S: Equatable { static func == (a: S, b: S) -> Bool { %s; return true } }\n"
                 "func callerFn() { %s; let x = S(); _ = [x].contains(x) }\ncallerFn()\n") % (E("S.=="), BEG),
            chained=["A", "B"]),
        "N4_local_fn_reference_never_called": dict(
            A="public func aTouch() {}\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nfunc eff() { %s }\n"
                 "func callerFn() { %s; let f = eff; _ = f }\ncallerFn()\n") % (E("eff"), BEG),
            chained=["A", "B"]),
        # N5: the OPERATOR passed as the comparator runs the element's `<` (positive twin of N6). The derived table
        # excludes `sorted(by:)` (a closure parameter); the first round-2 cut lost this form — CHARGED on 0.40.17.
        "N5_sorted_by_operator_ref_compares": dict(
            A="public func aTouch() {}\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nstruct C: Comparable { let v: Int\n"
                 "  static func < (a: C, b: C) -> Bool { %s; return a.v < b.v } }\n"
                 "func callerFn() { %s; _ = [C(v: 2), C(v: 1)].sorted(by: <); _ = [C(v: 1), C(v: 2)].max(by: <) }\ncallerFn()\n") % (E("C.<"), BEG),
            chained=["A", "B"]),
        # N6: a comparator FUNCTION that never calls the element's `<` — 0.40.17 charged `C.<` by name (FABRICATED).
        "N6_sorted_by_pure_fn_no_compare": dict(
            A="public func aTouch() {}\n",
            B="import A\npublic func bTouch() {}\n",
            App=("import Foundation\nimport A\nimport B\nstruct C: Comparable { let v: Int\n"
                 "  static func < (a: C, b: C) -> Bool { %s; return a.v < b.v } }\n"
                 "func byV(_ a: C, _ b: C) -> Bool { a.v > b.v }\n"
                 "func liveFn() { _ = C(v: 1) < C(v: 2) }\n"
                 "func callerFn() { %s; _ = [C(v: 2), C(v: 1)].sorted(by: byV) }\ncallerFn(); liveFn()\n") % (E("C.<"), BEG),
            chained=["A", "B"]),
        # ── SIDECAR-DELETED arm (FABLE-REVIEW §3.5): K6's both-chained charge with every chained report's
        # `.callgraph.json`/`.hierarchy.json` sidecar removed before App is scanned. ──
        "S1_sidecar_deleted_open_class": dict(
            A="open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") } }\npublic func dispFn(_ b: Base) { b.m() }\n",
            B=("import Foundation\nimport A\npublic final class BSub: Base { public override init() {}\n"
               "  public override func m() { %s } }\n") % E("BSub.m"),
            App="import A\nimport B\nfunc callerFn() { %s; dispFn(BSub()) }\ncallerFn()\n" % BEG,
            chained=["A", "B"]),
        "S2_sidecar_deleted_plain_effect": dict(
            A=("import Foundation\npublic func doIt() { %s }\n") % E("doIt"),
            B="import A\npublic func bTouch() { doIt() }\n",
            App="import A\nimport B\nfunc callerFn() { %s; bTouch() }\ncallerFn()\n" % BEG,
            chained=["A", "B"]),
    }

_fixtures0 = fixtures
def fixtures(d):
    fx = _fixtures0(d)
    # the SIDECAR-PRESENT twins of the S-pairs (S1/S2 hand App the report with its sidecars deleted)
    for k in [k for k in fx if k.startswith("S")]:
        fx[k.replace("_deleted_", "_present_")] = dict(fx[k], sidecar=True)
    return fx

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
            mine = [str(p) for p in deps.glob("*.Swift.json")]
            if mine: env["CANDOR_DEPS"] = " ".join(mine)
            sh([BIN, str(d / m), "--out", str(d / f"out_{m}" / m)], env=env)
            for f in (d / f"out_{m}").glob("*.json"):
                # the original controls hand App the report ONLY (no sidecar); `sidecar=True` also copies the
                # `.callgraph.json`/`.hierarchy.json` sidecars beside it, for the S-pairs.
                if not fx.get("sidecar") and (f.name.endswith(".callgraph.json") or f.name.endswith(".hierarchy.json")): continue
                shutil.copy(f, deps / f.name)
        env = dict(os.environ); env["CANDOR_DEPS"] = " ".join(str(p) for p in deps.glob("*.Swift.json"))
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
