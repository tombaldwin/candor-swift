import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1904 / R1905 — a `$n` PROJECTED-VALUE receiver calls what the wrapper's `projectedValue` IS. Every cell below was
/// EXECUTED first (the fixture compiles with swiftc and each function either creates the marker file or does not), and the
/// scan is read both standalone and chained to a REAL producer report (the join is live: the chained arm charges `Fs`).
///   R1904 — `T.$n.m()`, `self.$n.m()`, `x.$n.m()` and a bare `$n.m()` over a scan wrapper whose `projectedValue` is declared
///           type `P`: a typed call on `P` (a dependency's body charges, a scan type's body charges, a PURE twin does not).
///           A wrapper the scan cannot read, or whose `projectedValue` has no usable declared type, is HEDGED at the call site.
///   R1905 — the declaring type is found by its FULL path, a local/parameter wrapper shadows a module `@TaskLocal`, and a member
///           inherited from a dependency class is not a module-scope name: none of those may drop the C12 hedge.
final class ProjectedValueWrapperProcessTests: XCTestCase {

    private static let dep = #"""
import Foundation
public final class Box {
    public init() {}
    public func withValue<R>(_ v: Int, operation: () -> R) -> R { FileManager.default.createFile(atPath: "/tmp/candor-r1904-never-run", contents: nil); return operation() }
}
public final class PureBox {
    public init() {}
    public func withValue<R>(_ v: Int, operation: () -> R) -> R { operation() }
}
@propertyWrapper public struct DepWrap<V> { public var wrappedValue: V; public init(wrappedValue: V) { self.wrappedValue = wrappedValue }
    public var projectedValue: Box { Box() } }
public enum Ctx {
    @DepWrap public static var current: Int = 0
}
extension PureBox { public func go3() {} }
public final class XBox { public init() {}
    public func withValue<R>(_ v: Int, operation: () -> R) -> R { FileManager.default.createFile(atPath: "/tmp/candor-r1904-never-run", contents: nil); return operation() } }
// a dependency that publishes the leaves `go` / `go2` (the C12 hedge needs a dependency that could answer the name)
public final class Other { public init() {}; public func go() {}; public func go2() {} }
open class DepBase { public init() {}
    @DepWrap public var z: Int = 0 }
"""#

    private static let app = #"""
import Foundation
import Guess
@propertyWrapper public struct MirBox { public var wrappedValue: Int; public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
    public var projectedValue: Box { Box() } }
@propertyWrapper public struct MirPure { public var wrappedValue: Int; public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
    public var projectedValue: PureBox { PureBox() } }
public final class LocalBox { public init() {}
    public func run(_ p: Int) -> Int { FileManager.default.createFile(atPath: "/tmp/candor-r1904-never-run", contents: nil); return p } }
@propertyWrapper public struct MirLocal { public var wrappedValue: Int; public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
    public var projectedValue: LocalBox { LocalBox() } }
@propertyWrapper public struct MirGen<V> { public var wrappedValue: V; public init(wrappedValue: V) { self.wrappedValue = wrappedValue }
    public var projectedValue: V { wrappedValue } }
@TaskLocal public var loc: Int = 0
public enum Own { @TaskLocal public static var current: Int = 0
    public static func inOwn(_ p: Int) -> Int { $current.withValue(p) { 1 } } }
public enum Ctx2 {
    @MirBox public static var other: Int = 0
    @MirPure public static var pure: Int = 0
    @MirLocal public static var lb: Int = 0
    @DepWrap public static var dw: Int = 0
    public static func d_bare(_ p: Int) -> Int { $other.withValue(p) { 1 } }
    public static func f_self(_ p: Int) -> Int { Self.$other.withValue(p) { 1 } }
    public static func d_bare_pure(_ p: Int) -> Int { $pure.withValue(p) { 1 } }
    public static func d_bare_local(_ p: Int) -> Int { $lb.run(p) }
}
public struct Holder { @MirBox public var x: Int = 0; @MirPure public var y: Int = 0
    public func e_inst(_ p: Int) -> Int { $x.withValue(p) { 1 } }
    public func e_self(_ p: Int) -> Int { self.$x.withValue(p) { 1 } } }
public func a_typed(_ p: Int) -> Int { Ctx2.$other.withValue(p) { 1 } }
public func b_pure(_ p: Int) -> Int { Ctx2.$pure.withValue(p) { 1 } }
public func c_local(_ p: Int) -> Int { Ctx2.$lb.run(p) }
public func e_obj(_ h: Holder, _ p: Int) -> Int { h.$x.withValue(p) { 1 } }
public func e_obj_pure(_ h: Holder, _ p: Int) -> Int { h.$y.withValue(p) { 1 } }
public func g_depwrap(_ p: Int) -> Int { Ctx2.$dw.withValue(p) { 1 } }
public func h_tl(_ p: Int) -> Int { Own.$current.withValue(p) { 1 } }
public func h_tl_global(_ p: Int) -> Int { $loc.withValue(p) { 1 } }
public enum Q { public enum Own { @MirBox public static var current: Int = 0
    public static func inQOwn(_ p: Int) -> Int { $current.withValue(p) { 1 } } } }
public func i_nested(_ p: Int) -> Int { Q.Own.$current.withValue(p) { 1 } }
public func i_modq(_ p: Int) -> Int { Guess.Ctx.$current.withValue(p) { 1 } }
public func j_local(_ p: Int) -> Int { @MirBox var loc = 0; return $loc.withValue(p) { 1 } }
public func j_param(@MirBox _ loc: Int, _ p: Int) -> Int { $loc.withValue(p) { 1 } }
public enum Gen { @MirGen public static var gg: Box = Box()
    public static func k_gen(_ p: Int) -> Int { $gg.withValue(p) { 1 } } }
public func k_gen_q(_ p: Int) -> Int { Gen.$gg.withValue(p) { 1 } }
@TaskLocal public var z: Int = 0
public final class Sub: DepBase { public func l_inherit(_ p: Int) -> Int { $z.withValue(p) { 1 } } }   // `$z` is the dependency's wrapper, not the module TaskLocal
public func m_opt(_ h: Holder?, _ p: Int) -> Int { h?.$x.withValue(p) { 1 } ?? 0 }

@propertyWrapper public struct MirXBox { public var wrappedValue: Int; public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
    public var projectedValue: XBox { XBox() } }
@propertyWrapper public struct MirFM { public var wrappedValue: Int; public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
    public var projectedValue: FileManager { .default } }
extension FileManager { public func go() { createFile(atPath: "/tmp/candor-r1904-never-run", contents: nil) } }
extension XBox { public func go2() { FileManager.default.createFile(atPath: "/tmp/candor-r1904-never-run", contents: nil) } }
public enum Ctx7 {
    @MirFM static var fm2: Int = 0
    @MirXBox static var bx: Int = 0
    @MirPure static var px: Int = 0
    static func b_fm_scanext(_ p: Int) -> Int { $fm2.go(); return p }
    static func b_depbox_scanext(_ p: Int) -> Int { $bx.go2(); return p }
    static func b_fromext_withValue(_ p: Int) -> Int { $bx.withValue(p) { 1 } }
    static func b_pure_ext(_ p: Int) -> Int { $px.go3(); return p }
}
public func ctrl_fm_go() { FileManager.default.go() }
"""#

    private struct Fixture { let root: URL; let bin: URL
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") } }

    private func make() throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1904-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("Guess/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Guess", products: [.library(name: "Guess", targets: ["Guess"])], targets: [.target(name: "Guess")])
        """)
        try write("Guess/Sources/Guess/lib.swift", Self.dep)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../Guess")],
            targets: [.target(name: "App", dependencies: [.product(name: "Guess", package: "Guess")])])
        """)
        try write("app/Sources/App/app.swift", Self.app)
        let fx = Fixture(root: root, bin: bin)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("Guess").path, "--out", fx.depDir.appendingPathComponent("rGuess").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        for extra in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path)
            where !(extra.hasSuffix(".Swift.json") && !extra.contains("callgraph") && !extra.contains("hierarchy")) {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(extra))
        }
        return fx
    }

    private struct Row { var effects: Set<String>; var why: Set<String>; var invisible: Set<String> }

    private func rows(_ fx: Fixture, chained: Bool, env extra: [String: String] = [:]) throws -> [String: Row] {
        var env = extra
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let tag = "o-\(UUID().uuidString)"
        let r = try ProcessHarness.run(fx.bin, [fx.appDir.path, "--out", fx.root.appendingPathComponent(tag).path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: fx.root.appendingPathComponent("\(tag).App.Swift.json"))) as? [String: Any]
        var out: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            out[(f["fn"] as? String) ?? "?"] = Row(effects: Set((f["inferred"] as? [String]) ?? []),
                                                    why: Set((f["unknownWhy"] as? [String]) ?? []),
                                                    invisible: Set((f["invisible"] as? [String]) ?? []))
        }
        return out
    }

    private let tok = "dispatch:<untyped>.withValue"

    func testAProjectedValueIsTypedThroughItsWrapperOrHedged() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        // EXECUTED: these create the marker file (the dependency's / the scan's `Fs` body runs)
        let runs = ["a_typed", "Ctx2.d_bare", "Ctx2.f_self", "Holder.e_inst", "Holder.e_self", "e_obj", "m_opt", "i_nested",
                    "Q.Own.inQOwn", "c_local", "Ctx2.d_bare_local"]
        // EXECUTED: the pure twins — a different type's `withValue`, which writes nothing
        let pure = ["b_pure", "Ctx2.d_bare_pure", "e_obj_pure"]
        // EXECUTED effect, receiver NOT identified: hedged at the call site (R1905's cells and R1904's unreadable wrappers)
        let hedged = ["g_depwrap", "i_modq", "j_local", "j_param", "Sub.l_inherit", "k_gen_q", "Gen.k_gen"]
        // EXECUTED pure: the platform's TaskLocal (this scan's declaration, found by full path)
        let platform = ["h_tl", "h_tl_global", "Own.inOwn"]
        // EXECUTED EFFECT over a type the scan only EXTENDS (`extension FileManager`, `extension Box`): the typed call cannot land
        // (the §2 join reads neither the scan's extension bodies nor the platform table), so the hedge must stay — standalone and chained
        let extended = ["Ctx7.b_fm_scanext", "Ctx7.b_depbox_scanext", "Ctx7.b_fromext_withValue"]
        let scanLocal: Set<String> = ["c_local", "Ctx2.d_bare_local"]
        for chained in [true, false] {
            let r = try rows(fx, chained: chained)
            for c in runs {
                if chained || scanLocal.contains(c) {
                    XCTAssertTrue(r[c]?.effects.contains("Fs") ?? false, "chained=\(chained) \(c): the projected value's body writes a file — rows: \(r)")
                } else {
                    XCTAssertFalse(r[c]?.invisible.isEmpty ?? true, "standalone \(c): a typed call into a dependency this scan cannot read is disclosed `invisible` — rows: \(r)")
                }
            }
            for c in pure {
                XCTAssertFalse(r[c]?.effects.contains("Fs") ?? false, "chained=\(chained) \(c): pure twin must not be charged")
            }
            // chained, main reads absent on the first two (the dependency report publishes no body for `go`/`go2`): held at "not lower"
            for c in extended where !chained || c == "Ctx7.b_fromext_withValue" {
                XCTAssertFalse(r[c]?.why.isEmpty ?? true, "chained=\(chained) \(c): over a type the scan extends — rows: \(r)")
            }
            XCTAssertFalse(r["Ctx7.b_pure_ext"]?.effects.contains("Fs") ?? false, "chained=\(chained) pure twin over an extended type must not be charged")
            for c in hedged {
                XCTAssertTrue(r[c]?.why.contains(tok) ?? false, "chained=\(chained) \(c): receiver not identified — rows: \(r)")
            }
            for c in platform {
                XCTAssertFalse(r[c]?.why.contains(tok) ?? false, "chained=\(chained) \(c): the platform's TaskLocal")
                XCTAssertFalse(r[c]?.effects.contains("Fs") ?? false, "chained=\(chained) \(c): the platform's TaskLocal")
            }
        }
    }
}
