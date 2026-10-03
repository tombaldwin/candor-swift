import XCTest
import Foundation

/// SOUNDNESS R867 — A CALL ON A CHAINED DEPENDENCY'S NON-FINAL CLASS MUST CARRY THAT DEPENDENCY'S OWN
/// SUBCLASS OVERRIDES (SPEC §4 ⟨0.39⟩, conformance PART 94).
///
/// dep:  `open class BaseO { open func m() { <Fs> } }`, `final class SubO: BaseO { override func m() { <Env> } }`
/// app:  `viaTyped(_ b: BaseO) { b.m() }` — executed with a `SubO`, the program reads the environment.
///
/// v0.39.3 read `[Fs]` and `deny Env` exited 0, while the same source as ONE package reads `[Env, Fs]`.
/// THE MECHANISM, measured: the producer already publishes a class-override union entry (`conformers`
/// holds subclasses as well as protocol conformers) — but only while `BaseO.m`'s own body is PURE. The
/// emission loop skipped any hash a REAL entry claimed, so the moment the base did anything the overrides
/// vanished from the wire. (The row's lead, the hierarchy sidecar the consumer drops, is not the cause: a
/// pure `BaseO.m` chains correctly without it.) The union is now published BESIDE the real entry, under the
/// same hash, for a dynamically dispatched member, over the TRANSITIVE implementor set.
///
/// Every arm is a one-variable fixture whose program was BUILT AND RUN when the row was worked (the
/// override's effect observed or not observed), and the gate is asserted on the unit AND its caller.
/// `CANDOR_R867_OFF=1` restores v0.39.3 exactly; running this file under it is what shows the defect
/// arms can fail (the controls must pass either way).
final class DepSubclassOverrideProcessTests: XCTestCase {

    private static let ENV = "_ = ProcessInfo.processInfo.environment[\"HOME\"]"
    private static let FS = "_ = FileManager.default.fileExists(atPath: \"/tmp\")"

