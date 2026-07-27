import XCTest
import Foundation

/// THE ⟨0.19⟩ REASON CLASS MUST SURVIVE THE SCAN BOUNDARY.
///
/// `deny E Unknown[<class>]` is how the Unknown ratchet is adopted on real code: you narrow the gate to
/// the hole classes you care about rather than denying every Unknown at once. Two defects made that
/// narrowed form read GREEN on candor-swift where the same code unsplit reads red — and each is invisible
/// unless you compare the arms, because bare `deny Unknown` fires throughout.
///
///  1. `reasonClass` tested `w == "dynamicmemberlookup"` while the engine emits `kind:detail`, so
///     `dynamicMemberLookup:Dyn.anything` — candor-swift's ONLY reflect-class producer — projected to
///     `unresolved`. `Unknown[reflect]` was silently unsatisfiable, even single-tree.
///  2. A chained dep's Unknown arrived carrying only `dep:<hash>`, which projects to `unresolved`, so the
///     dependency's own reason never crossed the join. candor-java found the same gap (`6ab26e4`) and
///     needed no format rung: the dependency's report already carries `unknownWhy`.
///
/// Tested over a THREE-package chain (A -> B -> C, C originating the Unknown), because a two-package
/// fixture only exercises the first hop.
final class ReasonClassAcrossBoundaryProcessTests: XCTestCase {

    private struct Chain { let root: URL, a: URL, b: URL, c: URL, single: URL, depsC: URL, depsB: URL }

