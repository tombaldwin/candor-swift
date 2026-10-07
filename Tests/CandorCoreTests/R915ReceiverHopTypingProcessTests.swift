import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R915 — A MEMBER HOP THE RECEIVER'S TYPE DID NOT RECORD KEPT THE OUTER BASE'S TYPE (`rootOf`'s
/// fallback), so the call was keyed `Outer.member`: a WRONG JOIN where `Outer` declares that member (a
/// fabrication) and a silent drop where it does not. Four index gaps feed that one fallback, each closed by
/// asking the declaration: (A) a NESTED TYPE path read as a value hop, (B) a MEMBER typealias collapsed by bare
/// name (RxSwift's seventy-five `typealias Parent`), (C) a field a local SUPERTYPE declares (inherited stored
/// field, protocol-extension property such as Kingfisher's `kf`), (D) a stored property initialised by a
/// SPECIALISED constructor (`Machine<Void>()`). Wherever none answers, the release's reading stands.
///
/// EXECUTED: this source, compiled with `swiftc` and run with a driver (`swiftagent-r915/fx/r915`, `fx/r915k`):
/// every `s0*`/`m01*` cell read the environment, every `f0*` cell did not, `k01shadow` read the environment
/// and did NOT run `QuietBoxK.go`, `k02generic` read the environment. v0.39.3 (2111a54) and 519f62d read
/// every defect cell 0 and every fabrication cell 1.
final class R915ReceiverHopTypingProcessTests: XCTestCase {
    static let source = #"""
import Foundation
// Effects are observable: `Loud*` read the environment (returned and printed by the driver);
// `Quiet*` do not. Every cell name is unique and no cell name is a prefix of another (§3.3).

public struct Loud { public init() {}; public func emit() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] } }
public struct Quiet { public init() {}; public func store() -> String? { nil } }

// ── S1: a stored field INHERITED from a local superclass (hop kind `unrecorded`, inherited) ──
open class Base1 { public let sink = Loud(); public let keep = Quiet(); public init() {} }
public final class Sub1: Base1 {
    public func m01self() -> String? { self.sink.emit() }      // explicit self
    public func m01bare() -> String? { sink.emit() }           // implicit self
    // F1: the guess keys `Sub1.store`, which exists and reads the env — a WRONG join (Quiet.store is called)
    public func store() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] }
    public func m01fab() -> String? { self.keep.store() }
}
public func s01inherit(_ s: Sub1) -> String? { s.sink.emit() }
public func f01inherit(_ s: Sub1) -> String? { s.keep.store() }

// ── S2: a protocol-EXTENSION property (Kingfisher's `.kf`) ──
public protocol Compat2 {}
public struct Wrap2<B> { public let base: B; public func setImage() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] } }
extension Compat2 { public var kf2: Wrap2<Self> { Wrap2(base: self) } }
public final class View2: Compat2 { public init() {} }
public func s02protoext(_ v: View2) -> String? { v.kf2.setImage() }

// ── S3/F3: a MEMBER-SCOPED typealias, collapsed by simple name (RxSwift `typealias Parent`) ──
public final class Sched3 { public init() {}; public func schedule() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] } }
public final class OpA3 { public let scheduler = Sched3(); public init() {}; public func go3() -> String? { nil } }
public final class SinkA3 {
    public typealias Parent = OpA3
    public let parent: Parent
    public init(_ p: Parent) { parent = p }
    public func s03alias() -> String? { parent.scheduler.schedule() }   // S3: silent if Parent is mis-resolved
    public func f03alias() -> String? { parent.go3() }                   // F3: wrong join to OpB3.go3
}
public final class OpB3 { public init() {}; public func go3() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] } }
public final class SinkB3 { public typealias Parent = OpB3; public let parent: Parent; public init(_ p: Parent) { parent = p } }

// ── S4/F4: a NESTED TYPE path read as a value hop (`Outer.Inner.make()`) ──
public enum Outer4 {
    public static func make() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] }   // F4's wrong target
    public enum Inner4 {
        public static func make() -> String? { nil }
        public static func load() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] }
    }
}
public func s04nested() -> String? { Outer4.Inner4.load() }
public func f04nested() -> String? { Outer4.Inner4.make() }

// ── S5: a stored property initialised by a SPECIALISED generic constructor (`Machine<Void>()`) ──
public struct Machine5<T> { public init() {}; public func fire() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] } }
public final class Holder5 {
    private var sm = Machine5<Void>()
    public init() {}
    public func s05genctor() -> String? { self.sm.fire() }
}

