import Foundation
// ---- init inheritance (Swift: designated inits are inherited only when the subclass declares NO designated init) ----
open class Base27 {
    public init(path: String) { FileManager.default.createFile(atPath: path, contents: nil) }     // LOUD designated
    public init(name: String) { _ = name }                                                           // PURE designated, same arity
}
public final class NoInit27: Base27 {}                                                               // inherits both
public final class ConvOnly27: Base27 { public convenience init(x: Int) { self.init(name: "x") } } // a convenience init only: designated inits still inherited
public final class Desig27: Base27 { public init(label: String) { super.init(name: label) } }        // own designated init: nothing inherited
public struct I27 { public init() {}
    public func noinit_path(_ p: String) { _ = NoInit27(path: p) }                                   // WRITES (inherited loud init)
    public func noinit_name(_ p: String) { _ = NoInit27(name: p) }                                   // pure (inherited pure init, same arity as the loud one)
    public func conv_path(_ p: String) { _ = ConvOnly27(path: p) }                                   // WRITES (designated inits inherited past a convenience init)
    public func conv_x(_ p: String) { _ = ConvOnly27(x: 1) }                                         // pure
    public func desig(_ p: String) { _ = Desig27(label: p) }                                         // pure (super.init(name:))
}
// ---- member overrides and super calls ----
open class OBase27 { public init() {}
    open func go27(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }         // LOUD
    open func quiet27(_ p: String) {} }                                                              // PURE
public final class OSub27: OBase27 {
    public override func go27(_ p: String) {}                                                        // PURE override
    public override func quiet27(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }   // LOUD override
    public func via_super(_ p: String) { super.go27(p) } }                                           // WRITES (OBase27.go27)
public struct O27 { public init() {}
    public func sub_go(_ p: String) { OSub27().go27(p) }                                             // pure (the override)
    public func sub_quiet(_ p: String) { OSub27().quiet27(p) }                                       // WRITES
    public func base_go(_ p: String) { OBase27().go27(p) }                                           // WRITES
    public func upcast_go(_ p: String) { let b: OBase27 = OSub27(); b.go27(p) }                      // pure (dynamic dispatch to the override)
}
// ---- protocol-extension default vs class member ----
public protocol P27 { func run27(_ p: String) }
extension P27 { public func run27(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // LOUD default
public final class C27: P27 { public init() {}; public func run27(_ p: String) {} }                 // the class's own member wins
public final class D27: P27 { public init() {} }                                                     // takes the default
public struct Q27 { public init() {}
    public func class_wins(_ p: String) { C27().run27(p) }                                           // pure
    public func default_runs(_ p: String) { D27().run27(p) }                                         // WRITES
    public func existential(_ p: String) { let e: P27 = C27(); e.run27(p) } }                        // WRITES (existential call goes to the protocol requirement → C27.run27... see truth)
// ---- generic superclass nesting a type whose leaf a top-level type shares ----
open class GBase27<T> { public init() {}
    public struct Node27 { public init() {}
        public func fire27(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } } }   // LOUD, nested in a GENERIC superclass
public struct Node27 { public init() {}
    public func fire27(_ p: String) -> Int { p.count } }                                            // PURE top-level twin
public final class GSub27: GBase27<Int> {
    public func gen_nested(_ p: String) { Node27().fire27(p) } }                                     // WRITES (GBase27.Node27 through the generic superclass)
public struct Plain27 { public init() {}
    public func top(_ p: String) -> Int { Node27().fire27(p) } }                                    // pure (top-level Node27)
