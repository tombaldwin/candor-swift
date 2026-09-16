import XCTest
@testable import CandorCore

/// THE R445 GATE: a `why` that disagrees with the model must be a TEST FAILURE, not prose.
///
/// R445 was 56 stale sentences in `APPLE_PRIVACY_KEYS` — every modelled key still carrying the reason it
/// had back when it was not modelled, 47 of them the bare string "not modelled", one line under an output
/// reading *"56 of Apple's 57 … are modelled"*. They were INERT (only `PRIVACY_UNMODELLED_KEYS` ever
/// printed one, and it filters), and that is precisely why they rotted: nothing anyone could run
/// disagreed with them. The bill arrived somewhere else — the stale `NSLocalNetworkUsageDescription`
/// reason made R390, a Bonjour app told by `--verify` it needed no privacy key, read as a CONSIDERED
/// limitation for as long as it did.
///
/// The doc comment on `APPLE_PRIVACY_KEYS` has named this file since 2026-08-05 and THE FILE DID NOT
/// EXIST (R450) — "`PrivacyKeyUniverseTests` pins the arithmetic" was itself a limitation-written-as-prose,
/// asserting the very gate whose absence let R445 happen. It exists now.
///
/// BOTH SIDES OF EVERY ASSERTION ARE DERIVED from `privacyKeyMap` and `APPLE_PRIVACY_KEYS`. There is no
/// second hand-written list here to check the first against — that shape is the two-sided drift that
/// makes a ratchet vacuous (candor-spec `conformance/probe_check.py`, `COVERED_FLOOR`). The ONE literal
/// in this file is `expectedUniverseCount`, and it is a tripwire on the fetched universe, not a copy of
/// the model.
final class PrivacyKeyUniverseTests: XCTestCase {

    /// Keys `privacyKeyMap` can actually emit. Derived; the single source of "modelled".
    private var modelled: Set<String> { Set(privacyKeyMap.values.flatMap { $0 }) }

    /// The unmodelled set, recomputed here from the same two tables the shipped accessor uses — so this
    /// test agrees with `PRIVACY_UNMODELLED_KEYS` by construction rather than by a maintained copy.
    private var unmodelled: Set<String> { Set(APPLE_PRIVACY_KEYS).subtracting(modelled) }

    /// THE R445 ASSERTION, both directions.
    ///
    /// A reason for a key that IS modelled is the R445 defect: a sentence explaining a gap that closed,
    /// sitting where a reader looks to decide whether a gap is known. A key that is unmodelled with NO
    /// reason is the weaker half of the same defect: a disclosure that names a gap and cannot say why.
    func testReasonsExistForExactlyTheUnmodelledKeys() {
        let reasoned = Set(PRIVACY_UNMODELLED_WHY.keys)

        let staleReasons = reasoned.intersection(modelled).sorted()
        XCTAssertEqual(staleReasons, [],
                       "R445: PRIVACY_UNMODELLED_WHY explains \(staleReasons.count) key(s) that "
                       + "privacyKeyMap DOES model. A reason for a closed gap is a false all-clear "
                       + "waiting to be read — delete the entry when you model the key: \(staleReasons)")

        let unexplained = unmodelled.subtracting(reasoned).sorted()
        XCTAssertEqual(unexplained, [],
                       "\(unexplained.count) key(s) left the model with no recorded reason, so the "
                       + "verify's own gap disclosure would print the NO REASON RECORDED placeholder. "
                       + "Add the reason to PRIVACY_UNMODELLED_WHY: \(unexplained)")

        // …and a reason naming a key Apple does not document explains nothing at all.
        let orphans = reasoned.subtracting(Set(APPLE_PRIVACY_KEYS)).sorted()
        XCTAssertEqual(orphans, [],
                       "PRIVACY_UNMODELLED_WHY names key(s) absent from Apple's universe: \(orphans)")
    }

    /// The shipped accessor is what the output actually reads, so assert on IT, not only on the tables:
    /// the placeholder must never be reachable in a green tree, and it must carry a real reason per key.
    func testTheShippedDisclosureCarriesARealReasonForEveryKeyItNames() {
        let disclosed = PRIVACY_UNMODELLED_KEYS
        XCTAssertEqual(Set(disclosed.map { $0.key }), unmodelled,
                       "PRIVACY_UNMODELLED_KEYS must be exactly Apple's universe minus privacyKeyMap")
        for d in disclosed {
            XCTAssertFalse(d.why.hasPrefix("NO REASON RECORDED"),
                           "\(d.key) reaches the user-facing disclosure with the placeholder reason")
            // Long enough to be a reason rather than a label. "not modelled" — the R445 string — is 12.
            XCTAssertGreaterThan(d.why.count, 40,
                                 "\(d.key)'s reason is a label, not a reason: \(d.why)")
        }
    }

    /// `privacyKeyMap` must only ever emit keys Apple documents — a typo here is a key the verify demands
    /// and Apple has never heard of, and it would ALSO silently inflate the modelled count while leaving
    /// the real key in the unmodelled list.
    func testEveryModelledKeyIsOneAppleDocuments() {
        let invented = modelled.subtracting(Set(APPLE_PRIVACY_KEYS)).sorted()
        XCTAssertEqual(invented, [],
                       "privacyKeyMap emits key(s) that are not in Apple's documented universe: \(invented)")
    }

    /// The arithmetic the COVERAGE line prints: modelled + unmodelled == the universe, and the universe
    /// has no duplicate row. A duplicate would make `.count` — printed verbatim as "Apple's N documented
    /// … keys" — overstate the denominator, which is the under-reporting direction for a disclosure.
    func testTheCoverageArithmeticThatIsPrintedHolds() {
        XCTAssertEqual(Set(APPLE_PRIVACY_KEYS).count, APPLE_PRIVACY_KEYS.count,
                       "duplicate key in APPLE_PRIVACY_KEYS inflates the printed denominator")
        XCTAssertEqual(modelled.intersection(Set(APPLE_PRIVACY_KEYS)).count + unmodelled.count,
                       APPLE_PRIVACY_KEYS.count)
        // A tripwire on the FETCHED universe, not on the model: this number may only change when Apple's
        // protected-resources list changes, and changing it should mean re-fetching, not editing to fit.
        let expectedUniverseCount = 57
        XCTAssertEqual(APPLE_PRIVACY_KEYS.count, expectedUniverseCount,
                       "Apple's key universe changed size. Re-fetch protected-resources.json (the doc "
                       + "comment has the URL) rather than adjusting this number to match the table.")
    }
}
