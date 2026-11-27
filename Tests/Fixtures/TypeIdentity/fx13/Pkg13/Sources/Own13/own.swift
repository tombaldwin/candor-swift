import Foundation
// (A) a nested `Data` declared in a MODULE-QUALIFIED extension of the enclosing type, in another file (ext.swift). Swift sees Outer13.Data here.
public struct Outer13 { public init() {}
    public func a_pure(_ p: String) { let d = Data(); d.write(to: p) }          // Outer13.Data.write: pure
    public func a_loud(_ p: String) { let d = Data(); d.wipe13(p) }            // Outer13.Data.wipe13: WRITES
    public func a_inline(_ p: String) { Data().wipe13(p) }                      // WRITES
}
// (B) control: the same shape, the extension spelled UNQUALIFIED (ext.swift)
public struct Outer13b { public init() {}
    public func b_pure(_ p: String) { let d = Data(); d.write(to: p) }          // Outer13b.Data.write: pure
    public func b_loud(_ p: String) { let d = Data(); d.wipe13(p) }            // WRITES
}
// (C) a member alias contributed by a PROTOCOL EXTENSION of a scan protocol
public protocol P13 {}
extension P13 { public typealias Data = Quiet13 }
public struct C13: P13 { public init() {}
    public func c_alias(_ p: String) { let d = Data(); d.write(to: p) } }        // Quiet13.write: pure
public struct Quiet13 { public init() {}; public func write(to p: String) {} }
// (D) the module-wide nested-alias fallback on a platform name the scan does NOT declare as a type: a nested alias `S13.URL`
public struct S13 { public typealias URL = QuietURL13 }
public struct QuietURL13 { public init(fileURLWithPath p: String) {}; public func checkResourceIsReachable() throws -> Bool { true } }
public struct Q13 { public init() {}
    public func q_url(_ p: String) -> Bool { let u = URL(fileURLWithPath: p); return (try? u.checkResourceIsReachable()) == nil } }  // Foundation.URL: a stat, throws on a missing path
// Foundation control
public struct Plain13 { public init() {}
    public func p_data(_ p: String) throws { let d = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) } }  // WRITES
// (E) a superclass spelled MODULE-QUALIFIED whose nested `Data` the subclass inherits (Swift sees Base13.Data from Sub13)
open class Base13 { public init() {}
    public struct Data { public init() {}
        public func write(to p: String) {}
        public func wipe13(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } } }
public final class Sub13: Own13.Base13 {
    public func s_pure(_ p: String) { let d = Data(); d.write(to: p) }          // Base13.Data.write: pure
    public func s_loud(_ p: String) { Data().wipe13(p) }                        // WRITES
}
