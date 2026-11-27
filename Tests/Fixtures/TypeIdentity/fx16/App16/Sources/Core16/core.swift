import Foundation
// A sibling target Feat16 does NOT import: its `Lib16` is PURE (B1 direction: the scan's twin is pure, the dependency's loud) and
// its `Kit16` is LOUD (the mirror: the scan's twin is loud, the dependency's pure).
public final class Lib16 { public init() {}
    public func wipe16(_ p: String) -> Int { p.count } }
public final class Kit16 { public init() {}
    public func tap16(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 } }
