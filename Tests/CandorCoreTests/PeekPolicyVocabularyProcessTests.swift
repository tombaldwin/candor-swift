import XCTest
import Foundation

/// **⟨0.30⟩ THE PEEK MUST READ THE POLICY IT IS GIVEN — INCLUDING ITS VOCABULARY** (SPEC §6.2, §3.1).
///
/// A VERIFIED FAIL-OPEN whose shape is that **a strictly STRONGER policy answered WEAKER.** The ⟨0.30⟩
/// peek re-parsed the policy file for itself with `aliases: [:]`, so a `deny Unknown[corp]` line written
/// against a `.candor/config` `unknown-alias` was an unrecognised class token to THAT read — a ⟨0.24⟩
/// `gateRefusals` error — and `peekRules` drops the entire rule set on any such error. The peek then
/// never ran at all, and the disclosure it owes for the OTHER, perfectly ordinary rules in the same file
/// vanished with it.
///
/// MEASURED on `258794a`, one SPM tree whose test helper spawns `/bin/sh`, `unknown-alias corp = reflect`
/// filed beside the policy:
///
///     deny Exec                          exit 2   names the helper; excluded classes `peeked: true`
///     deny Exec + deny Unknown[corp]     exit 0   nothing said; excluded classes `peeked: false`
///
/// The GATE was never wrong here — `scanPolicy` is parsed WITH the vocabulary and expands `corp`
/// correctly — which is exactly what made this quiet: adding a rule deleted the disclosure belonging to
/// a different rule that was never in doubt, and no arm read the `peeked: false` it left behind.
///
/// THE RULE: the vocabulary travels with the POLICY that uses it (the ⟨0.24⟩ anchoring ruling), so both
/// readers of one policy file expand one rule the same way. §6.2 already requires the gate and the
/// disclosure to apply the SAME rule; that was being honoured on the rule's SHAPE (⟨0.30⟩ stopped
/// flattening rules into effect names) and missed on the rule's WORDS.
final class PeekPolicyVocabularyProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// An SPM package whose EXCLUDED harness target performs `Exec`, and a policy directory held
    /// SEPARATE from it — with the two in one tree the anchors coincide and every row here is vacuous.
    private func fixture() throws -> (tree: URL, pdir: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-peekvocab-\(UUID().uuidString)")
        let tree = base.appendingPathComponent("tree"), pdir = base.appendingPathComponent("pdir")
        let fm = FileManager.default
        try fm.createDirectory(at: tree.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tree.appendingPathComponent("Tests/AppTests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: pdir.appendingPathComponent(".candor"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.target(name: "App"),
                                                     .testTarget(name: "AppTests", dependencies: ["App"])])
        """.write(to: tree.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func add(_ a: Int) -> Int { a + 1 }\n"
            .write(to: tree.appendingPathComponent("Sources/App/Lib.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import XCTest
        func helper() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); try? p.run() }
        """.write(to: tree.appendingPathComponent("Tests/AppTests/Helper.swift"),
                  atomically: true, encoding: .utf8)
        try "unknown-alias corp = reflect\n"
            .write(to: pdir.appendingPathComponent(".candor/config"), atomically: true, encoding: .utf8)
        return (tree, pdir)
    }

    private func scan(_ tree: URL, policy: URL, out: String) throws -> (out: String, err: String, code: Int32) {
        try ProcessHarness.run(try bin(),
                               [tree.path, "--policy", policy.path,
                                "--out", tree.appendingPathComponent(out).path],
                               cwd: tree)
    }

    private func excludedFlags(_ report: URL) throws -> [String: Bool] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        var out: [String: Bool] = [:]
        for e in (d?["excluded"] as? [[String: Any]] ?? []) {
            if let c = e["class"] as? String { out[c] = e["peeked"] as? Bool ?? false }
        }
        return out
    }

    /// **THE CONTROL, and it must be read FIRST: the weaker policy answers.** Without it a green on the
    /// row below could mean the peek works or that the fixture never had an excluded `Exec` to find.
    func testTheWeakerPolicyAloneStillNamesTheExcludedEffect() throws {
        let (tree, pdir) = try fixture()
        defer { try? FileManager.default.removeItem(at: tree.deletingLastPathComponent()) }
        let pol = pdir.appendingPathComponent("plain.policy")
        try "deny Exec\n".write(to: pol, atomically: true, encoding: .utf8)
        let r = try scan(tree, policy: pol, out: "plain")
        XCTAssertEqual(r.code, 2, "the peek reads the harness target and finds the Exec: \(r.err)")
        XCTAssertTrue(r.err.contains("helper"), "…and NAMES the function: \(r.err)")
        XCTAssertEqual(try excludedFlags(tree.appendingPathComponent("plain.App.Swift.json"))["harness-target"],
                       true, "the peek must record that it READ the class")
    }

    /// **THE DEFECT: adding a rule must not delete another rule's answer.** `deny Exec + deny
    /// Unknown[corp]` denies everything the control denies and more, so no resolution of the added rule
    /// can make this run MORE certifiable — `Reject` is upward-closed (PAPER3 Lemma 2). Answering exit 0
    /// where the weaker policy answers exit 2 is therefore not a judgement call, it is a contradiction.
    func testAnAliasedRuleDoesNotSwitchOffThePeekForTheRestOfTheFile() throws {
        let (tree, pdir) = try fixture()
        defer { try? FileManager.default.removeItem(at: tree.deletingLastPathComponent()) }
        let pol = pdir.appendingPathComponent("alias.policy")
        try "deny Exec\ndeny Unknown[corp]\n".write(to: pol, atomically: true, encoding: .utf8)
        let r = try scan(tree, policy: pol, out: "alias")
        let flags = try excludedFlags(tree.appendingPathComponent("alias.App.Swift.json"))
        XCTAssertEqual(flags["harness-target"], true,
                       "the peek must RUN — an alias token in one rule cannot switch off the read the "
                       + "whole disclosure depends on: \(flags)")
        XCTAssertEqual(r.code, 2, "…so the `deny Exec` half still names the helper, exactly as it does "
                       + "without the second line: \(r.err)")
        XCTAssertTrue(r.err.contains("helper"), "…and NAMES it: \(r.err)")
    }

    /// AND THE CARVE-OUT IT MUST NOT SWALLOW: a policy the gate genuinely will NOT honour still leaves
    /// the peek silent. ⟨0.29⟩'s rule is that a refused policy leaves `outOfScope` ABSENT — `[]` would
    /// claim a look taken against rules that never stood. `corp` with NO alias defined anywhere is that
    /// case, and the fix must not have turned every unrecognised token into a peek.
    func testAPolicyThePeekWillNotHonourStillLeavesTheKeyAbsent() throws {
        let (tree, pdir) = try fixture()
        defer { try? FileManager.default.removeItem(at: tree.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: pdir.appendingPathComponent(".candor/config"))
        let pol = pdir.appendingPathComponent("unknown.policy")
        try "deny Exec\ndeny Unknown[corp]\n".write(to: pol, atomically: true, encoding: .utf8)
        let r = try scan(tree, policy: pol, out: "unhon")
        XCTAssertEqual(r.code, 2, "the policy carries a token no route will honour: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: tree.appendingPathComponent("unhon.App.Swift.json"))) as? [String: Any]
        XCTAssertNil(d?["outOfScope"],
                     "⟨0.29⟩: a refused policy leaves the key ABSENT — `[]` would claim a look taken "
                     + "against rules that never stood: \(String(describing: d?["outOfScope"]))")
    }
}
