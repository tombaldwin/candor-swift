import Foundation
import Core24
// imports an OWN module the declaring file does not, which declares same-named twins
public struct UC24 { public init() {}
    public func field_lib(_ p: String) { H24().lib.wipe24(p) }                              // WRITES (DepA.Lib24; Core24's is pure)
    public func field_kit(_ p: String) -> Int { H24().kit.tap24(p) }                       // pure (DepA.Kit24; Core24's writes)
    public func global_lib(_ p: String) { gLib24.wipe24(p) }                               // WRITES
    public func global_kit(_ p: String) -> Int { gKit24.tap24(p) }                         // pure
    public func ret_lib(_ p: String) { mkLib24().wipe24(p) }                               // WRITES
    public func ret_kit(_ p: String) -> Int { mkKit24().tap24(p) }                         // pure
    public func param_lib(_ h: H24, _ p: String) { h.lib.wipe24(p) }                       // WRITES
    public func param_kit(_ h: H24, _ p: String) -> Int { h.kit.tap24(p) }                 // pure
    public func closure_lib(_ p: String) { withLib24 { $0.wipe24(p) } }                    // WRITES
    public func closure_kit(_ p: String) -> Int { withKit24 { $0.tap24(p) } }              // pure
    public func bare_lib(_ p: String) -> Int { Lib24().wipe24(p) }                         // pure (Core24.Lib24)
    public func bare_kit(_ p: String) -> Int { Kit24().tap24(p) } }                        // WRITES (Core24.Kit24)
