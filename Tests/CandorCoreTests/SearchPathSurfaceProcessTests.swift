import XCTest
import Foundation

/// SOUNDNESS R387 (the `create:` half) and R467 (the ubiquity-container sibling).
///
/// **THE BYPASS NEEDED A BENIGN SIBLING TO SHOW UP AT ALL, which is why it survived a census.**
/// `FileManager.url(for:in:appropriateFor:create: true)` charges `Fs` and captures NOTHING into
/// `paths`. On its own that is already uncertifiable — `AS-EFF-008` refuses an `allow` over a function
/// with no visible literal — so every hand-check of the call in isolation looked fine. Put ONE
/// unrelated readable literal in the same function and the surface reads complete, and
/// `allow Fs /tmp/benign.txt` exits 0 over a call that creates a directory. Measured on the pre-fix
/// binary at `630f142`.
///
/// **WHY THE FIX IS NOT THE WHOLE BRANCH.** R387 proposed marking `Fs` incomplete on EVERY
/// `url(for:)`/`urls(for:)`. Measured instead (`testALookupsDestinationIsAlreadyDisclosedDownstream`
/// below, which passes on BOTH arms): a LOOKUP hands the caller a URL, and the general
/// unreadable-locator rule already marks `Fs` incomplete at whatever the caller does with it. Only a
/// call that performs the filesystem operation ITSELF has no later site to be caught at. Marking the
/// lookups too would have added a redundant second `incomplete` to rows that already carry one.
final class SearchPathSurfaceProcessTests: XCTestCase {