// ── controls (the release already answers these) ──
public final class Own6 { public let sink = Loud(); public init() {} }
public func k06own(_ o: Own6) -> String? { o.sink.emit() }

func kmark(_ p: String) { _ = FileManager.default.createFile(atPath: "/tmp/r915k_" + p, contents: nil) }
// K1: a closure parameter SHADOWS an inherited field of the same name
public struct QuietBoxK { public init() {}; public func go() -> String? { kmark("k1wrong"); return nil } }
public struct LoudK { public init() {}; public func go() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] } }
open class BaseK1 { public let mutableState = QuietBoxK(); public init() {} }
public final class SubK1: BaseK1 {
    public func k01shadow() -> String? { let f: (LoudK) -> String? = { mutableState in mutableState.go() }; return f(LoudK()) }
}
// K2: an inherited field typed by the superclass's GENERIC PARAMETER, re-specialised by the subclass
public protocol SockK2 { func open2() -> String? }
public struct RealSockK2: SockK2 { public init() {}; public func open2() -> String? { nil }; public func finish() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] } }
open class ChanK2<S: SockK2> {
    public let sock: S
    public init(_ s: S) { sock = s }
    public func finish() -> String? { ProcessInfo.processInfo.environment["R915_ENV"] }   // the release's (wrong) join target
}
public final class StreamK2: ChanK2<RealSockK2> {
    public init() { super.init(RealSockK2()) }
    public func k02generic() -> String? { self.sock.finish() }
}

// ── CALLERS of the method cells
public func callM01self() -> String? { Sub1().m01self() }
public func callS03alias() -> String? { SinkA3(OpA3()).s03alias() }
public func callS05genctor() -> String? { Holder5().s05genctor() }
"""#

    private func gate(_ root: URL, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
    }
    static let off = ["CANDOR_R915_OFF": "1"]

    /// Silences: the effect happens (executed); 0 -> 1, and the switch restores the release's 0.
    static let defects = [
        "deny Env Sub1.m01self", "deny Env Sub1.m01bare", "deny Env s01inherit", "deny Env callM01self",   // C
        "deny Env s02protoext",                                                                            // C (kf)
        "deny Env SinkA3.s03alias", "deny Env callS03alias",                                               // B
        "deny Env s04nested",                                                                              // A
        "deny Env Holder5.s05genctor", "deny Env callS05genctor",                                          // D
    ]
    /// Fabrications: the guessed join charged a member the call does not run (executed: no env read).
    static let fabrications = ["deny Env Sub1.m01fab", "deny Env f01inherit", "deny Env SinkA3.f03alias", "deny Env f04nested"]

    func testSilencesCloseAndTheSwitchRestoresTheRelease() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        for p in Self.defects {
            XCTAssertEqual(try gate(root, p), 1, "`\(p)` must fail: the effect really happens (executed)")
            XCTAssertNotEqual(try gate(root, p, env: Self.off), 1, "`\(p)` under CANDOR_R915_OFF is the release")
        }
    }

    func testWrongJoinsAreRetargetedAndTheSwitchRestoresThem() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        for p in Self.fabrications {
            XCTAssertNotEqual(try gate(root, p), 1, "`\(p)`: the called member is pure (executed)")
            XCTAssertEqual(try gate(root, p, env: Self.off), 1, "`\(p)` under CANDOR_R915_OFF keeps the release's join")
        }
    }

    /// THE FLOOR — two shapes this change's own corpus A/B caught moving the release's answer.
    func testTheReleaseAnswerStandsWhereNoDeclarationAnswers() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        // K1 (Alamofire `mutableState.write { mutableState in ... }`): the closure parameter shadows the
        // inherited field; typing it as the field fabricated `QuietBoxK.go`'s Fs (executed: it does not run).
        XCTAssertNotEqual(try gate(root, "deny Fs SubK1.k01shadow"), 1, "a shadowing closure parameter is not the field")
        XCTAssertEqual(try gate(root, "deny Unknown SubK1.k01shadow"), 1, "the release's disclosure stands")
        // K2 (swift-nio `self.socket.finishConnect()`): a generic-parameter field re-specialised by the subclass.
        // Typing it by the superclass's BOUND dropped the call (ABSENT) over an executed env read.
        XCTAssertEqual(try gate(root, "deny Env StreamK2.k02generic"), 1, "the release's answer stands (executed: Env)")
        // A control the release already answered.
        XCTAssertEqual(try gate(root, "deny Env k06own"), 1)
    }
}
