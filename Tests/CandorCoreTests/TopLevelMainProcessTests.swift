import XCTest
import Foundation

/// End-to-end pins for the synthetic `<main>` unit (SPEC §2 `unitKind: "initializer"`) that captures a
/// file's TOP-LEVEL executable statements. Swift allows bare executable statements directly at file scope
/// in `main.swift` / script files; before this they were collected by nothing (they belong to no
/// declaration), so a file whose only effect lived at the top level scanned as an EMPTY report — a false
/// "pure" verdict (the cardinal sin, top-level edition). These are properties of the whole scan, so they
/// are pinned at the process layer (mirrors LlmProcessTests / KappaFamiliesProcessTests).
final class TopLevelMainProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: TopLevelMainProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    // ── a top-level effectful statement mints a `<main>` unit with unitKind "initializer" ──────────────
    func testTopLevelEffectMintsMainInitializerUnit() throws {
        let by = try scan("""
        import Foundation
        let _ = URLSession.shared.dataTask(with: "https://api.openai.com/x") { _, _, _ in }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Llm", "Net"],
                       "a top-level model-reaching statement must surface on `<main>` — a false-pure verdict is the cardinal sin")
        XCTAssertEqual(by["<main>"]?["unitKind"] as? String, "initializer",
                       "the top-level unit carries unitKind \"initializer\" (SPEC §2; the JVM engine's <clinit> uses the same kind)")
        XCTAssertEqual(by["<main>"]?["fn"] as? String, "<main>", "the wire name must be exactly <main>")
    }

    // a wildcard `let _ = try? String(contentsOfFile:)` binds no name (no lazy global unit) → `<main>` [Fs].
    func testTopLevelWildcardBindingIsCaptured() throws {
        let by = try scan("""
        import Foundation
        let _ = try? String(contentsOfFile: "/etc/x")
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Fs"],
                       "a top-level wildcard binding runs its initializer for effect — captured on <main>")
    }

    // a top-level CALL reaches its callee TRANSITIVELY (edge), not by inlining the callee's body as direct.
    func testTopLevelCallReachesCalleeTransitively() throws {
        let by = try scan("""
        import Foundation
        func work() { _ = URLSession.shared.dataTask(with: "https://api.openai.com/x") { _, _, _ in } }
        work()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "work"), ["Llm", "Net"], "the named function is unchanged")
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Llm", "Net"],
                       "the top-level `work()` call makes work's effects transitively visible on <main>")
        // transitive, NOT inlined: <main> edges to work and carries NO direct effect of its own.
        XCTAssertEqual((by["<main>"]?["direct"] as? [String])?.sorted() ?? [], [],
                       "the callee's effects reach <main> via the call edge, not as <main>'s direct effects")
        XCTAssertEqual((by["<main>"]?["calls"] as? [String])?.sorted(), ["work"])
    }

    // a plain LIBRARY file — imports + declarations, no top-level executable statements — gains NO `<main>`.
    func testPureLibraryFileGetsNoMainUnit() throws {
        let by = try scan("""
        import Foundation
        struct S { func f() {} }
        func g() -> Int { 1 }
        """)
        XCTAssertNil(by["<main>"], "a file with no top-level executable statements must not gain a <main> unit (no flood)")
    }

    // a NAMED top-level global is still its own first-touch unit, NOT folded into `<main>`.
    func testNamedGlobalIsNotFoldedIntoMain() throws {
        let by = try scan("""
        import Foundation
        let token = try? String(contentsOfFile: "/etc/t")
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "token"), ["Fs"], "the named global keeps its own lazy unit")
        XCTAssertNil(by["<main>"], "a named global-var decl is not a bare top-level statement — no <main>")
    }

    // A `let` inside a TOP-LEVEL BLOCK is a LOCAL of that block, not a module global. Swift allows
    // executable statements at file scope, so such a binding is lexically outside any type — and was
    // registered as a global, minting a unit named after a local. candor-swift's own main.swift has
    // `let pipe = Pipe()` three blocks deep inside `if wantWorkspace { for … { … } }`, and its report
    // carried a global `pipe` with Ipc that no module-level `pipe` exists to justify. Global units are
    // keyed by bare name, so a phantom is also a magnet: any bare read of that name in the module
    // resolves to it. The block's effects belong to `<main>`, which still carries them.
    func testBindingInsideTopLevelBlockIsNotAGlobal() throws {
        let by = try scan("""
        import Foundation
        if CommandLine.arguments.count > 1 {
            let handle = try? String(contentsOfFile: "/etc/t")
            print(handle ?? "")
        }
        """)
        XCTAssertNil(by["handle"], "a binding inside a top-level block is a LOCAL — it must not mint a global unit")
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Fs"], "its effect is the top level's, and is still charged there")
    }

    // READING A MEMBER OF A GLOBAL forces its initializer just as a bare read does — `cfg.count` is a read
    // of `cfg`. The `DeclReferenceExpr` visitor skipped the whole member-access form, so an effectful
    // global stayed silent at every reader that touched a member OF it, which is the commoner shape:
    // candor-swift's own `analysis.allFns` and swift-syntax's `SYNTAX_NODES.map { … }` both read this way.
    // (candor-spec SOUNDNESS-VEIN-initializer-edge.md — the swift sibling of candor-ts's import edge.)
    // The exclusions that keep it exact are pinned below: the member NAME is not a read of a global, and a
    // bare `self` property is not a global at all.
    func testReadingAMemberOfAGlobalForcesItsInitializer() throws {
        let by = try scan("""
        import Foundation
        let cfg = (try? String(contentsOfFile: "/etc/c")) ?? ""
        func member() -> Int { cfg.count }
        func bare() -> String { cfg }
        struct Holder {
            var cfg: [String] = []
            // `self.cfg` — an instance property that happens to share the global's name. Appending to it
            // must NOT charge the global's Fs (it did: a whole engine's methods lit up this way).
            mutating func add(_ s: String) { cfg.append(s) }
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "member"), ["Fs"],
                       "reading `cfg.count` forces cfg's initializer — it read silent-pure before: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "bare"), ["Fs"], "the bare read still works: \(by)")
        XCTAssertNil(by["Holder.add"],
                     "a same-named INSTANCE property is not the global — appending to self.cfg is pure: \(by)")
    }

    // a TUPLE-destructured global (`let (a, b) = effectfulInit()`) binds names so it is NOT a <main>
    // statement, but the IdentifierPattern-only unit guard used to DROP its initializer effect (a false-
    // pure global — the cardinal sin). Each bound name now carries the shared initializer's effect.
    func testTupleDestructuredGlobalIsNotDropped() throws {
        let by = try scan("""
        import Foundation
        let (a, b) = ((try? String(contentsOfFile: "/etc/x")), 1)
        func use() { _ = a; _ = b }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "a"), ["Fs"], "tuple element `a` carries the initializer effect")
        XCTAssertEqual(ProcessHarness.inferred(by, "b"), ["Fs"], "tuple element `b` carries the initializer effect (first-touch over-approximation is sound)")
        XCTAssertEqual(ProcessHarness.inferred(by, "use"), ["Fs"], "a reader of a tuple element inherits the effect")
    }

    // the type-member sibling: `static let (p, q) = effectfulInit()` inside a type — a static tuple
    // property is a first-touch init like the global, and used to fall through the same guard.
    func testStaticMemberTupleIsNotDropped() throws {
        let by = try scan("""
        import Foundation
        struct S { static let (p, q) = ((try? String(contentsOfFile: "/etc/x")), 1) }
        func u() { _ = S.p }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "S.p"), ["Fs"], "static tuple member `p` carries the initializer effect")
        XCTAssertEqual(ProcessHarness.inferred(by, "S.q"), ["Fs"], "static tuple member `q` carries the initializer effect")
    }
}
