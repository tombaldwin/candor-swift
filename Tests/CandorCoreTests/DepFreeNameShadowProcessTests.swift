import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R649 — **`depShadows` READ KEY EXISTENCE AS "A DEPENDENCY DECLARES THIS NAME", AND
/// `pkg#<leaf>` IS MINTED FOR EVERY ENTRY, A METHOD'S LEAF INCLUDED.**
///
/// The index publishes three key shapes per entry — `pkg#leaf`, `pkg#tail2`, `pkg#<full qual>` — as
/// spellings a JOIN can ask on. A join reads the entry's VALUE and is gated on a unique hit, so a leaf
/// key that over-matches costs an over-charge at worst. `depShadows` reads the same key's EXISTENCE as a
/// PROPOSITION — *"a chained dependency declares this bare name, so the platform κ table must not fire"* —
/// and on a true answer it WITHDRAWS a classification. Same key, opposite failure direction.
///
/// So a dependency that merely has a METHOD called `connect` silenced the POSIX free
/// `connect(fd, &addr, len)` in every file that imports it. ONE VARIABLE — the dependency member's NAME;
/// same consumer text, same binary, same policy:
///
///     dep `Chan.connectX`   posixClient -> ['Net']   deny Net exit 1
///     dep `Chan.connect`    posixClient -> ['Env']   deny Net exit 0     ← the cardinal sin
///
/// and the second row is not merely silent: the unqualified-call join finds that SAME bare key and
/// attaches the METHOD's effects, so the real `Net` is replaced by a fabricated `Env`. The κ free names
/// that are also ordinary method leaves are `connect`, `write`, `File`, `Folder`, `Date`, `UUID`,
/// `Process`, `Pipe`, `FileHandle`, `fopen`, `sendmsg`.
///
/// **NOT INTRODUCED BY R567(b)**, which is what the report that sent me here said. `pkg#<leaf>` has been
/// minted for every entry since the three-shape key set existed; `8931087` added only the BARE
/// (de-suffixed) spelling, which widened the same hole to OVERLOADED members. `testSingleSignature…`
/// below FAILS under `CANDOR_R567B_OFF=1` too, and that is what proves the age of it.
///
/// §1b: `CANDOR_R616_OFF=1` restores the old `byKey` membership test. The two defect rows go RED under
/// it; the two CONTROLS — the renamed member, and a dependency's real FREE function still shadowing —
/// pass in both arms.
final class DepFreeNameShadowProcessTests: XCTestCase {

    private struct Arm {
        var rows: [String: Set<String>]
        var depFns: [String]
        var gate: Int32
    }

