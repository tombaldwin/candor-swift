#!/usr/bin/env python3
"""Call-target matrix generator for candor-swift.

Axes:
  kind       call kind (templates below: D* explicit dispatch, S* static controls, H* implicit
             runtime->user hooks / operators, U* unit identity)
  place      where the implementor (or hook-declaring type) lives relative to the call site:
               L1  same file
               L2  other file, same module
               L3a other module, same package: abstraction + dispatch site in Lib, implementor + caller in App
               L3b other module, same package: abstraction + implementor in Lib, dispatch site + caller in App
               L4a chained dependency: as L3a but Lib is a separate package, scanned standalone and chained
               L4b chained dependency: as L3b, chained
             (UNSEEN = the Lib's own standalone scan in L4a: the implementor exists only in the consumer;
              measured as the dispatch fn `dispFn` in the Lib report.)
  mult       M1 one effectful implementor; M2 two, the passed one effectful; M3 two, the passed one PURE
             (the dispatch fn is still exercised with the effectful one by `crossFn`); M0 all pure (control)
             For hooks/static/unit: M1 effectful; MD decoy (the used body pure, a same-named effectful one elsewhere).
  eff        Fs / Net / Exec

Each cell: a directory with sources, a ground-truth build recipe, and gated function names.
Gated functions: callerFn (always), dispFn (when the template has a separate dispatch site), crossFn (M3).
Ground truth: every gated fn prints BEGIN:<fn>/END:<fn>; every effectful body prints EFF:<body> after
performing the effect; GT(fn) = an EFF token appears inside fn's BEGIN/END.
"""
import json, os, sys, itertools, pathlib, shutil

OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent / "cells"

def effect_stmt(eff, body, celldir):
    if eff == "Fs":
        return f'_ = FileManager.default.createFile(atPath: "{celldir}/run/W_{body}", contents: nil); print("EFF:{body}")'
    if eff == "Net":
        return ('do { let sem = DispatchSemaphore(value: 0); '
                'URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:9/")!) { _, _, e in '
                f'print("EFF:{body}:net=\\(e != nil)"); sem.signal() }}.resume(); sem.wait() }}')
    if eff == "Exec":
        return ('do { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true"); '
                f'try? p.run(); p.waitUntilExit(); print("EFF:{body}:exec=\\(p.terminationStatus)") }}')
    raise ValueError(eff)

def pure_stmt(body):
    return f'print("RAN:{body}")'

def B(fn):  # begin/end wrappers for gated fns
    return f'print("BEGIN:{fn}"); defer {{ print("END:{fn}") }}'

# ---------------------------------------------------------------------------------------------
# Template protocol: a template is a dict with
#   group: 'D' dispatch (uses mult M0..M3), 'S' static/control, 'H' hook, 'U' unit identity
#   places: allowed placements
#   abs(ctx) -> code for the abstraction (protocol/base), lives with the dispatch site (a) or impl (b)
#   impl(ctx, T, stmt) -> code for one implementor type T whose behaviour statement is stmt
#   ds(ctx) -> dispatch fn code (named dispFn) or None (site directly in callerFn)
#   cl(ctx, T) -> callerFn body code using implementor T (or None for templates with custom cl)
#   cx(ctx, T) -> crossFn body (exercises dispFn with T) — default: same as cl
# ctx: dict(pub=..., opn=...) access keywords; templates always emit public/open (harmless in-module).
# ---------------------------------------------------------------------------------------------
T = {}

def tpl(name, **kw):
    kw.setdefault("group", "D")
    T[name] = kw

ALLP = ["L1", "L2", "L3a", "L3b", "L4a", "L4b"]
BP = ["L1", "L2", "L3b", "L4b"]          # site with caller, type elsewhere
AP = ["L1", "L2", "L3a", "L4a"]          # generic site with abstraction, type with caller

