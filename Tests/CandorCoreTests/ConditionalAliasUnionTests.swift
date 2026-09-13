import XCTest
import Foundation

/// SOUNDNESS R429 — **A `#if`-DUPLICATED `typealias` WAS RESOLVED BY SOURCE ORDER, AND THE LOSING ARM'S
/// EFFECTS WERE DROPPED.**
///
/// `DeclCollector` recorded `typeAliases[name] = underlying` into a plain map and the Driver merged those
/// LAST-WRITER-WINS — its own comment said so, calling a redeclared alias "rare". A `#if`/`#else` pair
/// declaring one alias name over two different types is not rare; it is the idiom conditional
/// compilation exists for. Only the arm written LAST survived, and the other arm's effects were not
/// hedged or disclosed — they were gone.
///
/// MEASURED on the shipped 0.37.0 binary, two programs identical but for the ORDER of the arms:
///
///     #if os(macOS)  typealias Impl = FsImpl   #else  typealias Impl = EnvImpl  #endif   → ["Env"]
///     #if os(macOS)  typealias Impl = EnvImpl  #else  typealias Impl = FsImpl   #endif   → ["Fs"]
///
/// **THE GATE CONSEQUENCE NEEDED A SCOPED RULE TO SEE, which is why it survived.** A bare `deny Fs`
/// fires on both orders — the helper `FsImpl.act` carries `Fs` on its own and the deny lands there. It
/// is the FUNCTION-level attribution that is wrong, so `deny Fs go` exits **0** on one order and **1**
/// on the other. A program that writes a file passes a scoped deny because of where its `#else` sits.
///
/// This is SOUNDNESS R105's rust defect in a second engine, and SPEC ⟨0.36⟩ already names it:
/// *"resolution by SOURCE ORDER was and remains the cardinal sin under ⟨0.21⟩."* Tom RULED UNION for
/// this shape on 2026-09-12.
///
/// **THE UNION IS DONE AT THE CALL EDGE, NOT IN `dealias`.** 26 call sites read `dealias` as
/// single-valued; making it multi-valued is the large mechanical refactor this project's history prices
/// above the defect it prevents. One edge per arm reaches the same answer through the propagation that
/// already exists — and it is keyed on the WRITTEN name, never by searching for aliases whose arms
/// contain the resolved type, which would cross-charge two unrelated aliases that happen to share one.
/// `testTwoAliasesSharingAnArmTypeDoNotCrossCharge` is that control.
final class ConditionalAliasUnionTests: XCTestCase {
    private static let HELPERS = """
    enum FsImpl { static func act(_ p: String, _ v: String) { try? v.write(toFile: p, atomically: true, encoding: .utf8) } }
    enum EnvImpl { static func act(_ p: String, _ v: String) { setenv(p, v, 1) } }
    """

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\n" + src, name: name)
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

    private static func duplicated(_ first: String, _ second: String) -> String {
        """
        \(HELPERS)
        #if os(macOS)
        typealias Impl = \(first)
        #else
        typealias Impl = \(second)
        #endif
        public func go() { Impl.act("/tmp/benign", "x") }
        """
    }

    /// THE DECISION: the answer must not depend on which arm was written first. This is R105's invariant,
    /// and it is the one that holds whatever the right answer turns out to be.
    func testTheAnswerDoesNotDependOnWhichArmIsWrittenFirst() throws {
        let a = try scan(Self.duplicated("FsImpl", "EnvImpl"), name: "R429A")
        let b = try scan(Self.duplicated("EnvImpl", "FsImpl"), name: "R429B")
        let ea = (try XCTUnwrap(a.fns["go"], "go absent:\n\(a.out)")["inferred"] as? [String])?.sorted()
        let eb = (try XCTUnwrap(b.fns["go"], "go absent:\n\(b.out)")["inferred"] as? [String])?.sorted()
        XCTAssertEqual(ea, eb, "two programs identical but for `#if` arm ORDER answered differently — the "
                       + "alias map resolved by source position:\nA:\n\(a.out)\nB:\n\(b.out)")
        XCTAssertEqual(ea, ["Env", "Fs"], "both arms are in the source the engine was pointed at, so the "
                       + "answer is the UNION — picking one is the ⟨0.21⟩ cardinal sin:\n\(a.out)")
    }