    private func makeChain() throws -> Chain {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-rc-\(UUID().uuidString)")
        func pkg(_ name: String, _ src: String) throws -> URL {
            let d = root.appendingPathComponent(name)
            try fm.createDirectory(at: d.appendingPathComponent("Sources/\(name)"), withIntermediateDirectories: true)
            try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "\(name)", targets: [.target(name: "\(name)")])
            """.write(to: d.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try src.write(to: d.appendingPathComponent("Sources/\(name)/S.swift"), atomically: true, encoding: .utf8)
            return d
        }
        // C originates a REFLECT-class Unknown beside a Net effect.
        let cBody = """
        @dynamicMemberLookup
        public struct Dyn { public subscript(dynamicMember m: String) -> String { m } }
        public func cReflect(_ d: Dyn) {
            _ = d.anything
            let t = URLSession.shared.dataTask(with: "https://c.example.com/x") { _, _, _ in }
            t.resume()
        }
        """
        let c = try pkg("PkgC", "import Foundation\n" + cBody)
        let b = try pkg("PkgB", "import PkgC\npublic func bMiddle(_ d: Dyn) { cReflect(d) }\n")
        let a = try pkg("PkgA", "import PkgB\npublic func aTop(_ d: Dyn) { bMiddle(d) }\n")
        // the SINGLE-TREE control: the same three bodies in one package
        let single = try pkg("One", "import Foundation\n" + cBody
            + "\npublic func bMiddle(_ d: Dyn) { cReflect(d) }\npublic func aTop(_ d: Dyn) { bMiddle(d) }\n")
        for d in ["depsC", "depsB"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        return Chain(root: root, a: a, b: b, c: c, single: single,
                     depsC: root.appendingPathComponent("depsC"), depsB: root.appendingPathComponent("depsB"))
    }

    /// Scan each link, feeding the previous link's report forward. Returns the three reports' fn maps.
    private func runChain(_ bin: URL, _ ch: Chain) throws -> (b: [String: [String: Any]], a: [String: [String: Any]]) {
        func fns(_ p: URL) throws -> [String: [String: Any]] {
            let d = try JSONSerialization.jsonObject(with: Data(contentsOf: p)) as? [String: Any]
            var by: [String: [String: Any]] = [:]
            for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
                if let n = f["fn"] as? String { by[n] = f }
            }
            return by
        }
        XCTAssertEqual(try ProcessHarness.run(bin, [ch.c.path, "--out", ch.root.appendingPathComponent("rC").path]).code, 0)
        try FileManager.default.copyItem(at: ch.root.appendingPathComponent("rC.PkgC.Swift.json"),
                                         to: ch.depsC.appendingPathComponent("c.json"))
        XCTAssertEqual(try ProcessHarness.run(bin, [ch.b.path, "--out", ch.root.appendingPathComponent("rB").path],
                                             env: ["CANDOR_DEPS": ch.depsC.path]).code, 0)
        try FileManager.default.copyItem(at: ch.root.appendingPathComponent("rB.PkgB.Swift.json"),
                                         to: ch.depsB.appendingPathComponent("b.json"))
        XCTAssertEqual(try ProcessHarness.run(bin, [ch.a.path, "--out", ch.root.appendingPathComponent("rA").path],
                                             env: ["CANDOR_DEPS": ch.depsB.path]).code, 0)
        return (try fns(ch.root.appendingPathComponent("rB.PkgB.Swift.json")),
                try fns(ch.root.appendingPathComponent("rA.PkgA.Swift.json")))
    }

    private func gate(_ bin: URL, _ ch: Chain, _ target: URL, _ policy: String, deps: URL?) throws -> Int32 {
        let p = ch.root.appendingPathComponent("p.candor")
        try policy.write(to: p, atomically: true, encoding: .utf8)
        var env: [String: String] = [:]
        if let deps { env["CANDOR_DEPS"] = deps.path }
        return try ProcessHarness.run(bin, [target.path, "--policy", p.path], env: env).code
    }

    /// `Unknown[reflect]` must bite on the same code single-tree, one hop chained, and two hops chained;
    /// `Unknown[native]` must bite in none of them, or the filter is not filtering.
    func testTheReasonClassSurvivesTwoChainHops() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let ch = try makeChain()
        defer { try? FileManager.default.removeItem(at: ch.root) }
        let (b, a) = try runChain(bin, ch)

        XCTAssertEqual(b["bMiddle"]?["unknownWhy"] as? [String], ["dynamicMemberLookup:Dyn.anything"],
                       "hop 1: the dependency's own reason crosses the join")
        XCTAssertEqual(a["aTop"]?["unknownWhy"] as? [String], ["dynamicMemberLookup:Dyn.anything"],
                       "hop 2: and again, through a middle package that only inherited it")

        for (label, target, deps) in [("single-tree", ch.single, Optional<URL>.none),
                                      ("1 hop", ch.b, ch.depsC), ("2 hops", ch.a, ch.depsB)] {
            XCTAssertEqual(try gate(bin, ch, target, "deny Unknown[reflect]\n", deps: deps), 1,
                           "\(label): deny Unknown[reflect] must bite")
            XCTAssertEqual(try gate(bin, ch, target, "deny Unknown[native]\n", deps: deps), 0,
                           "\(label): deny Unknown[native] must NOT bite — or the class filter is inert")
            // the chained arms must not acquire a class the single-tree control does not have
            XCTAssertEqual(try gate(bin, ch, target, "deny Unknown[unresolved]\n", deps: deps), 0,
                           "\(label): a classified hole must not also read `unresolved`")
        }
    }

    /// THE SECOND DIRECTION. Where the dependency classified NOTHING — its report carries `Unknown` with
    /// no `unknownWhy`, which SPEC §4 permits for a purely inherited Unknown — the join must fall back to
    /// `dep:<hash>` and the conservative `unresolved`, never to silence and never to a guessed class.
    func testAnUnclassifiedDepFallsBackToUnresolved() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let ch = try makeChain()
        defer { try? FileManager.default.removeItem(at: ch.root) }
        // the producing version has to match this build, or §2.1 staleness answers instead of this arm
        let v = try ProcessHarness.run(bin, ["--version"]).out
            .split(separator: "\n")[0].split(separator: " ")[1]
        let deps = ch.root.appendingPathComponent("depsPlain")
        try FileManager.default.createDirectory(at: deps, withIntermediateDirectories: true)
        let report: [String: Any] = [
            "candor": ["version": "candor-swift-\(v)", "spec": "0.23", "toolchain": "swiftsyntax"],
            "package": "PkgC",
            "functions": [["fn": "cReflect", "hash": "PkgC#cReflect", "inferred": ["Net", "Unknown"]]],
        ]
        try JSONSerialization.data(withJSONObject: report).write(to: deps.appendingPathComponent("c.json"))

        let r = try ProcessHarness.run(bin, [ch.b.path, "--out", ch.root.appendingPathComponent("rB2").path],
                                       env: ["CANDOR_DEPS": deps.path])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: ch.root.appendingPathComponent("rB2.PkgB.Swift.json"))) as! [String: Any]
        let fn = ((d["functions"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
            .first { $0["fn"] as? String == "bMiddle" }
        XCTAssertEqual(fn?["unknownWhy"] as? [String], ["dep:PkgC#cReflect"],
                       "with nothing to carry, the provenance pointer stands")
        XCTAssertEqual(try gate(bin, ch, ch.b, "deny Unknown[unresolved]\n", deps: deps), 1,
                       "an unclassified hole reads `unresolved` — the spec's conservative projection")
        XCTAssertEqual(try gate(bin, ch, ch.b, "deny Unknown[reflect]\n", deps: deps), 0,
                       "…and never a guessed class")
    }
}
