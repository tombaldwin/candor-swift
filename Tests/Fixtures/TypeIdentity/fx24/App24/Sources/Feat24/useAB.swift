import Foundation
import DepA
import DepB
// imports BOTH the declaring module and a twin-declaring one (a superset of the declaring file's imports)
public struct UAB24 { public init() {}
    public func field_lib(_ p: String) { H24().lib.wipe24(p) }                              // WRITES
    public func field_kit(_ p: String) -> Int { H24().kit.tap24(p) }                       // pure
    public func ret_lib(_ p: String) { mkLib24().wipe24(p) } }                             // WRITES