    /// The gate, scoped — the bare form cannot see this because the helper carries `Fs` on its own, which
    /// is exactly why the defect survived. Asserted for BOTH orders.
    func testAScopedDenyIsNotDecidedByArmOrder() throws {
        for (tag, src) in [("FsFirst", Self.duplicated("FsImpl", "EnvImpl")),
                           ("EnvFirst", Self.duplicated("EnvImpl", "FsImpl"))] {
            let r = try scan(src, name: "R429Gate\(tag)", policy: "deny Fs go\n")
            XCTAssertEqual(r.code, 1, "\(tag): `deny Fs go` must fire — this program writes a file in one "
                           + "configuration, and which one is not a function of where `#else` sits:\n\(r.out)")
        }
    }

    /// The surface stays withheld: the arms are different definitions, so publishing one's literal would
    /// be the pick-by-position this row removes, re-entering through the union.
    ///
    /// **Passes against the pre-fix engine too, and is kept as a GUARD rather than evidence** — there it
    /// also failed to certify, for an unrelated reason (the literal sits inside the helper, not at the
    /// aliased call). Its job is to fail if a future widening starts publishing an arm's literal.
    func testTheUnionDoesNotPublishAnArmsLiteralAsACertifiedDestination() throws {
        let r = try scan(Self.duplicated("FsImpl", "EnvImpl"), name: "R429Surface",
                         policy: "allow Fs /tmp/benign\n")
        XCTAssertEqual(r.code, 1, "a union that CERTIFIED off one arm's literal would be the original "
                       + "defect coming back through the fix:\n\(r.out)")
    }

    // ── the over-charge controls ─────────────────────────────────────────────────────────────────────

    /// An ORDINARY alias must charge exactly its own arm. If this gains `Env`, the union is firing on
    /// names that are not arm sets at all.
    func testAnOrdinaryAliasChargesOnlyItsOwnType() throws {
        let src = """
        \(Self.HELPERS)
        typealias Impl = FsImpl
        public func go() { Impl.act("/tmp/benign", "x") }
        """
        let r = try scan(src, name: "R429Single")
        let e = (try XCTUnwrap(r.fns["go"], "go absent:\n\(r.out)")["inferred"] as? [String])?.sorted()
        XCTAssertEqual(e, ["Fs"], "a single-armed alias is not an arm set:\n\(r.out)")
    }

    /// THE CONTROL THAT DECIDED THE IMPLEMENTATION. Keying the union on "aliases whose arms contain the
    /// resolved type" would make `A` (single-armed, → FsImpl) inherit `B`'s EnvImpl arm purely because
    /// the two share `FsImpl`. That is fabrication in the direction this engine is least able to notice,
    /// so the lookup is by the WRITTEN receiver name instead.
    func testTwoAliasesSharingAnArmTypeDoNotCrossCharge() throws {
        let src = """
        \(Self.HELPERS)
        typealias A = FsImpl
        #if os(macOS)
        typealias B = FsImpl
        #else
        typealias B = EnvImpl
        #endif
        public func onlyA() { A.act("/tmp/benign", "x") }
        """
        let r = try scan(src, name: "R429Cross")
        let e = (try XCTUnwrap(r.fns["onlyA"], "onlyA absent:\n\(r.out)")["inferred"] as? [String])?.sorted()
        XCTAssertEqual(e, ["Fs"], "`onlyA` never mentions B — charging B's other arm to it is a "
                       + "fabrication:\n\(r.out)")
    }

    /// Arms that AGREE must not become noisy. This is the shape measured at 6.6% prevalence in a real
    /// registry slice (R105): every real conditional alias is a portability shim whose arms classify
    /// identically, so a union that added disclosure here would be noise on almost every real hit.
    func testDuplicatedArmsThatAgreeAddNothing() throws {
        let src = """
        \(Self.HELPERS)
        #if os(macOS)
        typealias Impl = FsImpl
        #else
        typealias Impl = FsImpl
        #endif
        public func go() { Impl.act("/tmp/benign", "x") }
        """
        let r = try scan(src, name: "R429Agree")
        let e = (try XCTUnwrap(r.fns["go"], "go absent:\n\(r.out)")["inferred"] as? [String])?.sorted()
        XCTAssertEqual(e, ["Fs"], "arms that answer the same add nothing to disclose:\n\(r.out)")
    }
}
