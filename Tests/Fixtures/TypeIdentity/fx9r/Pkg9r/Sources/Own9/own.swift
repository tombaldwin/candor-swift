import Foundation
// REFUSAL cells: here Swift's own scope DOES see a nested `Data`, so the scan type is the right binding and the effect is its.
public struct Outer9 { public init() {}
    public struct Data { public init() {}
        public func write(to url: Any) {} }                                                  // pure
    public func r_nested(_ p: String) { let d = Data(); d.write(to: p) }                      // Outer9.Data: pure
    public func r_nested_ann(_ p: String) { let d: Data = Data(); d.write(to: p) }            // Outer9.Data: pure
    public func r_qualified(_ p: String) throws { let d = Foundation.Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) }   // Foundation.Data: WRITES
}
open class Base9 { public init() {}
    public struct Data { public init() {}
        public func write(to url: Any) {} } }                                                 // pure, nested in the SUPERCLASS
public final class Sub9: Base9 {
    public func r_super(_ p: String) { let d = Data(); d.write(to: p) }                       // inherited member type: Base9.Data (pure)
}
// the same shape where the platform IS meant: a type in this module that does NOT nest a Data
public struct Plain9 { public init() {}
    public func p_data(_ p: String) throws { let d = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) } }   // WRITES (Foundation.Data): Swift sees no nested `Data` from here, though Outer9 and Base9 nest one in this module
