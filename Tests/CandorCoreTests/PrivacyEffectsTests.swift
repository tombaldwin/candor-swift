import XCTest
import Foundation
@testable import CandorCore

/// End-to-end pins for the `privacy/1` SPEC EXTENSION (SPEC-EXTENSION-privacy.md) — the six Apple
/// privacy-sensor effects (Location/Camera/Mic/Contacts/Photos/Notify). Each is classified by the framework
/// TYPE the call targets (the same `MODEL_SDK_TYPES` mechanism as `Llm`); each is a boundary effect that is
/// gate-able (`deny Location`), high-salience, and DISCLOSED via the envelope's `extensions` array — but is
/// NOT allowlistable via a literal (a sensor read has no host/path to certify). These are properties of the
/// whole scan + gate, so they are pinned at the process layer (mirrors LlmProcessTests / GateProcessTests).
final class PrivacyEffectsTests: XCTestCase {

    private func scan(_ src: String) throws -> (by: [String: [String: Any]], envelope: [String: Any]) {
        let bin = try ProcessHarness.binaryURL(for: PrivacyEffectsTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let by = try ProcessHarness.fns(ofJson: r.out)
        let env = (try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]) ?? [:]
        return (by, env)
    }

    /// Run a scan + `--policy` gate over `src`, returning the process result.
    private func gate(_ src: String, policy: String) throws -> (out: String, err: String, code: Int32) {
        let bin = try ProcessHarness.binaryURL(for: PrivacyEffectsTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let policyFile = root.appendingPathComponent("policy.txt")
        try policy.write(to: policyFile, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--json", "--policy", policyFile.path])
    }

    // ── (a) each sensor type classifies its effect ──────────────────────────────────────────────────
    func testLocationManagerClassifiesLocation() throws {
        let (by, env) = try scan("""
        import Foundation
        import CoreLocation
        struct Tracker {
            let manager = CLLocationManager()
            func whereAmI() { manager.requestLocation() }
        }
        Tracker().whereAmI()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Tracker.whereAmI"), ["Location"],
                       "a CLLocationManager call carries Location")
        // NO companion effect: a sensor read is not network I/O (unlike Llm which adds Net).
        XCTAssertEqual(env["extensions"] as? [String], ["privacy/2"], "the extension must be disclosed")
    }

    func testAudioRecorderClassifiesMic() throws {
        let (by, _) = try scan("""
        import Foundation
        import AVFoundation
        struct Rec {
            func capture() {
                let r = try? AVAudioRecorder(url: URL(fileURLWithPath: "/tmp/a.m4a"), settings: [:])
                r?.record()
            }
        }
        Rec().capture()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Rec.capture"), ["Mic"],
                       "AVAudioRecorder is unambiguously Mic")
    }

    // finding 5 — a bare AVCaptureSession (no visible media-type arg) is AMBIGUOUS: it could capture audio
    // OR video, so it over-discloses BOTH Camera AND Mic. A missed sensor in a privacy manifest is the
    // App-Store-rejection-shaped error, so an ambiguous capture declares both (never silently under-declare).
    func testBareCaptureSessionClassifiesBothCameraAndMic() throws {
        let (by, _) = try scan("""
        import Foundation
        import AVFoundation
        struct Cam {
            func start() {
                let s = AVCaptureSession()
                s.startRunning()
            }
        }
        Cam().start()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Cam.start"), ["Camera", "Mic"],
                       "a bare AVCaptureSession is an ambiguous capture → over-disclose BOTH Camera and Mic")
    }

    // finding 5 — the media-type argument is STATICALLY VISIBLE on AVCaptureDevice.default(for:), so the
    // Camera/Mic split is precise: `.audio` → Mic, `.video` → Camera.
    func testCaptureDeviceAudioClassifiesMic() throws {
        let (by, _) = try scan("""
        import Foundation
        import AVFoundation
        struct Rec {
            func mic() {
                _ = AVCaptureDevice.default(for: .audio)
            }
        }
        Rec().mic()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Rec.mic"), ["Mic"],
                       "AVCaptureDevice.default(for: .audio) is a microphone capture → Mic, not Camera")
    }

    func testCaptureDeviceVideoClassifiesCamera() throws {
        let (by, _) = try scan("""
        import Foundation
        import AVFoundation
        struct Cam {
            func lens() {
                _ = AVCaptureDevice.default(for: .video)
            }
        }
        Cam().lens()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Cam.lens"), ["Camera"],
                       "AVCaptureDevice.default(for: .video) is a camera capture → Camera, not Mic")
    }

    // finding 5 — a capture with a media-type arg that is NOT statically visible (a variable) is ambiguous
    // → over-disclose BOTH (the safe privacy direction — never miss a real sensor behind a runtime value).
    func testCaptureDeviceRuntimeMediaTypeClassifiesBoth() throws {
        let (by, _) = try scan("""
        import Foundation
        import AVFoundation
        struct Any_ {
            func capture(mt: AVMediaType) {
                _ = AVCaptureDevice.default(for: mt)
            }
        }
        Any_().capture(mt: .audio)
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Any_.capture"), ["Camera", "Mic"],
                       "a runtime media-type arg is ambiguous → over-disclose BOTH Camera and Mic")
    }

    // ── finding 4 — AVAudioEngine is mic-gated on `.inputNode`, not the bare type ────────────────────
    // A playback-only AVAudioEngine (no `.inputNode`) must NOT be fabricated as Mic (it is a general
    // audio-graph type — playback/synthesis/mixing). Bare AVAudioEngine was removed from the Mic table.
    func testAudioEnginePlaybackIsNotMic() throws {
        let (by, env) = try scan("""
        import Foundation
        import AVFoundation
        struct Player {
            func play() {
                let engine = AVAudioEngine()
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.prepare()
                try? engine.start()
                node.play()
            }
        }
        Player().play()
        """)
        XCTAssertFalse((ProcessHarness.inferred(by, "Player.play") ?? []).contains("Mic"),
                       "a playback-only AVAudioEngine touches no microphone — classifying Mic fabricates")
        XCTAssertNil(env["extensions"], "no privacy effect present → extensions must be omitted")
    }

    // The mic-specific member `AVAudioEngine.inputNode` (and a tap installed on it) IS Mic — member-gated.
    func testAudioEngineInputNodeClassifiesMic() throws {
        let (by, _) = try scan("""
        import Foundation
        import AVFoundation
        struct Capture {
            func listen() {
                let engine = AVAudioEngine()
                let input = engine.inputNode
                input.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
                try? engine.start()
            }
        }
        Capture().listen()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Capture.listen"), ["Mic"],
                       "AVAudioEngine.inputNode (the microphone input) is Mic — member-gated, not the bare type")
    }

    func testContactStoreClassifiesContacts() throws {
        let (by, _) = try scan("""
        import Foundation
        import Contacts
        struct Book {
            func load() {
                let store = CNContactStore()
                _ = try? store.unifiedContacts(matching: .init(), keysToFetch: [])
            }
        }
        Book().load()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Book.load"), ["Contacts"],
                       "a CNContactStore call carries Contacts")
    }

    func testPhotoLibraryClassifiesPhotos() throws {
        let (by, _) = try scan("""
        import Foundation
        import Photos
        struct Album {
            func save() {
                PHPhotoLibrary.shared().performChanges({})
            }
        }
        Album().save()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Album.save"), ["Photos"],
                       "a PHPhotoLibrary call carries Photos")
    }

    func testNotificationCenterClassifiesNotify() throws {
        let (by, _) = try scan("""
        import Foundation
        import UserNotifications
        struct Alert {
            func ping() {
                let center = UNUserNotificationCenter.current()
                center.add(UNNotificationRequest(identifier: "x", content: .init(), trigger: nil))
            }
        }
        Alert().ping()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Alert.ping"), ["Notify"],
                       "a UNUserNotificationCenter call carries Notify")
    }

    // ── (b) anti-fabrication: a LOCAL type named like a sensor type does NOT get the effect ──────────
    func testProjectTypeShadowingLocationManagerStaysPure() throws {
        let (by, env) = try scan("""
        import Foundation
        struct CLLocationManager { func requestLocation() {} }
        func local() { let m = CLLocationManager(); m.requestLocation() }
        """)
        XCTAssertNil(by["local"], "a project's own CLLocationManager is not CoreLocation's — classifying fabricates")
        // no privacy effect anywhere → the extension is NOT disclosed.
        XCTAssertNil(env["extensions"], "no privacy effect present → extensions must be omitted")
    }

    // ── (c) wire disclosure: a plain (non-privacy) report OMITS the extensions key ───────────────────
    func testPlainReportOmitsExtensions() throws {
        let (_, env) = try scan("""
        import Foundation
        struct Api {
            func call() {
                let t = URLSession.shared.dataTask(with: "https://api.stripe.com/v1/charges") { _, _, _ in }
                t.resume()
            }
        }
        Api().call()
        """)
        XCTAssertNil(env["extensions"], "a plain report must omit the extensions key (byte-unchanged)")
    }

    // ── (d) deny Location gates a location-reaching function (exit 1; the diagnostic names Location) ──
    func testDenyLocationGatesLocationReach() throws {
        let r = try gate("""
        import Foundation
        import CoreLocation
        struct Tracker {
            func whereAmI() {
                let m = CLLocationManager()
                m.requestLocation()
            }
        }
        Tracker().whereAmI()
        """, policy: "deny Location\n")
        XCTAssertEqual(r.code, 1, "deny Location must gate a location-reaching function — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-006") && r.err.contains("Location"),
                      "the deny diagnostic must name Location; stderr: \(r.err)")
    }

    // a non-location function is NOT caught by `deny Location` — the effect is specific.
    func testDenyLocationDoesNotGatePlainNet() throws {
        let r = try gate("""
        import Foundation
        struct Api {
            func call() {
                let t = URLSession.shared.dataTask(with: "https://api.stripe.com/v1/charges") { _, _, _ in }
                t.resume()
            }
        }
        Api().call()
        """, policy: "deny Location\n")
        XCTAssertEqual(r.code, 0, "a non-location function carries no Location — deny Location must pass; stderr: \(r.err)")
    }

    // ── (e) NOT allowlistable via a literal: `allow Location …` is rejected (no host/path to certify) ─
    func testAllowLocationIsRejected() throws {
        // Location is not in ALLOW_EFFECTS (like Ipc/Clipboard) — there is no literal surface to certify.
        //
        // ⟨0.24⟩ **THIS ROW CHANGED, AND THE OLD ANSWER WAS THE DEFECT** (SPEC §6.2, candor-spec
        // `1e1748a`). It used to be warned-and-IGNORED with the scan exiting 0, so a location-reaching fn
        // was UNGATED while the operator read an `allow` rule that gated nothing at all. A dropped rule is
        // the LIMIT CASE of "silently rewritten into a different policy": the policy that ran was the one
        // WITHOUT this line. `allow`'s effect position is a fixed, CLOSED set with no scope reading
        // available, so a token outside it cannot be honoured as written and refusing loses nothing.
        // Now exit 2, naming the token and the accepted set; the stderr warning is unchanged, it is just
        // no longer the whole answer.
        //
        // The DENY half is untouched — `deny Location` is the correct way to gate a sensor, and rows
        // (a)–(d) above pin that it still fires.
        let r = try gate("""
        import Foundation
        import CoreLocation
        struct Tracker {
            func whereAmI() {
                let m = CLLocationManager()
                m.requestLocation()
            }
        }
        Tracker().whereAmI()
        """, policy: "allow Location somewhere\n")
        XCTAssertEqual(r.code, 2, "`allow Location` cannot be honoured, and a rule the engine cannot honour "
                       + "is REFUSED rather than dropped — dropping it left the sensor ungated behind a "
                       + "rule that looked like a gate; stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("ignoring policy rule"),
                      "the unsupported allow rule is still warned about; stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("`Location`") && r.err.contains("Db, Exec, Fs, Llm, Net"),
                      "and the refusal names the token AND the closed set it is outside of; stderr: \(r.err)")
    }

    // ── privacy/2 ────────────────────────────────────────────────────────────────────────────────────
    // Every second-wave type must classify, and the two ambiguity rules must behave as documented. Written
    // because the wave exists to stop `exit 0` meaning "the six I model are declared" while reading as
    // "your plist is right".
    func testSecondWaveTypesClassify() {
        let expected: [(String, String)] = [
            ("HKHealthStore", "Health"), ("HKSampleQuery", "Health"), ("HKLiveWorkoutBuilder", "Health"),
            ("CMMotionManager", "Motion"), ("CMPedometer", "Motion"), ("CMHeadphoneMotionManager", "Motion"),
            ("EKEventEditViewController", "Calendar"),
            ("CBCentralManager", "Bluetooth"), ("CBPeripheralManager", "Bluetooth"),
            ("SFSpeechRecognizer", "Speech"), ("LAContext", "Biometrics"),
            ("MPMediaLibrary", "MediaLibrary"), ("MPMediaQuery", "MediaLibrary"),
            ("HMHomeManager", "HomeKit"), ("ATTrackingManager", "Tracking"),
            ("NISession", "NearbyInteraction"), ("INPreferences", "Siri"),
        ]
        for (type, effect) in expected {
            XCTAssertEqual(PRIVACY_SDK_TYPES[type], effect, "\(type) must classify as \(effect)")
        }
    }

    /// Value types CARRY a reading; they do not take one. The CLLocation precedent, applied to the new wave
    /// — a fabricated `Health` on a struct holding a already-read quantity is the precision failure.
    func testSecondWaveValueTypesAreNotClassified() {
        for t in ["HKQuantity", "HKQuantitySample", "CMDeviceMotion", "CMAccelerometerData",
                  "EKEvent", "EKReminder", "CBUUID", "MPMediaItem"] {
            XCTAssertNil(PRIVACY_SDK_TYPES[t], "\(t) carries a reading — classifying it would fabricate")
        }
    }

    /// EventKit's split mirrors the capture split exactly, including the ambiguous default.
    func testEventKitAmbiguityMirrorsCapture() {
        XCTAssertEqual(privacyEventKitEffects(entityType: "event"), ["Calendar"])
        XCTAssertEqual(privacyEventKitEffects(entityType: "reminder"), ["Reminders"])
        XCTAssertEqual(privacyEventKitEffects(entityType: nil).sorted(), ["Calendar", "Reminders"])
        XCTAssertEqual(privacyEventKitEffects(entityType: "somethingElse").sorted(), ["Calendar", "Reminders"])
        // and the store itself is NOT in the flat table — it is only reachable through the discriminator,
        // which is what stops a bare lookup from silently picking one side.
        XCTAssertNil(PRIVACY_SDK_TYPES["EKEventStore"])
        XCTAssertTrue(PRIVACY_EVENTKIT_TYPES.contains("EKEventStore"))
    }

    /// LocalNetwork is absent ON PURPOSE — the reach is not separable from `Net` by type. Asserted so the
    /// omission is a decision with a test behind it rather than something nobody got round to.
    func testLocalNetworkIsDeliberatelyAbsent() {
        for t in ["NWBrowser", "NWListener", "NetServiceBrowser", "NetService"] {
            XCTAssertNil(PRIVACY_SDK_TYPES[t], "\(t) must not carry a LocalNetwork effect — see the extension doc")
        }
    }

    // ── privacy/2 direction ──────────────────────────────────────────────────────────────────────────
    // Apple distinguishes reading from writing in three key families (HealthKit Share/Update, Photos
    // full/Add, Calendars full/write-only) and the first wave collapsed all three into interchangeable
    // alternatives — which let an app that both reads and writes HealthKit pass while declaring only
    // Share, and be rejected by Apple. These assert the direction half, and above all what it REFUSES
    // to claim.
    func testPrivacyWriteVerbs() {
        for m in ["save", "delete", "remove", "addSamples", "performChanges",
                  "creationRequestForAsset", "requestWriteOnlyAccessToEvents"] {
            XCTAssertEqual(privacyKind(root: "HKHealthStore", member: m), ["write"], "\(m) mutates the store")
        }
    }

    func testPrivacyReadVerbs() {
        for m in ["execute", "fetchAssets", "events", "predicateForEvents", "requestImage",
                  "unifiedContacts", "requestFullAccessToEvents"] {
            XCTAssertEqual(privacyKind(root: "HKHealthStore", member: m), ["read"], "\(m) observes only")
        }
    }

    /// `requestAuthorization(toShare:read:)` names BOTH sides in one call and the discriminating argument
    /// is a Set built at runtime — genuinely ambiguous, so it declares both on this extension's standing
    /// trade-off (a missed sensor is the App-Store-shaped error).
    func testAuthorizationRequestIsAmbiguousAndDeclaresBoth() {
        XCTAssertEqual(privacyKind(root: "HKHealthStore", member: "requestAuthorization").sorted(),
                       ["read", "write"])
    }

    /// THE LOAD-BEARING CASE, same as `fs`: a verb that reveals nothing contributes nothing, and the
    /// effect keeps its pre-`privacy/2` any-key semantics. Anything here returning a direction would ADD
    /// a key requirement on the strength of a verb that said neither.
    func testUnrevealingVerbsMakeNoClaim() {
        for m in ["isAvailable", "authorizationStatus2", "someFutureVerb", "init", "description"] {
            XCTAssertEqual(privacyKind(root: "HKHealthStore", member: m), [],
                           "\(m) must not claim a direction it did not reveal")
        }
    }

    /// The direction-sensitive key families, asserted as DATA — a wrong key here is an App-Store-shaped
    /// wrong answer, and the three pairs are exactly the ones Apple splits.
    func testDirectionSensitiveKeyFamilies() {
        XCTAssertEqual(privacyKeyMapByDirection["Health"]?["read"], ["NSHealthShareUsageDescription"])
        XCTAssertEqual(privacyKeyMapByDirection["Health"]?["write"], ["NSHealthUpdateUsageDescription"])
        // Add-only permits writing and nothing else; the full key permits both, so it satisfies a write.
        // Reading REQUIRES the full key — Add-only does not grant it.
        XCTAssertEqual(privacyKeyMapByDirection["Photos"]?["read"], ["NSPhotoLibraryUsageDescription"])
        XCTAssertTrue(privacyKeyMapByDirection["Photos"]?["write"]?.contains("NSPhotoLibraryAddUsageDescription") ?? false)
        XCTAssertFalse(privacyKeyMapByDirection["Photos"]?["read"]?.contains("NSPhotoLibraryAddUsageDescription") ?? true,
                       "Add-only must NOT satisfy a read")
        XCTAssertFalse(privacyKeyMapByDirection["Calendar"]?["read"]?.contains("NSCalendarsWriteOnlyAccessUsageDescription") ?? true,
                       "write-only must NOT satisfy a read")
    }

    /// Only the three families Apple actually splits are direction-sensitive. A single-key effect must
    /// stay out, or a proved direction would start demanding a key that does not exist.
    func testOnlyAppleSplitFamiliesAreDirectionSensitive() {
        XCTAssertEqual(Set(privacyKeyMapByDirection.keys), ["Health", "Photos", "Calendar"])
        for e in ["Contacts", "Mic", "Location", "Motion", "Bluetooth"] {
            XCTAssertNil(privacyKeyMapByDirection[e], "\(e) has one key — direction cannot change it")
        }
    }
}
