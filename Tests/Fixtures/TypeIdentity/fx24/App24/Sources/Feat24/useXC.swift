import Foundation
import Core24
import DepB
import DepAX
// the declaring file is in Core24 (another own module); this file imports DepB (twins) and DepAX (extensions)
public struct UXC24 { public init() {}
    public func tool(_ p: String) { HC24().tool.run24(p) }                                  // WRITES (DepA.Tool24)
    public func gear(_ p: String) -> Int { HC24().gear.spin24(p) }                         // pure (DepA.Gear24; DepB's writes)
    public func ext_pipe(_ p: String) { HC24().pipe.extWipe24(p) }                         // WRITES (DepAX)
    public func ext_quiet(_ p: String) -> Int { HC24().pipe.extQuiet24(p) } }              // pure