    private static func manifest(_ mod: String, deps: [String]) -> String {
        let d = deps.map { ".package(path: \"../\($0.lowercased())\")" }.joined(separator: ", ")
        let p = deps.map { ".product(name: \"\($0)\", package: \"\($0.lowercased())\")" }.joined(separator: ", ")
        return """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(mod)", products: [.library(name: "\(mod)", targets: ["\(mod)"])],
            dependencies: [\(d)], targets: [.target(name: "\(mod)", dependencies: [\(p)])])
        """
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fns(_ url: URL) throws -> [[String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (d?["functions"] as? [[String: Any]]) ?? []
    }

    private struct Scan {
        let root: URL, app: URL, reports: [String]
        let appRows: [String: [String: Any]]
        let depRows: [String: [[String: Any]]]      // per dependency module, every entry (duplicates kept)
    }

    /// Scan each dependency STANDALONE-but-chained-on-the-earlier-ones (in the order given), then the app.
    private func scan(deps: [(name: String, deps: [String], src: String)], app: [String: String]) throws -> Scan {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r867-\(UUID().uuidString)")
        var reports: [String] = []
        var depRows: [String: [[String: Any]]] = [:]
        for d in deps {
            let dir = root.appendingPathComponent(d.name.lowercased())
            try write(dir.appendingPathComponent("Package.swift"), Self.manifest(d.name, deps: d.deps))
            try write(dir.appendingPathComponent("Sources/\(d.name)/dep.swift"), d.src)
            let out = root.appendingPathComponent("rep-\(d.name)")
            let r = try ProcessHarness.run(bin, [dir.path, "--out", out.path],
                                           env: d.deps.isEmpty ? [:] : ["CANDOR_DEPS": reports.joined(separator: " ")])
            XCTAssertEqual(r.code, 0, "dependency scan \(d.name): \(r.err)")
            let rep = root.appendingPathComponent("rep-\(d.name).\(d.name).Swift.json")
            reports.append(rep.path)
            depRows[d.name] = try fns(rep)
        }
        let appDir = root.appendingPathComponent("app")
        try write(appDir.appendingPathComponent("Package.swift"), Self.manifest("App", deps: deps.map(\.name)))
        for (f, src) in app { try write(appDir.appendingPathComponent("Sources/App/\(f)"), src) }
        let out = root.appendingPathComponent("rep-app")
        let r = try ProcessHarness.run(bin, [appDir.path, "--out", out.path], env: ["CANDOR_DEPS": reports.joined(separator: " ")])
        XCTAssertEqual(r.code, 0, "consumer scan: \(r.err)")
        var rows: [String: [String: Any]] = [:]
        for e in try fns(root.appendingPathComponent("rep-app.App.Swift.json")) {
            if let n = e["fn"] as? String { rows[n] = e }
        }
        return Scan(root: root, app: appDir, reports: reports, appRows: rows, depRows: depRows)
    }

    /// The engine's own gate over the consumer, chained exactly as the report scan was.
    private func gate(_ s: Scan, _ policy: String) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = s.root.appendingPathComponent("p-\(UUID().uuidString).policy")
        try (policy + "\n").write(to: pol, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [s.app.path, "--out", s.root.appendingPathComponent("g").path,
                                             "--policy", pol.path],
                                       env: ["CANDOR_DEPS": s.reports.joined(separator: " ")])
        return r.code
    }

    private func inferred(_ s: Scan, _ fn: String) -> Set<String> {
        Set((s.appRows[fn]?["inferred"] as? [String]) ?? [])
    }

    // ── PART 94's fixture, swift side ────────────────────────────────────────────────────────────────
    private static func part94Dep(override: Bool) -> String {
        let sub = override
            ? "public final class SubO: BaseO {\n  public override init() { super.init() }\n  public override func m() { \(ENV) }\n}\n"
            : "public final class SubO: BaseO {\n  public override init() { super.init() }\n  public func n() { \(ENV) }\n}\n"
        return "import Foundation\nopen class BaseO {\n  public init() {}\n  open func m() { \(FS) }\n}\n" + sub
            + "public func mkO() -> BaseO { SubO() }\n"
    }
    private static let part94App = """
    import Dep
    public func viaTyped(_ b: BaseO) { b.m() }
    public func viaChain() { mkO().m() }
    public func viaBound() { let b = mkO(); b.m() }
    public func callTyped() { viaTyped(mkO()) }
    """

    func testPart94OverrideIsCarriedOnEverySpellingAndItsCaller() throws {
        let s = try scan(deps: [("Dep", [], Self.part94Dep(override: true))], app: ["a.swift": Self.part94App])
        defer { try? FileManager.default.removeItem(at: s.root) }
        // The producer leg, asserted: the real entry is UNCHANGED (its own body), and the union rides
        // beside it under the SAME hash. A green consumer row could otherwise come from anything.
        let rows = (s.depRows["Dep"] ?? []).filter { ($0["hash"] as? String) == "Dep#BaseO.m" }
        XCTAssertEqual(rows.count, 2, "a real entry AND a union entry under one hash; got \(rows)")
        let real = rows.first { ($0["interfaceUnion"] as? Bool) != true }
        let union = rows.first { ($0["interfaceUnion"] as? Bool) == true }
        XCTAssertEqual(real?["inferred"] as? [String], ["Fs"], "the base's own entry must not absorb its overrides")
        XCTAssertEqual(union?["inferred"] as? [String], ["Env"])
        for fn in ["viaTyped", "viaChain", "viaBound", "callTyped"] {
            XCTAssertTrue(inferred(s, fn).isSuperset(of: ["Env", "Fs"]),
                          "R867: \(fn) runs SubO.m (Env) — got \(s.appRows[fn] ?? [:])")
            XCTAssertEqual(try gate(s, "deny Env \(fn)"), 1, "deny Env \(fn) must fire")
            XCTAssertEqual(try gate(s, "deny Env Unknown \(fn)"), 1, "deny Env Unknown \(fn) must fire")
        }
    }

    func testPart94ControlSiblingMethodIsNotCharged() throws {
        let s = try scan(deps: [("Dep", [], Self.part94Dep(override: false))], app: ["a.swift": Self.part94App])
        defer { try? FileManager.default.removeItem(at: s.root) }
        for fn in ["viaTyped", "viaChain", "viaBound", "callTyped"] {
            XCTAssertEqual(inferred(s, fn), ["Fs"], "CONTROL: SubO does not override m — \(s.appRows[fn] ?? [:])")
            XCTAssertEqual(try gate(s, "deny Env Unknown \(fn)"), 0, "no effect and no hedge on \(fn)")
        }
        // …and the producer publishes nothing beside the real entry: byte-identical to v0.39.3 here.
        let rows = (s.depRows["Dep"] ?? []).filter { ($0["hash"] as? String) == "Dep#BaseO.m" }
        XCTAssertEqual(rows.count, 1, "no union entry when no override contributes; got \(rows)")
    }

    // ── siblings ────────────────────────────────────────────────────────────────────────────────────
    private func assertCarries(_ deps: [(name: String, deps: [String], src: String)], app: String,
                               _ effect: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let s = try scan(deps: deps, app: ["a.swift": app])
        defer { try? FileManager.default.removeItem(at: s.root) }
        for fn in ["f", "callF"] {
            XCTAssertTrue(inferred(s, fn).contains(effect), "\(fn) must carry \(effect): \(s.appRows[fn] ?? [:])",
                          file: file, line: line)
            XCTAssertEqual(try gate(s, "deny \(effect) \(fn)"), 1, "deny \(effect) \(fn)", file: file, line: line)
        }
    }
    private func assertNotCharged(_ deps: [(name: String, deps: [String], src: String)], app: String,
                                  fns: [String], _ effect: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let s = try scan(deps: deps, app: ["a.swift": app])
        defer { try? FileManager.default.removeItem(at: s.root) }
        for fn in fns {
            XCTAssertNotNil(s.appRows[fn], "the row exists (the base reads env) — \(fn)", file: file, line: line)
            XCTAssertFalse(inferred(s, fn).contains(effect), "\(fn) must NOT carry \(effect): \(s.appRows[fn] ?? [:])",
                           file: file, line: line)
            XCTAssertEqual(try gate(s, "deny \(effect) Unknown \(fn)"), 0, "deny \(effect) Unknown \(fn)",
                           file: file, line: line)
        }
    }

    /// `public` (not `open`) still permits subclassing INSIDE the defining module.
    func testPublicNonOpenClassOverrideInItsOwnModule() throws {
        try assertCarries([("Dep", [], """
            import Foundation
            public class P { public init() {}
              public func m() { \(Self.ENV) } }
            public final class PS: P { public override init() { super.init() }
              public override func m() { \(Self.FS) } }
            public func mk() -> P { PS() }
            """)], app: "import Dep\npublic func f(_ p: P) { p.m() }\npublic func callF() { f(mk()) }\n", "Fs")
    }

    /// Two levels down: `Leaf: Mid: B`, only `Leaf` overrides. `conformers[B]` holds `Mid` alone.
    func testMultiLevelOverride() throws {
        try assertCarries([("Dep", [], """
            import Foundation
            open class B { public init() {}
              open func m() { \(Self.ENV) } }
            open class Mid: B { public override init() { super.init() } }
            public final class Leaf: Mid { public override init() { super.init() }
              public override func m() { \(Self.FS) } }
            public func mk() -> B { Leaf() }
            """)], app: "import Dep\npublic func f(_ b: B) { b.m() }\npublic func callF() { f(mk()) }\n", "Fs")
    }

    /// `super.m()` INSIDE the dependency's override — the override's own body still runs.
    func testSuperCallInsideTheDependencyOverride() throws {
        try assertCarries([("Dep", [], """
            import Foundation
            open class B { public init() {}
              open func m() { \(Self.ENV) } }
            public final class S: B { public override init() { super.init() }
              public override func m() { super.m(); \(Self.FS) } }
            public func mk() -> B { S() }
            """)], app: "import Dep\npublic func f(_ b: B) { b.m() }\npublic func callF() { f(mk()) }\n", "Fs")
    }

    /// A class-constrained protocol whose REQUIREMENT has an effectful extension default and a conformer
    /// overriding it — the same suppression, on the protocol half (a real `PC.m` entry hid the union).
    func testProtocolRequirementWithDefaultAndOverridingConformer() throws {
        try assertCarries([("Dep", [], """
            import Foundation
            public protocol PC: AnyObject { func m() }
            extension PC { public func m() { \(Self.ENV) } }
            public final class CI: PC { public init() {}
              public func m() { \(Self.FS) } }
            public func mk() -> PC { CI() }
            """)], app: "import Dep\npublic func f(_ p: PC) { p.m() }\npublic func callF() { f(mk()) }\n", "Fs")
    }

    /// Two chained packages each declaring `BaseO`: one file per import, so the bare name is unambiguous in
    /// each. Only DepA's override writes — DepC's must not borrow it, and DepA's must carry it.
    func testTwoPackagesEachWithABaseO() throws {
        let deps: [(name: String, deps: [String], src: String)] = [
            ("DepA", [], """
                import Foundation
                open class BaseO { public init() {}
                  open func m() { \(Self.ENV) } }
                public final class SA: BaseO { public override init() { super.init() }
                  public override func m() { \(Self.FS) } }
                public func mkA() -> BaseO { SA() }
                """),
            ("DepC", [], """
                import Foundation
                open class BaseO { public init() {}
                  open func m() { \(Self.ENV) } }
                public final class SC: BaseO { public override init() { super.init() }
                  public override func m() { \(Self.ENV) } }
                public func mkC() -> BaseO { SC() }
                """)]
        let s = try scan(deps: deps, app: [
            "a.swift": "import DepA\npublic func fA(_ b: BaseO) { b.m() }\npublic func callFA() { fA(mkA()) }\n",
            "c.swift": "import DepC\npublic func fC(_ b: BaseO) { b.m() }\npublic func callFC() { fC(mkC()) }\n"])
        defer { try? FileManager.default.removeItem(at: s.root) }
        for fn in ["fA", "callFA"] {
            XCTAssertTrue(inferred(s, fn).contains("Fs"), "\(fn): \(s.appRows[fn] ?? [:])")
            XCTAssertEqual(try gate(s, "deny Fs \(fn)"), 1)
        }
        for fn in ["fC", "callFC"] {
            XCTAssertFalse(inferred(s, fn).contains("Fs"), "\(fn) must not borrow DepA's override: \(s.appRows[fn] ?? [:])")
            XCTAssertEqual(try gate(s, "deny Fs Unknown \(fn)"), 0)
        }
    }

    // ── controls: where no override can run, nothing may be added ──────────────────────────────────

    /// A `final` member on a non-final class cannot be overridden; a sibling's other method must not leak.
    func testFinalMethodIsNotUnioned() throws {
        try assertNotCharged([("Dep", [], """
            import Foundation
            open class B { public init() {}
              public final func m() { \(Self.ENV) }
              open func n() {} }
            public final class S: B { public override init() { super.init() }
              public override func n() { \(Self.FS) } }
            public func mk() -> B { S() }
            """)], app: "import Dep\npublic func f(_ b: B) { b.m() }\npublic func callF() { f(mk()) }\n",
            fns: ["f", "callF"], "Fs")
    }

    /// An EXTENSION-ONLY protocol member is statically dispatched to the extension: a conformer's
    /// same-named method never runs through `p.m()` (executed: its file is never written).
    func testExtensionOnlyProtocolMemberIsNotUnioned() throws {
        try assertNotCharged([("Dep", [], """
            import Foundation
            public protocol PE: AnyObject {}
            extension PE { public func m() { \(Self.ENV) } }
            public final class EI: PE { public init() {}
              public func m() { \(Self.FS) } }
            public func mk() -> PE { EI() }
            """)], app: "import Dep\npublic func f(_ p: PE) { p.m() }\npublic func callF() { f(mk()) }\n",
            fns: ["f", "callF"], "Fs")
    }

    /// A CONSUMER's own `super.m()` is statically dispatched to the dependency base's body: the dependency's
    /// sibling override never runs through it (executed).
    func testConsumerSuperCallDoesNotTakeTheOverrideUnion() throws {
        try assertNotCharged([("Dep", [], """
            import Foundation
            open class B { public init() {}
              open func m() { \(Self.ENV) } }
            public final class S: B { public override init() { super.init() }
              public override func m() { \(Self.FS) } }
            """)], app: """
            import Dep
            public final class Mine: B { public override init() { super.init() }
              public override func m() { super.m() } }
            public func g() { Mine().m() }
            """, fns: ["Mine.m", "g"], "Fs")
    }

    /// The union entry is not a unit, so it must not narrow the AS-EFF-005 prior of the real entry it sits
    /// beside (`[Fs] ∩ [Env] = []` reported the base's own unchanged `Fs` as GAINED).
    func testOwnReportAsBaselineRaisesNoGain() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let s = try scan(deps: [("Dep", [], Self.part94Dep(override: true))], app: ["a.swift": Self.part94App])
        defer { try? FileManager.default.removeItem(at: s.root) }
        let dep = s.root.appendingPathComponent("dep")
        let r = try ProcessHarness.run(bin, [dep.path, "--out", s.root.appendingPathComponent("again").path],
                                       env: ["CANDOR_BASELINE": s.reports[0]])
        XCTAssertEqual(r.code, 0, "an unchanged package against its own report: \(r.err)")
        XCTAssertFalse(r.err.contains("[AS-EFF-005]"), r.err)
    }

