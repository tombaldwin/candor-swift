import Foundation
import DepB
// the use file imports the TWIN module only; the field is DepA's; DepB's extension of DepA.Lib25 supplies extWipe25
public struct UB25 { public init() {}
    public func ext_twin(_ p: String) { H25().lib.extWipe25(p) }                                            // WRITES (DepB's extension of DepA.Lib25)
    public func ext_twin_quiet(_ p: String) -> Int { H25().lib.extQuiet25(p) }                               // pure
    public func field(_ p: String) { H25().lib.wipe25(p) } }                                                 // WRITES (DepA.Lib25.wipe25)
