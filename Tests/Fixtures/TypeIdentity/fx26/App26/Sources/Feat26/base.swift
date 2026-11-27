import Foundation
// (a) shared leaves: a superclass nests a type whose simple name a TOP-LEVEL type of the same module also has
open class Base26 { public init() {}
    public struct Cfg26 { public init() {}
        public func wipeCfg26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // LOUD, nested
    public struct Tap26 { public init() {}
        public func tap26(_ p: String) -> Int { p.count } }                                                  // PURE, nested
    public struct Near26 { public init() {}
        public func near26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } } }     // LOUD, shadowed by Mid26's
open class Mid26: Base26 {
    public struct Near26 { public init() {}
        public func near26(_ p: String) -> Int { p.count } } }                                               // PURE, nearer than Base26's
public struct Cfg26 { public init() {}
    public func wipeCfg26(_ p: String) -> Int { p.count } }                                                  // PURE top-level twin
public struct Tap26 { public init() {}
    public func tap26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }           // LOUD top-level twin
public struct Near26 { public init() {}
    public func near26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }          // LOUD top-level twin
// (b) member aliases contributed by a superclass and by a protocol extension, beside a same-named top-level type
public struct LoudRes26 { public init() {}
    public func res26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public struct QuietRes26 { public init() {}
    public func res26(_ p: String) -> Int { p.count } }
open class AliasBase26 { public init() {}
    public typealias Res26 = LoudRes26 }
public struct Res26 { public init() {}
    public func res26(_ p: String) -> Int { p.count } }                                                      // PURE top-level twin
public protocol Prov26 {}
extension Prov26 { public typealias Hand26 = QuietRes26 }
public struct Hand26 { public init() {}
    public func res26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }           // LOUD top-level twin
// (c) a protocol-extension member reached through a NESTED type whose leaf a top-level type shares
public protocol Mk26 {}
extension Mk26 { public func mark26(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
    public var markProp26: Int { FileManager.default.createFile(atPath: NSTemporaryDirectory() + "/fx26-markprop", contents: nil); return 1 } }
public struct Body26 { public init() {}
    public func mark26(_ p: String) -> Int { p.count }                                                       // PURE top-level twin
    public var markProp26: Int { 0 } }
// (f) ProdB26 lives in ANOTHER FILE than ProdA26 (use.swift), as swift-nio's two producers do
public struct ProdB26 {
    public struct Src26 { public init() {}
        public func put26(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 0 } }   // LOUD
    public struct Pair26 { public init() {}; public var src = Src26() }
    public static func make() -> Pair26 { Pair26() } }
// (h) an OWNER simple name two declarations share, only ONE of which nests its field's type (swift-crypto `ASN1.SubjectPublicKeyInfo`
// beside CryptoExtras' top-level `SubjectPublicKeyInfo`): the nested one's binding must not retype the top-level one's field
public enum NsH26 {
    public struct Alg26 { public init() {}
        public func alg26(_ p: String) -> Int { p.count } }                                                       // PURE, nested
    public struct Info26 { public init() {}; public var alg = Alg26() } }
