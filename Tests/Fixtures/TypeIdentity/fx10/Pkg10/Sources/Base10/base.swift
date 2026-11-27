import Foundation
// a superclass in ANOTHER OWN MODULE that nests types (unique leaves)
open class OBase10 { public init() {}
    public struct Cfg10 { public init() {}
        public func wipeCfg10(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // LOUD
    public struct Calm10 { public init() {}
        public func calm10(_ p: String) -> Int { p.count } } }                                                // pure twin, unique name
