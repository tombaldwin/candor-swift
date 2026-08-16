import XCTest
import Foundation

/// ⟨0.24⟩ **`parsepolicy` CARRIES EVERY LINE THE ENGINE DID NOT HONOUR AS WRITTEN** (SPEC §3.1,
/// candor-spec `195d45a` + `901f14d`).
///
/// MEASURED 2026-07-28 on `candor-spec/conformance/policydsl/policy.txt`:
/// **java 10, ts 2, rust 0, swift 0** — this engine emitted no `errors` key AT ALL, while its stderr
/// listed nine policy lines dropped entirely (an unknown effect name, an `allow` on an effect with no
/// literal surface, two malformed `forbid`s, two value-less `allow`s, two unknown rule kinds) plus two
/// unrecognised value tokens. None of it reached the machine output.
///
/// A DROPPED RULE IS THE LIMIT CASE of "silently rewritten into a different policy": the rewritten policy
/// is the one WITHOUT that line, which is a bigger rewrite than a narrowed filter, not a smaller one. And
/// it mattered more here than in the engine that prompted the clause, because this engine's GATE already
/// REFUSES some of these lines — so the parse was narrowing silently while the gate refused, two answers
/// to one question, and the witness gave the quieter one.
///
/// THE SHAPE IS PINNED AND NOT THIS ENGINE'S CHOICE: `{kind, token, accepted, rule, message}` with
/// `accepted` an ARRAY OF TOKENS (candor-ts emits prose there, which the consumer the field exists for
/// cannot parse) and `kind` from a CLOSED set — `reason-class/alias`, `Net destination-class`,
/// `effect-name`, `rule-kind`, `rule-form`.
///
/// ⟨0.24⟩ `rule-form` arrived hours after the set was pinned at four (candor-spec `f735b16`): a rule whose
/// KIND is recognised but whose FORM is malformed is described by none of the other values, and folding it
/// into `rule-kind` — which this engine did on its first wiring — is a true statement about a set that was
/// itself incomplete. **A closed set is only a constraint if it is closed over the DOMAIN rather than over
/// the author's sample**, which is why `testEachKindOfTheClosedSetIsReachable` asserts EQUALITY with the
/// set rather than membership in it: an engine speaking four of five values fails that row.
final class ParsePolicyErrorsProcessTests: XCTestCase {

