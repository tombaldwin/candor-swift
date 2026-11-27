import Foundation
// top-level twins, VISIBLE in Feat26 (it imports Core26), of names a dependency superclass nests
public struct Gear26 { public init() {}
    public func spin26(_ p: String) -> Int { p.count } }                                                   // PURE
public struct Calm26 { public init() {}
    public func hush26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }        // LOUD
// a loud superclass init (inherited by nested classes with no init of their own)
open class LoudInit26 { public init() { FileManager.default.createFile(atPath: NSTemporaryDirectory() + "/fx26-loudinit", contents: nil) } }
