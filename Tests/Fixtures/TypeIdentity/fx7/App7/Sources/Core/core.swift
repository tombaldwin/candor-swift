import Foundation
// Core: LOUD Lib (no dependency in this fixture; Feature IMPORTS Core)
public final class Lib { public init() {}
    public func wipeLib(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
open class Base { public init() {}
    public struct Cfg { public init() {}
        public func wipeCfg(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } } }   // nested in a SUPERCLASS, loud; leaf unique
open class Base2 { public init() {}
    public struct Knob { public init() {}
        public func turnKnob(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } } } // nested in a superclass, loud; leaf SHARED with Other.Knob
public struct Other { public init() {}
    public struct Knob { public init() {}
        public func turnKnob(_ p: String) -> Int { p.count } } }                                            // pure twin sharing the leaf
