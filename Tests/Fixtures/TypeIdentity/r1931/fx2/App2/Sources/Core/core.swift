// another TARGET of the same package declares a pure `Lib` -- Feature does not import Core
public final class Lib { public init() {}
    public func wipeLib(_ p: String) -> Int { p.count } }
