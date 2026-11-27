import Foundation
import DepB
// imports a DEPENDENCY the declaring file does not, which declares same-named twins
public struct UB24 { public init() {}
    public func field_lib(_ p: String) { H24().lib.wipe24(p) }                              // WRITES (DepA.Lib24)
    public func field_kit(_ p: String) -> Int { H24().kit.tap24(p) }                       // pure (DepA.Kit24; DepB's writes)
    public func global_lib(_ p: String) { gLib24.wipe24(p) }                               // WRITES
    public func global_kit(_ p: String) -> Int { gKit24.tap24(p) }                         // pure
    public func ret_lib(_ p: String) { mkLib24().wipe24(p) }                               // WRITES
    public func ret_kit(_ p: String) -> Int { mkKit24().tap24(p) }                         // pure
    public func local_lib(_ p: String) { let l = H24().lib; l.wipe24(p) }                  // WRITES
    public func local_kit(_ p: String) -> Int { let k = H24().kit; return k.tap24(p) }     // pure
    public func param_lib(_ h: H24, _ p: String) { h.lib.wipe24(p) }                       // WRITES
    public func param_kit(_ h: H24, _ p: String) -> Int { h.kit.tap24(p) }                 // pure
    public func closure_lib(_ p: String) { withLib24 { $0.wipe24(p) } }                    // WRITES (T4)
    public func closure_kit(_ p: String) -> Int { withKit24 { $0.tap24(p) } }              // pure (T4)
    public func ext_lib(_ p: String) { H24().lib.extLib24(p) }                             // WRITES (DepAX's extension; useX imports it)
    public func bare_lib(_ p: String) -> Int { Lib24().wipe24(p) }                         // pure (DepB.Lib24)
    public func bare_kit(_ p: String) -> Int { Kit24().tap24(p) } }                        // WRITES (DepB.Kit24)
