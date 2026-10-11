import XCTest
import Foundation

/// SOUNDNESS R1109 — A TYPE THAT CONFORMS TO A PROTOCOL ONLY THROUGH A REFINING PROTOCOL IS AN IMPLEMENTOR
/// OF IT. `struct Deep: Recurring` with `protocol Recurring: Inline` implements `Inline`'s requirements, so
/// `x.text` on an `x: any Inline` holding a `Deep` runs `Deep.text`. `conformers[Inline]` holds only the
/// types that SPELL `: Inline` — protocol inheritance is kept in `protocolSupers` on purpose — so `Deep`
/// was in no implementor set: not the in-scan protocol CHA, not the producer's `interfaceUnion` entry.
///
/// Found by the R1108 adjudication of R1105's `interfaceUnion` removals: swift-markdown
/// `InlineMarkup.plainText` lost `Unknown` in v0.40.5 because its only carriers were the types spelling
/// `: InlineMarkup` (SymbolLink, InlineHTML — correctly pure after R1105), while `Emphasis`, `Strong` and
/// `Strikethrough` (via `RecurringInlineMarkup`) still carry it. PRE-EXISTING, masked in v0.40.4 by the
/// direct conformers' over-charges: the chained consumer's `deny Fs` fell 1 → 0 between v0.40.4 and
/// v0.40.5 on the one-variable fixture below, whose `show(Deep())` was BUILT AND RUN and wrote its file.
///
/// Every dispatch arm here was executed when the row was worked (a marker per body): `viaAct(Deep())` runs
/// `Deep.act`, `viaAct(Deep2())` the refining protocol's DEFAULT `Mid2.act`, `viaConv`/`viaGeneric` run
/// `Deep.act`, `viaExtra(Deep())` runs the `Inline` EXTENSION, never `Deep.extra`, and `viaAct(Deep3())`
/// runs `Deep3.act`, never `Mid3`'s overridden default — the two controls.
/// `CANDOR_R1109_OFF=1` restores v0.40.5; running this file under it shows the defect arms fail.
final class RefiningProtocolConformerProcessTests: XCTestCase {

    private static let ENV = "_ = ProcessInfo.processInfo.environment[\"HOME\"]"
    private static let FS = "_ = FileManager.default.fileExists(atPath: \"/tmp\")"
    private static let RAND = "_ = Int.random(in: 0..<9)"
    private static let CLOCK = "_ = Date()"

    private static let dep = """
    import Foundation
    public protocol Conv { var text: String { get }; func act() }
    public protocol Inline: Conv {}
    public protocol Recurring: Inline {}
    public protocol Mid2: Inline {}
    extension Inline { public func extra() {} }
    extension Mid2 { public func act() { \(RAND) } }
    public protocol Mid3: Inline {}
    extension Mid3 { public func act() { \(CLOCK) } }
    public struct Deep3: Mid3 {
        public init() {}
        public var text: String { "deep3" }
        public func act() {}
    }
    public struct Leaf: Inline {
        public init() {}
        public var text: String { "leaf" }
        public func act() {}
    }
    public struct Deep: Recurring {
        public init() {}
        public var text: String { \(FS); return "deep" }
        public func act() { \(ENV) }
        public func extra() { \(CLOCK) }
    }
    public struct Deep2: Mid2 {
        public init() {}
        public var text: String { "deep2" }
    }
    """
    private static let callers = """
    public func viaText(_ x: any Inline) -> String { x.text }
    public func viaAct(_ x: any Inline) { x.act() }
    public func viaConv(_ x: any Conv) { x.act() }
    public func viaGeneric<T: Inline>(_ x: T) { x.act() }
    public func viaExtra(_ x: any Inline) { x.extra() }
    """

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

    private func rows(_ url: URL) throws -> [[String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return (d?["functions"] as? [[String: Any]]) ?? []
    }

    private struct Scan { let root: URL, app: URL, depsEnv: [String: String], appRows: [String: [String: Any]], depRows: [[String: Any]] }

    /// `chained`: the callers live in a CONSUMER package that chains the dependency's report.
    /// Otherwise they live in the dependency itself (one package, the in-scan CHA).
    private func scan(chained: Bool) throws -> Scan {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1109-\(UUID().uuidString)")
        let depDir = root.appendingPathComponent("dep")
        try write(depDir.appendingPathComponent("Package.swift"), Self.manifest("Dep", deps: []))
        try write(depDir.appendingPathComponent("Sources/Dep/dep.swift"), Self.dep + (chained ? "" : "\n" + Self.callers))
        let depOut = root.appendingPathComponent("rep-dep")
        let r = try ProcessHarness.run(bin, [depDir.path, "--out", depOut.path])
        XCTAssertEqual(r.code, 0, "dependency scan: \(r.err)")
        let depRep = root.appendingPathComponent("rep-dep.Dep.Swift.json")
        let depRows = try rows(depRep)
        guard chained else {
            var m: [String: [String: Any]] = [:]
            for e in depRows where (e["interfaceUnion"] as? Bool) != true { if let n = e["fn"] as? String { m[n] = e } }
            return Scan(root: root, app: depDir, depsEnv: [:], appRows: m, depRows: depRows)
        }
        let appDir = root.appendingPathComponent("app")
        try write(appDir.appendingPathComponent("Package.swift"), Self.manifest("App", deps: ["Dep"]))
        try write(appDir.appendingPathComponent("Sources/App/a.swift"), "import Dep\n" + Self.callers)
        let env = ["CANDOR_DEPS": depRep.path]
        let out = root.appendingPathComponent("rep-app")
        let a = try ProcessHarness.run(bin, [appDir.path, "--out", out.path], env: env)
        XCTAssertEqual(a.code, 0, "consumer scan: \(a.err)")
        var m: [String: [String: Any]] = [:]
        for e in try rows(root.appendingPathComponent("rep-app.App.Swift.json")) { if let n = e["fn"] as? String { m[n] = e } }
        return Scan(root: root, app: appDir, depsEnv: env, appRows: m, depRows: depRows)
    }

    private func gate(_ s: Scan, _ policy: String) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = s.root.appendingPathComponent("p-\(UUID().uuidString).policy")
        try (policy + "\n").write(to: pol, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [s.app.path, "--out", s.root.appendingPathComponent("g-\(UUID().uuidString)").path,
                                             "--policy", pol.path], env: s.depsEnv)
        return r.code
    }

