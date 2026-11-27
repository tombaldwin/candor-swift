import Foundation
import DepA
// the DECLARING file: imports DepA only. Fields/globals/factories are DepA's types.
public final class H23 { public init() {}
    public var lib = Lib23()                                                                           // DepA.Lib23 (LOUD wipe23)
    public var kit = Kit23() }                                                                          // DepA.Kit23 (PURE tap23)
public func mk23() -> Lib23 { Lib23() }
public func with23(_ f: (Lib23) -> Void) { f(Lib23()) }                                               // T4 callee
public func with23(_ f: (Kit23) -> Void) { f(Kit23()) }                                               // OVERLOADED T4 callee (differs by closure param type)
public func gen23<T>(_ v: T, _ f: (T) -> Void) { f(v) }                                                // GENERIC T4 callee
// a scan protocol with a DEFAULT witness in a protocol extension; DepA's Enc23 conforms via a scan extension with NO own member
public protocol Enc23P { func enc23(_ p: String) }
extension Enc23P { public func enc23(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }   // LOUD default
extension Enc23: Enc23P {}
// protocol inheritance: Enc23b conforms to the REFINING protocol; the member is the parent's default
public protocol Enc23Q: Enc23P {}
extension Enc23b: Enc23Q {}
// conditional conformance of a platform generic type
extension Array: Enc23P where Element == Int {}
public struct W23 { public init() {}
    public func w_default(_ e: Enc23P, _ p: String) { e.enc23(p) }                                      // WRITES (Enc23's default witness)
    public func w_refined(_ p: String) { let e: Enc23P = Enc23b(); e.enc23(p) }                         // WRITES
    public func w_cond(_ p: String) { let e: Enc23P = [1]; e.enc23(p) }                                 // WRITES (conditional conformance)
    public func live(_ p: String) { depLive23(p) } }
public enum Enc23Box { public static func make() -> Enc23P { Enc23() } }
