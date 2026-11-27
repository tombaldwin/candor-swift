import Foundation
// a DEPENDENCY superclass that nests types
open class DBase10 { public init() {}
    public struct DCfg10 { public init() {}
        public func wipeD10(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // LOUD
    public struct DCalm10 { public init() {}
        public func calmD10(_ p: String) -> Int { p.count } } }                                            // pure twin, unique name
public func depWrite10(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
