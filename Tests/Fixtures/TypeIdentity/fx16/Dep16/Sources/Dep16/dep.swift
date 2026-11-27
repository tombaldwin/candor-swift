import Foundation
// The DEPENDENCY's types. A sibling target of the consumer (Core16, not imported by Feat16) declares LIB16 pure and KIT16 loud
// under the same names; the consumer also nests a pure `Box16`. Swift binds every spelling in Feat16 to THESE.
public final class Lib16 { public init() {}
    public func wipe16(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }          // LOUD
public final class Kit16 { public init() {}
    public func tap16(_ p: String) -> Int { p.count } }                                                    // PURE (mirror)
public final class Box16 { public init() {}
    public func seal16(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }          // LOUD
public func depLive16(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
