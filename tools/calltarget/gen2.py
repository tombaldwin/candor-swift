#!/usr/bin/env python3
"""Second matrix batch: axes the register rows showed missing from batch 1 (refined stdlib protocols,
explicit ~=, wrong-witness overloads, constrained protocol-extension operators, super into a dependency,
class-property/ subscript reads across the chain, protocol-extension default with no override)."""
import sys, json, pathlib, shutil
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gen
from gen import B, ALLP, BP, AP
gen.T.clear(); gen.U.clear()
tpl = gen.tpl; H = gen.H

# R1312 / R1310: a LOCAL protocol refining CustomStringConvertible, read as a property / interpolated
tpl("D22_refined_csc_property", places=ALLP,
    abs=lambda c: "public protocol Conv: CustomStringConvertible { }",
    impl=lambda c, t, s: f"public struct {t}: Conv {{ public init() {{}}\n  public var description: String {{ {s}; return \"d\" }} }}",
    ds=lambda c: f"public func dispFn(_ p: any Conv) -> String {{ {B('dispFn')}; return p.description }}",
    call=lambda c, t: f"_ = dispFn({t}())")
tpl("D23_refined_csc_interp", places=ALLP,
    abs=lambda c: "public protocol Conv: CustomStringConvertible { }",
    impl=lambda c, t, s: f"public struct {t}: Conv {{ public init() {{}}\n  public var description: String {{ {s}; return \"d\" }} }}",
    ds=lambda c: f"public func dispFn(_ p: any Conv) -> String {{ {B('dispFn')}; return \"\\(p)\" }}",
    call=lambda c, t: f"_ = dispFn({t}())")
# protocol default with NO conformer override, conformer effect lives in another requirement it calls
tpl("D24_default_only_requirement", places=ALLP,
    abs=lambda c: "public protocol P { func m(); func k() }\nextension P { public func m() { k() } }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func k() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ p: any P) {{ {B('dispFn')}; p.m() }}",
    call=lambda c, t: f"dispFn({t}())")
# super call from a consumer subclass into the base; base is PURE, the override in Lib's other subclass is effectful (R1381)
tpl("D25_class_subscript_override", places=ALLP,
    abs=lambda c: "open class Base { public init() {}\n  open subscript(i: Int) -> Int { return i } }",
    impl=lambda c, t, s: f"public final class {t}: Base {{ public override init() {{}}\n  public override subscript(i: Int) -> Int {{ {s}; return i }} }}",
    ds=lambda c: f"public func dispFn(_ b: Base) -> Int {{ {B('dispFn')}; return b[0] }}",
    call=lambda c, t: f"_ = dispFn({t}())")
tpl("D26_existential_array_elem", places=ALLP,
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ ps: [any P]) {{ {B('dispFn')}; for p in ps {{ p.m() }} }}",
    call=lambda c, t: f"dispFn([{t}()])")
tpl("D27_optional_chain_existential", places=ALLP,
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: f"public struct {t}: P {{ public init() {{}}\n  public func m() {{ {s} }} }}",
    ds=lambda c: f"public func dispFn(_ p: (any P)?) {{ {B('dispFn')}; p?.m() }}",
    call=lambda c, t: f"dispFn({t}())")
tpl("D28_class_protocol_conformer_subclass", places=ALLP,   # R867 shape: protocol conformer is a class, subclass overrides
    abs=lambda c: "public protocol P { func m() }",
    impl=lambda c, t, s: (f"open class Base{t}: P {{ public init() {{}}\n  open func m() {{ print(\"RAN:Base{t}.m\") }} }}\n"
                          f"public final class {t}: Base{t} {{ public override init() {{}}\n  public override func m() {{ {s} }} }}"),
    ds=lambda c: f"public func dispFn(_ p: any P) {{ {B('dispFn')}; p.m() }}",
    call=lambda c, t: f"dispFn({t}())")

EQO = lambda c, t, s: f"public struct {t}: Equatable {{ public init() {{}}\n  public static func == (a: {t}, b: {t}) -> Bool {{ {s}; return true }} }}"
H("H41_explicit_tilde_eq", impl=EQO, call=lambda c, t: f"_ = {t}() ~= {t}()")
H("H42_wrong_witness_overload",   # R1283: declared ==(T, T?) only; [T] == [T] runs the SYNTHESIZED == (field effect)
  impl=lambda c, t, s: (f"public struct F{t}: Equatable {{ public init() {{}}\n  public static func == (a: F{t}, b: F{t}) -> Bool {{ {s}; return true }} }}\n"
                        f"public struct {t}: Equatable {{ public let f = F{t}(); public init() {{}}\n"
                        f"  public static func == (a: {t}, b: {t}?) -> Bool {{ print(\"RAN:{t}.==opt\"); return true }} }}"),
  call=lambda c, t: f"_ = [{t}()] == [{t}()]")
H("H43_constrained_proto_ext_operator",   # R1284 c03constr
  impl=lambda c, t, s: (f"public protocol Q{t} {{ var k: Int {{ get }} }}\n"
                        f"extension Q{t} where Self: Equatable {{ public static func <~> (a: Self, b: Self) -> Bool {{ {s}; return a == b }} }}\n"
                        f"public struct {t}: Q{t}, Equatable {{ public var k = 0; public init() {{}} }}"),
  call=lambda c, t: f"_ = {t}() <~> {t}()", extra="infix operator <~>: ComparisonPrecedence")
