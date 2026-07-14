import XCTest
import Foundation

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
        XCTAssertEqual(env["extensions"] as? [String], ["privacy/1"], "the extension must be disclosed")
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

    func testCaptureSessionClassifiesCamera() throws {
        // The AVCaptureDevice/Session ambiguity STARTER call: a bare AVCaptureSession is Camera (the dominant
        // use); finer audio/video discrimination by the media-type argument is a future refinement.
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
        XCTAssertEqual(ProcessHarness.inferred(by, "Cam.start"), ["Camera"],
                       "a bare AVCaptureSession is Camera (the starter call for the audio/video ambiguity)")
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
        // Location is not in ALLOW_EFFECTS (like Ipc/Clipboard) — `allow Location <x>` is warned + ignored,
        // so a location-reaching fn is UNGATED by an allow rule (only deny/containment name it). The scan
        // still succeeds (exit 0) — the malformed rule is dropped, not a hard error.
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
        XCTAssertEqual(r.code, 0, "allow Location is not a thing — the rule is ignored, the scan passes; stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("ignoring policy rule"),
                      "the unsupported allow rule must be warned + ignored; stderr: \(r.err)")
    }
}
