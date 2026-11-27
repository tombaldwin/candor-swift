import Foundation
import DepB
// a use file whose OWN imports differ from the declaring file's: DepB (not imported by decl.swift) declares a same-named Lib23/Kit23.
// The field is STILL DepA's (declared in decl.swift); bare spellings here are DepB's.
public struct UB23 { public init() {}
    public func field_lib(_ p: String) { H23().lib.wipe23(p) }                                          // WRITES (DepA.Lib23)
    public func field_kit(_ p: String) -> Int { H23().kit.tap23(p) }                                   // pure (DepA.Kit23; DepB's tap23 writes)
    public func bare_lib(_ p: String) -> Int { Lib23().wipe23(p) }                                      // pure (DepB.Lib23)
    public func bare_kit(_ p: String) -> Int { Kit23().tap23(p) }                                       // WRITES (DepB.Kit23)
    public func ret_lib(_ p: String) { mk23().wipe23(p) }                                               // WRITES (DepA.Lib23 via factory)
}
