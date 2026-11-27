import Foundation
// a sibling target Feature22 does NOT import
public final class Lib22 { public init() {}
    public func wipe22(_ p: String) -> Int { p.count } }                                         // PURE twin of Base22.Lib22.wipe22
public final class Kit22 { public init() {}
    public func tap22(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 } }   // LOUD; Base22's is pure
