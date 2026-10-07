import XCTest
import Foundation
import SwiftSyntax
import SwiftParser
@testable import CandorCore

/// SOUNDNESS R976 — THE STDLIB'S GENERIC SPELLING OF A SUGARED TYPE DROPPED THE CALL.
///
/// `Optional<T>` is `T?`, `Array<T>` is `[T]`, `Dictionary<K, V>` is `[K: V]`, and a `Swift.`-qualified
/// spelling of any of them (or of `Set<T>`) is the same type again. Every type helper switched on the syntax
/// NODE KIND, so the generic spelling — an `IdentifierTypeSyntax`/`MemberTypeSyntax` — was read as a type
/// named `Optional` (or `Swift.Array`, …): a WRONG type rather than a refusal, so the receiver resolved
/// against the stdlib and the call left `functions[]` with nothing said. Found by the 0.40.0 monotone check:
/// swift-nio's `ChannelHandlerContext.fireChannelRead` is `self.next?.invokeChannelRead(data)` over
/// `var next: Optional<ChannelHandlerContext>`, and the `deny Env Unknown` gate on `EventCounterHandler
/// .channelRead` went 1 -> 0 once R915 removed a wrong-owner `Unknown` that had been standing in front of it.
///
/// EXECUTED: this source with a driver calling every `s*` cell (`swiftagent-rel/census` holds the 319-cell
/// census it is drawn from, all 319 executed): every `s*` cell reads the environment. v0.39.3 and the
/// staged 0.40.0 read every `s*` cell 0 and every `k*` control 1. Cell names are unique and none is a prefix
/// of another (§3.3).
final class R976GenericSugarSpellingProcessTests: XCTestCase {
    static let source = #"""
import Foundation
public final class Ctx: Hashable {
    public init() {}
    public func invoke() { _ = ProcessInfo.processInfo.environment["R976_ENV"] }
    public static func == (a: Ctx, b: Ctx) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}
// the swift-nio shape: a linked context whose `next` is spelled `Optional<…>`
public final class Link {
    var nextA: Optional<Ctx> = Ctx()
    var nextS: Swift.Optional<Ctx> = Ctx()
    var nextK: Ctx? = Ctx()
    var listA: Array<Ctx>? = [Ctx()]
    var mapO: Dictionary<String, Optional<Ctx>> = ["k": Ctx()]
    public init() {}
    public func s01field() { self.nextA?.invoke() }
    public func s02swfield() { nextS?.invoke() }
    public func s03optarr() { if let l = listA { for c in l { c.invoke() } } }
    public func s04dictopt() { mapO["k"]??.invoke() }
    public func k01sugar() { self.nextK?.invoke() }
}
public func s05param(_ x: Optional<Ctx>) { guard let y = x else { return }; y.invoke() }
public func s06arrlocal() { let xs: Array<Ctx> = [Ctx()]; for x in xs { x.invoke() } }
public func s07swarr(_ xs: Swift.Array<Ctx>) { xs.first?.invoke() }
public func s08swdict(_ d: Swift.Dictionary<String, Ctx>) { for (_, v) in d { v.invoke() } }
public func s09swset(_ s: Swift.Set<Ctx>) { s.forEach { $0.invoke() } }
public typealias MaybeCtx = Optional<Ctx>
public func s10alias(_ x: MaybeCtx) { x?.invoke() }
public func s11closure() { let f = { (x: Optional<Ctx>) in x?.invoke() }; f(Ctx()) }
public var g12: Optional<Ctx> = Ctx()
public func s12global() { g12?.invoke() }
public func mk13() -> Optional<Ctx> { Ctx() }
public func s13ret() { let x = mk13(); x?.invoke() }
public func k02param(_ x: Ctx?) { x?.invoke() }
// a caller one hop out, the gate a user actually writes
public func s14caller() { Link().s01field() }
"""#

    private func gate(_ root: URL, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
    }
    static let off = ["CANDOR_R976_OFF": "1"]

    static let silences = [
        "deny Env Link.s01field", "deny Env Link.s02swfield", "deny Env Link.s03optarr", "deny Env Link.s04dictopt",
        "deny Env s05param", "deny Env s06arrlocal", "deny Env s07swarr", "deny Env s08swdict", "deny Env s09swset",
        "deny Env s10alias", "deny Env s11closure", "deny Env s12global", "deny Env s13ret", "deny Env s14caller",
    ]

    func testEveryGenericSpellingChargesAndTheSwitchRestoresTheRelease() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        for p in Self.silences {
            XCTAssertEqual(try gate(root, p), 1, "`\(p)` must fail: the effect really happens (executed)")
            XCTAssertNotEqual(try gate(root, p, env: Self.off), 1, "`\(p)` under CANDOR_R976_OFF is the release")
        }
    }

    /// The sugar spellings the release already answered, under either setting of the switch.
    func testTheSugarControlsAreUnchanged() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        for p in ["deny Env Link.k01sugar", "deny Env k02param"] {
            XCTAssertEqual(try gate(root, p), 1, p)
            XCTAssertEqual(try gate(root, p, env: Self.off), 1, "\(p) — the release")
        }
    }

    /// The rewrite is the OUTERMOST node only, and only for the three sugared stdlib generics: a user generic
    /// is returned unchanged, and the module strip applies only to a `Swift.` base.
    func testTheRewriteIsNarrow() {
        func ty(_ s: String) -> TypeSyntax { var p = Parser(s); return TypeSyntax.parse(from: &p) }
        func spell(_ s: String) -> String { desugaredType(ty(s)).trimmedDescription }
        XCTAssertEqual(typeName(ty("Optional<Ctx>")).name, "Ctx")
        XCTAssertEqual(typeName(ty("Swift.Optional<Ctx>")).name, "Ctx")
        XCTAssertNil(typeName(ty("Array<Ctx>")).name, "an array has no name, as `[Ctx]` has none")
        XCTAssertEqual(arrayElementName(ty("Swift.Array<Ctx>")), "Ctx")
        XCTAssertEqual(arrayElementName(ty("Swift.Set<Ctx>")), "Ctx")
        XCTAssertEqual(dictValueName(ty("Swift.Dictionary<String, Ctx>")), "Ctx")
        XCTAssertEqual(spell("Box<Ctx>"), "Box<Ctx>")
        XCTAssertEqual(spell("Other.Optional<Ctx>"), "Other.Optional<Ctx>")
        XCTAssertEqual(spell("Optional<Ctx, Int>"), "Optional<Ctx, Int>")
    }
}
