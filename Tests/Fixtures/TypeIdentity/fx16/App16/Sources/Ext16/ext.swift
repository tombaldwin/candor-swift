import Foundation
import Feat16
// A LOUD type nested in an extension of Feat16's `Outer16f`, declared in a module Feat16 does not import: inside Feat16's own
// `Outer16f`, bare `Tank16` is still Feat16's top-level (pure) `Tank16`.
extension Outer16f {
    public struct Tank16 { public init() {}
        public func fill16(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } } }
public func extTouch16(_ p: String) { Outer16f.Tank16().fill16(p) }
// `Feat16.N` names an OWN module's type: never "as if undeclared"
public struct Ext16Use { public init() {}
    public func q_own_loud(_ p: String) { Feat16.Pipe16().flow16(p) } }                          // WRITES: Feat16.Pipe16
