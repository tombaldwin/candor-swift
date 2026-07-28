import XCTest
import Foundation

/// ⟨0.24⟩ **A TYPO'D EFFECT NAME DELETES THE RULE, SILENTLY, FOUR-WAY GREEN** (SPEC §6.2, candor-spec
/// `1e1748a`). MEASURED 2026-07-28 on all four engines:
///
///     deny Nett app             ->  rust 0  ts 0  java 0  swift 0   the rule is DELETED, the gate is green
///     allow Nett host.example   ->  rust 0  ts 0  java 0  swift 0   the certification silently vanishes
///
/// The operator reads an armed `deny Net`; there is no gate at all. This format already calls a dropped
/// rule *"the limit case of silently rewritten into a different policy… a bigger rewrite than a narrowed
/// filter, not a smaller one"* — and yet the BIGGER rewrite was warning-only while the SMALLER one (a
/// narrowed `Unknown[…]` filter) was already exit 2. That is a clause scoped to the position its defect
/// was found in rather than to the condition its reasoning names.
///
/// **THE GRAMMAR DEFENCE IS REAL BUT NARROWER than it was taken to be**, and the two mirrors below are
/// what keep this repair from becoming its own over-reach:
///
///   - `allow`'s effect position is a FIXED, CLOSED set with no scope reading available → exit 2.
///   - a `deny` whose effect list ends up EMPTY after scope-splitting is malformed under either reading
///     → exit 2.
///   - `deny Net Exex app` — at least one valid effect plus an unrecognised trailing token that MIGHT be
///     a scope — genuinely cannot be told from a legitimate scope by the parser. **It stays permissive**,
///     and `parsepolicy` reports it either way.
final class EffectNameTypoProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// A `Net`-reaching scan fixture + a one-entry report of the same signature, so every row is measured
    /// on BOTH routes: the two CLIs must refuse the same policies.
    private func makeRoot() throws -> URL {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func send() {
            URLSession.shared.dataTask(with: URL(string: "https://api.example.com/x")!) { _, _, _ in }.resume()
        }
        func readIt() -> String {
            return (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
        }
        """)
        let candor = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candor, withIntermediateDirectories: true)
        try """
        {"candor":{"spec":"0.23","toolchain":"swiftsyntax","version":"handwritten"},
         "package":"App","analyzed":{"count":1,"digest":"1111111111111111"},
         "functions":[{"fn":"app.send","loc":"a.swift:1:1","inferred":["Net"],"direct":["Net"],
                       "hash":"App#send","calls":[],"netClass":["unknown-host"]}]}
        """.write(to: candor.appendingPathComponent("report.App.Swift.json"), atomically: true, encoding: .utf8)
        return root
    }

    /// (scan exit, gate --report exit) for one policy over the shared fixture.
    private func exits(_ root: URL, _ policy: String) throws -> (scan: Int32, gate: Int32, err: String) {
        let pol = root.appendingPathComponent("pol.txt")
        try policy.write(to: pol, atomically: true, encoding: .utf8)
        let s = try ProcessHarness.run(bin(), [root.path, "--out", root.appendingPathComponent("r").path,
                                               "--policy", pol.path])
        let g = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", pol.path])
        return (s.code, g.code, s.err + g.err)
    }

    // ── THE ROWS ───────────────────────────────────────────────────────────────────────────────────

    func testATypodDenyEffectNameIsAPolicyError() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try exits(root, "deny Nett app\n")
        XCTAssertEqual(r.scan, 2, "before: the rule was DELETED and the gate went green while the operator "
                       + "read an armed `deny Net`. stderr: \(r.err)")
        XCTAssertEqual(r.gate, 2, "and the two routes must refuse the same policies. stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("`Nett`"), "naming the token: \(r.err)")
        XCTAssertTrue(r.err.contains("Net,"), "and listing the accepted effect names: \(r.err)")
    }

    func testATypodAllowEffectNameIsAPolicyError() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try exits(root, "allow Nett host.example\n")
        XCTAssertEqual(r.scan, 2, "`allow`'s effect position is a CLOSED set — there is no scope reading "
                       + "available, so this is unambiguously a typo. stderr: \(r.err)")
        XCTAssertEqual(r.gate, 2, "stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("`Nett`"), "naming the token: \(r.err)")
    }

    /// `Clock` is a REAL effect name that `allow` has no literal surface for — the same closed-set rule,
    /// and the one that shows this is about the POSITION's vocabulary rather than about spelling.
    func testAnAllowOnAnEffectWithNoLiteralSurfaceIsAPolicyErrorToo() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try exits(root, "allow Clock whatever\n")
        XCTAssertEqual(r.scan, 2, "stderr: \(r.err)")
        XCTAssertEqual(r.gate, 2, "stderr: \(r.err)")
    }

    /// A `deny` naming nothing recognisable — the effect list is EMPTY after scope-splitting, which is
    /// malformed under either reading of the trailing token.
    func testADenyWhoseEffectListEndsUpEmptyIsAPolicyError() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for policy in ["deny notaneffect\n", "deny app\n", "deny\n"] {
            let r = try exits(root, policy)
            XCTAssertEqual(r.scan, 2, "`\(policy.trimmingCharacters(in: .newlines))` names no effect at "
                           + "all — there is no legitimate policy it could be. stderr: \(r.err)")
            XCTAssertEqual(r.gate, 2, "stderr: \(r.err)")
        }
    }

    // ── THE MIRRORS. The refusal must not swallow the ambiguous middle ──────────────────────────────

    /// **THE OVER-REACH MIRROR.** `deny Net Exex app` keeps a valid effect and its unrecognised trailing
    /// token might genuinely be a scope — the parser cannot tell. It STAYS PERMISSIVE. Refusing here
    /// would break every policy whose scope happens not to be an effect name, which is most of them.
    func testTheAmbiguousMiddleStaysPermissive() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for policy in ["deny Net Exex app\n", "deny Fs foo\n", "deny Net trailing junk\n"] {
            let r = try exits(root, policy)
            XCTAssertNotEqual(r.scan, 2, "`\(policy.trimmingCharacters(in: .newlines))` is the genuinely "
                              + "ambiguous middle SPEC §6.2 leaves open — `parsepolicy` reports it, the "
                              + "gate does not refuse it. stderr: \(r.err)")
            XCTAssertNotEqual(r.gate, 2, "stderr: \(r.err)")
        }
    }

    /// `pure <scope>` is a `deny` with an intentionally empty effect list. The empty-list rule must not
    /// reach it — it is a different keyword taking a different branch, and refusing it would delete the
    /// most common rule in the DSL.
    func testPureIsUntouched() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scoped = try exits(root, "pure parse\n")
        XCTAssertEqual(scoped.scan, 0, "a `pure` scope matching nothing here is clean. stderr: \(scoped.err)")
        XCTAssertEqual(scoped.gate, 0, "stderr: \(scoped.err)")
        let bare = try exits(root, "pure\n")
        XCTAssertEqual(bare.scan, 1, "and a bare `pure` still FIRES on the Net-reaching fn — the mirror is "
                       + "worthless if `pure` gates nothing. stderr: \(bare.err)")
        XCTAssertEqual(bare.gate, 1, "stderr: \(bare.err)")
    }

    /// THE CONTROL: the correctly-spelled rules still work on both routes, so the rows above measure a
    /// live gate rather than an engine that refuses everything.
    func testTheCorrectlySpelledRulesStillWork() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deny = try exits(root, "deny Net\n")
        XCTAssertEqual(deny.scan, 1, "control: `deny Net` fires on the scan route. stderr: \(deny.err)")
        XCTAssertEqual(deny.gate, 1, "…and on the report route. stderr: \(deny.err)")
        // The `allow` control is SCAN-ONLY by design: `gate --report` refuses every `allow` (the
        // AS-EFF-008 surface-completeness marker does not ride the wire), which is its own pinned rule.
        let pol = root.appendingPathComponent("pol.txt")
        try "allow Fs /etc\n".write(to: pol, atomically: true, encoding: .utf8)
        let allow = try ProcessHarness.run(bin(), [root.path, "--out", root.appendingPathComponent("r").path,
                                                   "--policy", pol.path])
        XCTAssertEqual(allow.code, 0, "control: `allow Fs /etc` certifies the visible path, so the `allow` "
                       + "arm above is refusing a typo rather than failing on every allow. stderr: \(allow.err)")
    }

    /// And the WITNESS still reports all of it without refusing — the parse is what the conformance
    /// grammar differential reads, and an engine that refused would delete it.
    func testParsePolicyStillReportsTheseWithoutRefusing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("pol.txt")
        try "deny Nett app\nallow Nett host.example\ndeny Net Exex app\n".write(to: pol, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin(), ["parsepolicy", pol.path])
        XCTAssertEqual(r.code, 0, "the witness never refuses a policy it can READ: \(r.err)")
        let obj = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any] ?? [:]
        let rules = ((obj["errors"] as? [[String: Any]]) ?? []).compactMap { $0["rule"] as? String }
        XCTAssertEqual(rules.sorted(), ["allow Nett host.example", "deny Nett app"], "\(obj)")
        XCTAssertEqual((obj["deny"] as? [[String: Any]])?.count, 1,
                       "…and `deny Net Exex app` is still BUILT, with `Net` kept: \(obj)")
    }
}
