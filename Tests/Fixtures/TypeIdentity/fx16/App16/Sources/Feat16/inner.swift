import Foundation
import Dep16
// SOUNDNESS R1950 — bare N inside a type that NESTS N is that innermost nested type, not the package-wide simple key.
public struct Store16 { public init() {}
    public func put16(_ p: String) -> Int { p.count } }                                         // TOP-LEVEL, PURE
public struct Outer16a { public init() {}
    public struct Store16 { public init() {}
        public func put16(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // NESTED, LOUD
    public func r_inner_loud(_ p: String) { let s = Store16(); s.put16(p) }                     // WRITES (Outer16a.Store16)
    public func r_inner_inline(_ p: String) { Store16().put16(p) }                              // WRITES
}
public struct Pipe16 { public init() {}
    public func flow16(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // TOP-LEVEL, LOUD
public struct Outer16b { public init() {}
    public struct Pipe16 { public init() {}
        public func flow16(_ p: String) -> Int { p.count } }                                    // NESTED, PURE
    public func r_inner_pure(_ p: String) -> Int { let q = Pipe16(); return q.flow16(p) }        // pure (Outer16b.Pipe16)
    public func r_top_loud(_ p: String) { let q = Pipe16(); _ = q.flow16(p); _ = p }             // pure too: still Outer16b.Pipe16
}
public struct Plain16 { public init() {}
    public func r_plain_top(_ p: String) { Pipe16().flow16(p) } }                                // WRITES: top-level Pipe16
public struct Outer16c { public init() {}
    public struct Knob16 { public init() {}
        public func turn16(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }  // OUTER, LOUD
    public struct Mid16 { public init() {}
        public struct Knob16 { public init() {}
            public func turn16(_ p: String) -> Int { p.count } }                                // INNER, PURE
        public func r_mid_pure(_ p: String) -> Int { Knob16().turn16(p) } }                     // pure: Outer16c.Mid16.Knob16
    public func r_outer_loud(_ p: String) { Knob16().turn16(p) }                                // WRITES: Outer16c.Knob16
}
// SOUNDNESS R1947 — a QUALIFIED spelling names the module's type even inside a type nesting the same name.
public struct Outer16d { public init() {}
    public struct Data { public init() {}
        public mutating func append(contentsOf p: [UInt8]) {                                    // LOUD under Foundation's pure name
            FileManager.default.createFile(atPath: String(decoding: p, as: UTF8.self), contents: nil) } }
    public func q_found_pure(_ p: String) -> Int { var d = Foundation.Data(); d.append(contentsOf: Array(p.utf8)); return d.count }   // pure
    public func q_nested_loud(_ p: String) { var d = Data(); d.append(contentsOf: Array(p.utf8)) }                                    // WRITES
    public func q_found_write(_ p: String) throws { try Foundation.Data("x".utf8).write(to: URL(fileURLWithPath: p)) }               // WRITES
}
public struct Outer16e { public init() {}
    public struct Lib16 { public init() {}
        public func wipe16(_ p: String) -> Int { p.count } }                                    // nested PURE twin of Dep16.Lib16
    public func q_dep(_ p: String) { Dep16.Lib16().wipe16(p) }                                  // WRITES: Dep16's
    public func q_nested_pure(_ p: String) -> Int { Lib16().wipe16(p) }                         // pure: Outer16e.Lib16
}
// R1950's rewrite must not bind a nested type the file cannot see (Ext16 extends `Outer16f` from a module Feat16 does not import).
public struct Tank16 { public init() {}
    public func fill16(_ p: String) -> Int { p.count } }                                        // TOP-LEVEL, PURE
public struct Outer16f { public init() {}
    public func r_unseen_nested(_ p: String) -> Int { Tank16().fill16(p) } }                    // pure: Feat16.Tank16