    /// The peek attribution keyed this run's own entries by `fn` with `Dictionary(uniqueKeysWithValues:)`,
    /// which TRAPS on the union entry published beside a real one. A scan with an excluded effectful file
    /// (so the peek runs) over a local class whose base AND override are both effectful must complete.
    func testPeekSurvivesAUnionEntryBesideItsRealEntry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r867-peek-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Package.swift"), """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "App", targets: [.executableTarget(name: "App")])
            """)
        try write(root.appendingPathComponent("Sources/App/main.swift"), """
            import Foundation
            class Doer { func work() { \(Self.FS) } }
            final class Sub: Doer { override func work() { \(Self.ENV) } }
            struct RunnerCaller { static func invoke(_ d: Doer) { d.work() } }
            RunnerCaller.invoke(Sub())
            """)
        try write(root.appendingPathComponent("Tests/AppTests/T.swift"), """
            import Foundation
            func evil() { _ = URLSession.shared.dataTask(with: URL(string: "https://e.example")!) }
            """)
        let pol = root.appendingPathComponent(".policy")
        try "deny Net\n".write(to: pol, atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("r")
        let r = try ProcessHarness.run(try ProcessHarness.binaryURL(for: Self.self),
                                       [root.path, "--policy", pol.path, "--out", out.path], cwd: root)
        XCTAssertTrue([0, 1, 2].contains(r.code), "the scan must not trap (exit \(r.code)): \(r.err)")
        let rows = try fns(root.appendingPathComponent("r.App.Swift.json")).filter { ($0["fn"] as? String) == "Doer.work" }
        XCTAssertEqual(rows.count, 2, "the fixture must actually carry the duplicate it exists to test: \(rows)")
    }

    /// THE IN-SCAN TWIN, found in the corpus A/B (RxSwift `Disposable`/`Sink`/`DebugSink`): a protocol
    /// dispatch edged only the types that SPELL `: D`, so a subclass's override of a conforming class's
    /// witness was missed by the package's own scan. Executed: `f(DebugSink())` writes the file.
    func testInScanProtocolDispatchReachesASubclassOverrideOfAConformer() throws {
        let root = try ProcessHarness.makePackage("""
            import Foundation
            public protocol D { func dispose() }
            open class Sink: D { public init() {}
              open func dispose() { } }
            public final class DebugSink: Sink { public override init() { super.init() }
              public override func dispose() { \(Self.FS) } }
            public func f(_ d: D) { d.dispose() }
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        let rows = try ProcessHarness.fns(ofJson: r.out)
        XCTAssertTrue(Set((rows["f"]?["inferred"] as? [String]) ?? []).contains("Fs"), "\(rows["f"] ?? [:])")
    }
}
