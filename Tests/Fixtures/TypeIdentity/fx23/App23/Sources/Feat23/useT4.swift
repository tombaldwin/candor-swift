import Foundation
import DepA
// T4 closure params typed from the callee signature in decl.swift (overloaded / generic / shadowed)
public struct UT23 { public init() {}
    public func t4_overload_lib(_ p: String) { with23 { l in l.wipe23(p) } }                            // WRITES (resolves to the Lib23 overload)
    public func t4_overload_kit(_ p: String) { with23 { k in _ = k.tap23(p) } }                          // pure (the Kit23 overload)
    public func t4_generic(_ p: String) { gen23(Lib23()) { $0.wipe23(p) } }                             // WRITES
    public func t4_shadow(_ p: String) -> Int { with23 { (l: Lib23) in let l = Kit23(); _ = l.tap23(p) }; return 0 }   // pure: the param is shadowed by a Kit23 local
}
