import Foundation
import DepA
// the DECLARING file: imports DepA only. Every binder below is DepA's type.
public final class H24 { public init() {}
    public var lib = Lib24()
    public var kit = Kit24()
    public var pipe = Pipe24()
    public func live(_ p: String) { depLive24(p) } }
public let gLib24 = Lib24()
public let gKit24: Kit24 = Kit24()
public func mkLib24() -> Lib24 { Lib24() }
public func mkKit24() -> Kit24 { Kit24() }
public func withLib24(_ f: (Lib24) -> Void) { f(Lib24()) }
public func withKit24(_ f: (Kit24) -> Int) -> Int { f(Kit24()) }
