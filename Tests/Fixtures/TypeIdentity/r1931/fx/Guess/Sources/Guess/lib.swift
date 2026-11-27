import Foundation
// the DEPENDENCY's Lib: its wipeLib WRITES (App's own Lib.wipeLib is pure)
public final class Lib { public init() {}
    public func wipeLib(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public func depWrite(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