    /// `policy` is the deny line; `depSource`/`appSource` are the only things that vary between arms.
    private func runPair(depSource: String, appSource: String, deny: String, label: String) throws -> Arm {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r649-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "RatesDep",
            products: [.library(name: "RatesCore", targets: ["RatesCore"])],
            targets: [.target(name: "RatesCore")])
        """)
        try write("dep/Sources/RatesCore/lib.swift", depSource)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [.product(name: "RatesCore", package: "dep")])])
        """)
        try write("app/Sources/App/app.swift", appSource)
        try write("deny.policy", "\(deny)\n")

        let depDir = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path,
                                              "--out", depDir.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        let report = depDir.appendingPathComponent("r.RatesDep.Swift.json")
        let depDoc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        let depFns = ((depDoc?["functions"] as? [[String: Any]]) ?? [])
            .map { ($0["fn"] as? String) ?? "?" }.sorted()
        for extra in try FileManager.default.contentsOfDirectory(atPath: depDir.path)
        where extra != report.lastPathComponent {
            try FileManager.default.removeItem(at: depDir.appendingPathComponent(extra))
        }

        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                             "--out", root.appendingPathComponent("ch").path],
                                       env: ["CANDOR_DEPS": depDir.path])
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Set<String>] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = Set((f["inferred"] as? [String]) ?? [])
        }
        let g = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                             "--policy", root.appendingPathComponent("deny.policy").path,
                                             "--out", root.appendingPathComponent("g").path],
                                       env: ["CANDOR_DEPS": depDir.path])
        return Arm(rows: rows, depFns: depFns, gate: g.code)
    }

    /// The POSIX client. Compiles and runs (§E3): `connect(fd, sa, len)` under `import Darwin` is the real
    /// 3-arg C signature `kappaFree` classifies, and the consumer text is BYTE-IDENTICAL across the arms.
    private static let posixApp = """
    import Darwin
    import RatesCore
    public func posixClient(_ fd: Int32, _ sa: UnsafePointer<sockaddr>, _ len: socklen_t) {
        _ = connect(fd, sa, len)
    }
    """

    private static func depDeclaring(_ member: String) -> String {
        """
        import Foundation
        public final class Chan {
            public init() {}
            public func \(member)() { _ = ProcessInfo.processInfo.environment["A"] }
        }
        """
    }

    func testADependencyMethodLeafIsNotAFreeNameAndMustNotShadowTheKappaTable() throws {
        let r = try runPair(depSource: Self.depDeclaring("connect"), appSource: Self.posixApp,
                            deny: "deny Net", label: "single")
        XCTAssertEqual(r.depFns, ["Chan.connect"],
                       "§E3 premise: the dependency publishes a METHOD, under a two-segment qual whose "
                       + "LEAF happens to be a κ free name. If this ever reads as a one-segment qual the "
                       + "row is measuring something else")
        XCTAssertEqual(r.rows["posixClient"], ["Net"],
                       "`connect(fd, sa, len)` IS the POSIX network-establishing call and κ classifies it. "
                       + "A dependency's unrelated METHOD named `connect` is not a declaration of the free "
                       + "name `connect`, and must not withdraw that classification. Before R649 this read "
                       + "['Env'] — the κ Net LOST and the dep method's effect fabricated in its place")
        XCTAssertEqual(r.gate, 1, "GATE LEVEL — `deny Net` over a POSIX connect(2). Was exit 0")
    }

    /// R567(b) widened the same leaf key to OVERLOADED members, so this arm broke LATER than the one
    /// above — and only this one is closed by restricting that widening, which is why the proposed remedy
    /// would have read as a fix while the single-signature arm stayed red.
    func testAnOverloadedDependencyMethodLeafIsAlsoNotAFreeName() throws {
        let r = try runPair(depSource: """
        import Foundation
        public final class Chan {
            public init() {}
            public func connect() { _ = ProcessInfo.processInfo.environment["A"] }
            public func connect(_ b: Bool) { _ = ProcessInfo.processInfo.environment["B"] }
        }
        """, appSource: Self.posixApp, deny: "deny Net", label: "overload")
        XCTAssertEqual(r.depFns, ["Chan.connect()", "Chan.connect(Bool)"],
                       "§E3 premise: the producer really does suffix the two overloads apart")
        XCTAssertEqual(r.rows["posixClient"], ["Net"], "same sin, reached through the R567(b) bare spelling")
        XCTAssertEqual(r.gate, 1)
    }

    /// CONTROL — the SAME dependency with the member RENAMED by one character. It passed before R649 and
    /// must still pass, or the change is moving something other than the free-name test.
    func testControlTheRenamedDependencyMemberLeavesTheKappaAnswerAlone() throws {
        let r = try runPair(depSource: Self.depDeclaring("connectX"), appSource: Self.posixApp,
                            deny: "deny Net", label: "rename")
        XCTAssertEqual(r.rows["posixClient"], ["Net"], "the arm that was already green")
        XCTAssertEqual(r.gate, 1)
    }

    /// CONTROL — **0.33.0's `shellOut` SHADOW IS THE BEHAVIOUR THIS ROW NARROWS AND MUST NOT DELETE.** A
    /// dependency's real FREE function of a κ name still shadows the platform table, and the consumer
    /// inherits the dependency's OWN recorded effects instead of κ's guess. Asserting `["Env"]` exactly
    /// is both halves at once: `Env` is the dependency's real effect (the join still works) and the
    /// ABSENCE of `Exec` is κ still being shadowed (the heuristic did not come back). The program
    /// compiles and runs.
    func testControlARealDependencyFreeFunctionStillShadowsTheKappaTable() throws {
        let r = try runPair(depSource: """
        import Foundation
        public func shellOut(to s: String) { _ = ProcessInfo.processInfo.environment[s] }
        """, appSource: """
        import RatesCore
        public func viaShellOut() { shellOut(to: "PATH") }
        """, deny: "deny Exec", label: "freefn")
        XCTAssertEqual(r.depFns, ["shellOut"],
                       "§E3 premise: a FREE function is published under a ONE-segment qual — which is "
                       + "exactly the distinction `freeLeaves` is built on")
        XCTAssertEqual(r.rows["viaShellOut"], ["Env"],
                       "BOTH halves of the 0.33.0 discipline in one assertion: `Env` present means the "
                       + "cross-package join still resolves the dependency's own `shellOut`; `Exec` ABSENT "
                       + "means κ's JohnSundell/ShellOut guess is still shadowed by that real declaration. "
                       + "If `Exec` appears here, R649 narrowed the shadow too far and the engine is "
                       + "guessing over a dependency it can read")
        XCTAssertEqual(r.gate, 0,
                       "…and the gate agrees: `deny Exec` over a dependency `shellOut` that does not exec")
    }

    /// CONTROL — a dependency GLOBAL is a one-segment qual too, so the free-name test must keep shadowing
    /// it. `Date` is a κ free name (`CAPABILITY_FREE_EFFECT`, arity 0 → Clock); a dependency declaring its
    /// own free `Date()` must still take precedence over the platform table, exactly as a local one does.
    func testControlADependencyFreeFunctionShadowingAKappaCtorName() throws {
        let r = try runPair(depSource: """
        import Foundation
        public func Date() -> Int { Int(ProcessInfo.processInfo.environment["N"] ?? "") ?? 0 }
        """, appSource: """
        import RatesCore
        public func stamp() -> Int { Date() }
        """, deny: "deny Clock", label: "ctorname")
        XCTAssertEqual(r.depFns, ["Date"], "§E3 premise: a one-segment qual")
        XCTAssertEqual(r.rows["stamp"], ["Env"],
                       "the dependency's own free `Date()` reads the environment and does NOT read the "
                       + "clock. κ would say Clock; the real declaration shadows it — the anti-fabrication "
                       + "direction this predicate exists to serve, kept intact")
        XCTAssertEqual(r.gate, 0, "`deny Clock` over a function that does not read a clock")
    }
}
