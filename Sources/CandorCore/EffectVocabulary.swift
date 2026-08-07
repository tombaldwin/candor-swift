// candor-swift — the EFFECT VOCABULARY: the wire-level `Effect` enum and `EffectSet`.
//
// WHY THIS IS IN CandorCore AND NOT NEXT TO THE REST OF THE DOMAIN MODEL.
//
// This enum is the LAST copy of the sensor vocabulary in the pipeline and the only one that decides
// what reaches the report: `EffectSet.init` is a `compactMap(Effect.from)`, so a name the classifier
// produces that is not a case here is computed, propagated, gated on in-process — and then silently
// dropped at serialisation. A function whose only effect was that name serialises as `inferred: []`,
// which under ⟨0.21⟩ is a positive purity claim. It is the cardinal sin with no failure anywhere.
//
// That has now happened TWICE (privacy/3's nine families; privacy/4's `MotionRaw`). Both times the
// name was correctly present in the type table, the key map and `PRIVACY_EFFECTS_ORDER`, and both
// times nothing went red — because this type lived in the EXECUTABLE target, which SwiftPM cannot
// `@testable import`, so no unit test could see it to check. The vocabulary was untestable by
// construction, which is the actual root cause; adding the missing case a second time would have
// left that intact. Moving it into the library target is what makes
// `EffectVocabularyTests.testEveryClassifiedEffectReachesTheReport` possible — it asserts every name
// in `PRIVACY_EFFECTS_ORDER` and `privacyKeyMap` round-trips through `Effect.from`, so the next
// family added to the classifier and forgotten here fails the build instead of the user.
//
// Independence is preserved: this is still a HAND-WRITTEN list, not derived from the classifier's.
// The test compares two independent copies; it does not collapse them into one.

import Foundation

