import Foundation
// A DEPENDENCY superclass nesting types whose simple names the consumer's own module Core26 ALSO declares top-level.
open class DBase26 { public init() {}
    public struct Gear26 { public init() {}
        public func spin26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // LOUD (Core26's Gear26 is pure)
    public struct Calm26 { public init() {}
        public func hush26(_ p: String) -> Int { p.count } } }                                            // PURE (Core26's Calm26 is loud)
public func depLive26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
// a dependency type whose COMPUTED property writes (read through a consumer's field)
public struct DepStat26 { public init() {}
    public var code26: Int { FileManager.default.createFile(atPath: NSTemporaryDirectory() + "/fx26-depprop", contents: nil); return 1 } }
