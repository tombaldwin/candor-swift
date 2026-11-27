import Foundation
// the DEPENDENCY's Lib: its wipeLib WRITES (App's own Lib.wipeLib is pure)
public final class Lib { public init() {}
    public func wipeLib(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public func depWrite(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
public final class Vault { public init() {}
    public func chain() -> Vault { self }
    public func wipeVault(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
// fx4 additions (identity design): a PURE dependency `Kit` whose name a sibling scan target declares LOUD (mirror)
public final class Kit { public init() {}
    public func tapKit(_ p: String) -> Int { p.count } }