# ---- explicit dispatch ----------------------------------------------------------------------
tpl("D01_class_virtual", places=ALLP,
    abs=lambda c: "open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") } }",
    impl=lambda c, t, s: f"public final class {t}: Base {{ public override init() {{}}\n  public override func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ b: Base) {{ {B('dispFn')}; b.m() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D02_proto_existential", places=ALLP,
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ p: any P) {{ {B('dispFn')}; p.m() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D03_generic_bound", places=ALLP,
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn<X: P>(_ p: X) {{ {B('dispFn')}; p.m() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D04_opaque_some", places=ALLP,
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ p: some P) {{ {B('dispFn')}; p.m() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D05_ext_default_calls_req", places=ALLP,
    abs=lambda c: "public protocol P { func m() }\nextension P { public func run() { m() } }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ p: any P) {{ {B('dispFn')}; p.run() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D06_proto_property_req", places=ALLP,
    abs=lambda c: "public protocol P { var v: Int { get } }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public var v: Int {{ {s}; return 1 }} }}",
    ds=lambda c: f"public func dispFn(_ p: any P) -> Int {{ {B('dispFn')}; return p.v }}",
    call=lambda c, t: f"_ = dispFn({t}())")
tpl("D07_class_property_override", places=ALLP,
    abs=lambda c: "open class Base { public init() {}\n  open var v: Int { return 0 } }",
    impl=lambda c, t, s: f"public final class {t}: Base {{ public override init() {{}}\n  public override var v: Int {{ {s}; return 1 }} }}",
    ds=lambda c: f"public func dispFn(_ b: Base) -> Int {{ {B('dispFn')}; return b.v }}",
    call=lambda c, t: f"_ = dispFn({t}())")
tpl("D08_proto_subscript_req", places=ALLP,
    abs=lambda c: "public protocol P { subscript(i: Int) -> Int { get } }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public subscript(i: Int) -> Int {{ {s}; return i }} }}",
    ds=lambda c: f"public func dispFn(_ p: any P) -> Int {{ {B('dispFn')}; return p[0] }}",
    call=lambda c, t: f"_ = dispFn({t}())")
tpl("D09_fnvalue_method_ref", places=ALLP,
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ f: () -> Void) {{ {B('dispFn')}; f() }}",
    call=lambda c, t: f"dispFn({t}().m)")
tpl("D10_fnvalue_closure_literal", places=ALLP,
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ f: () -> Void) {{ {B('dispFn')}; f() }}",
    call=lambda c, t: f"dispFn({{ {t}().m() }})")
tpl("D11_stored_closure_deferred", places=ALLP,
    abs=lambda c: ("public protocol P { func m() }\npublic final class Box { var f: (() -> Void)? = nil; public init() {}\n"
                   "  public func set(_ g: @escaping () -> Void) { f = g }\n  public func fire() { f?() } }"),
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ b: Box) {{ {B('dispFn')}; b.fire() }}",
    call=lambda c, t: f"let b = Box(); b.set {{ {t}().m() }}; dispFn(b)")
tpl("D12_generic_holder", places=ALLP,
    abs=lambda c: "public protocol P { func m() }\npublic struct Holder<X: P> { let t: X; public init(_ t: X) { self.t = t }\n  public func go() { t.m() } }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn<X: P>(_ h: Holder<X>) {{ {B('dispFn')}; h.go() }}",
    call=lambda c, t: f"dispFn(Holder({t}()))")
tpl("D13_any_cast", places=ALLP,
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ x: Any) {{ {B('dispFn')}; (x as? P)?.m() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D14_inherited_requirement", places=ALLP,
    abs=lambda c: "public protocol P0 { func m() }\npublic protocol P: P0 {}",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ p: any P) {{ {B('dispFn')}; p.m() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D15_composition", places=ALLP,
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: f"public struct {t}: P, Sendable {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ p: any P & Sendable) {{ {B('dispFn')}; p.m() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D16_static_req_metatype", places=ALLP,
    abs=lambda c: "public protocol P { static func mk() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public static func mk() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn<X: P>(_ t: X.Type) {{ {B('dispFn')}; X.mk() }}",
    call=lambda c, t: f"dispFn({t}.self)")
tpl("D17_init_req_generic", places=ALLP,
    abs=lambda c: "public protocol P { init(k: Int) }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init(k: Int) {{ {s} }} }}",
    ds=lambda c: f"public func dispFn<X: P>(_ t: X.Type) {{ {B('dispFn')}; _ = X(k: 1) }}",
    call=lambda c, t: f"dispFn({t}.self)")
tpl("D18_ext_member_shadow_static", places=ALLP,   # extension non-requirement: existential call runs the EXTENSION body
    abs=lambda c: "public protocol P { func m() }\nextension P { public func n() { m() } }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }}\n  public func n() {{ print(\"RAN:{t}.n\") }} }}",
    ds=lambda c: f"public func dispFn(_ p: any P) {{ {B('dispFn')}; p.n() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D19_class_super_chain", places=ALLP,
    abs=lambda c: "open class Base { public init() {}\n  open func m() { print(\"RAN:Base.m\") }\n  public func tmpl() { m() } }",
    impl=lambda c, t, s: f"public final class {t}: Base {{ public override init() {{}}\n  public override func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ b: Base) {{ {B('dispFn')}; b.tmpl() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D20_callAsFunction_req", places=ALLP,
    abs=lambda c: "public protocol P { func callAsFunction() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func callAsFunction() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn<X: P>(_ p: X) {{ {B('dispFn')}; p() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D21_async_await", places=ALLP,
    abs=lambda c: "public protocol P { func m() async }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() async {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ p: any P) async {{ {B('dispFn')}; await p.m() }}",
    call=lambda c, t: f"let sem = DispatchSemaphore(value: 0); Task {{ await dispFn({t}()); sem.signal() }}; sem.wait()")

# ---- static controls ----------------------------------------------------------------------
tpl("S01_free_fn", group="S", places=BP,
    abs=lambda c: "",
    impl=lambda c, t, s: f"public func f{t}() {{ {s} }}",
    ds=None, call=lambda c, t: f"f{t}()")
tpl("S02_struct_method", group="S", places=BP,
    abs=lambda c: "",
    impl=lambda c, t, s: f"public struct {t} {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=None, call=lambda c, t: f"{t}().m()")
tpl("S03_struct_computed_prop", group="S", places=BP,
    abs=lambda c: "",
    impl=lambda c, t, s: f"public struct {t} {{ public init() {{}}\n  public var v: Int {{ {s}; return 1 }} }}",
    ds=None, call=lambda c, t: f"_ = {t}().v")
tpl("S04_init", group="S", places=BP,
    abs=lambda c: "",
    impl=lambda c, t, s: f"public struct {t} {{ public init() {{ {s} }} }}",
    ds=None, call=lambda c, t: f"_ = {t}()")
tpl("S05_static_method", group="S", places=BP,
    abs=lambda c: "",
    impl=lambda c, t, s: f"public enum {t} {{ public static func mk() {{ {s} }} }}",
    ds=None, call=lambda c, t: f"{t}.mk()")
tpl("S06_callAsFunction_concrete", group="S", places=BP,
    abs=lambda c: "",
    impl=lambda c, t, s: f"public struct {t} {{ public init() {{}}\n  public func callAsFunction() {{ {s} }} }}",
    ds=None, call=lambda c, t: f"let x = {t}(); x()")
tpl("S07_ext_method_own_type", group="S", places=BP,
    abs=lambda c: "",
    impl=lambda c, t, s: f"public struct {t} {{ public init() {{}} }}\nextension {t} {{ public func m() {{ {s} }} }}",
    ds=None, call=lambda c, t: f"{t}().m()")

# ---- implicit runtime->user hooks and operators ---------------------------------------------
# 'call' is the hook site in callerFn (concrete form); 'gcall'+'gds' is the generic form, site in dispFn.
def H(name, impl, call, gds=None, gcall=None, places=None, extra=""):
    T[name] = dict(group="H", places=places or BP, abs=lambda c: extra, impl=impl, ds=None, call=call)
    if gds:
        T[name + "_gen"] = dict(group="H", places=AP, abs=lambda c: extra, impl=impl,
                                ds=lambda c, gds=gds: f"public func dispFn{gds[0]} {{ {B('dispFn')}; {gds[1]} }}",
                                call=gcall)

H("H01_interp_description",
  impl=lambda c, t, s: f"public struct {t}: CustomStringConvertible {{ public init() {{}}\n  public var description: String {{ {s}; return \"d\" }} }}",
  call=lambda c, t: f'let s = "\\({t}())"; _ = s',
  gds=("<X: CustomStringConvertible>(_ x: X) -> String", 'return "\\(x)"'), gcall=lambda c, t: f"_ = dispFn({t}())")
H("H02_String_describing",
  impl=lambda c, t, s: f"public struct {t}: CustomStringConvertible {{ public init() {{}}\n  public var description: String {{ {s}; return \"d\" }} }}",
  call=lambda c, t: f"_ = String(describing: {t}())",
  gds=("(_ x: Any) -> String", "return String(describing: x)"), gcall=lambda c, t: f"_ = dispFn({t}())")
H("H03_print",
  impl=lambda c, t, s: f"public struct {t}: CustomStringConvertible {{ public init() {{}}\n  public var description: String {{ {s}; return \"d\" }} }}",
  call=lambda c, t: f"print({t}())")
H("H04_array_interp",
  impl=lambda c, t, s: f"public struct {t}: CustomStringConvertible {{ public init() {{}}\n  public var description: String {{ {s}; return \"d\" }} }}",
  call=lambda c, t: f'let s = "\\([{t}()])"; _ = s')
H("H05_explicit_description",
  impl=lambda c, t, s: f"public struct {t}: CustomStringConvertible {{ public init() {{}}\n  public var description: String {{ {s}; return \"d\" }} }}",
  call=lambda c, t: f"_ = {t}().description",
  gds=("<X: CustomStringConvertible>(_ x: X) -> String", "return x.description"), gcall=lambda c, t: f"_ = dispFn({t}())")
EQ = lambda c, t, s: f"public struct {t}: Equatable {{ public init() {{}}\n  public static func == (a: {t}, b: {t}) -> Bool {{ {s}; return true }} }}"
CMP = lambda c, t, s: (f"public struct {t}: Comparable {{ public let k: Int; public init(_ k: Int = 0) {{ self.k = k }}\n"
                       f"  public static func < (a: {t}, b: {t}) -> Bool {{ {s}; return a.k < b.k }}\n"
                       f"  public static func == (a: {t}, b: {t}) -> Bool {{ return a.k == b.k }} }}")
HSH = lambda c, t, s: (f"public struct {t}: Hashable {{ public init() {{}}\n  public static func == (a: {t}, b: {t}) -> Bool {{ return true }}\n"
                       f"  public func hash(into h: inout Hasher) {{ {s}; h.combine(1) }} }}")
H("H06_eq_declared", impl=EQ, call=lambda c, t: f"_ = {t}() == {t}()",
  gds=("<X: Equatable>(_ a: X, _ b: X) -> Bool", "return a == b"), gcall=lambda c, t: f"_ = dispFn({t}(), {t}())")
H("H07_neq_derived", impl=EQ, call=lambda c, t: f"_ = {t}() != {t}()",
  gds=("<X: Equatable>(_ a: X, _ b: X) -> Bool", "return a != b"), gcall=lambda c, t: f"_ = dispFn({t}(), {t}())")
H("H08_sorted", impl=CMP, call=lambda c, t: f"_ = [{t}(2), {t}(1)].sorted()",
  gds=("<X: Comparable>(_ a: [X]) -> [X]", "return a.sorted()"), gcall=lambda c, t: f"_ = dispFn([{t}(2), {t}(1)])")
H("H09_sort_inplace", impl=CMP, call=lambda c, t: f"var a = [{t}(2), {t}(1)]; a.sort(); _ = a")
H("H10_gt_derived", impl=CMP, call=lambda c, t: f"_ = {t}(2) > {t}(1)",
  gds=("<X: Comparable>(_ a: X, _ b: X) -> Bool", "return a > b"), gcall=lambda c, t: f"_ = dispFn({t}(2), {t}(1))")
H("H11_free_max", impl=CMP, call=lambda c, t: f"_ = max({t}(2), {t}(1))")
H("H12_set_insert", impl=HSH, call=lambda c, t: f"var st = Set<{t}>(); st.insert({t}()); _ = st",
  gds=("<X: Hashable>(_ x: X) -> Int", "var st = Set<X>(); st.insert(x); return st.count"), gcall=lambda c, t: f"_ = dispFn({t}())")
H("H13_dict_literal", impl=HSH, call=lambda c, t: f"let d = [{t}(): 1]; _ = d")
H("H14_hashValue", impl=HSH, call=lambda c, t: f"_ = {t}().hashValue")
H("H15_for_in_sequence",
  impl=lambda c, t, s: (f"public struct {t}: Sequence, IteratorProtocol {{ var n = 0; public init() {{}}\n"
                        f"  public mutating func next() -> Int? {{ {s}; n += 1; return n > 1 ? nil : n }} }}"),
  call=lambda c, t: f"for _ in {t}() {{ }}",
  gds=("<X: Sequence>(_ s: X) -> Int", "var k = 0; for _ in s { k += 1 }; return k"), gcall=lambda c, t: f"_ = dispFn({t}())")
H("H16_collection_first",
  impl=lambda c, t, s: (f"public struct {t}: Collection {{ public init() {{}}\n  public var startIndex: Int {{ 0 }}\n  public var endIndex: Int {{ 1 }}\n"
                        f"  public func index(after i: Int) -> Int {{ i + 1 }}\n  public subscript(i: Int) -> Int {{ {s}; return i }} }}"),
  call=lambda c, t: f"_ = {t}().first")
H("H17_switch_pattern", impl=EQ, call=lambda c, t: f"switch {t}() {{ case {t}(): break; default: break }}")
H("H18_json_encode",
  impl=lambda c, t, s: (f"public struct {t}: Encodable {{ public init() {{}}\n"
                        f"  public func encode(to e: Encoder) throws {{ {s}; var c = e.singleValueContainer(); try c.encode(1) }} }}"),
  call=lambda c, t: f"_ = try? JSONEncoder().encode({t}())",
  gds=("<X: Encodable>(_ x: X) -> Int", "return (try? JSONEncoder().encode(x))?.count ?? 0"), gcall=lambda c, t: f"_ = dispFn({t}())")
H("H19_deinit",
  impl=lambda c, t, s: f"public final class {t} {{ public init() {{}}\n  deinit {{ {s} }} }}",
  call=lambda c, t: f"do {{ let o = {t}(); _ = o }}")
H("H20_didSet",
  impl=lambda c, t, s: f"public final class {t} {{ public init() {{}}\n  public var v: Int = 0 {{ didSet {{ {s} }} }} }}",
  call=lambda c, t: f"let o = {t}(); o.v = 1")
H("H21_property_wrapper",
  impl=lambda c, t, s: (f"@propertyWrapper public struct W{t} {{ var x = 0; public init(wrappedValue: Int) {{ x = wrappedValue }}\n"
                        f"  public var wrappedValue: Int {{ get {{ x }} set {{ {s}; x = newValue }} }} }}\n"
                        f"public struct {t} {{ public init() {{}}\n  @W{t} public var v: Int = 0 }}"),
  call=lambda c, t: f"var o = {t}(); o.v = 1; _ = o")
H("H22_lazy_var",
  impl=lambda c, t, s: f"public final class {t} {{ public init() {{}}\n  public lazy var v: Int = {{ {s}; return 1 }}() }}",
  call=lambda c, t: f"let o = {t}(); _ = o.v")
H("H23_synth_eq_field",
  impl=lambda c, t, s: (f"public struct F{t}: Equatable {{ public init() {{}}\n  public static func == (a: F{t}, b: F{t}) -> Bool {{ {s}; return true }} }}\n"
                        f"public struct {t}: Equatable {{ public let f = F{t}(); public init() {{}} }}"),
  call=lambda c, t: f"_ = {t}() == {t}()")
H("H24_synth_hash_field",
  impl=lambda c, t, s: (f"public struct F{t}: Hashable {{ public init() {{}}\n  public static func == (a: F{t}, b: F{t}) -> Bool {{ true }}\n"
                        f"  public func hash(into h: inout Hasher) {{ {s}; h.combine(1) }} }}\n"
                        f"public struct {t}: Hashable {{ public let f = F{t}(); public init() {{}} }}"),
  call=lambda c, t: f"var st = Set<{t}>(); st.insert({t}()); _ = st")
H("H25_synth_codable_field",
  impl=lambda c, t, s: (f"public struct F{t}: Encodable {{ public init() {{}}\n"
                        f"  public func encode(to e: Encoder) throws {{ {s}; var c = e.singleValueContainer(); try c.encode(1) }} }}\n"
                        f"public struct {t}: Encodable {{ public let f = F{t}(); public init() {{}} }}"),
  call=lambda c, t: f"_ = try? JSONEncoder().encode({t}())")
H("H26_dynamic_member",
  impl=lambda c, t, s: f"@dynamicMemberLookup public struct {t} {{ public init() {{}}\n  public subscript(dynamicMember k: String) -> Int {{ {s}; return 1 }} }}",
  call=lambda c, t: f"_ = {t}().anything")
H("H27_string_literal_init",
  impl=lambda c, t, s: f"public struct {t}: ExpressibleByStringLiteral {{ public init(stringLiteral v: String) {{ {s} }} }}",
  call=lambda c, t: f'let x: {t} = "lit"; _ = x')
H("H28_custom_operator",
  impl=lambda c, t, s: f"public struct {t} {{ public init() {{}}\n  public static func + (a: {t}, b: {t}) -> {t} {{ {s}; return a }} }}",
  call=lambda c, t: f"_ = {t}() + {t}()")
H("H29_localizedDescription",
  impl=lambda c, t, s: f"public struct {t}: LocalizedError {{ public init() {{}}\n  public var errorDescription: String? {{ {s}; return \"e\" }} }}",
  call=lambda c, t: f"let e: Error = {t}(); _ = e.localizedDescription")
H("H30_contains_eq", impl=EQ, call=lambda c, t: f"_ = [{t}()].contains({t}())",
  gds=("<X: Equatable>(_ a: [X], _ x: X) -> Bool", "return a.contains(x)"), gcall=lambda c, t: f"_ = dispFn([{t}()], {t}())")
H("H31_tuple_payload_synth_eq",
  impl=lambda c, t, s: (f"public struct F{t}: Equatable {{ public init() {{}}\n  public static func == (a: F{t}, b: F{t}) -> Bool {{ {s}; return true }} }}\n"
                        f"public enum {t}: Equatable {{ case one((F{t}, Int)) }}"),
  call=lambda c, t: f"_ = {t}.one((F{t}(), 1)) == {t}.one((F{t}(), 1))")
H("H32_keypath",
  impl=lambda c, t, s: f"public struct {t} {{ public init() {{}}\n  public var v: Int {{ {s}; return 1 }} }}",
  call=lambda c, t: f"let kp = \\{t}.v; _ = {t}()[keyPath: kp]")
H("H33_debug_reflecting",
  impl=lambda c, t, s: f"public struct {t}: CustomDebugStringConvertible {{ public init() {{}}\n  public var debugDescription: String {{ {s}; return \"d\" }} }}",
  call=lambda c, t: f"_ = String(reflecting: {t}())")
H("H34_text_output_streamable",
  impl=lambda c, t, s: f"public struct {t}: TextOutputStreamable {{ public init() {{}}\n  public func write<Tg: TextOutputStream>(to o: inout Tg) {{ {s}; o.write(\"w\") }} }}",
  call=lambda c, t: f'var s = ""; print({t}(), to: &s); _ = s')
H("H35_dump_mirror",
  impl=lambda c, t, s: f"public struct {t}: CustomReflectable {{ public init() {{}}\n  public var customMirror: Mirror {{ {s}; return Mirror(reflecting: 1) }} }}",
  call=lambda c, t: f'var s = ""; dump({t}(), to: &s); _ = s')
H("H36_proto_ext_operator_inherited",   # R1284 shape
  impl=lambda c, t, s: (f"public protocol Q0{t} {{ var k: Int {{ get }} }}\npublic protocol Q1{t}: Q0{t} {{}}\n"
                        f"extension Q1{t} {{ public static func <~> (a: Self, b: Self) -> Bool {{ {s}; return a.k == b.k }} }}\n"
                        f"public struct {t}: Q1{t} {{ public var k = 0; public init() {{}} }}"),
  call=lambda c, t: f"_ = {t}() <~> {t}()", extra="infix operator <~>: ComparisonPrecedence")
H("H37_iterator_protocol_generic_seq",
  impl=lambda c, t, s: (f"public struct {t}It: IteratorProtocol {{ var n = 0\n  public mutating func next() -> Int? {{ {s}; n += 1; return n > 1 ? nil : n }} }}\n"
                        f"public struct {t}: Sequence {{ public init() {{}}\n  public func makeIterator() -> {t}It {{ {t}It() }} }}"),
  call=lambda c, t: f"_ = {t}().map {{ $0 }}")
H("H38_mutating_compound_assign",
  impl=lambda c, t, s: f"public struct {t} {{ public var k = 0; public init() {{}}\n  public static func += (a: inout {t}, b: Int) {{ {s}; a.k += b }} }}",
  call=lambda c, t: f"var o = {t}(); o += 1; _ = o")
H("H39_subscript_concrete",
  impl=lambda c, t, s: f"public struct {t} {{ public init() {{}}\n  public subscript(i: Int) -> Int {{ {s}; return i }} }}",
  call=lambda c, t: f"_ = {t}()[0]")
H("H40_willSet_struct_prop",
  impl=lambda c, t, s: f"public struct {t} {{ public init() {{}}\n  public var v: Int = 0 {{ willSet {{ {s} }} }} }}",
  call=lambda c, t: f"var o = {t}(); o.v = 2; _ = o")

# ---- unit identity -------------------------------------------------------------------------
# Each U template defines the whole program via 'files' (place-independent unless noted) and the
# expected GT is executed. 'decoy' variants swap which body the caller reaches.
U = {}
def UT(name, files, gated=("callerFn",), mains="callerFn()", pkg=None):
    U[name] = dict(files=files, gated=gated, mains=mains, pkg=pkg)

def ufile_main(c, body):
    return f"import Foundation\n{body}\n"

# U01 R1396: same-named extension members in two targets (A method effectful, B property pure) and reverse
for arr, (aeff, beff) in {"a": (True, False), "b": (False, True)}.items():
    def mk(c, arr=arr, aeff=aeff, beff=beff):
        A = c["E"]("A.probe") if aeff else c["P"]("A.probe")
        Bs = c["E"]("B.probe") if beff else c["P"]("B.probe")
        return {
            "Package.swift": ('// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "u01", targets: [\n'
                              '  .target(name: "T0", path: "Sources/T0"), .target(name: "A", dependencies: ["T0"], path: "Sources/A"),\n'
                              '  .executableTarget(name: "B", dependencies: ["T0", "A"], path: "Sources/B")])\n'),
            "Sources/T0/T.swift": "public struct T { public init() {} }\n",
            "Sources/A/A.swift": f"import Foundation\nimport T0\npublic extension T {{ func probe() {{ {A} }} }}\npublic func useA(_ t: T) {{ {B('useA')}; t.probe() }}\n",
            "Sources/B/main.swift": (f"import Foundation\nimport T0\nimport A\nprivate extension T {{ var probe: Int {{ {Bs}; return 1 }} }}\n"
                                     f"func useB(_ t: T) -> Int {{ {B('useB')}; return t.probe }}\n_ = useB(T()); useA(T())\n"),
        }
    UT(f"U01_ext_member_two_targets_{arr}", mk, gated=("useA", "useB"), pkg="multi3")

# U02 R1271: nested Box.K vs top-level K, the caller uses one
for which in ("nested", "top"):
    def mk(c, which=which):
        return {"main.swift": ufile_main(c,
            f"enum Box {{ struct K {{ func m() {{ {c['E']('Box.K.m') if which=='nested' else c['P']('Box.K.m')} }} }} }}\n"
            f"struct K {{ func m() {{ {c['P']('K.m') if which=='nested' else c['E']('K.m')} }} }}\n"
            f"func callerFn() {{ {B('callerFn')}; {'Box.K().m()' if which=='nested' else 'K().m()'} }}\n"
            f"func decoyFn() {{ {B('decoyFn')}; {'K().m()' if which=='nested' else 'Box.K().m()'} }}\ncallerFn(); decoyFn()\n")}
    UT(f"U02_same_leaf_nested_{which}", mk, gated=("callerFn", "decoyFn"))

# U02c same-leaf with comparison witness (R1271's exact shape: Box.KeyT vs top-level KeyT, effectful <)
def mk(c):
    return {"main.swift": ufile_main(c,
        f"enum Box {{ struct KeyT: Comparable {{ let k: Int; static func < (a: KeyT, b: KeyT) -> Bool {{ {c['E']('Box.KeyT.<')}; return a.k < b.k }} }} }}\n"
        f"struct KeyT: Comparable {{ let k: Int; static func < (a: KeyT, b: KeyT) -> Bool {{ {c['P']('KeyT.<')}; return a.k < b.k }} }}\n"
        f"func callerFn() {{ {B('callerFn')}; _ = [Box.KeyT(k: 2), Box.KeyT(k: 1)].sorted() }}\n"
        f"func decoyFn() {{ {B('decoyFn')}; _ = [KeyT(k: 2), KeyT(k: 1)].sorted() }}\ncallerFn(); decoyFn()\n")}
UT("U02c_same_leaf_witness", mk, gated=("callerFn", "decoyFn"))

# U03 fileprivate same-named helper in two files
def mk(c):
    return {"main.swift": ufile_main(c, f"fileprivate func helper() {{ {c['P']('main.helper')} }}\nfunc callerFn() {{ {B('callerFn')}; helper() }}\ncallerFn(); otherFn()\n"),
            "other.swift": ufile_main(c, f"fileprivate func helper() {{ {c['E']('other.helper')} }}\nfunc otherFn() {{ {B('otherFn')}; helper() }}\n")}
UT("U03_fileprivate_dup", mk, gated=("callerFn", "otherFn"), mains="")

# U04 overload by label
def mk(c):
    return {"main.swift": ufile_main(c, f"func f(a: Int) {{ {c['E']('f(a:)')} }}\nfunc f(b: Int) {{ {c['P']('f(b:)')} }}\n"
            f"func callerFn() {{ {B('callerFn')}; f(b: 1) }}\nfunc labelAFn() {{ {B('labelAFn')}; f(a: 1) }}\ncallerFn(); labelAFn()\n")}
UT("U04_overload_label", mk, gated=("callerFn", "labelAFn"))

# U05 overload by parameter type
def mk(c):
    return {"main.swift": ufile_main(c, f"func f(_ x: Int) {{ {c['E']('f(Int)')} }}\nfunc f(_ x: String) {{ {c['P']('f(String)')} }}\n"
            f"func callerFn() {{ {B('callerFn')}; f(\"s\") }}\nfunc intArgFn() {{ {B('intArgFn')}; f(1) }}\ncallerFn(); intArgFn()\n")}
UT("U05_overload_type", mk, gated=("callerFn", "intArgFn"))

# U06 static vs instance same name
def mk(c):
    return {"main.swift": ufile_main(c, f"struct S {{ static func m() {{ {c['E']('S.m static')} }}\n  func m() {{ {c['P']('S.m inst')} }} }}\n"
            f"func callerFn() {{ {B('callerFn')}; S().m() }}\nfunc staticFn() {{ {B('staticFn')}; S.m() }}\ncallerFn(); staticFn()\n")}
UT("U06_static_vs_instance", mk, gated=("callerFn", "staticFn"))

# U07 R1397: extension Array computed property / method / static, and extension on a local struct (control)
def mk(c):
    return {"main.swift": ufile_main(c,
        f"extension Array {{ var probe: Int {{ {c['E']('Array.probe')}; return 1 }}\n  func mprobe() {{ {c['E']('Array.mprobe')} }}\n"
        f"  static var sprobe: Int {{ {c['E']('Array.sprobe')}; return 1 }}\n  subscript(probe i: Int) -> Int {{ {c['E']('Array.sub')}; return i }} }}\n"
        f"extension Dictionary {{ var dprobe: Int {{ {c['E']('Dict.dprobe')}; return 1 }} }}\n"
        f"extension String {{ var strprobe: Int {{ {c['E']('String.strprobe')}; return 1 }} }}\n"
        f"extension Int {{ var iprobe: Int {{ {c['E']('Int.iprobe')}; return 1 }} }}\n"
        f"func propFn(_ a: [Int]) -> Int {{ {B('propFn')}; return a.probe }}\n"
        f"func methFn(_ a: [Int]) {{ {B('methFn')}; a.mprobe() }}\n"
        f"func statFn() -> Int {{ {B('statFn')}; return [Int].sprobe }}\n"
        f"func subFn(_ a: [Int]) -> Int {{ {B('subFn')}; return a[probe: 0] }}\n"
        f"func dictFn(_ d: [String: Int]) -> Int {{ {B('dictFn')}; return d.dprobe }}\n"
        f"func strFn(_ s: String) -> Int {{ {B('strFn')}; return s.strprobe }}\n"
        f"func intFn(_ i: Int) -> Int {{ {B('intFn')}; return i.iprobe }}\n"
        f"func litFn() -> Int {{ {B('litFn')}; return [1, 2].probe }}\n"
        f"_ = propFn([1]); methFn([1]); _ = statFn(); _ = subFn([1]); _ = dictFn([:]); _ = strFn(\"s\"); _ = intFn(1); _ = litFn()\n")}
UT("U07_stdlib_extension_members", mk, gated=("propFn", "methFn", "statFn", "subFn", "dictFn", "strFn", "intFn", "litFn"), mains="")

# U08 same type name in two modules
def mk(c):
    return {
        "Package.swift": ('// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "u08", targets: [\n'
                          '  .target(name: "M1", path: "Sources/M1"), .target(name: "M2", path: "Sources/M2"),\n'
                          '  .executableTarget(name: "App", dependencies: ["M1", "M2"], path: "Sources/App")])\n'),
        "Sources/M1/a.swift": f"import Foundation\npublic struct T {{ public init() {{}}\n  public func m() {{ {c['E']('M1.T.m')} }} }}\n",
        "Sources/M2/a.swift": f"import Foundation\npublic struct T {{ public init() {{}}\n  public func m() {{ {c['P']('M2.T.m')} }} }}\n",
        "Sources/App/main.swift": (f"import Foundation\nimport M1\nimport M2\nfunc callerFn() {{ {B('callerFn')}; M2.T().m() }}\n"
                                   f"func m1Fn() {{ {B('m1Fn')}; M1.T().m() }}\ncallerFn(); m1Fn()\n")}
UT("U08_same_type_two_modules", mk, gated=("callerFn", "m1Fn"), pkg="multi3b")

# U09 R943: constrained extensions with the same member
def mk(c):
    return {"main.swift": ufile_main(c, f"struct G<X> {{ }}\nextension G where X == Int {{ func m() {{ {c['E']('G<Int>.m')} }} }}\n"
            f"extension G where X == String {{ func m() {{ {c['P']('G<String>.m')} }} }}\n"
            f"func callerFn() {{ {B('callerFn')}; G<String>().m() }}\nfunc intGFn() {{ {B('intGFn')}; G<Int>().m() }}\ncallerFn(); intGFn()\n")}
UT("U09_constrained_ext_same_member", mk, gated=("callerFn", "intGFn"))

# U10 nested local function shadowing a top-level one
def mk(c):
    return {"main.swift": ufile_main(c, f"func h() {{ {c['E']('top.h')} }}\nfunc callerFn() {{ {B('callerFn')}; func h() {{ {c['P']('local.h')} }}; h() }}\n"
            f"func topHFn() {{ {B('topHFn')}; h() }}\ncallerFn(); topHFn()\n")}
UT("U10_local_fn_shadow", mk, gated=("callerFn", "topHFn"))

# U11 generic overload vs concrete
def mk(c):
    return {"main.swift": ufile_main(c, f"func g<X>(_ t: X) {{ {c['P']('g<X>')} }}\nfunc g(_ t: Int) {{ {c['E']('g(Int)')} }}\n"
            f"func callerFn() {{ {B('callerFn')}; g(\"s\") }}\nfunc intOverFn() {{ {B('intOverFn')}; g(1) }}\ncallerFn(); intOverFn()\n")}
UT("U11_generic_vs_concrete_overload", mk, gated=("callerFn", "intOverFn"))

# U12 protocol-extension non-requirement vs conformer's own same-named member (static dispatch on existential)
def mk(c):
    return {"main.swift": ufile_main(c, f"protocol P {{ }}\nextension P {{ func n() {{ {c['E']('P.ext.n')} }} }}\n"
            f"struct S: P {{ func n() {{ {c['P']('S.n')} }} }}\n"
            f"func callerFn() {{ {B('callerFn')}; S().n() }}\nfunc existFn() {{ {B('existFn')}; let p: any P = S(); p.n() }}\ncallerFn(); existFn()\n")}
UT("U12_ext_nonreq_vs_conformer", mk, gated=("callerFn", "existFn"))

# U13 same-named method on two unrelated types, receiver typed by an unannotated local from a function return
def mk(c):
    return {"main.swift": ufile_main(c, f"struct A {{ func go() {{ {c['P']('A.go')} }} }}\nstruct Bz {{ func go() {{ {c['E']('Bz.go')} }} }}\n"
            f"func makeB() -> Bz {{ Bz() }}\nfunc makeA() -> A {{ A() }}\n"
            f"func callerFn() {{ {B('callerFn')}; let x = makeB(); x.go() }}\nfunc aRetFn() {{ {B('aRetFn')}; let y = makeA(); y.go() }}\ncallerFn(); aRetFn()\n")}
UT("U13_untyped_local_from_return", mk, gated=("callerFn", "aRetFn"))

# U14 private extension member in another file with the same name as a method on another type
def mk(c):
    return {"main.swift": ufile_main(c, f"struct S {{ }}\nfunc callerFn() {{ {B('callerFn')}; S().zap() }}\ncallerFn(); otherFn()\n"),
            "a.swift": ufile_main(c, f"extension S {{ func zap() {{ {c['E']('S.zap')} }} }}\n"),
            "b.swift": ufile_main(c, f"struct R {{ func zap() {{ {c['P']('R.zap')} }} }}\nfunc otherFn() {{ {B('otherFn')}; R().zap() }}\n")}
UT("U14_ext_other_file", mk, gated=("callerFn", "otherFn"), mains="")

# U15 class method overridden in an extension-declared subclass, called through a protocol default (unit merges)
def mk(c):
    return {"main.swift": ufile_main(c, f"class Base {{ func m() {{ {c['P']('Base.m')} }} }}\nclass Sub: Base {{ }}\n"
            f"extension Sub {{ override func m() {{ {c['E']('Sub.m(ext)')} }} }}\n"
            f"func callerFn() {{ {B('callerFn')}; let b: Base = Sub(); b.m() }}\ncallerFn()\n")}
UT("U15_override_in_extension", mk)


# ---------------------------------------------------------------------------------------------
def gen_cell(cid, celldir, name, t, place, mult, eff):
    """returns cell meta dict and writes files."""
    cd = str(celldir)
    E = lambda b: effect_stmt(eff, b, cd)
    P = pure_stmt
    c = {}
    grp = t["group"]
    if grp == "D":
        if mult == "M1": impls = [("Eimp", True)]; passT = "Eimp"
        elif mult == "M2": impls = [("Eimp", True), ("Qimp", False)]; passT = "Eimp"
        elif mult == "M3": impls = [("Eimp", True), ("Qimp", False)]; passT = "Qimp"
        elif mult == "M0": impls = [("Qimp", False), ("Rimp", False)]; passT = "Qimp"
    else:
        if mult == "M1": impls = [("Eimp", True)]; passT = "Eimp"
        elif mult == "MD": impls = [("Qimp", False), ("Eimp", True)]; passT = "Qimp"   # decoy
    abs_code = t["abs"](c)
    impl_code = "\n".join(t["impl"](c, n, E(n) if e else P(n)) for n, e in impls)
    ds_code = t["ds"](c) if t["ds"] else ""
    cl_code = f"public func callerFn() {{ {B('callerFn')}; {t['call'](c, passT)} }}"
    gated = ["callerFn"] + (["dispFn"] if t["ds"] else [])
    mains = "callerFn()"
    if grp == "D" and mult == "M3":
        cl_code += f"\npublic func crossFn() {{ {B('crossFn')}; {t['call'](c, 'Eimp')} }}"
        gated.append("crossFn"); mains += "; crossFn()"
    if grp == "H" and mult == "MD":
        # decoy: a second caller that uses the effectful type, so the effectful body is live code
        cl_code += f"\npublic func liveFn() {{ {B('liveFn')}; {t['call'](c, 'Eimp')} }}"
        gated.append("liveFn"); mains += "; liveFn()"
    hdr = "import Foundation\n"
    files = {}
    # site-side = abstraction + dispatch site; impl-side = implementors
    if place == "L1":
        files["main.swift"] = hdr + "\n".join([abs_code, impl_code, ds_code, cl_code, mains]) + "\n"
        layout = "single"
    elif place == "L2":
        files["main.swift"] = hdr + "\n".join([abs_code, ds_code, cl_code, mains]) + "\n"
        files["impl.swift"] = hdr + impl_code + "\n"
        layout = "single"
    else:
        a_side = place.endswith("a")   # a: abs+ds in Lib; impl+cl in App.  b: abs+impl in Lib; ds+cl in App
        lib = hdr + "\n".join([abs_code] + ([ds_code] if a_side else [impl_code])) + "\n"
        app = hdr + "import Lib\n" + "\n".join(([impl_code] if a_side else [ds_code]) + [cl_code, mains]) + "\n"
        if grp == "H" and not t["ds"] and "infix operator" in abs_code and not a_side:
            pass
        layout = "pkg" if place.startswith("L3") else "chain"
        if layout == "pkg":
            files["Package.swift"] = ('// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "Cell", targets: [\n'
                                      '  .target(name: "Lib", path: "Sources/Lib"),\n'
                                      '  .executableTarget(name: "App", dependencies: ["Lib"], path: "Sources/App")])\n')
            files["Sources/Lib/lib.swift"] = lib
            files["Sources/App/main.swift"] = app
        else:
            files["Lib/Package.swift"] = ('// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "Lib", products: [.library(name: "Lib", targets: ["Lib"])],\n'
                                          '  targets: [.target(name: "Lib", path: "Sources/Lib")])\n')
            files["Lib/Sources/Lib/lib.swift"] = lib
            files["App/Package.swift"] = ('// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "App", dependencies: [.package(path: "../Lib")],\n'
                                          '  targets: [.executableTarget(name: "App", dependencies: [.product(name: "Lib", package: "Lib")], path: "Sources/App")])\n')
            files["App/Sources/App/main.swift"] = app
        # gated fns that live in Lib
        if a_side and t["ds"]:
            gated_where = {"dispFn": "lib"}
        else:
            gated_where = {}
    for rel, txt in files.items():
        p = celldir / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(txt)
    meta = dict(id=cid, name=name, group=grp, place=place, mult=mult, eff=eff, layout=layout, gated=gated,
                gated_where=locals().get("gated_where", {}))
    return meta

def gen_unit(cid, celldir, name, u, eff):
    cd = str(celldir)
    c = {"E": lambda b: effect_stmt(eff, b, cd), "P": pure_stmt}
    files = u["files"](c)
    for rel, txt in files.items():
        if rel.endswith("main.swift") and u["mains"]:
            pass
        p = celldir / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(txt)
    layout = ("chain" if u["pkg"] == "chainU" else "pkgN") if u["pkg"] else "single"
    return dict(id=cid, name=name, group="U", place="-", mult="-", eff=eff, layout=layout, gated=list(u["gated"]),
                gated_where={}, pkg=u["pkg"])

def main():
    if OUT.exists(): shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    cells = []
    n = 0
    def nid():
        nonlocal n; n += 1; return f"c{n:04d}"
    for name, t in T.items():
        mults = ["M1", "M2", "M3", "M0"] if t["group"] == "D" else ["M1", "MD"]
        for place in t["places"]:
            for mult in mults:
                effs = ["Fs"]
                # effect axis: Net/Exec on a fixed subset (effect is a classifier axis, orthogonal to target resolution)
                if mult == "M1" and place in ("L1", "L4a", "L4b") and name in ("D01_class_virtual", "D02_proto_existential", "D06_proto_property_req",
                                                                              "H01_interp_description", "H06_eq_declared", "S02_struct_method"):
                    effs += ["Net", "Exec"]
                for eff in effs:
                    cid = nid(); cd = OUT / cid
                    cells.append(gen_cell(cid, cd, name, t, place, mult, eff))
    for name, u in U.items():
        for eff in ["Fs"]:
            cid = nid(); cd = OUT / cid
            cells.append(gen_unit(cid, cd, name, u, eff))
    json.dump(cells, open(OUT / "cells.json", "w"), indent=1)
    print(len(cells), "cells")

if __name__ == "__main__":
    main()
