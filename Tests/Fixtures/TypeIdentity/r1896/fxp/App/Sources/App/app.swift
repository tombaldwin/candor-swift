import Foundation
import Guess
public struct GBox2<DepStore> {                       // a GENERIC PARAMETER named like the dependency type; no scan type shares the name
    public var t = Guess.DepStore()
    public init() {}
    public func c_genparam2(_ p: String) { t.wipeDep(p) }   // WRITES
}
public struct Msg4 {
    public var lg = Guess.Logger()                     // dependency type sharing a PLATFORM type's name
    public var ds = Guess.DepStore()                   // control
    public init() {}
    public func c_platname(_ p: String) { lg.emitL(p) }     // WRITES
    public func c_ctrl(_ p: String) { ds.wipeDep(p) }       // WRITES
}
