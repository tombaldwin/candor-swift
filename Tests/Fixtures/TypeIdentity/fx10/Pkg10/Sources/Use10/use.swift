import Foundation
import Base10
import Guess10

// (a) superclass in ANOTHER own module
public final class SubOther: OBase10 {
    public func inh_other_module(_ p: String) { let c = Cfg10(); c.wipeCfg10(p) }          // WRITES: inherited member type OBase10.Cfg10
    public func inh_other_pure(_ p: String) -> Int { let c = Calm10(); return c.calm10(p) } // pure twin
}
// (b) superclass in a DEPENDENCY: the nested type is the dependency's, never a scan type
public final class SubDep: DBase10 {
    public func inh_dependency(_ p: String) { let c = DCfg10(); c.wipeD10(p) }             // WRITES: DBase10.DCfg10
    public func inh_dep_pure(_ p: String) -> Int { let c = DCalm10(); return c.calmD10(p) } // pure twin
}
// (c) generic superclass
open class GBase10<T> { public init() {}
    public struct GCfg10 { public init() {}
        public func wipeG10(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // LOUD
    public struct GCalm10 { public init() {}
        public func calmG10(_ p: String) -> Int { p.count } } }
public final class SubGen: GBase10<Int> {
    public func inh_generic(_ p: String) { let c = GCfg10(); c.wipeG10(p) }                // WRITES
    public func inh_generic_pure(_ p: String) -> Int { let c = GCalm10(); return c.calmG10(p) }
}
// (d) a member typealias reached through protocol CONFORMANCE
public struct LoudHandle10 { public init() {}
    public func wipeHandle10(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public struct CalmHandle10 { public init() {}
    public func calmHandle10(_ p: String) -> Int { p.count } }
public protocol Provides10 {}
extension Provides10 { public typealias Handle10 = LoudHandle10; public typealias Calm10Alias = CalmHandle10 }
public struct Conf10: Provides10 { public init() {}
    public func alias_conformance(_ p: String) { let h = Handle10(); h.wipeHandle10(p) }           // WRITES
    public func alias_conformance_pure(_ p: String) -> Int { let h = Calm10Alias(); return h.calmHandle10(p) } }
public struct OtherHolder10 { public init() {}
    public struct Handle10 { public init() {}                                                      // a DECOY nested `Handle10`, pure
        public func wipeHandle10(_ p: String) -> Int { p.count } } }
// (e) an ASSOCIATEDTYPE named like a scan type (S14): Swift binds it to the witness, the scan declares a LOUD top-level Item10
public struct Item10 { public init() {}
    public func hushItem10(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public struct QuietItem10 { public init() {}
    public func hushItem10(_ p: String) -> Int { p.count } }
public protocol Maker10 { associatedtype Item10; func make() -> Item10 }
public struct M10: Maker10 { public init() {}
    public typealias Item10 = QuietItem10
    public func make() -> Item10 { QuietItem10() }
    public func assoc_witness(_ p: String) -> Int { let i: Item10 = make(); return i.hushItem10(p) }   // PURE (QuietItem10), pinned by the sidecar edge
}
// (S13) a nested type declared in an EXTENSION of a foreign type
extension Data {
    public struct Chunk10 { public init() {}
        public func wipeChunk10(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // LOUD
    public struct CalmChunk10 { public init() {}
        public func calmChunk10(_ p: String) -> Int { p.count } }
}
public struct Ext10 { public init() {}
    public func s13_ext_nested(_ p: String) { let c = Data.Chunk10(); c.wipeChunk10(p) }                       // WRITES
    public func s13_ext_pure(_ p: String) -> Int { let c = Data.CalmChunk10(); return c.calmChunk10(p) }
    public func live(_ p: String) { depWrite10(p) } }
