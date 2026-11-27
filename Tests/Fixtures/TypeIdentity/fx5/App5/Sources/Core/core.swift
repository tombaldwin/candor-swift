import Foundation
// Sibling target that Feature does NOT import.
public final class CoreOnlyLib { public init() {}
    public func wipeLib(_ p: String) -> Int { p.count } }                     // PURE; Guess.Lib.wipeLib WRITES
public final class CoreOnlyKit { public init() {}
    public func tapKit(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 } }   // LOUD; Guess.Kit.tapKit is pure
