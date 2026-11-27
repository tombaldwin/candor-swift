import Foundation
import Dep16
// In THIS target `Lib16`, `Kit16` and (outside `Outer16`) `Box16` are Dep16's: Core16 is not imported.
public struct Outer16 { public init() {}
    public struct Box16 { public init() {}
        public func seal16(_ p: String) -> Int { p.count } } }                       // nested-only scan Box16, PURE
public typealias DepLib16 = Lib16                                                    // = Dep16.Lib16 (this file imports Dep16)
extension Lib16 {                                                                    // an extension of Dep16.Lib16, in the scan
    public func extWipe16(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
    public func extQuiet16(_ p: String) -> Int { p.count } }
public struct U16 { public init() {}
    public func s1_ann(_ p: String) { let x: Lib16 = Lib16(); x.wipe16(p) }                     // WRITES
    public func s1_inline(_ p: String) { Lib16().wipe16(p) }                                    // WRITES
    public func s1_as(_ p: String) { let a: Any = Lib16(); let x = a as! Lib16; x.wipe16(p) }   // WRITES
    public func s1_ext(_ p: String) { Lib16().extWipe16(p) }                                    // WRITES: the scan's extension member
    public func s1_ext_quiet(_ p: String) -> Int { Lib16().extQuiet16(p) }                      // pure twin (unique name)
    public func s2_nested(_ p: String) { let b = Box16(); b.seal16(p) }                         // WRITES: Dep16.Box16
    public func s3_qual(_ p: String) { let x = Dep16.Lib16(); x.wipe16(p) }                     // WRITES
    public func s3_qual_ann(_ p: String) { let x: Dep16.Lib16 = Dep16.Lib16(); x.wipe16(p) }    // WRITES
    public func s5_alias(_ p: String) { DepLib16().wipe16(p) }                                  // WRITES
    public func m_kit(_ p: String) -> Int { let k = Kit16(); return k.tap16(p) }                // pure (Dep16.Kit16; Core16's writes)
    public func m_kit_inline(_ p: String) -> Int { Kit16().tap16(p) }                           // pure
    public func live(_ p: String) { depLive16(p) }
}
extension Outer16 {
    public func s4_own(_ p: String) -> Int { Box16().seal16(p) }                                // pure: Outer16.Box16 (visible nested)
}
