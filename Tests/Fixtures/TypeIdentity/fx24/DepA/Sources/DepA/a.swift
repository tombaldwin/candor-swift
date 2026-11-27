import Foundation
// the DECLARED types: Lib24 is LOUD, Kit24 is PURE. DepB and Core24 declare twins with the opposite loudness.
public final class Lib24 { public init() {}
    public func wipe24(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class Kit24 { public init() {}
    public func tap24(_ p: String) -> Int { p.count } }
public final class Pipe24 { public init() {} }
public final class Tool24 { public init() {}
    public func run24(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }      // LOUD
public final class Gear24 { public init() {}
    public func spin24(_ p: String) -> Int { p.count } }                                                // PURE
public func depLive24(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
