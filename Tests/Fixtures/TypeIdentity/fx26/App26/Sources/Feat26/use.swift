import Foundation
import Core26
import Dep26

// (a) inherited nested types, shared leaf
public final class Sub26: Mid26 {
    public func a_grand(_ p: String) { let c = Cfg26(); c.wipeCfg26(p) }               // WRITES: Base26.Cfg26 (grandparent), not top-level Cfg26
    public func a_grand_inline(_ p: String) { Cfg26().wipeCfg26(p) }                    // WRITES
    public func a_grand_mirror(_ p: String) -> Int { Tap26().tap26(p) }                 // pure: Base26.Tap26, not the loud top-level Tap26
    public func a_nearer(_ p: String) -> Int { let n = Near26(); return n.near26(p) }   // pure: Mid26.Near26 shadows Base26's and the top level
}
// the same lookups from an EXTENSION of the subclass in this file
extension Sub26 {
    public func a_ext(_ p: String) { Cfg26().wipeCfg26(p) }                              // WRITES
    public func a_ext_mirror(_ p: String) -> Int { Tap26().tap26(p) }                   // pure
}
// a type nested in a type that inherits: the nested type's OWN supertype answers before the outer type's members
public struct Outer26 { public init() {}
    public struct Cfg26 { public init() {}
        public func wipeCfg26(_ p: String) -> Int { p.count } }                          // PURE, nested in the OUTER type
    public final class In26: Base26 {
        public func a_in(_ p: String) { Cfg26().wipeCfg26(p) } }                         // WRITES: In26 inherits Base26.Cfg26 before Outer26.Cfg26
}
// a FIELD spelled bare inside a subclass (declaration scope, lane L3's binder): the inherited type
public final class SubF26: Base26 {
    var c = Cfg26()
    var t: Tap26 = Tap26()
    public func f_field(_ p: String) { c.wipeCfg26(p) }                                  // WRITES
    public func f_field_mirror(_ p: String) -> Int { t.tap26(p) }                        // pure
}
// (b) member aliases
public final class SubA26: AliasBase26 {
    public func b_super_alias(_ p: String) { Res26().res26(p) }                         // WRITES: AliasBase26.Res26 = LoudRes26
}
public struct ConfA26: Prov26 { public init() {}
    public func b_proto_alias(_ p: String) -> Int { Hand26().res26(p) }                  // pure: Prov26's Hand26 = QuietRes26, not the loud top-level
}
public struct OwnA26 { public init() {}
    public typealias Res26 = LoudRes26
    public typealias Hand26 = QuietRes26
    public func b_own_alias(_ p: String) { let r: Res26 = Res26(); r.res26(p) }          // WRITES: OwnA26.Res26 = LoudRes26
    public func b_own_alias_mirror(_ p: String) -> Int { let h: Hand26 = Hand26(); return h.res26(p) }   // pure
}
// (c) a dependency superclass nests a name Core26 (imported) declares top-level: Swift binds the inherited member type
public final class SubD26: DBase26 {
    public func d_dep_nested(_ p: String) { Gear26().spin26(p) }                         // WRITES: DBase26.Gear26
    public func d_dep_nested_mirror(_ p: String) -> Int { Calm26().hush26(p) }           // pure: DBase26.Calm26
    public func live(_ p: String) { depLive26(p) }
}
// (d) a nested class with NO init of its own, inheriting a loud init, beside a top-level same-leaf type
public final class SubI26 { public init() {} }                                           // top-level, pure init
public struct OuterI26 { public init() {}
    public final class SubI26: LoudInit26 {}                                             // inherits LoudInit26.init
    public final class LoneI26: LoudInit26 {}
    public func i_twin(_ p: String) { let s = SubI26(); _ = s; _ = p }                   // WRITES (marker file)
    public func i_lone(_ p: String) { let l = LoneI26(); _ = l; _ = p }                  // WRITES
}
// (e) a protocol-extension member reached through a NESTED type (shared leaf with top-level Body26): field and local
public struct Tbl26 { public init() {}
    public struct Body26: Mk26 { public init() {} }
    var body = Body26()
    public func e_field(_ p: String) { body.mark26(p) }                                  // WRITES: Mk26.mark26 (Tbl26.Body26 declares none)
    public func e_local(_ p: String) { let b = Body26(); b.mark26(p) }                   // WRITES
    public func e_field_prop(_ p: String) -> Int { body.markProp26 }                      // WRITES (marker): Mk26.markProp26
    public func e_local_prop(_ p: String) -> Int { let b = Body26(); return b.markProp26 } // WRITES (marker)
}
public struct Plain26 { public init() {}
    public func e_top(_ p: String) -> Int { Body26().mark26(p) }                         // pure: the top-level Body26's own mark26
    public func e_top_prop(_ p: String) -> Int { Body26().markProp26 } }                  // pure (marker)
// (f) two declarations share the SIMPLE name of a nested type whose field is spelled bare (`Pair26.src: Src26` in ProdA26 and in
// ProdB26, the swift-nio `NewSequence.source` shape): the shared simple key must not take one declaration's binding
public struct ProdA26 {
    public struct Src26 { public init() {}
        public func put26(_ p: String) -> Int { p.count } }                                               // PURE
    public struct Pair26 { public init() {}; public var src = Src26() }
    public static func make() -> Pair26 { Pair26() } }
public struct UseP26 { public init() {}
    public func p_shared(_ p: String) { let q = ProdB26.make(); _ = q.src.put26(p) } }                     // WRITES (ProdB26's)
// (g) a case payload bound from a pattern matched against `self`, where another enum shares the CASE NAME (the swift-certificates
// `CertificateStore.Backing.custom` shape, exposed when the wrong-type edge that covered it at the callers went)
public struct LoudStore26 { public init() {}
    public mutating func put26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public enum Back26 {
    case custom(LoudStore26)
    case none
    public mutating func g_switch_self(_ p: String) { switch self { case .custom(var s): s.put26(p); self = .custom(s); case .none: break } }   // WRITES
    public func g_if_case_self(_ p: String) { if case .custom(var s) = self { s.put26(p) } }                                             // WRITES
}
public enum OtherBack26 { case custom(Int); case none }
public struct Alg26 { public init() {}
    public func alg26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }                // LOUD, top-level
public struct Info26 { public init() {}; public var alg = Alg26() }
public struct UseH26 { public init() {}
    public func h_top_owner(_ p: String) { Info26().alg.alg26(p) } }                                                 // WRITES (top-level Alg26)
