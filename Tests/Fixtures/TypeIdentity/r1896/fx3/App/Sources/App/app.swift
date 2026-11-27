import Foundation
import Guess
public final class OwnStore { public init() {}
    public func wipeOwn(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class OwnPure { public init() {}
    public func calmOwn(_ p: String) -> Int { p.count } }
public enum Outer { public final class Inner { public init() {}
    public func wipeNest(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } } }
public enum Kind { case Node(Int)
    public func wipeKind(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class Teller { public init() {}
    public func settleUp(_ p: String) -> Int { p.count } }
public struct Msg {
    public var tc = Guess.Teller()
    public var mkr = Guess.Maker()
    public var fDep = Guess.DepStore()
    public let lDep = Guess.DepStore()
    public var pDep = Guess.DepPure()
    public var fOwn = App.OwnStore()
    public var pOwn = App.OwnPure()
    public var nest = Outer.Inner()
    public var viaInit = Guess.DepStore.init()
    public var gen = Guess.DepGen<Int>()
    public var opt: Guess.DepStore? = Guess.DepStore()
    public var comp: Guess.DepStore { Guess.DepStore() }
    public var fac = Guess.makeStore()
    public var kd = Kind.Node(1)
    public var dk = Guess.DepKind.Node(1)
    public var mk = Guess.DepNS.Make()
    public var iuoOwn: OwnStore!
    public var iuoPure: OwnPure!
    public init() { iuoOwn = OwnStore(); iuoPure = OwnPure() }
    public func s_iuo(_ p: String) { iuoOwn.wipeOwn(p) }
    public func s_iuo_self(_ p: String) { self.iuoOwn.wipeOwn(p) }
    public func s_iuo_pure(_ p: String) -> Int { iuoPure.calmOwn(p) }
    public func s_b1(_ p: String) { tc.settleUp(p) }
    public func s_b2(_ p: String) { mkr.wipeDep(p) }
    public func s_dkind(_ p: String) { dk.wipeKindDep(p) }
    public func s_mk(_ p: String) { mk.wipeDep(p) }
    public func s_bare(_ p: String) { fDep.wipeDep(p) }
    public func s_self(_ p: String) { self.fDep.wipeDep(p) }
    public func s_let(_ p: String) { lDep.wipeDep(p) }
    public func s_pure(_ p: String) -> Int { pDep.calmDep(p) }
    public func s_own(_ p: String) { fOwn.wipeOwn(p) }
    public func s_ownpure(_ p: String) -> Int { pOwn.calmOwn(p) }
    public func s_nest(_ p: String) { nest.wipeNest(p) }
    public func s_init(_ p: String) { viaInit.wipeDep(p) }
    public func s_gen(_ p: String) { gen.wipeGen(p) }
    public func s_opt(_ p: String) { opt?.wipeDep(p) }
    public func s_comp(_ p: String) { comp.wipeDep(p) }
    public func s_fac(_ p: String) { fac.wipeDep(p) }
    public func s_kind(_ p: String) { kd.wipeKind(p) }
    public func s_shadow_local(_ p: String) -> Int { let fDep = Guess.DepPure(); return fDep.calmDep(p) }
    public func s_shadow_param(_ fDep: Guess.DepPure, _ p: String) -> Int { fDep.calmDep(p) }
    public func s_closure(_ p: String) { [1].forEach { _ in fDep.wipeDep(p) } }
}
extension Msg { public func s_ext(_ p: String) { fDep.wipeDep(p) } }
open class Base { public var inh = Guess.DepStore(); public init() {} }
public final class Derived: Base { public func s_inherit(_ p: String) { inh.wipeDep(p) } }
public final class DerivedDep: Guess.DepBase { public func s_inheritdep(_ p: String) { inhDep.wipeDep(p) } }
public struct GenOwner<T> { var g = Guess.DepStore(); public init() {}
    public func s_genowner(_ p: String) { g.wipeDep(p) } }
open class OBase { public var oi = OwnStore(); public var ai: Guess.DepStore = Guess.DepStore(); public var qi = App.OwnStore(); public init() {} }
public final class ODerived: OBase {
    public func s_oinh(_ p: String) { oi.wipeOwn(p) }
    public func s_ainh(_ p: String) { ai.wipeDep(p) }
    public func s_qinh(_ p: String) { qi.wipeOwn(p) }
    public func s_qinh_self(_ p: String) { self.qi.wipeOwn(p) } }