// ── The candor domain model (candor-spec/MODEL.md) — candor-swift's named realization of the shared
// vocabulary. Independently derived (NO shared code across engines — that independence is what the
// conformance differential proves); mirrors candor-java's `io.poly.candor.model` and Rust's candor-report
// structs. These types OWN the §2 wire serialization, so the entry/envelope shape lives in one place.
public enum Effect: String, CaseIterable, Sendable {
    case clipboard = "Clipboard", clock = "Clock", db = "Db", env = "Env", exec = "Exec"
    case fs = "Fs", ipc = "Ipc", llm = "Llm", log = "Log", net = "Net", rand = "Rand", unknown = "Unknown"
    // `privacy/1` SPEC EXTENSION (SPEC-EXTENSION-privacy.md) — Apple privacy-sensor effects. Each is an
    // outside-world surface (a sensor / personal-data store / the user's attention) on the same footing as
    // Clipboard (main-spec §6.1): a boundary effect, high-salience, NOT allowlistable via a literal (there is
    // no host/path to certify — `deny Location`/containment yes, `allow Location <x>` no). The extension is
    // DISCLOSED in the envelope's `extensions` array when any of these appears (Report.privacyActive).
    case location = "Location", camera = "Camera", mic = "Mic", contacts = "Contacts", photos = "Photos", notify = "Notify"
    // privacy/2 (2026-08-04) — the second wave; see SPEC-EXTENSION-privacy.md
    case health = "Health", motion = "Motion", calendar = "Calendar", reminders = "Reminders", bluetooth = "Bluetooth", speech = "Speech", biometrics = "Biometrics", mediaLibrary = "MediaLibrary", homeKit = "HomeKit", tracking = "Tracking", nearbyInteraction = "NearbyInteraction", siri = "Siri"
    // privacy/3 (2026-08-05) — added after fetching Apple's protected-resources list (56 keys documented,
    // 26 modelled). THIS ENUM IS THE SEVENTH COPY OF THE SENSOR VOCABULARY and the last one to matter:
    // `Effect.from` returns nil for a name that is not a case, so a family present in the type table, the
    // key map, the ordered list and four other places was still COMPUTED AND THEN DISCARDED at
    // serialisation. Nothing failed; the effect simply never reached the report.
    case nfc = "Nfc", fallDetection = "FallDetection", sensorKit = "SensorKit", fileProvider = "FileProvider",
         systemExtension = "SystemExtension", appleEvents = "AppleEvents", videoSubscriber = "VideoSubscriber",
         gameCenterFriends = "GameCenterFriends", clinicalRecords = "ClinicalRecords"
    // privacy/4 (2026-08-05)
    case focusStatus = "FocusStatus", identity = "Identity", financialData = "FinancialData",
         handsTracking = "HandsTracking", worldSensing = "WorldSensing", mainCamera = "MainCamera",
         locationTemporary = "LocationTemporary", accessoryTracking = "AccessoryTracking"
    // privacy/4 (2026-08-06) — the raw CoreMotion stream, split from `Motion` because Apple requires
    // NSMotionUsageDescription for the stored/derived APIs and NOT for CMMotionManager. Added here in a
    // FOLLOW-UP to the split, which is the whole point of this comment: the privacy/3 note above names
    // this exact failure mode, and the split shipped without this case regardless. `CMMotionManager` was
    // classified `MotionRaw`, then dropped by `EffectSet.init`'s `compactMap` — so a function whose only
    // effect was the raw stream serialised as `inferred: []`, an unqualified purity claim, on every
    // channel including the ⟨0.24⟩ `gate --report` route (live gate exit 1, report gate exit 0 on the
    // same policy). Removing an over-report replaced it with silence, which is the worse half.
    // `testEveryClassifiedEffectReachesTheReport` now pins the round-trip so the eighth copy of the
    // vocabulary cannot drift from the first again without a red test.
    case motionRaw = "MotionRaw"
    // privacy/4 (2026-08-07) — the out-of-process system pickers, keyless for the same reason as
    // MotionRaw: a real surface, no manifest requirement.
    case contactsPicker = "ContactsPicker", photosPicker = "PhotosPicker"
    // privacy/4 (2026-08-07) — EventKit's UI classes, split from `Calendar`: their NSCalendars* key is
    // required only below iOS 17 (EventKitUI is out-of-process on 17+), which the verify reports as a
    // NAMED CONDITION rather than a hard failure. Case added IN THE SAME EDIT as the classifier row —
    // the MotionRaw note above is about forgetting exactly this.
    case calendarUI = "CalendarUI"
    // constant-basis families (CONSTANT-PROVENANCE-DESIGN.md rungs 1-2)
    case folderDesktop = "FolderDesktop", folderDocuments = "FolderDocuments",
         folderDownloads = "FolderDownloads", removableVolume = "RemovableVolume",
         networkVolume = "NetworkVolume", localNetwork = "LocalNetwork",
         systemAdministration = "SystemAdministration", audioCapture = "AudioCapture",
         appBundles = "AppBundles", appData = "AppData", criticalMessaging = "CriticalMessaging"
    public var specName: String { rawValue }
    public static func from(_ name: String) -> Effect? { Effect(rawValue: name) }
}
// The `privacy/1` extension's effect NAMES (the six SPEC-EXTENSION-privacy.md effects). Used to detect
// whether the extension is active (any effector reaches one) so the envelope discloses `extensions`.

public let PRIVACY_EFFECTS: Set<String> = PRIVACY_EFFECTS_ALL   // derived — see PRIVACY_EFFECTS_ALL
// A set of effects (SEMANTICS §1). Wire form = spec-name-sorted names — which, for this vocabulary, is the
// same lexicographic order a `Set<String>.sorted()` produced, so adoption is byte-identical.
public struct EffectSet {
    public private(set) var effects: Set<Effect>
    public init(names: some Sequence<String>) { self.effects = Set(names.compactMap(Effect.from)) }
    public func toNames() -> [String] { effects.map { $0.specName }.sorted() }
}