    /// Every fixture pairs the call under test with ONE benign readable literal, because that is the
    /// only shape in which the defect is observable — see the class comment.
    private static let benign = #"try? "x".write(toFile: "/tmp/benign.txt", atomically: true, encoding: .utf8)"#

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32, out: String) {
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

    private func incomplete(_ r: (fns: [String: [String: Any]], code: Int32, out: String),
                            _ fn: String) -> [String] {
        (r.fns[fn]?["incomplete"] as? [String]) ?? []
    }

    // ── R387 — THE ROW'S OWN REPRO ────────────────────────────────────────────────────────────────

    /// `create: true` MATERIALISES a directory whose location is an enum the surface cannot name, and
    /// nothing downstream will disclose it because the call IS the whole operation. Pre-fix:
    /// `paths:['/tmp/benign.txt'] incomplete:NONE`, `allow Fs /tmp/benign.txt` **exit 0**.
    func testR387ACreatingSearchPathCallMarksItsFsSurfaceIncomplete() throws {
        let src = """
        import Foundation
        func makeDir() {
            \(Self.benign)
            _ = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true)
        }
        """
        let r = try scan(src, name: "SpCreate")
        XCTAssertEqual(r.fns["makeDir"]?["paths"] as? [String], ["/tmp/benign.txt"],
                       "the benign literal must still be captured — the fix withholds the SURFACE, "
                       + "it does not drop what the engine could read: \(r.out)")
        XCTAssertTrue(incomplete(r, "makeDir").contains("Fs"),
                      "R387: a search-path CREATE has no expressible destination, so the Fs surface is "
                      + "INCOMPLETE and the sibling literal must not certify it: \(r.out)")

        // CALIBRATION — the gate must be able to fail, or the assertion below proves nothing.
        XCTAssertEqual(try scan(src, name: "SpCreateDeny", policy: "deny Fs\n").code, 1,
                       "deny Fs must fire here on both arms; if it does not, the fixture never reached "
                       + "the engine and the allow result below is meaningless")
        // THE BYPASS ITSELF — 0 before the fix, 1 after.
        XCTAssertEqual(try scan(src, name: "SpCreateAllow", policy: "allow Fs /tmp/benign.txt\n").code, 1,
                       "allow Fs <the benign literal> must NOT certify a directory creation whose "
                       + "destination the policy surface cannot name")
    }

    /// FAIL-CLOSED on the flag, per the denylist discipline: only a literal `false` is evidence that
    /// nothing is created. A computed flag is unreadable, and an unreadable flag that decided the
    /// question the permissive way would be the gate-masking shape all over again — write
    /// `create: shouldCreate` and the bypass returns.
    func testR387AnUnreadableCreateFlagFailsClosed() throws {
        let r = try scan("""
        import Foundation
        func maybeMakeDir(_ shouldCreate: Bool) {
            \(Self.benign)
            _ = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: shouldCreate)
        }
        """, name: "SpFlagVar")
        XCTAssertTrue(incomplete(r, "maybeMakeDir").contains("Fs"),
                      "an unreadable create: flag must be treated as creating: \(r.out)")
    }

    // ── R467 — THE SIBLING WITH THE SAME SHAPE ────────────────────────────────────────────────────

    /// `url(forUbiquityContainerIdentifier:)` reaches this same branch (its member is `url`), does real
    /// work at a location no path literal can name, and is commonly called for that side effect with
    /// the returned URL discarded. Measured pre-fix in exactly R387's posture:
    /// `paths:['/tmp/benign.txt'] incomplete:NONE`.
    func testR467AUbiquityContainerCallMarksItsFsSurfaceIncomplete() throws {
        let src = """
        import Foundation
        func icloud() {
            \(Self.benign)
            _ = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }
        """
        let r = try scan(src, name: "SpUbiq")
        XCTAssertTrue(incomplete(r, "icloud").contains("Fs"),
                      "R467: the ubiquity container is not a nameable path, so the Fs surface is "
                      + "INCOMPLETE: \(r.out)")
        XCTAssertEqual(try scan(src, name: "SpUbiqAllow", policy: "allow Fs /tmp/benign.txt\n").code, 1)
    }

    // ── THE OVER-CHARGE CONTROLS — the direction the fix did NOT intend ───────────────────────────

    /// `urls(for:in:)` NAMES a directory and touches nothing. Marking it incomplete would assert
    /// AS-EFF-008's own words — *"reaches a structurally-invisible Fs endpoint"* — of a call that
    /// reaches no endpoint, and would make `allow Fs` unusable for ordinary code. This is the
    /// commonest spelling in the ecosystem, so a regression here is the expensive direction.
    func testAPlainSearchPathLookupStaysCertifiable() throws {
        let src = """
        import Foundation
        func lookup() {
            \(Self.benign)
            _ = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        }
        """
        let r = try scan(src, name: "SpLookup")
        XCTAssertFalse(incomplete(r, "lookup").contains("Fs"),
                       "a lookup materialises nothing; its destination is disclosed where the caller "
                       + "USES it, not here: \(r.out)")
        XCTAssertEqual(try scan(src, name: "SpLookupAllow", policy: "allow Fs /tmp/benign.txt\n").code, 0,
                       "allow Fs over a readable literal must still PASS — this is the fix's blast "
                       + "radius, and it is the commonest FileManager spelling there is")
    }

    /// The same, one label over: `create: false` locates without creating.
    func testACreateFalseLookupStaysCertifiable() throws {
        let r = try scan("""
        import Foundation
        func locate() {
            \(Self.benign)
            _ = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: false)
        }
        """, name: "SpCreateFalse")
        XCTAssertFalse(incomplete(r, "locate").contains("Fs"),
                       "create: false creates nothing: \(r.out)")
    }

    // ── THE MEASUREMENT THAT CHOSE THE ARM ────────────────────────────────────────────────────────

    /// **THIS IS WHY THE LOOKUPS ARE EXCLUDED, and it passes on BOTH arms deliberately** — it is not
    /// testing the fix, it is pinning the premise the fix was scoped on. Use the URL a lookup returns
    /// and the general unreadable-locator rule marks `Fs` incomplete at the WRITE. If that ever stops
    /// being true, excluding the lookups stops being safe, and this assertion is the thing that says
    /// so rather than a sentence in a comment.
    func testALookupsDestinationIsAlreadyDisclosedDownstream() throws {
        let r = try scan("""
        import Foundation
        func writeThere() {
            \(Self.benign)
            let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? "y".write(to: u.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        }
        """, name: "SpDownstream")
        XCTAssertTrue(incomplete(r, "writeThere").contains("Fs"),
                      "the premise this fix's SCOPE rests on: a lookup's destination is disclosed at "
                      + "the point of use by the general rule, so the lookup itself need not be "
                      + "marked. If this fails, widen the fix to the whole branch: \(r.out)")
    }
}
