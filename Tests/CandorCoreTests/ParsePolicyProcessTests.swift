import XCTest
import Foundation

/// Process-level pins for the `parsepolicy <file>` subcommand — the §6.2 grammar dump the cross-impl
/// conformance suite (PART 4) diffs against the other engines. The JSON shape is the family's:
/// {"deny":[{effects,scope}], "allow":[{effect,scope,values}], "forbid":[{from,to}]} — field-for-field
/// what candor-java's Query.policyJson emits, effects/values deduped + sorted.
final class ParsePolicyProcessTests: XCTestCase {

    func testParsePolicyDumpsTheCanonicalShape() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-pp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pol = dir.appendingPathComponent("policy.txt")
        // The edge cases the engines used to disagree on: inline comment, pure, duplicate tokens,
        // the glued arrow, a `::`-written scope, the value-less allow.
        try """
        deny Net Db domain
        deny Net Net                # duplicate effects dedup to a set
        pure parse
        allow Net in billing api.stripe.com api.stripe.com hooks.stripe.com
        allow Net in
        forbid app::web -> app::db
        forbid glued->arrow
        deny Exec # inline comment stripped, scope stays empty
        """.write(to: pol, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, ["parsepolicy", pol.path])
        XCTAssertEqual(r.code, 0, "a readable policy dumps and exits 0 — stderr: \(r.err)")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
                                "stdout must be one JSON object: \(r.out.prefix(200))")

        let deny = try XCTUnwrap(obj["deny"] as? [[String: Any]])
        let denySet = Set(deny.map { "\(($0["effects"] as? [String] ?? []).joined(separator: ","))|\($0["scope"] as? String ?? "?")" })
        XCTAssertEqual(denySet, ["Db,Net|domain", "Net|", "|parse", "Exec|"],
                       "deny rules: dedup'd sorted effects + scope (pure = empty effects): \(deny)")

        let allow = try XCTUnwrap(obj["allow"] as? [[String: Any]])
        XCTAssertEqual(allow.count, 1, "the value-less `allow Net in` is dropped: \(allow)")
        XCTAssertEqual(allow.first?["effect"] as? String, "Net")
        XCTAssertEqual(allow.first?["scope"] as? String, "billing")
        XCTAssertEqual(allow.first?["values"] as? [String], ["api.stripe.com", "hooks.stripe.com"],
                       "values dedup'd + sorted")

        let forbid = try XCTUnwrap(obj["forbid"] as? [[String: Any]])
        XCTAssertEqual(forbid.count, 1, "the glued arrow is dropped: \(forbid)")
        XCTAssertEqual(forbid.first?["from"] as? String, "app::web")
        XCTAssertEqual(forbid.first?["to"] as? String, "app::db")
    }

    func testParsePolicyMissingArgAndUnreadableFileExitTwo() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let noArg = try ProcessHarness.run(bin, ["parsepolicy"])
        XCTAssertEqual(noArg.code, 2, "missing file arg is a usage error — stderr: \(noArg.err)")
        XCTAssertTrue(noArg.err.contains("usage: candor-swift parsepolicy"), "stderr: \(noArg.err)")

        let missing = try ProcessHarness.run(bin, ["parsepolicy", "/no/such/policy-\(UUID().uuidString)"])
        XCTAssertEqual(missing.code, 2, "an unreadable policy must fail, never dump an empty parse")
        XCTAssertTrue(missing.err.contains("cannot read policy"), "stderr: \(missing.err)")
    }
}
