// a SECOND dependency declaring the SAME names, with the opposite loudness
import Foundation
public final class Lib23 { public init() {}
    public func wipe23(_ p: String) -> Int { p.count } }                                                // PURE
public final class Kit23 { public init() {}
    public func tap23(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 } }   // LOUD
