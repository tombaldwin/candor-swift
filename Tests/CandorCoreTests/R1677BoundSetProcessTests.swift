import XCTest
import Foundation

/// SOUNDNESS R1677 — A GENERIC BOUND IS A SET. `genericBounds` was `[String: String]` (one protocol per parameter: the FIRST member of
/// a composition, the LAST `where` requirement), so a call to any other required protocol's member joined no conformer and the caller
/// was ABSENT over a conformer that writes a file. EXECUTED (swiftc, run: every charged caller below writes its marker; the `k*`
/// callers over `PA & PB` conformers that are pure write nothing). Spellings: `D: P & Q` (second member, reversed order), `where D: P, D: Q`,
/// `<D: P> where D: Q`, a parameter pack `<each D: P>` (even the single bound), `some`/`any P & Q` (an R1676 REGRESSION: the
/// pre-R1676 composition arm tried every member and the first-member reading pre-empted it), `protocol Y: P & Q`, a generic class'
/// field, an extension `where`, a local copy, an optional, `[D]`, `D.Type`, a closure capture and an extension default. A pure
/// control with the same shapes stays pure. A trailing MARKER requirement (`<T: DP> … where T: Sendable`) no longer replaces the real bound (m1/m2). Also R1686: `let x: D = d` under `<D: P>` (single bound, ABSENT).
/// Switches: `CANDOR_R1677_OFF` (all but R1686), `CANDOR_R1686_OFF`.
final class R1677BoundSetProcessTests: XCTestCase {
    static let src = #"""
import Foundation
func mark(_ n: String) { FileManager.default.createFile(atPath: "/tmp/r1677t-" + n, contents: nil) }
protocol P { func pm() }
protocol Q { func qm() }
protocol Pure { func nm() }
struct Both: P, Q {
    func pm() { mark("pm") }
    func qm() { mark("qm") }
}
// a Q-only conformer: its effect must be reachable too
struct OnlyQ: Q { func qm() { mark("qm_onlyq") } }
struct Quiet: P, Q, Pure { func pm() {}; func qm() {}; func nm() {} }
// effect only in a protocol requirement of Q's SECOND conformer, with P conformer quiet
struct QuietP: P { func pm() {} }
struct LoudQOnly: Q { func qm() { mark("qm_loudqonly") } }

// 1. D: P & Q  -- call P member (first), Q member (second)
func c1p<D: P & Q>(_ d: D) { d.pm() }
func c1q<D: P & Q>(_ d: D) { d.qm() }
// 2. D: Q & P reversed
func c2p<D: Q & P>(_ d: D) { d.pm() }
func c2q<D: Q & P>(_ d: D) { d.qm() }
// 3. where D: P, D: Q
func c3p<D>(_ d: D) where D: P, D: Q { d.pm() }
func c3q<D>(_ d: D) where D: P, D: Q { d.qm() }
// 3b. <D: P> where D: Q
func c3bp<D: P>(_ d: D) where D: Q { d.pm() }
func c3bq<D: P>(_ d: D) where D: Q { d.qm() }
// 4. parameter pack
func c4p<each D: P>(_ d: repeat each D) { repeat (each d).pm() }
func c4q<each D: P & Q>(_ d: repeat each D) { repeat (each d).qm() }
func c4r<each D: P>(_ d: repeat each D) where repeat each D: Q { repeat (each d).qm() }
// 5. some / any compositions
func c5q(_ d: some P & Q) { d.qm() }
func c5p(_ d: some P & Q) { d.pm() }
func c5aq(_ d: any P & Q) { d.qm() }
func c5ap(_ d: any P & Q) { d.pm() }
// 6. protocol inheritance
protocol X: P, Q {}
protocol Y: P & Q {}
struct XB: X { func pm() { mark("xpm") }; func qm() { mark("xqm") } }
struct YB: Y { func pm() { mark("ypm") }; func qm() { mark("yqm") } }
func c6xp<D: X>(_ d: D) { d.pm() }
func c6xq<D: X>(_ d: D) { d.qm() }
func c6yq<D: Y>(_ d: D) { d.qm() }
func c6ax(_ d: any X) { d.qm() }
func c6sx(_ d: some X) { d.qm() }
// 7. generic class property
final class H<D: P & Q> { var d: D; init(_ d: D) { self.d = d }; func hp() { d.pm() }; func hq() { d.qm() } }
final class W<D> where D: P, D: Q { var d: D; init(_ d: D) { self.d = d }; func wp() { d.pm() }; func wq() { d.qm() } }
// 8. extension where
struct Box<D> { var d: D }
extension Box where D: P, D: Q { func ep() { d.pm() }; func eq() { d.qm() } }
extension Box where D: P & Q { func ep2() { d.pm() }; func eq2() { d.qm() } }
// 9. generic method on a protocol conformer type: member of Q implemented only by a Q-only type not P
func c9<D: P & Q>(_ d: D, _ o: some Q) { o.qm() }

// ---- R1677 family 2: locals, arrays, optionals, statics, closures, extension defaults, pure controls
extension Q { func qdef() { mark("qdef") } }
protocol SP { static func pmake() }
protocol SQ { static func qmake() }
struct SBoth: SP, SQ { static func pmake() { mark("spmake") }; static func qmake() { mark("sqmake") } }
func l1<D: P & Q>(_ d: D) { let x = d; x.qm() }
func l2<D: P & Q>(_ d: D) { let x: D = d; x.qm() }
func a1<D: P & Q>(_ ds: [D]) { for d in ds { d.qm() } }
func o1<D: P & Q>(_ d: D?) { d?.qm() }
func s1<D: SP & SQ>(_ t: D.Type) { D.qmake() }
func s2<D: SP & SQ>(_ t: D.Type) { D.pmake() }
func cl1<D: P & Q>(_ d: D) { let f = { d.qm() }; f() }
func df1<D: P & Q>(_ d: D) { d.qdef() }
func df2<D>(_ d: D) where D: P, D: Q { d.qdef() }
func sd1<D: X & Sendable>(_ d: D) { d.qm() }
final class S1<D: P & Q> { var d: D; init(_ d: D) { self.d = d }; func sq() { self.d.qm() }; func sp() { self.d.pm() } }
final class F1 { var d: any P & Q; init(_ d: any P & Q) { self.d = d }; func fq() { d.qm() }; func fp() { d.pm() } }
final class F2 { var d: (any P & Q)?; init(_ d: (any P & Q)?) { self.d = d }; func f2q() { d?.qm() } }
func lt1(_ d: any P & Q) { let x = d; x.qm() }
func lt2(_ d: any P & Q) { let x: any P & Q = d; x.qm() }
// pure controls: no effectful conformer anywhere for these protocols
protocol PA { func pa() }
protocol PB { func pb() }
struct QuietAB: PA, PB { func pa() {}; func pb() {} }
func k4<D: PA & PB>(_ d: D) { d.pa(); d.pb() }
func k5<D>(_ d: D) where D: PA, D: PB { d.pa(); d.pb() }
func k6<each D: PA & PB>(_ d: repeat each D) { repeat (each d).pb() }
func k7(_ d: some PA & PB) { d.pb() }
final class K8<D: PA & PB> { var d: D; init(_ d: D) { self.d = d }; func kb() { d.pb(); d.pa() } }
func k9<D: PA & PB>(_ ds: [D]) { for d in ds { d.pb() } }

// single-bound twins of the local/array/static/optional-field spellings
func l1s<D: P>(_ d: D) { let x = d; x.pm() }
func l2s<D: P>(_ d: D) { let x: D = d; x.pm() }
func a1s<D: P>(_ ds: [D]) { for d in ds { d.pm() } }
func s1s<D: SP>(_ t: D.Type) { D.pmake() }
final class F2s { var d: (any P)?; init(_ d: (any P)?) { self.d = d }; func f2s() { d?.pm() } }
func lt1s(_ d: any P) { let x = d; x.pm() }
func lt2s(_ d: any P) { let x: any P = d; x.pm() }

protocol DP { func todata() }
struct DLoud: DP, Sendable { func todata() { mark("todata") } }
func m1<T: DP>(_ v: T) where T: Sendable { v.todata() }
final class M2<T: DP> where T: Sendable { var v: T; init(_ v: T) { self.v = v }; func m2() { v.todata() } }
func m3<T: Sendable>(_ v: T) where T: DP { v.todata() }

"""#
    private func scan(_ root: URL, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }
    private func gate(_ root: URL, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = root.appendingPathComponent("policy.candor")
        try policy.write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", root.appendingPathComponent("g").path],
                                      env: env).code
    }

    func testEverySpellingOfASecondRequiredProtocolDispatches() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in ["m1", "M2.m2", "m3", "c1p", "c1q", "c2p", "c2q", "c3p", "c3q", "c3bp", "c3bq", "c4p", "c4q", "c4r", "c5p", "c5q", "c5ap", "c5aq", "c6xp", "c6xq", "c6yq", "c6ax", "c6sx", "H.hp", "H.hq", "W.wp", "W.wq", "Box.ep", "Box.eq", "Box.ep2", "Box.eq2", "c9", "l1", "l2", "a1", "o1", "s1", "s2", "cl1", "df1", "df2", "sd1", "S1.sq", "S1.sp", "F1.fq", "F1.fp", "F2.f2q", "lt1", "lt2", "l1s", "a1s", "s1s", "F2s.f2s", "lt1s", "lt2s", "l2s"] {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes the marker (executed) — \(by[fn] ?? [:])")
        }
        for fn in ["k4", "k5", "k6", "k7", "K8.kb", "k9"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, fn), "\(fn): every conformer is pure (executed: no marker) — \(by[fn] ?? [:])")
        }
    }

    func testTheKillSwitchRestoresTheSilenceAndTheGateFlips() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let off = try scan(root, env: ["CANDOR_R1677_OFF": "1", "CANDOR_R1686_OFF": "1"])
        for fn in ["m1", "M2.m2", "c1q", "c2p", "c3p", "c3bp", "c4p", "c4q", "c4r", "c5q", "c5aq", "c6yq", "H.hq", "W.wp", "Box.ep", "Box.eq2", "l1", "l2", "a1", "o1", "s1", "cl1", "df1", "S1.sq", "F1.fq", "F2.f2q", "lt1", "lt2"] {
            XCTAssertNil(ProcessHarness.chargedNothing(off, fn), "the R1676 reading was silent: \(fn) \(off[fn] ?? [:])")
            XCTAssertNotEqual(ProcessHarness.inferred(off, fn), ["Fs"], "\(fn) under the switch")
        }
        for fn in ["c1q", "c3p", "c4p", "c5q", "c6yq", "H.hq", "o1", "F2.f2q"] {
            XCTAssertEqual(try gate(root, "deny Fs \(fn)\n"), 1, "\(fn): the gate flips with the fix")
            XCTAssertEqual(try gate(root, "deny Fs \(fn)\n", env: ["CANDOR_R1677_OFF": "1"]), 0, "\(fn): and is silent without it")
        }
        XCTAssertEqual(try gate(root, "deny Fs k4\n"), 0)
        XCTAssertEqual(try gate(root, "deny Fs K8.kb\n"), 0)
    }
}
