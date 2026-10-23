import XCTest
import Foundation

/// SPEC §4 ⟨0.40⟩ — WHICH `interfaceUnion` ENTRIES THE PRODUCER PUBLISHES, AND WHAT GOES ON THEM.
/// SOUNDNESS R1357 (a union carries no `dispatchesOn`, and an otherwise-pure union is not published at all) and
/// R1368 (past the bounded-CHA limit the union is not published at all). Conformance PARTs 102 and 103 pin the
/// same cells four-way; these are the in-repo arms, so the suite goes red without the spec checkout.
///
/// ONE RULE, NOT TWO. Both rows trace to one line in the union loop (`main.swift`): a union was a projection of
/// its contributors onto TWO of a row's channels — `inferred` and `invisible` — and was emitted iff that
/// projection was non-empty. A row is emitted on a third channel too (`dispatchesOn`, ⟨0.39⟩ obligation 1), and
/// the producer's own in-scan dispatch applies the 12-implementor bound before it unions anything. The union
/// now carries the contributors' `dispatchesOn`, is emitted on the same three channels a row is, and past the
/// bound carries the in-scan hedge (`Unknown`, `dispatch:<P>.<m>`) on its own key.
///
/// THE FIRST ARM WAS WRITTEN BEFORE THE FIX, and it is the one this change could break (SOUNDNESS R764):
/// publishing a previously omitted PURE union makes a chained consumer's lookup HIT, and in another engine a
/// hit short-circuited the owner's coverage ledger and deleted `invisible: [owner]`. It passed at the parent
/// commit; it must still pass.
final class UnionPublicationProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: UnionPublicationProcessTests.self)
    }

    private func run(_ binary: URL, _ args: [String], env: [String: String] = [:]) throws
        -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT",
                  "CANDOR_WORKSPACE_CHAIN"] {
            environment.removeValue(forKey: k)
        }
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let exited = ProcessHarness.exitLatch(p)
        try p.run()
        let outData = ProcessHarness.drain(outPipe)
        let errData = ProcessHarness.drain(errPipe)
        exited.wait()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self),
                p.terminationStatus)
    }

    private static let FS = "_ = FileManager.default.contents(atPath: \"/tmp/x\")"
    private static let CLOCK = "_ = Date()"
    private static let ENV = "_ = ProcessInfo.processInfo.environment[\"PATH\"]"

    private static func manifest(_ mod: String, deps: [String]) -> String {
        let d = deps.map { ".package(path: \"../\($0.lowercased()))\"" }.joined(separator: ", ")
        let p = deps.map { ".product(name: \"\($0)\", package: \"\($0.lowercased())\")" }.joined(separator: ", ")
        return """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(mod)", products: [.library(name: "\(mod)", targets: ["\(mod)"])],
            dependencies: [\(d)], targets: [.target(name: "\(mod)", dependencies: [\(p)])])
        """
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fns(_ url: URL) throws -> (fns: [String: [String: Any]], unions: [String: [String: Any]],
                                            doc: [String: Any]) {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        var out: [String: [String: Any]] = [:], unions: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d["functions"] as? [Any]) ?? [] {
            if (f["interfaceUnion"] as? Bool) == true, let h = f["hash"] as? String { unions[h] = f; continue }
            if let name = f["fn"] as? String { out[name] = f }
        }
        return (out, unions, d)
    }

    /// Packages are `(module, deps, source)`, rendered in order. Every one but the last is scanned chained to the
    /// reports of ITS OWN dependencies (as a producer that resolved its owner is); the last is the consumer,
    /// scanned with the reports of `chain` (module names) on CANDOR_DEPS — so an owner can be left UNCHAINED to
    /// the consumer while the producer still knew it.
    private func scan(_ pkgs: [(String, [String], String)], chain: [String]) throws
        -> (app: [String: [String: Any]], appDoc: [String: Any],
            deps: [String: (fns: [String: [String: Any]], unions: [String: [String: Any]])], root: URL) {
        let bin = try binaryURL()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-unionpub-\(UUID().uuidString)")
        for (mod, deps, src) in pkgs {
            let dir = root.appendingPathComponent(mod.lowercased())
            try write(dir.appendingPathComponent("Package.swift"), Self.manifest(mod, deps: deps))
            try write(dir.appendingPathComponent("Sources/\(mod)/lib.swift"), src)
        }
        var reports: [String: String] = [:]
        var depDocs: [String: (fns: [String: [String: Any]], unions: [String: [String: Any]])] = [:]
        for (mod, deps, _) in pkgs.dropLast() {
            let out = root.appendingPathComponent("rep_\(mod)")
            let r = try run(bin, [root.appendingPathComponent(mod.lowercased()).path, "--out", out.path],
                            env: ["CANDOR_DEPS": deps.compactMap { reports[$0] }.joined(separator: " ")])
            XCTAssertEqual(r.code, 0, "dependency scan must succeed (\(mod)); stderr: \(r.err)")
            let path = root.appendingPathComponent("rep_\(mod).\(mod).Swift.json")
            reports[mod] = path.path
            let d = try fns(path)
            depDocs[mod] = (d.fns, d.unions)
        }
        let app = pkgs.last!.0
        let r = try run(bin, [root.appendingPathComponent(app.lowercased()).path, "--out",
                              root.appendingPathComponent("rep_\(app)").path],
                        env: ["CANDOR_DEPS": chain.compactMap { reports[$0] }.joined(separator: " ")])
        XCTAssertEqual(r.code, 0, "consumer scan must succeed; stderr: \(r.err)")
        let a = try fns(root.appendingPathComponent("rep_\(app).\(app).Swift.json"))
        return (a.fns, a.doc, depDocs, root)
    }

    private func eff(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set(by[fn]?["inferred"] as? [String] ?? [])
    }

    // ── PART 102's fixture, local and foreign ────────────────────────────────────────────────────────
    private static let apiAbstractions = """
    public protocol Mapper {
        func mapv(_ x: Int) -> Int
        func other() -> Int
    }
    public struct Nop: Mapper {
        public init() {}
        public func mapv(_ x: Int) -> Int { x }
        public func other() -> Int { 0 }
    }
    public protocol Sink {
        func put(_ v: any Mapper) -> Int
    }

    """
    /// `Doc: Sink`, whose `put` dispatches the FURTHER member `Mapper.mapv`; `busy` also does Clock of its own.
    private static func doc(busy: Bool) -> String {
        """
        public struct Doc: Sink {
            public init() {}
            public func put(_ v: any Mapper) -> Int { \(busy ? CLOCK + "; " : "")return v.mapv(1) }
        }

        """
    }
    /// The consumer's own `Mapper`: `far` puts the Fs on `mapv` (the member the union's contributor dispatches),
    /// `near` puts it on `other` (a member nobody dispatches) — the fabrication control.
    private static func app(far: Bool) -> String {
        """
        import Foundation
        import Api

        public struct Mine: Mapper {
            public init() {}
            public func mapv(_ x: Int) -> Int { \(far ? FS + "; " : "")return x }
            public func other() -> Int { \(far ? "" : FS + "; ")return 0 }
        }
        public func c_direct(_ s: any Sink) -> Int {
            \(ENV)
            return s.put(Mine())
        }

        """
    }
    private static let zapp = """
    import Foundation
    import Api

    public func c_none(_ s: any Sink) -> Int {
        \(ENV)
        return s.put(Nop())
    }

    """

    // ── R764: THE DISCLOSURE THE FIX COULD DELETE (written first; passes at the parent commit) ─────────
    //
    // The owner `Api` is NOT chained to the consumer (it is to `Prod`, PART 102's `u_` layout); `Prod` implements
    // Api's `Sink` with a pure `put` that dispatches `Mapper.mapv`. Before this change Prod published no
    // `Api#Sink.put` union (it was pure); after it, Prod publishes one carrying only `dispatchesOn`, so the
    // consumer's lookup HITS. The consumer has no `Mapper` of its own, so the hit joins nothing — and the
    // owner's `invisible` MUST survive the hit. CALIBRATED: registering a union entry's hash prefix as coverage
    // (`Deps.swift`, `if !isUnionEntry { register(pkg) }` made unconditional) fails both assertions here.
    private func r764Arm() throws -> (app: [String: [String: Any]], appDoc: [String: Any],
                                      deps: [String: (fns: [String: [String: Any]], unions: [String: [String: Any]])],
                                      root: URL) {
        let prod = "import Foundation\nimport Api\n\n" + Self.doc(busy: false)
        return try scan(
            [("Api", [], Self.apiAbstractions), ("Prod", ["Api"], prod), ("Zapp", ["Api", "Prod"], Self.zapp)],
            chain: ["Prod"])
    }

    /// LIVENESS of the arm below — FAILS at the parent commit by design: without the union there is no hit, and
    /// the guard would be asserting about a lookup that never happened.
    func testR764ArmReachesAHit() throws {
        let (_, _, deps, root) = try r764Arm()
        defer { try? FileManager.default.removeItem(at: root) }
        let u = deps["Prod"]?.unions["Api#Sink.put"]
        XCTAssertEqual(u?["inferred"] as? [String], [], "the pure union is published, so the consumer's lookup hits; got \(u ?? [:])")
        XCTAssertEqual(u?["dispatchesOn"] as? [String], ["Api#Mapper.mapv"])
        XCTAssertNil(u?["invisible"], "the producer resolved its owner, so the union carries no `invisible` of its own")
    }

    func testAPublishedPureUnionDoesNotDeleteTheUnchainedOwnersInvisible() throws {
        let (app, appDoc, deps, root) = try r764Arm()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(deps["Prod"]?.fns["Doc.put"]?["dispatchesOn"] as? [String], ["Api#Mapper.mapv"],
                       "fixture: Prod's contributor row must dispatch the further member")
        XCTAssertTrue(eff(app, "c_none").contains("Env"), "carrier lost — the row under test is not this one")
        XCTAssertEqual(app["c_none"]?["invisible"] as? [String], ["Api"],
                       "R764: the unchained owner's `invisible` must survive a union HIT; got \(app["c_none"] ?? [:])")
        let uncovered = ((appDoc["coverage"] as? [String: Any])?["uncovered"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        XCTAssertTrue(uncovered.contains("Api"),
                      "R764: …and the report's coverage ledger must still name the owner; got \(uncovered)")
    }

    // ── R1357: THE FURTHER MEMBER REACHES THE CONSUMER, local abstraction, `busy` (the SILENT cell) ──────
    func testBusyLocalUnionCarriesTheFurtherMember() throws {
        let api = "import Foundation\n" + Self.apiAbstractions + Self.doc(busy: true)
        let (app, _, deps, root) = try scan([("Api", [], api), ("App", ["Api"], Self.app(far: true))],
                                            chain: ["Api"])
        defer { try? FileManager.default.removeItem(at: root) }
        let u = deps["Api"]?.unions["Api#Sink.put"]
        XCTAssertEqual(u?["dispatchesOn"] as? [String], ["Api#Mapper.mapv"],
                       "§4 ⟨0.40⟩ rule 1: a narrow union names the members its contributors dispatch on; got \(u ?? [:])")
        XCTAssertEqual(u?["inferred"] as? [String], ["Clock"], "the union's own effect is unchanged; got \(u ?? [:])")
        XCTAssertTrue(eff(app, "c_direct").isSuperset(of: ["Clock", "Env", "Fs"]),
                      "R1357: the consumer's own Mine.mapv runs through Doc.put and writes; got \(app["c_direct"] ?? [:])")
    }

    // ── R1357: `bare` — an otherwise-pure union is PUBLISHED when it has members to name ─────────────────
    func testBareLocalUnionIsPublishedWithItsMember() throws {
        let api = "import Foundation\n" + Self.apiAbstractions + Self.doc(busy: false)
        let (app, _, deps, root) = try scan([("Api", [], api), ("App", ["Api"], Self.app(far: true))],
                                            chain: ["Api"])
        defer { try? FileManager.default.removeItem(at: root) }
        let u = deps["Api"]?.unions["Api#Sink.put"]
        XCTAssertNotNil(u, "a union with a member to name is published though otherwise pure")
        XCTAssertEqual(u?["inferred"] as? [String], [], "…and published PURE — it names, it does not hedge; got \(u ?? [:])")
        XCTAssertEqual(u?["dispatchesOn"] as? [String], ["Api#Mapper.mapv"])
        XCTAssertTrue(eff(app, "c_direct").contains("Fs"), "R1357 bare: got \(app["c_direct"] ?? [:])")
    }

    // ── R1357: foreign abstraction (the union keyed under the OWNER), owner chained ───────────────────
    func testBusyForeignUnionCarriesTheFurtherMember() throws {
        let prod = "import Foundation\nimport Api\n\n" + Self.doc(busy: true)
        let (app, _, deps, root) = try scan(
            [("Api", [], Self.apiAbstractions), ("Prod", ["Api"], prod), ("App", ["Api", "Prod"], Self.app(far: true))],
            chain: ["Api", "Prod"])
        defer { try? FileManager.default.removeItem(at: root) }
        let u = deps["Prod"]?.unions["Api#Sink.put"]
        XCTAssertEqual(u?["dispatchesOn"] as? [String], ["Api#Mapper.mapv"], "got \(u ?? [:])")
        XCTAssertTrue(eff(app, "c_direct").contains("Fs"), "R1357 foreign: got \(app["c_direct"] ?? [:])")
    }

    // ── THE FABRICATION CONTROL: Fs on a member NOBODY dispatches stays off the consumer ────────────────
    func testNearMemberIsNotJoined() throws {
        let api = "import Foundation\n" + Self.apiAbstractions + Self.doc(busy: true)
        let (app, _, _, root) = try scan([("Api", [], api), ("App", ["Api"], Self.app(far: false))],
                                         chain: ["Api"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(eff(app, "c_direct").contains("Env"), "carrier lost")
        XCTAssertFalse(eff(app, "c_direct").contains("Fs"),
                       "Mine.other writes and nobody dispatches it: joining it is a minted edge; got \(app["c_direct"] ?? [:])")
    }

    // ── A `super.m()` DOES NOT REACH THE OVERRIDE UNION'S FURTHER MEMBERS (the corpus A/B's over-charge) ──
    //
    // `V.visit` is pure, so the dependency publishes no real `Api#V.visit` and the static index keeps the
    // subclass-override union (R867's floor). Since R1357 that union names `Api#Mapper.mapv`, which `S1.visit`
    // dispatches. `C.visit`'s `super.visit()` runs `V.visit` alone (Swift dispatches `super.` statically), so the
    // consumer's own `Mine.mapv` Fs MUST NOT arrive. The dynamic call `c_dyn(v) { v.visit() }` is the
    // control: it does run `S1.visit` for an `S1`, so it MUST carry Fs.
    func testASuperCallDoesNotFollowTheOverrideUnionsFurtherMembers() throws {
        let api = Self.apiAbstractions + """
        open class V { public init() {}; open func visit(_ m: any Mapper) -> Int { 0 } }
        public final class S1: V { public override func visit(_ m: any Mapper) -> Int { m.mapv(1) } }

        """
        let app = """
        import Foundation
        import Api

        public struct Mine: Mapper {
            public init() {}
            public func mapv(_ x: Int) -> Int { \(Self.FS); return x }
            public func other() -> Int { 0 }
        }
        public final class C: V {
            public override func visit(_ m: any Mapper) -> Int { \(Self.ENV); return super.visit(Mine()) }
        }
        public func c_dyn(_ v: V) -> Int { v.visit(Mine()) }

        """
        let (app_, _, deps, root) = try scan([("Api", [], api), ("App", ["Api"], app)], chain: ["Api"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(deps["Api"]?.unions["Api#V.visit"]?["dispatchesOn"] as? [String], ["Api#Mapper.mapv"],
                       "fixture: the override union names the further member")
        XCTAssertTrue(eff(app_, "c_dyn").contains("Fs"), "CONTROL: a dynamic `v.visit` runs S1.visit; got \(app_["c_dyn"] ?? [:])")
        XCTAssertTrue(eff(app_, "C.visit").contains("Env"), "carrier lost")
        XCTAssertFalse(eff(app_, "C.visit").contains("Fs"),
                       "`super.visit` runs V.visit, which is pure: Mine.mapv's Fs is a minted edge; got \(app_["C.visit"] ?? [:])")
    }

    // ── R1368: PAST THE BOUND THE UNION IS PUBLISHED BROAD (PART 103) ─────────────────────────────────
    private static func sinks(_ n: Int, effectful: Int? = nil) -> String {
        "import Foundation\npublic protocol Sink { func put() -> Int }\n" + (1...n).map { k in
            "public struct K\(k): Sink { public init() {}; public func put() -> Int { "
                + (k == effectful ? FS + "; " : "") + "return \(k) } }\n"
        }.joined()
    }
    private static let cb = """
    import Foundation
    import Dep

    public func c_b(_ s: any Sink) -> Int {
        \(ENV)
        return s.put()
    }

    """

    func testPastTheBoundTheUnionCarriesTheHedge() throws {
        let (app, _, deps, root) = try scan([("Dep", [], Self.sinks(13)), ("App", ["Dep"], Self.cb)], chain: ["Dep"])
        defer { try? FileManager.default.removeItem(at: root) }
        let u = deps["Dep"]?.unions["Dep#Sink.put"]
        XCTAssertEqual(u?["inferred"] as? [String], ["Unknown"],
                       "R1368: 13 pure implementors — the union is published BROAD, never omitted; got \(u ?? [:])")
        XCTAssertEqual(u?["unknownWhy"] as? [String], ["dispatch:Sink.put"],
                       "…with the in-scan hedge's own reason, so `deny Unknown[dispatch]` reads it; got \(u ?? [:])")
        XCTAssertTrue(eff(app, "c_b").contains("Unknown"),
                      "the chained consumer reads Unknown, as the one-tree scan does; got \(app["c_b"] ?? [:])")
    }

    func testWithinTheBoundAPureUnionStaysUnpublished() throws {
        let (app, _, deps, root) = try scan([("Dep", [], Self.sinks(12)), ("App", ["Dep"], Self.cb)], chain: ["Dep"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(deps["Dep"]?.unions["Dep#Sink.put"],
                     "CONTROL: 12 pure implementors that dispatch nothing — silence is the purity claim")
        XCTAssertEqual(eff(app, "c_b"), ["Env"], "CONTROL (PART 92 c3_pure_only): got \(app["c_b"] ?? [:])")
    }

    /// Past the bound with an effectful contributor the union KEEPS that effect and ADDS the hedge — the
    /// change adds `Unknown` and removes nothing, so no consumer that was charged `Fs` here stops being charged.
    func testPastTheBoundAnEffectfulUnionKeepsItsEffect() throws {
        let (app, _, deps, root) = try scan([("Dep", [], Self.sinks(13, effectful: 5)), ("App", ["Dep"], Self.cb)],
                                            chain: ["Dep"])
        defer { try? FileManager.default.removeItem(at: root) }
        let u = deps["Dep"]?.unions["Dep#Sink.put"]
        XCTAssertEqual(u?["inferred"] as? [String], ["Fs", "Unknown"], "got \(u ?? [:])")
        XCTAssertTrue(eff(app, "c_b").isSuperset(of: ["Fs", "Unknown"]), "got \(app["c_b"] ?? [:])")
    }
}
