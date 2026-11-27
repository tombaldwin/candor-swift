import Foundation
// the dependency's types: `Lib22` WRITES (the scan's sibling Core22 declares a PURE `Lib22`); `Kit22` is PURE (Core22's is LOUD)
public final class Lib22 { public init() {}
    public func wipe22(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class Kit22 { public init() {}
    public func tap22(_ p: String) -> Int { p.count } }
public final class Pipe22 { public init() {}
    public func ownWipe22(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public func depWrite22(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
