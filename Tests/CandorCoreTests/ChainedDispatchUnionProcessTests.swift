import XCTest
import Foundation

/// SPEC §4 ⟨0.39⟩ — THE CHAINED-DISPATCH UNION, and SOUNDNESS R475/R504/R507.
///
/// THE DEFECT IS A TOGGLE AND IT RUNS THE WRONG WAY. A library whose public abstraction has ZERO local
/// conformers gives a chained consumer a disclosed `Unknown`; add ONE PURE conformer to that library and
/// the consumer is SILENTLY CERTIFIED PURE. So **adding a pure implementation to a library REMOVES a
/// disclosure from every consumer of it** — the ⟨0.21⟩ cardinal sin, reached by a route no single scan
/// can see, because nothing is wrong with either package on its own and the loss exists only in the join.
/// Measured live on `ratatui` (R475): `ratatui-core`'s `Terminal::size` dispatches `Backend::size` over
/// its sole local implementor `TestBackend` (pure) while `ratatui-crossterm`'s `CrosstermBackend::size`
/// performs `Ipc`, and an app chained onto both reported that function ABSENT.
///
/// THE FIXTURE IS THREE PACKAGES, AND FOR ONE ARM FOUR, because the effectful implementor lives in a
/// THIRD package — neither the dispatching dependency nor the consumer — so no two-package arm can
/// express the finding. It mirrors conformance PART 92 (`gen_chained_dispatch.py`) arm for arm, so a
/// failure here and a failure there name the same cell.
///
///   iface     `protocol Backend { func size() }` + `termSize(b)`, which DISPATCHES over it
///             `impl`   also declares ONE PURE conformer          `zero`  declares none
///   middle    `midSize(b)` — dispatches over `iface`'s abstraction and owns NEITHER it nor a conformer
///   effimpl   conforms to iface's FOREIGN abstraction, effectfully
///   app       `appSize(b) { termSize(b) }` — BYTE-IDENTICAL across the toggle's arms
///
/// THE CONTROL ARMS ARE NOT OPTIONAL. Widening a union is exactly where this family has turned a silence
/// into a fabrication before, so `zeroImplementorStaysDisclosed` (the toggle's other side) and
/// `onlyPureImplementorStaysPure` (the fabrication guard: a MISS ADDS NOTHING) carry as much weight as
/// the defect arm, and `aForeignUnionEntryIsNotCoverage` guards the one way this rung's own remedy can
/// manufacture this rung's own defect.
final class ChainedDispatchUnionProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: ChainedDispatchUnionProcessTests.self)
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

    private static let SINK = "_ = URLSession.shared.dataTask(with: URL(string: \"http://h\")!)"

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

    /// `iface` in its two variants. The CONSUMER's function under test is the same text in both, so
    /// nothing about the consumer can explain the answer moving — the cross the R475 filing got wrong
    /// three times by varying two things at once.
    private static func ifaceSource(_ variant: String) -> String {
        let decl = "public protocol Backend { func size() -> Int }\n"
        let pure = "public struct TestBackend: Backend { public init() {}; public func size() -> Int { return 7 } }\n"
        let disp = "public func termSize(_ b: Backend) -> Int { return b.size() }\n"
        return decl + (variant == "impl" ? pure : "") + disp
    }
    private static let middleSource = "import Iface\npublic func midSize(_ b: Backend) -> Int { return b.size() }\n"
    private static let effimplSource = """
    import Foundation
    import Iface
    public struct Crossterm: Backend { public init() {}; public func size() -> Int { \(SINK); return 0 } }
    """
    private static let appDispatch = "import Iface\npublic func appSize(_ b: Backend) -> Int { return termSize(b) }\n"
    private static let appMiddle = "import Iface\nimport Middle\npublic func appSize(_ b: Backend) -> Int { return midSize(b) }\n"
    private static let appThird = "import EffImpl\npublic func appRun() -> Int { return appSize(Crossterm()) }\n"

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Renders one arm and returns (root, dependency package dirs in scan order, app dir).
    /// `appOverride` replaces the consumer's own source — the R532 arms dispatch DIRECTLY on a
    /// `Backend`-typed receiver in the consumer (the site that forms the wire key), where the arms above
    /// forward to the dependency's `termSize`.
    private func render(iface: String, third: Bool, middle: Bool,
                        appOverride: String? = nil) throws -> (URL, [URL], URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r475-\(UUID().uuidString)")
        func pkg(_ n: String) -> URL { root.appendingPathComponent(n.lowercased()) }
        try write(pkg("Iface").appendingPathComponent("Package.swift"), Self.manifest("Iface", deps: []))
        try write(pkg("Iface").appendingPathComponent("Sources/Iface/iface.swift"), Self.ifaceSource(iface))
        var order = [pkg("Iface")]
        var appDeps = ["Iface"]
        if middle {
            try write(pkg("Middle").appendingPathComponent("Package.swift"), Self.manifest("Middle", deps: ["Iface"]))
            try write(pkg("Middle").appendingPathComponent("Sources/Middle/mid.swift"), Self.middleSource)
            order.append(pkg("Middle")); appDeps.append("Middle")
        }
        if third {
            try write(pkg("EffImpl").appendingPathComponent("Package.swift"), Self.manifest("EffImpl", deps: ["Iface"]))
            try write(pkg("EffImpl").appendingPathComponent("Sources/EffImpl/eff.swift"), Self.effimplSource)
            order.append(pkg("EffImpl")); appDeps.append("EffImpl")
        }
        // `appThird` is NOT appended to an override, and that is load-bearing rather than tidiness: it
        // carries `import EffImpl`, which would leave the app file with TWO dependency imports, and
        // `foreignOwnerModule` REFUSES a file that leaves two candidates. The R532 arms form their key
        // in the consumer itself, so the consumer's own import list has to stay decidable; the arms
        // above form theirs in the dependency, where it never mattered.
        var body = appOverride ?? (middle ? Self.appMiddle : Self.appDispatch)
        if third, appOverride == nil { body += Self.appThird }
        try write(pkg("App").appendingPathComponent("Package.swift"), Self.manifest("App", deps: appDeps))
        try write(pkg("App").appendingPathComponent("Sources/App/app.swift"), body)
        return (root, order, pkg("App"))
    }

    private func fns(_ url: URL) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let name = f["fn"] as? String { out[name] = f }
        }
        return out
    }

    /// Scan every dependency STANDALONE (each is its own package — chaining them to each other would
    /// hide which report carried which fact), then the consumer with their reports on CANDOR_DEPS.
    private func consumer(iface: String, third: Bool, middle: Bool = false, chained: Bool = true,
                          appOverride: String? = nil) throws
        -> (app: [String: [String: Any]], deps: [[String: [String: Any]]], root: URL) {
        let bin = try binaryURL()
        let (root, order, app) = try render(iface: iface, third: third, middle: middle,
                                            appOverride: appOverride)
        var reports: [String] = []
        var depDocs: [[String: [String: Any]]] = []
        for (i, d) in order.enumerated() {
            let out = root.appendingPathComponent("dep\(i)")
            let r = try run(bin, [d.path, "--out", out.path])
            XCTAssertEqual(r.code, 0, "dependency scan must succeed (\(d.lastPathComponent)); stderr: \(r.err)")
            let mod = d.lastPathComponent == "iface" ? "Iface"
                    : (d.lastPathComponent == "middle" ? "Middle" : "EffImpl")
            let path = root.appendingPathComponent("dep\(i).\(mod).Swift.json")
            reports.append(path.path)
            depDocs.append(try fns(path))
        }
        let appOut = root.appendingPathComponent("app")
        let r = try run(bin, [app.path, "--out", appOut.path],
                        env: chained ? ["CANDOR_DEPS": reports.joined(separator: " ")] : [:])
        XCTAssertEqual(r.code, 0, "consumer scan must succeed; stderr: \(r.err)")
        return (try fns(root.appendingPathComponent("app.App.Swift.json")), depDocs, root)
    }

    private func eff(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set(by[fn]?["inferred"] as? [String] ?? [])
    }

    // ── THE DEFECT ARM (PART 92 `c1_foreign_effectful`) ──────────────────────────────────────────
    func testAForeignEffectfulConformerReachesTheChainedConsumer() throws {
        let (app, deps, root) = try consumer(iface: "impl", third: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The two producer legs, asserted rather than assumed — a green consumer row could otherwise
        // come from any mechanism at all.
        XCTAssertEqual(deps[0]["termSize"]?["dispatchesOn"] as? [String], ["Iface#Backend.size"],
                       "obligation 1: the producer names the dispatched member EVEN THOUGH the row is "
                       + "otherwise pure; got \(deps[0]["termSize"] ?? [:])")
        XCTAssertEqual(deps[0]["termSize"]?["inferred"] as? [String], [],
                       "…and it is emitted EFFECT-FREE — absence keeps its meaning, a dispatching row "
                       + "simply stops being absent")
        XCTAssertEqual(deps[1]["Backend.size"]?["hash"] as? String, "Iface#Backend.size",
                       "obligation 2: a package conforming to a FOREIGN abstraction keys its union entry "
                       + "under the OWNING package, in the ⟨0.23⟩ `typeSurface` spelling; "
                       + "got \(deps[1]["Backend.size"] ?? [:])")
        XCTAssertEqual(deps[1]["Backend.size"]?["interfaceUnion"] as? Bool, true)
        // …and the joint effect, which is the property (PART 92 asserts at the consumer for this reason).
        XCTAssertTrue(eff(app, "appSize").contains("Net"),
                      "THE DEFECT: an effectful conformer supplied from a THIRD package must reach the "
                      + "consumer — absence here is a ⟨0.21⟩ positive claim of purity; got \(app["appSize"] ?? [:])")
    }

    // ── THE TOGGLE'S OTHER SIDE (PART 92 `c2_zero_impl`) ─────────────────────────────────────────
    func testZeroConformersStaysADisclosedUnknown() throws {
        let (app, _, root) = try consumer(iface: "zero", third: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(eff(app, "appSize").contains("Unknown"),
                      "the zero-conformer case MUST remain a disclosed Unknown — a fix that reddens its "
                      + "sibling and greys this one has traded one silence for another; got \(app["appSize"] ?? [:])")
        XCTAssertFalse(eff(app, "appSize").contains("Net"))
    }

    // ── THE FABRICATION GUARD (PART 92 `c3_pure_only`) — A MISS ADDS NOTHING ─────────────────────
    func testOnlyPureConformerStaysPure() throws {
        let (app, _, root) = try consumer(iface: "impl", third: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(ProcessHarness.chargedNothing(app, "appSize"),
                     "a consumer over a library whose only conformer ANYWHERE is pure is LEGITIMATELY "
                     + "pure: an engine that unions indiscriminately — charging every consumer of every "
                     + "dispatching library for effects nobody implements — reddens exactly here; "
                     + "got \(app["appSize"] ?? [:])")
    }

    // ── THE REFERENCE (PART 92 `c5_unchained`) ───────────────────────────────────────────────────
    func testUnchainedTheSameConsumerDisclosesViaInvisible() throws {
        let (app, _, root) = try consumer(iface: "impl", third: true, chained: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(eff(app, "appSize").contains("Net"))
        XCTAssertFalse((app["appSize"]?["invisible"] as? [String] ?? []).isEmpty,
                       "unchained, the same consumer discloses through `invisible` — chaining must not "
                       + "DELETE that disclosure, which is what the defect did; got \(app["appSize"] ?? [:])")
    }

    // ── SOUNDNESS R532 — A GENERIC PARAMETER IS NOT A TYPE NAME ─────────────────────────────────
    //
    // ⟨0.39⟩ made the receiver's SPELLED type a WIRE KEY. Four ways of spelling one existential
    // (`Backend`, `Iface.Backend`, `any Backend`, `[Backend]`) form `Iface#Backend.size`; the FIFTH —
    // the generic bound — formed `Iface#T.size`, a key naming a type the owning package does not have
    // and one no producer can ever publish under. MEASURED at 0.39.0, one variable, everything else
    // held identical: `_ b: Backend` → `inferred: [Net]`, `deny Net` exit 1; `<B: Backend>(_ b: B)` →
    // `inferred: []`, `dispatchesOn: [Iface#B.size]`, exit 0 — over the same dependency, the same
    // conformer and the same binary. The LOCAL-protocol path has resolved the bound since R26, so this
    // is §F1.3, two implementations of one question that drifted, with only the newer one on the wire.
    //
    // THE ARMS ARE A CROSS, not a single assertion: the generic spelling is asserted EQUAL to the
    // existential one rendered from the same helper, so the test keeps its meaning if the rung's key
    // format changes and cannot pass by both arms going silent (`chargedNothing` would then fire).
    private static let appGeneric =
        "import Iface\npublic func appSize<B: Backend>(_ b: B) -> Int { return b.size() }\n"
    private static let appWhere =
        "import Iface\npublic func appSize<B>(_ b: B) -> Int where B: Backend { return b.size() }\n"
    private static let appExistential =
        "import Iface\npublic func appSize(_ b: Backend) -> Int { return b.size() }\n"

    private func dispatchKeyAndEffects(_ appSrc: String) throws -> (key: [String], eff: Set<String>) {
        let (app, _, root) = try consumer(iface: "impl", third: true, appOverride: appSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        return (app["appSize"]?["dispatchesOn"] as? [String] ?? [], eff(app, "appSize"))
    }

    func testAGenericBoundReceiverFormsTheSameDispatchKeyAsTheExistentialOne() throws {
        let existential = try dispatchKeyAndEffects(Self.appExistential)
        // The reference arm must itself be non-vacuous — if the existential spelling stopped carrying
        // the effect, an equality assertion below would pass over two silences.
        XCTAssertEqual(existential.key, ["Iface#Backend.size"])
        XCTAssertTrue(existential.eff.contains("Net"), "reference arm is vacuous: \(existential)")

        for (name, src) in [("<B: Backend>", Self.appGeneric), ("where B: Backend", Self.appWhere)] {
            let generic = try dispatchKeyAndEffects(src)
            XCTAssertEqual(generic.key, existential.key,
                           "\(name) must key on the BOUND, not on the type-parameter name — "
                           + "`Iface#B.size` is a key no producer can publish under; got \(generic.key)")
            XCTAssertEqual(generic.eff, existential.eff,
                           "…and therefore carry the same effects as the existential spelling of the "
                           + "same dispatch; got \(generic.eff) vs \(existential.eff)")
        }
    }

    /// THE FABRICATION CONTROL, and the near-miss the resolution has to refuse. `<T: Encodable>` is a
    /// bound nearly every type satisfies, so keying a dispatch under it would union an unrelated
    /// package's `Encodable` conformers onto this row — the `STD_PURE_PROTOCOLS` carve-out the CHA arm
    /// beside this already applies to a non-generic owner, which the resolution must not step around.
    /// It compiles and the call is a real protocol requirement, so the absence asserted here is an
    /// absence over a reachable site (§E3).
    func testAStdPureBoundPublishesNoDispatchKeyAtAll() throws {
        let src = "import Iface\npublic func appSize<T: Encodable>(_ x: T, _ e: Encoder) -> Int {\n"
                + "    try? x.encode(to: e)\n    return 0\n}\n"
        let (app, _, root) = try consumer(iface: "impl", third: true, appOverride: src)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(app["appSize"]?["dispatchesOn"],
                     "a std-pure bound must publish NO dispatch key: keying it would charge this row "
                     + "with an unrelated package's Encodable conformers, and BEFORE this resolution it "
                     + "published `Iface#T.encode` — a nonsense key that read as an answer; "
                     + "got \(app["appSize"] ?? [:])")
    }

    // ── THE MIDDLE PACKAGE (PART 92 `c6_middle_package`, SOUNDNESS R504) ─────────────────────────
    func testAMiddlePackageThatOwnsNothingStillNamesTheMember() throws {
        let (app, deps, root) = try consumer(iface: "impl", third: true, middle: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(deps[1]["midSize"]?["dispatchesOn"] as? [String], ["Iface#Backend.size"],
                       "the DISPATCHER owns neither the abstraction nor any conformer of it, and must "
                       + "still name the member keyed under the package that DOES — otherwise the chain "
                       + "breaks ONE HOP SHORT; got \(deps[1]["midSize"] ?? [:])")
        XCTAssertTrue(eff(app, "appSize").contains("Net"),
                      "…and the consumer two hops out gets the effect; got \(app["appSize"] ?? [:])")
    }

    // ── THE REMEDY MUST NOT MANUFACTURE THE DEFECT ───────────────────────────────────────────────
    /// A FOREIGN UNION ENTRY IS NOT COVERAGE OF THE PACKAGE IT NAMES. Obligation 2 makes `effimpl`
    /// publish `Iface#Backend.size`; coverage (§2 rule 3) is the single mechanism that turns a report's
    /// SILENCE into a purity claim, so registering that hash prefix would grant EffImpl's report coverage
    /// of Iface and withdraw `invisible` for every unanswered call into Iface — R475's own shape,
    /// produced by R475's own remedy. THE NEAR-MISS CONTROL IS THE TEST: the same scan with Iface's own
    /// report chained DOES lose the disclosure, legitimately, so the assertion cannot pass vacuously.
    func testAForeignUnionEntryIsNotCoverageOfThePackageItNames() throws {
        let bin = try binaryURL()
        let (root, order, app) = try render(iface: "impl", third: true, middle: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var reports: [String: String] = [:]
        for (i, d) in order.enumerated() {
            let mod = d.lastPathComponent == "iface" ? "Iface" : "EffImpl"
            XCTAssertEqual(try run(bin, [d.path, "--out", root.appendingPathComponent("dep\(i)").path]).code, 0)
            reports[mod] = root.appendingPathComponent("dep\(i).\(mod).Swift.json").path
        }
        // READ THE κ LEDGER, NOT THE PER-FN `invisible`. The per-fn set is the wrong instrument here and
        // that is measured, not guessed: `appSize` INHERITS `invisible: [Iface]` from EffImpl's own entry
        // (EffImpl was scanned standalone and could not see Iface), so it reads the same in both arms and
        // the control below could never fail. The envelope's `coverage.uncovered` is scan-global and is
        // purely a statement about COVERAGE, which is the thing under test.
        func ledger(chaining: [String]) throws -> Set<String> {
            let tag = chaining.joined()
            let out = root.appendingPathComponent("a\(tag)")
            try? FileManager.default.removeItem(at: root.appendingPathComponent("a\(tag).App.Swift.json"))
            XCTAssertEqual(try run(bin, [app.path, "--out", out.path],
                                   env: ["CANDOR_DEPS": chaining.compactMap { reports[$0] }.joined(separator: " ")]).code, 0)
            let d = try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("a\(tag).App.Swift.json"))) as? [String: Any]
            let cov = (d?["coverage"] as? [String: Any])?["uncovered"] as? [[String: Any]] ?? []
            return Set(cov.compactMap { $0["name"] as? String })
        }
        let onlyForeign = try ledger(chaining: ["EffImpl"])
        XCTAssertTrue(onlyForeign.contains("Iface"),
                      "EffImpl's report names `Iface` only in a SYNTHETIC union entry's hash — it makes "
                      + "no claim about Iface's source, so Iface stays a disclosed blind spot; "
                      + "ledger was \(onlyForeign.sorted())")
        // THE NEAR-MISS: Iface's OWN report does grant that coverage, and the disclosure legitimately goes.
        let withOwner = try ledger(chaining: ["EffImpl", "Iface"])
        XCTAssertFalse(withOwner.contains("Iface"),
                       "CONTROL: chaining Iface's OWN report legitimately covers it, so the assertion "
                       + "above is not vacuous; ledger was \(withOwner.sorted())")
    }

    /// A SYNTHETIC UNION ENTRY IS NOT A UNIT, AND THE TWO GATE ROUTES MUST AGREE ABOUT THAT. Un-gating
    /// the union entries (obligation 2) put one in every report, and `gate --report` reads `functions`
    /// directly: measured before the filter, the supply-chain route reported THREE violations over a
    /// package the in-process route reports TWO for, the third naming `Ui.Backend.size` — a function
    /// with no body and an empty `loc`, which `fix-gate` is then asked to compute a hoist plan for.
    /// Nothing is lost by filtering: a union entry's effects are the union of rows already in the same
    /// report, so every effect is still charged to the function that really performs it. ONE ASSERTION,
    /// on AGREEMENT rather than on a count, because the property is that the two routes answer the same
    /// question the same way whatever the fixture grows into.
    func testTheTwoGateRoutesAgreeOverAReportCarryingUnionEntries() throws {
        let bin = try binaryURL()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r475-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Package.swift"), Self.manifest("Nest", deps: []))
        try write(root.appendingPathComponent("Sources/Nest/n.swift"), """
        import Foundation
        public protocol Backend { func size() -> Int }
        public struct Loud: Backend { public init() {}; public func size() -> Int { \(Self.SINK); return 0 } }
        public func termSize(_ b: Backend) -> Int { return b.size() }
        """)
        try write(root.appendingPathComponent("p.policy"), "deny Net\n")
        let out = root.appendingPathComponent("r")
        let inProcess = try run(bin, [root.path, "--policy", root.appendingPathComponent("p.policy").path,
                                      "--out", out.path])
        XCTAssertEqual(inProcess.code, 1, "CONTROL: the effectful conformer must violate `deny Net`")
        let report = root.appendingPathComponent("r.Nest.Swift.json")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any] ?? [:]
        XCTAssertTrue((doc["functions"] as? [[String: Any]] ?? []).contains { ($0["interfaceUnion"] as? Bool) == true },
                      "BASELINE: the report must actually CARRY a union entry, or this test measures nothing")

        let viaReport = try run(bin, ["gate", "--report", report.path,
                                      "--policy", root.appendingPathComponent("p.policy").path])
        XCTAssertEqual(viaReport.code, inProcess.code, "the two routes must agree on the verdict")
        func named(_ text: String) -> Set<String> {
            Set(text.split(separator: "\n").compactMap { line -> String? in
                guard line.contains("AS-EFF-006"), let a = line.firstIndex(of: "`") else { return nil }
                let rest = line[line.index(after: a)...]
                guard let b = rest.firstIndex(of: "`") else { return nil }
                return String(rest[..<b])
            })
        }
        XCTAssertEqual(named(viaReport.out + viaReport.err), named(inProcess.out + inProcess.err),
                       "the supply-chain route must name exactly the functions the in-process route "
                       + "names — a violation naming a synthetic union entry is a finding about a body "
                       + "that does not exist; via report: \(viaReport.out)\n\(viaReport.err)\n"
                       + "in process: \(inProcess.out)\n\(inProcess.err)")
        XCTAssertFalse(named(viaReport.out + viaReport.err).isEmpty, "…and both named something")
    }

    /// THE REPORT MUST BE THE SAME BYTES TWICE. Swift seeds Dictionary hashing PER PROCESS, and these
    /// union entries are built by iterating two dictionaries — a defect this engine has already shipped
    /// once (five runs of one binary over Alamofire gave five report hashes). Obligation 2 re-keys the
    /// entries by OWNING package, which is exactly the change that can make one member arrive under two
    /// keys and a `<` comparison non-total. candor-rust's port shipped precisely that and two runs gave
    /// different bytes, so this is checked rather than reasoned about — and ACROSS PROCESSES, because two
    /// scans inside one process share a hash seed and would pass while the defect was live.
    func testTheUnionEntriesAreByteDeterministicAcrossProcesses() throws {
        let bin = try binaryURL()
        let (root, order, _) = try render(iface: "impl", third: true, middle: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eff = order.first { $0.lastPathComponent == "effimpl" }!
        var seen = Set<String>()
        for i in 0..<5 {
            let out = root.appendingPathComponent("d\(i)")
            XCTAssertEqual(try run(bin, [eff.path, "--out", out.path]).code, 0)
            let bytes = try Data(contentsOf: root.appendingPathComponent("d\(i).EffImpl.Swift.json"))
            seen.insert(String(decoding: bytes, as: UTF8.self))
        }
        XCTAssertEqual(seen.count, 1,
                       "five scans of one package by one binary produced \(seen.count) distinct reports "
                       + "— a report that differs from ITSELF injects noise into every A/B and into "
                       + "`gains`, the product-facing supply-chain diff")
    }
}
