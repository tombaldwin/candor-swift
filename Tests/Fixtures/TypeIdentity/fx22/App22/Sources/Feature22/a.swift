import Base22
// the declarations: every type below is spelled HERE, where `Lib22`/`Kit22`/`Pipe22` are Base22's
public final class H22 { public init() {}
    public var lib = Lib22()
    public var kit = Kit22()
    public var pipe = Pipe22()
    public func a_live(_ p: String) { depWrite22(p) } }
public func mkLib22() -> Lib22 { Lib22() }
let gLib22 = Lib22()
let gKit22: Kit22 = Kit22()
public func withLib22(_ f: (Lib22) -> Void) { f(Lib22()) }
public struct O22 { public init() {}
    public struct Lib22 { public init() {}; public func wipe22(_ p: String) -> Int { p.count } }   // NESTED: Swift binds bare Lib22 here
    public var f = Lib22()
    public func o_nested(_ p: String) -> Int { f.wipe22(p) } }                                  // pure (O22.Lib22)