    private func parse(_ policy: String, config: String? = nil) throws -> (obj: [String: Any], code: Int32, err: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-pperr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        if let config {
            let candor = dir.appendingPathComponent(".candor")
            try FileManager.default.createDirectory(at: candor, withIntermediateDirectories: true)
            try config.write(to: candor.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        let pol = dir.appendingPathComponent("policy.txt")
        try policy.write(to: pol, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, ["parsepolicy", pol.path])
        let obj = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any] ?? [:]
        return (obj, r.code, r.err)
    }

    private func errors(_ obj: [String: Any]) -> [[String: Any]] {
        (obj["errors"] as? [[String: Any]]) ?? []
    }

    /// The CLOSED `kind` set. An engine inventing its own vocabulary name is exactly the drift the pin
    /// exists to stop — candor-java ships seven, this engine normalises onto these five.
    private static let KINDS: Set<String> = ["reason-class/alias", "Net destination-class",
                                             "effect-name", "rule-kind", "rule-form"]

    // ── THE ROW: every unhonoured line, not just the two that prompted the clause ───────────────────

    func testEveryUnhonouredLineIsReportedNotJustTheTokens() throws {
        let p = try parse("""
        deny Fs
        deny notaneffect
        allow Clock whatever
        forbid bad
        nonsense line
        allow Net in
        deny Fs Unknown[bogus,reflect] io
        deny Net[bogus,unknown-host] mixed
        """)
        XCTAssertEqual(p.code, 0, "`parsepolicy` REPORTS a parse it can read and cannot honour; it does "
                       + "not refuse it — the witness must not delete itself. stderr: \(p.err)")
        let e = errors(p.obj)
        let rules = e.compactMap { $0["rule"] as? String }
        XCTAssertEqual(rules.sorted(), [
            "allow Clock whatever", "allow Net in", "deny Fs Unknown[bogus,reflect] io",
            "deny Net[bogus,unknown-host] mixed", "deny notaneffect", "forbid bad", "nonsense line",
        ], "every DROPPED rule AND every unrecognised token — before this the engine emitted no `errors` "
           + "key at all and six of these lived on stderr only: \(e)")
        // …and the honoured `deny Fs` is NOT in there.
        XCTAssertFalse(rules.contains("deny Fs"), "\(e)")
    }

    func testTheShapeIsThePinnedOneWithAcceptedAsAnArray() throws {
        let p = try parse("deny Fs Unknown[bogus,reflect] io\nnonsense line\n")
        // NON-VACUITY FIRST. Written without this, the loop below has no body when `errors` is absent, so
        // the row passed against the DEFECT — a shape assertion over an empty list asserts nothing.
        XCTAssertEqual(errors(p.obj).count, 2, "two unhonoured lines, so the shape check below has a body "
                       + "to run over: \(p.obj)")
        for x in errors(p.obj) {
            XCTAssertEqual(Set(x.keys), ["kind", "token", "accepted", "rule", "message"],
                           "the pinned five fields, no renames: \(x)")
            XCTAssertNotNil(x["accepted"] as? [String],
                            "`accepted` is an ARRAY OF TOKENS — prose is unparseable by the consumer the "
                            + "field exists for: \(x)")
            XCTAssertTrue(Self.KINDS.contains(x["kind"] as? String ?? ""),
                          "`kind` is drawn from the CLOSED set \(Self.KINDS.sorted()): \(x)")
            XCTAssertFalse((x["token"] as? String ?? "").isEmpty, "\(x)")
            XCTAssertFalse((x["message"] as? String ?? "").isEmpty, "\(x)")
        }
    }

    func testEachKindOfTheClosedSetIsReachable() throws {
        let p = try parse("""
        deny Fs Unknown[bogus,reflect] io
        deny Net[bogus,unknown-host] mixed
        deny notaneffect
        nonsense line
        forbid bad
        """)
        let kinds = Set(errors(p.obj).compactMap { $0["kind"] as? String })
        XCTAssertEqual(kinds, Self.KINDS, "EVERY kind must be reachable, or the closed set is a "
                       + "vocabulary this engine only partly speaks. `forbid bad` is the `rule-form` row: "
                       + "a rule whose KIND is recognised but whose FORM is malformed — folding it into "
                       + "`rule-kind` is a true statement about an incomplete set: \(errors(p.obj))")
    }

    /// A typo inside an `unknown-alias` DEFINITION is a line the engine did not honour either, and it is
    /// the quietest of them — the policy line referring to the alias reads perfectly well.
    func testAnAliasDefinitionTypoIsReportedToo() throws {
        let p = try parse("deny Unknown[corp]\n", config: "unknown-alias corp = dispatch,nativ\n")
        let e = errors(p.obj)
        XCTAssertTrue(e.contains { ($0["token"] as? String) == "nativ" },
                      "the vocabulary the policy is written AGAINST is part of what was not honoured: \(e)")
        XCTAssertEqual(e.first { ($0["token"] as? String) == "nativ" }?["kind"] as? String,
                       "reason-class/alias")
    }

    // ── THE MIRRORS ────────────────────────────────────────────────────────────────────────────────

    /// OMITTED when empty, so a clean parse stays byte-identical and the four-way deny/allow/forbid
    /// comparison (conformance PART 4) is untouched.
    func testACleanParseHasNoErrorsKeyAtAll() throws {
        let p = try parse("deny Net Db domain\npure parse\nallow Net in billing api.stripe.com\nforbid web -> db\n")
        XCTAssertEqual(p.code, 0)
        XCTAssertFalse(p.obj.keys.contains("errors"),
                       "a clean parse must stay byte-identical to pre-feature: \(p.obj)")
        // ⟨0.29⟩ `only` joined the witness. This row PINNED THE OMISSION in place: it asserted the exact
        // three-key set, so the rung that added a fourth rule kind would have had to change this line to
        // publish it — and instead the kind was left out of the witness entirely and this row passed,
        // agreeing with itself about a document that had stopped describing the grammar.
        XCTAssertEqual(Set(p.obj.keys), ["deny", "allow", "forbid", "only"], "\(p.obj)")
    }

    /// **THE WITNESS MUST NOT DELETE ITSELF.** `parsepolicy` MUST NOT REFUSE a policy it can READ and
    /// cannot honour — when two engines applied the token rule in the PARSER the conformance battery
    /// began exiting 2 and the suite halted at PART 4, taking the whole differential offline. It still
    /// exits 2 on a file it cannot READ, which is a different case: exit 0 with an empty rule list there
    /// is the silent-empty this format forbids everywhere else.
    func testTheParseIsStillBuiltAndTheWitnessNeverRefuses() throws {
        let p = try parse("deny Fs Unknown[bogus,reflect] io\ndeny Net[bogus,unknown-host] mixed\n")
        XCTAssertEqual(p.code, 0, "stderr: \(p.err)")
        XCTAssertEqual((p.obj["deny"] as? [[String: Any]])?.count, 2,
                       "the RULES are still built — the advisory readers are unchanged: \(p.obj)")

        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let missing = try ProcessHarness.run(bin, ["parsepolicy", "/no/such/pol-\(UUID().uuidString)"])
        XCTAssertEqual(missing.code, 2, "a file with no parse to report is not the case the clause is about")
    }
}
