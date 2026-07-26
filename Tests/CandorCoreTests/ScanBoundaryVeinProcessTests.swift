import XCTest
import Foundation

/// Process-level pins for the SCAN-BOUNDARY vein: code candor analyses SOUNDLY inside one package,
/// split across a package boundary with the dependency's report chained via `CANDOR_DEPS` — the
/// arrangement candor's own docs recommend — and the effect DISAPPEARS.
/// (candor-spec/SOUNDNESS-VEIN-crossing-the-scan-boundary.md; reproduced in all four engines.)
///
/// Every case here is checked against a ONE-PACKAGE CONTROL holding byte-identical function bodies,
/// so a failure is a boundary effect and never a general limitation. The gate is the point: the
/// under-report is not merely report-level, it flips `deny` from exit 1 (violation, correct) to
/// exit 0 (a false all-clear) on identical source.
final class ScanBoundaryVeinProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        let bundleDir = Bundle(for: ScanBoundaryVeinProcessTests.self).bundleURL.deletingLastPathComponent()
        let exe = bundleDir.appendingPathComponent("candor-swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: exe.path),
                          "candor-swift binary not built next to the test bundle (\(exe.path)) — run `swift build` first")
        return exe
    }

    private func run(_ binary: URL, _ args: [String], env: [String: String] = [:]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT"] {
            environment.removeValue(forKey: k)
        }
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), p.terminationStatus)
    }

    /// The dependency's source. `Entry.description` reaches Env, so EVERY implicit stringification of
    /// an `Entry` runs it; `Plain.description` is pure and is the no-fabrication control (a pure
    /// witness is absent from the dep report, so joining must add nothing).
    private static let depSource = """
    import Foundation

    public struct Entry: CustomStringConvertible {
        public init() {}
        public var description: String {
            let v = ProcessInfo.processInfo.environment["ENTRY_FMT"] ?? ""
            return "entry\\(v)"
        }
    }

    public struct Plain: CustomStringConvertible {
        public init() {}
        public var description: String { return "plain" }
    }

    public final class Guardian {
        public init() {}
        deinit { _ = ProcessInfo.processInfo.environment["GUARD_EXIT"] }
    }

    public final class Quiet {
        public init() {}
        deinit { }
    }

    public protocol Speaker { func speak() }

    // A PURE FACTORY returning the protocol. Pure fns are omitted from a report, so no return type ever
    // travels — the consumer cannot type the binding and never forms a key (half 1, row 2).
    public final class LibSpeaker: Speaker {
        public init() {}
        public func speak() { _ = FileManager.default.contents(atPath: "/lib-speak") }
    }
    public func makeSpeaker() -> Speaker { return LibSpeaker() }

    public final class LoudSpeaker: Speaker {
        public init() {}
        public func speak() { _ = FileManager.default.contents(atPath: "/loud") }
    }
    """

    /// The consumer's source, with `IMPORT` replaced by `import DepLib` (split) or nothing (control).
    /// Three stringification forms, all of which resolve through the same operand-type resolver:
    /// a declared-type operand, an inline construction, and a `[Entry]` element bound to `$0`.
    private static let appSource = """
    IMPORT
    public func describeTyped(_ e: Entry) -> String { return "got \\(e)" }
    public func describeInline() -> String { return "got \\(Entry())" }
    public func describeMapped(_ es: [Entry]) -> [String] { return es.map { "\\($0)" } }
    public func describePure(_ p: Plain) -> String { return "got \\(p)" }
    public func scoped() { let g = Guardian(); _ = g }
    public func scopedQuiet() { let q = Quiet(); _ = q }
    public func handOut() -> Guardian { let g = Guardian(); return g }

    // dispatch over an IMPORTED protocol whose conformer is declared HERE
    public final class AppSpeaker: Speaker {
        public init() {}
        public func speak() { _ = ProcessInfo.processInfo.environment["APP_SPEAK"] }
    }
    public func viaFactoryBoundReceiver() { let s = makeSpeaker(); s.speak() }
    public func viaImportedProtocol(_ s: Speaker) { s.speak() }
    public func viaImportedProtocolLocal() { let s: Speaker = AppSpeaker(); s.speak() }

    // ERASURE GUARD for the same rung. `some Speaker` is OPAQUE: the CALLER picks one concrete type, so
    // the conformers visible here are NOT its candidate witnesses and unioning them charges effects this
    // function cannot perform. `any Speaker` is an existential and genuinely may be any of them.
    // `typeName` collapses both spellings to `Speaker`, so without an explicit check `some` inherits the
    // existential's CHA — measured, this function was charged AppSpeaker's Env.
    public func viaOpaqueImported(_ s: some Speaker) { s.speak() }
    public func viaExistentialImported(_ s: any Speaker) { s.speak() }

    // FABRICATION GUARD for the same rung: `enum Rank: String` puts `String` in the inheritance
    // clause, so String LOOKS like a supertype with `Rank` as its conformer. A call on a plain
    // String-typed value must NOT dispatch into `Rank.lowercased`.
    public enum Rank: String {
        case high, low
        public func lowercased() -> String {
            _ = ProcessInfo.processInfo.environment["RANK"]
            return "x"
        }
    }
    public func plainString(_ s: String) -> String { return s.lowercased() }
    """

    /// (root, depDir, appDir, ctlDir) — the split pair plus the one-package control.
    private func makeFixture() throws -> (root: URL, dep: URL, app: URL, ctl: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-vein-\(UUID().uuidString)")
        let dep = root.appendingPathComponent("deplib")
        let app = root.appendingPathComponent("app")
        let ctl = root.appendingPathComponent("ctl")
        let fm = FileManager.default
        try fm.createDirectory(at: dep.appendingPathComponent("Sources/DepLib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: ctl.appendingPathComponent("Sources/Ctl"), withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "DepLib", targets: [.target(name: "DepLib")])
        """.write(to: dep.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.write(to: dep.appendingPathComponent("Sources/DepLib/Lib.swift"),
                                 atomically: true, encoding: .utf8)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [.package(path: "../deplib")],
            targets: [.target(name: "App", dependencies: [.product(name: "DepLib", package: "deplib")])]
        )
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "import DepLib")
            .write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)

        // the CONTROL: the same two sources in ONE package, so the analysis is fully in-scan
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Ctl", targets: [.target(name: "Ctl")])
        """.write(to: ctl.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.write(to: ctl.appendingPathComponent("Sources/Ctl/Lib.swift"),
                                 atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "")
            .write(to: ctl.appendingPathComponent("Sources/Ctl/App.swift"), atomically: true, encoding: .utf8)
        return (root, dep, app, ctl)
    }

    private func scanDep(_ bin: URL, _ dep: URL, root: URL) throws -> URL {
        let r = try run(bin, [dep.path, "--out", root.appendingPathComponent("dep-r").path])
        XCTAssertEqual(r.code, 0, "dep scan must succeed; stderr: \(r.err)")
        return root.appendingPathComponent("dep-r.DepLib.Swift.json")
    }

    private func fns(ofReport url: URL) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let name = f["fn"] as? String { out[name] = f }
        }
        return out
    }

    private func policy(_ root: URL, _ lines: [String]) throws -> URL {
        let p = root.appendingPathComponent("candor.policy")
        try lines.joined(separator: "\n").appending("\n").write(to: p, atomically: true, encoding: .utf8)
        return p
    }

    // ── IMPLICIT STRINGIFICATION of a DEPENDENCY type ─────────────────────────────────────────────
    // `"\(e)"` where `e: DepLib.Entry` runs `Entry.description`, which reaches Env. The dep's report
    // records that accessor under `DepLib#Entry.description` — the join key this engine already
    // derives elsewhere — but both stringification rungs were LOCAL-only (`localTypes` for the
    // concrete witness, `localProtocols`/`conformers` for the CHA one), so the site recorded NOTHING,
    // not even Unknown, and the consumer certified clean.
    func testDependencyStringificationReachesItsWitness() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        // the one-package CONTROL gets all three forms right — that is what the split must match
        XCTAssertEqual(try run(bin, [ctl.path, "--out", root.appendingPathComponent("ctl-r").path]).code, 0)
        let ctlFns = try fns(ofReport: root.appendingPathComponent("ctl-r.Ctl.Swift.json"))
        for fn in ["describeTyped", "describeInline", "describeMapped"] {
            XCTAssertEqual(ctlFns[fn]?["inferred"] as? [String], ["Env"],
                           "CONTROL: \(fn) must reach Env in one package; got \(ctlFns[fn] ?? [:])")
        }

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0, "chained app scan must succeed; stderr: \(r.err)")
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        for fn in ["describeTyped", "describeInline", "describeMapped"] {
            XCTAssertEqual(by[fn]?["inferred"] as? [String], ["Env"],
                           "\(fn) must reach the dep's `description` across the scan boundary; got \(by[fn] ?? [:])")
        }
    }

    // NO FABRICATION: a dep type whose `description` is PURE is omitted from the dep report (silence
    // is the purity claim, §2 rule 3), so the same join must add exactly nothing.
    func testPureDependencyWitnessStaysPure() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertNil(by["describePure"],
                     "interpolating a dep type with a PURE description must stay pure; got \(by["describePure"] ?? [:])")
    }

    // The join is gated on the FILE's imports and on a package a loaded report COVERS: an app that
    // does not import the dep resolves to nothing, exactly as before — the joins-never-guess rule.
    func testStringificationJoinRequiresTheImport() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        // drop the import: the same source, now naming a type from no covered package in scope
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "")
            .write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertNil(by["describeTyped"], "no import of the covered package → no join; got \(by["describeTyped"] ?? [:])")
    }

    // THE GATE — the consequential form. `deny Env` on the three stringifying functions must fail
    // the SAME way in both arrangements; before the fix the chained scan PASSED (a false all-clear).
    func testDenyGateDoesNotFlipAcrossTheBoundary() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let pol = try policy(root, ["deny Env Unknown describeTyped",
                                    "deny Env Unknown describeInline",
                                    "deny Env Unknown describeMapped"])

        let control = try run(bin, [ctl.path, "--policy", pol.path,
                                    "--out", root.appendingPathComponent("ctl-g").path])
        XCTAssertEqual(control.code, 1, "CONTROL: one package must fail the deny gate; stderr: \(control.err)")

        let split = try run(bin, [app.path, "--policy", pol.path,
                                  "--out", root.appendingPathComponent("app-g").path],
                            env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(split.code, 1,
                       "split + chained must fail the SAME gate — exit 0 here is the false all-clear; stderr: \(split.err)")
    }

    // ── DEINIT GLUE over a DEPENDENCY class (the R33 mechanism across the boundary) ───────────────
    // `let g = Guardian()` runs `Guardian.deinit` at scope exit — deterministic under ARC for a
    // non-escaping local, and modeled inside the scan since R33. The edge was gated on
    // `localTypes.contains(t)`, so a dep class whose `deinit` is effectful read silent-pure with the
    // dep's report chained, even though that report records `DepLib#Guardian.deinit`.
    func testDependencyDeinitGlueChargesTheScope() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        XCTAssertEqual(try run(bin, [ctl.path, "--out", root.appendingPathComponent("ctl-r").path]).code, 0)
        let ctlFns = try fns(ofReport: root.appendingPathComponent("ctl-r.Ctl.Swift.json"))
        XCTAssertEqual(ctlFns["scoped"]?["inferred"] as? [String], ["Env"],
                       "CONTROL: the deinit glue must charge the scope in one package; got \(ctlFns["scoped"] ?? [:])")

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0, "chained app scan must succeed; stderr: \(r.err)")
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertEqual(by["scoped"]?["inferred"] as? [String], ["Env"],
                       "a dep class's effectful deinit must charge its holder; got \(by["scoped"] ?? [:])")
        // the two no-fabrication controls, both carried over from the in-scan rung:
        XCTAssertNil(by["scopedQuiet"], "a dep class with a PURE deinit has no report entry — nothing joins")
        XCTAssertNil(by["handOut"], "a RETURNED (escaping) value is not charged to the constructing scope")
    }

    func testDeinitGateDoesNotFlipAcrossTheBoundary() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let pol = try policy(root, ["deny Env Unknown scoped"])
        let control = try run(bin, [ctl.path, "--policy", pol.path,
                                    "--out", root.appendingPathComponent("ctl-g").path])
        XCTAssertEqual(control.code, 1, "CONTROL: one package must fail the deny gate; stderr: \(control.err)")
        let split = try run(bin, [app.path, "--policy", pol.path,
                                  "--out", root.appendingPathComponent("app-g").path],
                            env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(split.code, 1,
                       "split + chained must fail the SAME gate — exit 0 here is the false all-clear; stderr: \(split.err)")
    }

    // ── DISPATCH OVER AN IMPORTED PROTOCOL WHOSE CONFORMER IS LOCAL ───────────────────────────────
    // `s.speak()` where `s: DepLib.Speaker` and `final class AppSpeaker: Speaker` is declared HERE.
    // `protocolMethods`/`protoParams` are local-only, so `s` was never seen as protocol-typed and NO
    // dispatch was recorded — the call read silent-pure even though the witness that runs is a project
    // unit candor analysed correctly. This half needs no dep report: the conformance declaration is
    // ours, and `conformers` already records it.
    func testImportedProtocolDispatchesOverLocalConformers() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        // CONTROL: in ONE package both conformers are visible, so the dispatch unions Env (the app's)
        // and Fs (the dep's).
        XCTAssertEqual(try run(bin, [ctl.path, "--out", root.appendingPathComponent("ctl-r").path]).code, 0)
        let ctlFns = try fns(ofReport: root.appendingPathComponent("ctl-r.Ctl.Swift.json"))
        XCTAssertEqual(Set(ctlFns["viaImportedProtocol"]?["inferred"] as? [String] ?? []), ["Env", "Fs"],
                       "CONTROL: one package unions both conformers; got \(ctlFns["viaImportedProtocol"] ?? [:])")

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        for fn in ["viaImportedProtocol", "viaImportedProtocolLocal"] {
            XCTAssertTrue(Set(by[fn]?["inferred"] as? [String] ?? []).contains("Env"),
                          "\(fn) must reach the LOCAL conformer's witness; got \(by[fn] ?? [:])")
        }
        // RESIDUAL, pinned not repaired: the DEPENDENCY's own conformer (`LoudSpeaker`, Fs) is not
        // reachable from a plain dep report — it needs the protocol-CHA union entries a `--workspace`
        // child scan emits. The local half is recovered; the dep half stays out.
        XCTAssertFalse(Set(by["viaImportedProtocol"]?["inferred"] as? [String] ?? []).contains("Fs"),
                       "a plain dep report carries no conformer hierarchy — nothing may be invented for it")

        // ERASURE. `any Speaker` keeps the recovery; `some Speaker` must NOT get it — the caller
        // monomorphizes it, so charging every conformer's effect is a fabrication, not a conservative
        // over-approximation. Both are spelled `Speaker` after type-name resolution, which is exactly why
        // this needs asserting rather than assuming.
        // COULD-NOT-FORM-A-KEY (half 1, row 2). `makeSpeaker` is pure, so it is omitted from the dep's
        // report and no return type travels; the binding is untyped and NO key is formed. The report's
        // silence answers a question that was never asked, so this must DISCLOSE, not read pure.
        XCTAssertTrue(Set(by["viaFactoryBoundReceiver"]?["inferred"] as? [String] ?? []).contains("Unknown"),
                      "an untyped receiver from a CHAINED package must disclose; got \(by["viaFactoryBoundReceiver"] ?? [:])")

        XCTAssertTrue(Set(by["viaExistentialImported"]?["inferred"] as? [String] ?? []).contains("Env"),
                      "an EXISTENTIAL `any P` receiver keeps the dispatch; got \(by["viaExistentialImported"] ?? [:])")
        XCTAssertFalse(Set(by["viaOpaqueImported"]?["inferred"] as? [String] ?? []).contains("Env"),
                       "an OPAQUE `some P` receiver is monomorphized BY THE CALLER — dispatching it over "
                       + "local conformers FABRICATES; got \(by["viaOpaqueImported"] ?? [:])")
    }

    // The recovery is chaining-INDEPENDENT: the conformance is declared in the app, so it holds with
    // no dep report at all.
    func testImportedProtocolDispatchNeedsNoDepReport() throws {
        let bin = try binaryURL()
        let (root, _, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertTrue(Set(by["viaImportedProtocol"]?["inferred"] as? [String] ?? []).contains("Env"),
                      "unchained too; got \(by["viaImportedProtocol"] ?? [:])")
    }

    // THE FABRICATION MIRROR for that rung. Swift's inheritance clause is overloaded: `enum Rank: String`
    // records `String` as a supertype with `Rank` as its conformer, so an unguarded CHA would send every
    // call on a String-typed value into `Rank`'s methods. `plainString` must stay pure in EVERY mode.
    func testRawValueBaseDoesNotDispatchIntoItsEnums() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        for (label, args, env) in [
            ("control", [ctl.path, "--out", root.appendingPathComponent("ctl-r").path], [String: String]()),
            ("unchained", [app.path, "--out", root.appendingPathComponent("app-u").path], [:]),
            ("chained", [app.path, "--out", root.appendingPathComponent("app-c").path],
             ["CANDOR_DEPS": depReport.path]),
        ] {
            XCTAssertEqual(try run(bin, args, env: env).code, 0, "\(label) scan must succeed")
            let out = args[2]
            let suffix = label == "control" ? ".Ctl.Swift.json" : ".App.Swift.json"
            let by = try fns(ofReport: URL(fileURLWithPath: out + suffix))
            XCTAssertNil(by["plainString"],
                         "\(label): `s.lowercased()` on a String must not dispatch into `enum Rank: String`; got \(by["plainString"] ?? [:])")
        }
    }

    // A STALE dep report is not trusted at this join either (§2.1): the witness reads Unknown with
    // its origin named, never a stale effect claim — and `deny Env Unknown` still fails closed.
    func testStaleDepMakesTheWitnessUnknownNotPure() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let stale = root.appendingPathComponent("dep-stale.json")
        var d = try JSONSerialization.jsonObject(with: Data(contentsOf: depReport)) as! [String: Any]
        var candor = d["candor"] as! [String: Any]
        candor["version"] = "candor-doctored-0.0.0"
        d["candor"] = candor
        try JSONSerialization.data(withJSONObject: d).write(to: stale)

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": stale.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        let inferred = Set(by["describeTyped"]?["inferred"] as? [String] ?? [])
        XCTAssertTrue(inferred.contains("Unknown"), "a stale dep's witness must read Unknown; got \(inferred)")
        XCTAssertFalse(inferred.contains("Env"), "never a stale effect claim")
        XCTAssertEqual(by["describeTyped"]?["unknownWhy"] as? [String], ["dep-stale:DepLib"],
                       "the Unknown must name its origin (spec 0.6 unknownWhy)")
    }
}
