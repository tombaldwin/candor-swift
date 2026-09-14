import XCTest
import Foundation

/// SOUNDNESS R415 — **`execvP`'s SEARCH PATH WAS PUBLISHED AS THE COMMAND, AND `allow Exec` CERTIFIED A
/// CALLER-CONTROLLED ONE.**
///
/// `locatorLabelsForFree` declares which argument holds the locator; a name absent from it falls back to
/// `firstStringLiteral`, a scan of the WHOLE argument list. `execvP(file, search_path, argv)` takes a
/// `const char *` as argument 1, so the fallback found the search path and published it.
///
/// MEASURED, with `deny Exec` calibrated to exit 1 on the same file first:
///
///     public func run(_ file: String) { _ = execvP(file, "/usr/bin:/bin", &argv) }
///     → cmds: ["/usr/bin:/bin"], incomplete: none,  `allow Exec /usr/bin:/bin` EXIT 0
///
/// A fabricated command AND the AS-EFF-008 masking, from one sibling literal.
///
/// **THIS ROW HAD ITS SEVERITY CORRECTED DOWN AND THEN BACK UP, and the reason is worth keeping.** I
/// looked for a gate bypass, could not build one from the Db spelling that triggered the row, and wrote
/// into the register that the Exec names "take C arrays rather than string literals". That was
/// INFERRED, not measured, and it is false for exactly one member of the family — which a plan review
/// found by reading the signature. A row's stated mechanism is a hypothesis; so is a row's stated
/// BOUNDARY.
///
/// **THE OTHER THREE ARE PINNED HERE BECAUSE THEY WORK BY LUCK.** `execv`/`execvp`/`execve` take an
/// argv/envp ARRAY second, so the fallback happened to land on argument 0. Spelling luck is not
/// coverage — the same finding as R418's `createFile(named: "z")` — so the position is declared for all
/// four and asserted here.
final class ExecLocatorPositionTests: XCTestCase {
    private func scan(_ body: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32, out: String) {
        let src = """
        import Foundation
        \(body)
        """
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--json"]
        if let policy {
            let p = root.appendingPathComponent("p.pol")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        return (try ProcessHarness.fns(ofJson: r.out), r.code, r.out + r.err)
    }

    private static let runtimeCmd = """
    public func run(_ file: String) {
        var argv: [UnsafeMutablePointer<CChar>?] = [nil]
        _ = execvP(file, "/usr/bin:/bin", &argv)
    }
    """

    /// THE DECISION: a search path is not a command, and must not certify one.
    func testASearchPathDoesNotCertifyACallerControlledCommand() throws {
        let r = try scan(Self.runtimeCmd, name: "R415Gate", policy: "allow Exec /usr/bin:/bin\n")
        XCTAssertEqual(r.code, 1, "`allow Exec <search path>` must not certify a runtime command:\n\(r.out)")
    }

    /// The report, separately from the verdict — a gate can go red for the wrong reason.
    func testTheSearchPathIsNotPublishedAsTheCommand() throws {
        let r = try scan(Self.runtimeCmd, name: "R415Surface")
        let fn = try XCTUnwrap(r.fns["run"], "run absent:\n\(r.out)")
        XCTAssertNil(fn["cmds"], "the search path is not the command — publishing it is a fabrication:\n\(r.out)")
        XCTAssertEqual(fn["incomplete"] as? [String], ["Exec"],
                       "the command was caller-controlled and must be disclosed as invisible:\n\(r.out)")
    }

    /// THE OVER-MASK CONTROL, and it must assert the CAPTURE: a declared position that yields nothing
    /// would satisfy the two arms above while making every literal `execvP` uncertifiable.
    func testALiteralCommandIsStillPublished() throws {
        let src = """
        public func run() {
            var argv: [UnsafeMutablePointer<CChar>?] = [nil]
            _ = execvP("/bin/ls", "/usr/bin:/bin", &argv)
        }
        """
        let r = try scan(src, name: "R415Lit")
        let fn = try XCTUnwrap(r.fns["run"], "run absent:\n\(r.out)")
        XCTAssertEqual(fn["cmds"] as? [String], ["/bin/ls"],
                       "the command IS at the declared position and must still be read:\n\(r.out)")
        XCTAssertNil(fn["incomplete"], "a command in plain sight is not an invisible one:\n\(r.out)")
    }

    /// The three that worked by luck: same assertion, so a future edit to the table cannot quietly drop
    /// one of them back onto the whole-argument scan.
    func testTheRestOfTheExecFamilyReadsArgumentZero() throws {
        for name in ["execv", "execvp", "execve"] {
            let src = """
            public func run(_ file: String) {
                var argv: [UnsafeMutablePointer<CChar>?] = [nil]
                _ = \(name)(file, &argv)
            }
            """
            let r = try scan(src, name: "R415\(name)")
            let fn = try XCTUnwrap(r.fns["run"], "\(name): run absent:\n\(r.out)")
            XCTAssertEqual(fn["incomplete"] as? [String], ["Exec"],
                           "\(name): a runtime command must be disclosed as invisible:\n\(r.out)")
        }
    }
}
