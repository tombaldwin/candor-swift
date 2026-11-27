import Foundation
// an OWN module declaring twins of DepA's names with the opposite loudness
public final class Lib24 { public init() {}
    public func wipe24(_ p: String) -> Int { p.count } }                                                       // PURE
public final class Kit24 { public init() {}
    public func tap24(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 } }   // LOUD
