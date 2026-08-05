#!/usr/bin/env python3
"""PRIVACY-MANIFEST RECALL BATTERY.

The asymmetry that matters: an OVER-report costs a confusing permission prompt; an UNDER-report costs an
App Store REJECTION. So this measures the miss set, one fixture per Apple usage-description key family,
each exercising the canonical API a real app would call.

It deliberately includes families candor does NOT model, because "we found everything we look for" is
not the question. The question is what an app can require that we stay silent about.

CAVEAT ON THE ORACLE, stated up front: the expected-key list below is hand-compiled and is the weakest
part of this measurement. It should be diffed against Apple's current documentation before anyone
publishes a number from it. A key missing from THIS list is invisible to THIS battery.

    python3 tools/privacy-recall.py        # from the candor-swift repo root

EXIT 0 when every miss is a KNOWN one (listed in `PRIVACY_UNMODELLED_KEYS` and disclosed by the verify),
1 when a family we CLAIM to model is missed. The second is the rejection risk; the first is a documented
bound. That distinction is the whole point — this gate ratchets the modelled set and does not pretend
the unmodelled set is empty.

FOUND ON ITS FIRST RUN: `AVAudioSession.sharedInstance().setCategory(.record)` — how essentially every
recording app reaches the microphone — emitted NOTHING, on a sensor the vocabulary CLAIMS. The cause was
one level down and general: `X.sharedInstance()` as a receiver resolved to no type at all, because the
singleton convention was handled for the PROPERTY spellings (`FileManager.default`) and not the
parenthesised one.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

BIN = os.path.expanduser("~/git/candor-swift/.build/debug/candor-swift")

# (label, expected NS…UsageDescription or None, swift source exercising the canonical API)
CASES = [
    ("Camera / AVCaptureDevice", "NSCameraUsageDescription",
     'import AVFoundation\nfunc f() { _ = AVCaptureDevice.default(for: .video) }'),
    ("Camera / UIImagePickerController", "NSCameraUsageDescription",
     'import UIKit\nfunc f() { let p = UIImagePickerController(); p.sourceType = .camera }'),
    ("Mic / AVAudioRecorder", "NSMicrophoneUsageDescription",
     'import AVFoundation\nfunc f() { _ = try? AVAudioRecorder(url: URL(fileURLWithPath: "/tmp/a"), settings: [:]) }'),
    ("Mic / AVAudioSession.record", "NSMicrophoneUsageDescription",
     'import AVFoundation\nfunc f() { try? AVAudioSession.sharedInstance().setCategory(.record) }'),
    ("Photos / PHPhotoLibrary", "NSPhotoLibraryUsageDescription",
     'import Photos\nfunc f() { PHPhotoLibrary.requestAuthorization { _ in } }'),
    ("Photos add-only / PHAssetCreation", "NSPhotoLibraryAddUsageDescription",
     'import Photos\nfunc f() { PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in } }'),
    ("Contacts / CNContactStore", "NSContactsUsageDescription",
     'import Contacts\nfunc f() { _ = try? CNContactStore().containers(matching: nil) }'),
    ("Calendar / EKEventStore events", "NSCalendarsFullAccessUsageDescription",
     'import EventKit\nfunc f() { EKEventStore().requestFullAccessToEvents { _, _ in } }'),
    ("Reminders / EKEventStore", "NSRemindersFullAccessUsageDescription",
     'import EventKit\nfunc f() { EKEventStore().requestFullAccessToReminders { _, _ in } }'),
    ("Location / CLLocationManager", "NSLocationWhenInUseUsageDescription",
     'import CoreLocation\nfunc f() { CLLocationManager().requestWhenInUseAuthorization() }'),
    ("Motion / CMMotionManager", "NSMotionUsageDescription",
     'import CoreMotion\nfunc f() { CMMotionManager().startAccelerometerUpdates() }'),
    ("Motion / CMPedometer", "NSMotionUsageDescription",
     'import CoreMotion\nfunc f() { CMPedometer().startUpdates(from: Date()) { _, _ in } }'),
    ("Health read / HKHealthStore", "NSHealthShareUsageDescription",
     'import HealthKit\nfunc f() { HKHealthStore().requestAuthorization(toShare: nil, read: []) { _, _ in } }'),
    ("Bluetooth / CBCentralManager", "NSBluetoothAlwaysUsageDescription",
     'import CoreBluetooth\nfunc f() { _ = CBCentralManager(delegate: nil, queue: nil) }'),
    ("Speech / SFSpeechRecognizer", "NSSpeechRecognitionUsageDescription",
     'import Speech\nfunc f() { SFSpeechRecognizer.requestAuthorization { _ in } }'),
    ("FaceID / LAContext", "NSFaceIDUsageDescription",
     'import LocalAuthentication\nfunc f() { _ = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }'),
    ("Media library / MPMediaLibrary", "NSAppleMusicUsageDescription",
     'import MediaPlayer\nfunc f() { MPMediaLibrary.requestAuthorization { _ in } }'),
    ("HomeKit / HMHomeManager", "NSHomeKitUsageDescription",
     'import HomeKit\nfunc f() { _ = HMHomeManager() }'),
    ("Tracking / ATTrackingManager", "NSUserTrackingUsageDescription",
     'import AppTrackingTransparency\nfunc f() { ATTrackingManager.requestTrackingAuthorization { _ in } }'),
    ("NearbyInteraction / NISession", "NSNearbyInteractionUsageDescription",
     'import NearbyInteraction\nfunc f() { _ = NISession() }'),
    ("Siri / INPreferences", "NSSiriUsageDescription",
     'import Intents\nfunc f() { INPreferences.requestSiriAuthorization { _ in } }'),

    # ── families candor does NOT claim. Measured, not assumed. ──────────────────────────────────────
    ("LocalNetwork / NWBrowser", "NSLocalNetworkUsageDescription",
     'import Network\nfunc f() { _ = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp) }'),
    ("macOS Documents folder", "NSDocumentsFolderUsageDescription",
     'import Foundation\nfunc f() { _ = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Documents") }'),
    ("macOS Desktop folder", "NSDesktopFolderUsageDescription",
     'import Foundation\nfunc f() { _ = FileManager.default.contents(atPath: NSHomeDirectory() + "/Desktop/x") }'),
    ("macOS removable volumes", "NSRemovableVolumesUsageDescription",
     'import Foundation\nfunc f() { _ = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes/USB") }'),
    ("FocusStatus / INFocusStatusCenter", "NSFocusStatusUsageDescription",
     'import Intents\nfunc f() { INFocusStatusCenter.default.requestAuthorization { _ in } }'),
    ("GameKit friends / GKLocalPlayer", "NSGKFriendListUsageDescription",
     'import GameKit\nfunc f() { GKLocalPlayer.local.loadFriends { _, _ in } }'),
    ("VideoSubscriberAccount", "NSVideoSubscriberAccountUsageDescription",
     'import VideoSubscriberAccount\nfunc f() { VSAccountManager().checkAccessStatus(options: [:]) { _, _ in } }'),
    ("Clinical health records", "NSHealthClinicalHealthRecordsShareUsageDescription",
     'import HealthKit\nfunc f() { _ = HKObjectType.clinicalType(forIdentifier: .allergyRecord) }'),

    # ── shapes that could defeat detection even for a MODELLED sensor ───────────────────────────────
    ("Contacts behind a local wrapper type", "NSContactsUsageDescription",
     'import Contacts\nfinal class Svc { let s = CNContactStore()\n  func all() -> [CNContainer] { (try? s.containers(matching: nil)) ?? [] } }\n'
     'func f() { _ = Svc().all() }'),
    ("Camera via ObjC selector dispatch", "NSCameraUsageDescription",
     'import AVFoundation\nimport Foundation\nfunc f() {\n  let o: NSObject = AVCaptureDevice.default(for: .video) ?? NSObject()\n'
     '  _ = o.perform(NSSelectorFromString("unlockForConfiguration")) }'),
    ("Mic reached only through a stored closure", "NSMicrophoneUsageDescription",
     'import AVFoundation\nfinal class H { var go: (() -> Void)?\n  init() { go = { _ = try? AVAudioRecorder(url: URL(fileURLWithPath: "/tmp/a"), settings: [:]) } } }\n'
     'func f() { H().go?() }'),
]


def scan(src, ws, i):
    root = os.path.join(ws, f"c{i}")
    os.makedirs(os.path.join(root, "Sources", "App"), exist_ok=True)
    open(os.path.join(root, "Package.swift"), "w").write(
        '// swift-tools-version:5.9\nimport PackageDescription\n'
        'let package = Package(name: "App", targets: [.executableTarget(name: "App")])\n')
    open(os.path.join(root, "Sources", "App", "main.swift"), "w").write(src + "\n")
    subprocess.run([BIN, root, "--out", os.path.join(root, "r")],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    out = subprocess.run([BIN, "privacy-manifest", "--report", os.path.join(root, "r"), "--json"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=120).stdout
    try:
        d = json.loads(out[out.index("{"):])
    except Exception:
        return set()
    return {k for ks in (d.get("required") or {}).values() for k in ks}


# Families the extension does NOT claim, mirroring PRIVACY_UNMODELLED_KEYS. A miss here is DISCLOSED by
# the verify, so it is reported and does not fail the gate. A miss OUTSIDE this set is a broken promise.
KNOWN_UNMODELLED = {
    "NSLocalNetworkUsageDescription", "NSDocumentsFolderUsageDescription", "NSDesktopFolderUsageDescription",
    "NSDownloadsFolderUsageDescription", "NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription",
    "NSFocusStatusUsageDescription", "NSGKFriendListUsageDescription", "NSVideoSubscriberAccountUsageDescription",
    "NSHealthClinicalHealthRecordsShareUsageDescription", "NSSensorKitUsageDescription",
    "NSFileProviderDomainUsageDescription", "NSSystemAdministrationUsageDescription",
    "NSSystemExtensionUsageDescription",
}


def main():
    if not os.path.exists(BIN):
        print("build candor-swift first", file=sys.stderr); return 2
    ws = tempfile.mkdtemp(prefix="privacy-recall-")
    hits, misses = [], []
    try:
        for i, (label, want, src) in enumerate(CASES):
            got = scan(src, ws, i)
            ok = want in got if want else True
            (hits if ok else misses).append((label, want, sorted(got)))
            print(f"  {'✔' if ok else '✘'} {label:<44} {'' if ok else 'MISSED ' + str(want)}"
                  + (f"   (emitted: {', '.join(sorted(got)) or 'nothing'})" if not ok else ""))
    finally:
        shutil.rmtree(ws, ignore_errors=True)
    broken = [m for m in misses if m[1] not in KNOWN_UNMODELLED]
    known  = [m for m in misses if m[1] in KNOWN_UNMODELLED]
    print(f"\n  {len(hits)}/{len(CASES)} caught · {len(known)} known-unmodelled · {len(broken)} BROKEN PROMISE")
    if known:
        print("\n  outside the vocabulary, and DISCLOSED by every verify (not a defect, a stated bound):")
        for label, want, _ in known:
            print(f"    · {label}  →  {want}")
    if broken:
        print("\n  A FAMILY THE VOCABULARY CLAIMS, MISSED. This is an app that could be REJECTED after a")
        print("  green verify — the one outcome this feature exists to prevent:")
        for label, want, got in broken:
            print(f"    ✘ {label}  →  needs {want}, candor emitted {', '.join(got) or 'NOTHING'}")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
