import Foundation
import DepB
import DepAX
// imports DepB (twins) AND DepAX (extensions of DepA's types): the extension members must still be found
public struct UX24 { public init() {}
    public func ext_pipe(_ p: String) { H24().pipe.extWipe24(p) }                          // WRITES (DepAX)
    public func ext_quiet(_ p: String) -> Int { H24().pipe.extQuiet24(p) }                 // pure
    public func ext_lib(_ p: String) { H24().lib.extLib24(p) }                             // WRITES (DepAX)
    public func field_lib(_ p: String) { H24().lib.wipe24(p) }                              // WRITES
    public func field_kit(_ p: String) -> Int { H24().kit.tap24(p) } }                     // pure