H("H44_optional_eq",
  impl=EQO, call=lambda c, t: f"let a: {t}? = {t}(); _ = a == {t}()")
H("H45_enum_payload_synth_eq",   # non-tuple payload: control for R1282
  impl=lambda c, t, s: (f"public struct F{t}: Equatable {{ public init() {{}}\n  public static func == (a: F{t}, b: F{t}) -> Bool {{ {s}; return true }} }}\n"
                        f"public enum {t}: Equatable {{ case one(F{t}, Int) }}"),
  call=lambda c, t: f"_ = {t}.one(F{t}(), 1) == {t}.one(F{t}(), 1)")
H("H46_hashable_dict_subscript", impl=lambda c, t, s: (f"public struct {t}: Hashable {{ public init() {{}}\n  public static func == (a: {t}, b: {t}) -> Bool {{ true }}\n"
                                                    f"  public func hash(into h: inout Hasher) {{ {s}; h.combine(1) }} }}"),
  call=lambda c, t: f"var d: [{t}: Int] = [:]; d[{t}()] = 1; _ = d")
H("H47_struct_deinit_via_class_field",
  impl=lambda c, t, s: f"public final class C{t} {{ public init() {{}}\n  deinit {{ {s} }} }}\npublic struct {t} {{ let c = C{t}(); public init() {{}} }}",
  call=lambda c, t: f"do {{ let o = {t}(); _ = o }}")

# super into dependency: consumer subclass calls super.m(); base PURE; another Lib subclass effectful (over-charge probe, R1381)
U = gen.U
def mk(c):
    return {
        "Lib/Package.swift": ('// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "Lib", products: [.library(name: "Lib", targets: ["Lib"])],\n'
                              '  targets: [.target(name: "Lib", path: "Sources/Lib")])\n'),
        "Lib/Sources/Lib/lib.swift": (f"import Foundation\nopen class V {{ public init() {{}}\n  open func visit() {{ {c['P']('V.visit')} }} }}\n"
                                      f"public final class S1: V {{ public override func visit() {{ {c['E']('S1.visit')} }} }}\n"),
        "App/Package.swift": ('// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "App", dependencies: [.package(path: "../Lib")],\n'
                              '  targets: [.executableTarget(name: "App", dependencies: [.product(name: "Lib", package: "Lib")], path: "Sources/App")])\n'),
        "App/Sources/App/main.swift": (f"import Foundation\nimport Lib\nfinal class C: V {{ override func visit() {{ super.visit() }} }}\n"
                                       f"func callerFn() {{ {B('callerFn')}; C().visit() }}\nfunc liveFn() {{ {B('liveFn')}; S1().visit() }}\ncallerFn(); liveFn()\n")}
gen.UT("U16_super_into_dependency", mk, gated=("callerFn", "liveFn"), pkg="chainU")

# same-named private extension members in two files of ONE module, receiver a local struct (R1396 within a module)
def mk(c):
    return {"main.swift": f"import Foundation\nstruct T {{ }}\nfunc callerFn(_ t: T) -> Int {{ {B('callerFn')}; return t.probe }}\n_ = callerFn(T()); otherFn(T())\n"
                          f"private extension T {{ var probe: Int {{ {c['P']('main.probe')}; return 1 }} }}\n",
            "a.swift": f"import Foundation\nprivate extension T {{ func probe() {{ {c['E']('a.probe')} }} }}\nfunc otherFn(_ t: T) {{ {B('otherFn')}; t.probe() }}\n"}
gen.UT("U17_private_ext_two_files", mk, gated=("callerFn", "otherFn"))
def mk(c):  # reverse: the PROPERTY effectful, the method pure
    return {"main.swift": f"import Foundation\nstruct T {{ }}\nfunc callerFn(_ t: T) -> Int {{ {B('callerFn')}; return t.probe }}\n_ = callerFn(T()); otherFn(T())\n"
                          f"private extension T {{ var probe: Int {{ {c['E']('main.probe')}; return 1 }} }}\n",
            "a.swift": f"import Foundation\nprivate extension T {{ func probe() {{ {c['P']('a.probe')} }} }}\nfunc otherFn(_ t: T) {{ {B('otherFn')}; t.probe() }}\n"}
gen.UT("U17r_private_ext_two_files_rev", mk, gated=("callerFn", "otherFn"))
# R1396 reverse arrangement across targets with a non-stdlib receiver: B's property effectful, A's method pure (silence probe) — U01_b already; add Array receiver
def mk(c):
    return {
        "Package.swift": ('// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "u18", targets: [\n'
                          '  .target(name: "A", path: "Sources/A"),\n'
                          '  .executableTarget(name: "B", dependencies: ["A"], path: "Sources/B")])\n'),
        "Sources/A/A.swift": f"import Foundation\npublic extension Array {{ func probe() {{ {c['P']('A.probe')} }} }}\npublic func useA(_ t: [Int]) {{ {B('useA')}; t.probe() }}\n",
        "Sources/B/main.swift": (f"import Foundation\nimport A\nprivate extension Array {{ var probe: Int {{ {c['E']('B.probe')}; return 1 }} }}\n"
                                 f"func useB(_ t: [Int]) -> Int {{ {B('useB')}; return t.probe }}\n_ = useB([1]); useA([1])\n")}
gen.UT("U18_ext_member_two_targets_array_rev", mk, gated=("useA", "useB"), pkg="multi2")

if __name__ == "__main__":
    gen.OUT = pathlib.Path(sys.argv[1])
    gen.main()
