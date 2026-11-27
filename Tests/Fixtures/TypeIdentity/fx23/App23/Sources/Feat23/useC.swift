import Foundation
import Core23
// a use file importing an OWN module that declares Lib23 (pure wipe23): the field is still DepA's
public struct UC23 { public init() {}
    public func field_lib(_ p: String) { H23().lib.wipe23(p) }                                          // WRITES (DepA.Lib23)
    public func bare_lib(_ p: String) -> Int { Lib23().wipe23(p) }                                      // pure (Core23.Lib23)
}