    private func inferred(_ s: Scan, _ fn: String) -> Set<String> {
        Set((s.appRows[fn]?["inferred"] as? [String]) ?? [])
    }

    private func union(_ s: Scan, _ hash: String) -> Set<String>? {
        guard let e = s.depRows.first(where: { ($0["hash"] as? String) == hash && ($0["interfaceUnion"] as? Bool) == true })
        else { return nil }
        return Set((e["inferred"] as? [String]) ?? [])
    }

    private func assertDispatchArms(_ s: Scan, _ where_: String) throws {
        XCTAssertTrue(inferred(s, "viaText").contains("Fs"), "\(where_): viaText runs Deep.text — \(s.appRows["viaText"] ?? [:])")
        XCTAssertTrue(inferred(s, "viaAct").isSuperset(of: ["Env", "Rand"]),
                      "\(where_): viaAct runs Deep.act and Mid2's default — \(s.appRows["viaAct"] ?? [:])")
        XCTAssertTrue(inferred(s, "viaConv").isSuperset(of: ["Env", "Rand"]),
                      "\(where_): viaConv on the ROOT protocol, conformed to by nobody directly — \(s.appRows["viaConv"] ?? [:])")
        XCTAssertTrue(inferred(s, "viaGeneric").isSuperset(of: ["Env", "Rand"]),
                      "\(where_): the generic spelling — \(s.appRows["viaGeneric"] ?? [:])")
        XCTAssertEqual(try gate(s, "deny Fs viaText"), 1, "\(where_): deny Fs viaText must fire")
        XCTAssertEqual(try gate(s, "deny Env viaAct"), 1, "\(where_): deny Env viaAct must fire")
        XCTAssertEqual(try gate(s, "deny Rand viaAct"), 1, "\(where_): deny Rand viaAct must fire (refining default)")
        // CONTROL — `Mid3`'s default `act` is overridden by its only conformer, so it never runs through
        // `x.act()` (executed: `viaAct(Deep3())` runs `Deep3.act`); its `Clock` must not be charged.
        XCTAssertFalse(inferred(s, "viaAct").contains("Clock"), "\(where_): viaAct — \(s.appRows["viaAct"] ?? [:])")
        XCTAssertEqual(try gate(s, "deny Clock viaAct"), 0, "\(where_): deny Clock viaAct must pass")
        // CONTROL — an extension-only member is dispatched STATICALLY to `Inline`'s extension; `Deep.extra`
        // never runs through it (executed), so its `Clock` must not be charged.
        XCTAssertFalse(inferred(s, "viaExtra").contains("Clock"), "\(where_): viaExtra — \(s.appRows["viaExtra"] ?? [:])")
        XCTAssertEqual(try gate(s, "deny Clock viaExtra"), 0, "\(where_): deny Clock viaExtra must pass")
    }

    func testInScanDispatchReachesRefiningConformers() throws {
        let s = try scan(chained: false)
        defer { try? FileManager.default.removeItem(at: s.root) }
        try assertDispatchArms(s, "in-scan")
    }

    func testChainedConsumerReachesRefiningConformersThroughTheUnion() throws {
        let s = try scan(chained: true)
        defer { try? FileManager.default.removeItem(at: s.root) }
        // The producer leg: the union for each REQUIREMENT covers the refining conformers, including the
        // root protocol that nobody spells directly; the extension-only member gets no refining contributor.
        XCTAssertTrue(union(s, "Dep#Inline.text")?.contains("Fs") == true, "Dep#Inline.text: \(String(describing: union(s, "Dep#Inline.text")))")
        XCTAssertTrue(union(s, "Dep#Conv.text")?.contains("Fs") == true, "Dep#Conv.text: \(String(describing: union(s, "Dep#Conv.text")))")
        XCTAssertTrue(union(s, "Dep#Inline.act")?.isSuperset(of: ["Env", "Rand"]) == true,
                      "Dep#Inline.act: \(String(describing: union(s, "Dep#Inline.act")))")
        XCTAssertFalse(union(s, "Dep#Inline.extra")?.contains("Clock") == true,
                       "an extension-only member must not take a refining conformer's same-named method")
        XCTAssertFalse(union(s, "Dep#Inline.act")?.contains("Clock") == true,
                       "a refining protocol's default that every conformer overrides must not join the union")
        try assertDispatchArms(s, "chained")
    }
}
