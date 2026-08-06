// The vocabulary round-trip gate. See Sources/CandorCore/EffectVocabulary.swift for the two incidents
// that motivated it.
//
// The pipeline has several independent copies of the sensor vocabulary — the SDK type table, the
// usage-key map, the ordered list, and the `Effect` enum that owns serialisation. Independence is
// deliberate (they are cross-checks, not one list read four times). What was missing was any check
// that they AGREE, and the disagreement is not symmetric: a name the classifier can produce but the
// enum does not carry is dropped by `EffectSet.init`'s `compactMap`, so the effect is computed,
// propagated and gated in-process and then vanishes from the report. The function reads as pure.
//
// These tests are cheap and they are the only thing standing between "a family was added to the
// classifier" and "a function that reaches it serialises as `inferred: []`".

import XCTest
@testable import CandorCore

final class EffectVocabularyTests: XCTestCase {

    /// Every effect name the classifier can EMIT must survive serialisation.
    ///
    /// `MotionRaw` failed exactly this: present in `PRIVACY_SDK_TYPES`, `privacyKeyMap` and
    /// `PRIVACY_EFFECTS_ORDER`, absent from `Effect`, therefore absent from every report.
    func testEveryClassifiedEffectReachesTheReport() {
        for name in PRIVACY_EFFECTS_ORDER {
            XCTAssertNotNil(Effect.from(name),
                "'\(name)' is in PRIVACY_EFFECTS_ORDER but has no `Effect` case, so EffectSet.init "
                + "drops it and a function whose only effect is \(name) serialises as `inferred: []` "
                + "— a purity claim about a function with a real sensor reach.")
        }
        for name in PRIVACY_SDK_TYPES.values {
            XCTAssertNotNil(Effect.from(name),
                "SDK type table maps to '\(name)', which has no `Effect` case — it would be dropped "
                + "at serialisation.")
        }
        for name in privacyKeyMap.keys {
            XCTAssertNotNil(Effect.from(name),
                "privacyKeyMap keys '\(name)', which has no `Effect` case.")
        }
    }

    /// …and the reverse, which catches a case left behind after a rename: a privacy-family `Effect`
    /// case that no classifier table can produce is dead vocabulary, and a policy naming it would be
    /// accepted while never being able to fire.
    func testNoPrivacyEffectCaseIsUnreachable() {
        let producible = Set(PRIVACY_EFFECTS_ORDER)
        let core: Set<String> = ["Clipboard", "Clock", "Db", "Env", "Exec", "Fs", "Ipc", "Llm",
                                 "Log", "Net", "Rand", "Unknown"]
        for e in Effect.allCases where !core.contains(e.specName) {
            XCTAssertTrue(producible.contains(e.specName),
                "`Effect.\(e)` ('\(e.specName)') is in no classifier table — a policy could name it "
                + "and it could never fire.")
        }
    }

    /// The drop was invisible because it happened inside a `compactMap`. Pin the mechanism directly,
    /// so the reason this class of defect is silent stays documented in an executable form.
    func testEffectSetDropsUnknownNamesSilently() {
        let s = EffectSet(names: ["Net", "NoSuchEffectFamily"])
        XCTAssertEqual(s.toNames(), ["Net"],
            "EffectSet silently discards names with no `Effect` case — which is WHY the round-trip "
            + "assertions above exist. If this ever throws or preserves instead, revisit them.")
    }
}
