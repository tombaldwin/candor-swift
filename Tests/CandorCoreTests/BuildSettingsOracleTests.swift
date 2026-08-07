// A DIFFERENTIAL against Apple's own property-list parser.
//
// WHY THIS EXISTS, when BuildSettingsTests already covers every flip found so far. Those fixtures
// encode MY expectation of what a project means, and my expectation is precisely what has been wrong
// fourteen times across four rewrites of this evaluator — each round closed the flips of the previous
// round and shipped new ones the fixtures could not see, because the fixtures were written by the same
// reading that produced the bug.
//
// `project.pbxproj` is an OpenStep property list, so macOS ships an INDEPENDENT parser for exactly this
// format: `plutil`. It has no idea what candor is, cannot share a misreading with it, and settles the
// question the hand-written evaluator keeps getting wrong — how the file TOKENIZES. Both sides then
// apply the same declared/empty semantics, so any disagreement is a disagreement about parsing.
//
// The cases are GENERATED and every one is checked to be valid input to plutil first, so a case that
// stops being a real pbxproj fails loudly instead of quietly agreeing about nothing.
//
// CALIBRATION: run against the PREVIOUS evaluator this battery reports 6 over-declarations (cardinal
// sins) and 2 under-declarations; against the current one, zero. It discriminates — it is not a test
// that passes because both sides are empty.

import XCTest
@testable import CandorCore

final class BuildSettingsOracleTests: XCTestCase {

    /// One buildSettings body, and the label that names the shape it exercises.
    private static let cases: [(String, String)] = [
        ("plain",                #"INFOPLIST_KEY_NSCameraUsageDescription = "Take photos";"#),
        ("unquoted-value",       "INFOPLIST_KEY_NSCameraUsageDescription = TakePhotos;"),
        ("empty",                #"INFOPLIST_KEY_NSCameraUsageDescription = "";"#),
        ("inherited",            #"INFOPLIST_KEY_NSCameraUsageDescription = "$(inherited)";"#),
        ("braced-var",           #"INFOPLIST_KEY_NSCameraUsageDescription = "${FOO}";"#),
        ("cond-quoted-name",     #""INFOPLIST_KEY_NSCameraUsageDescription[sdk=iphoneos*]" = "For photos";"#),
        ("cond-quoted-empty",    #""INFOPLIST_KEY_NSCameraUsageDescription[sdk=iphoneos*]" = "";"#),
        ("two-conditions",       #""INFOPLIST_KEY_NSCameraUsageDescription[config=Debug][sdk=*]" = "";"#),
        ("hash-in-value",        ##"INFOPLIST_KEY_NSCameraUsageDescription = "#1 camera app";"##),
        ("url-in-value",         #"INFOPLIST_KEY_NSCameraUsageDescription = "see https://x/y";"#),
        ("semicolon-in-value",   #"INFOPLIST_KEY_NSCameraUsageDescription = "photos; videos";"#),
        ("escaped-quote",        #"INFOPLIST_KEY_NSCameraUsageDescription = "a \"quoted\" bit";"#),
        ("slashstar-in-value",   #"INFOPLIST_KEY_NSCameraUsageDescription = "path/*/glob";"#),
        ("brace-in-value",       #"INFOPLIST_KEY_NSCameraUsageDescription = "a {braced} bit";"#),
        ("comment-annotated",    #"INFOPLIST_KEY_NSCameraUsageDescription /* why */ = "For photos";"#),
        ("neighbour-searchpath", "HEADER_SEARCH_PATHS = \"$(SRCROOT)/Vendor/**\";\n\t\t\t\tINFOPLIST_KEY_NSCameraUsageDescription = \"\";"),
        ("neighbour-shellish",   #"OTHER_LDFLAGS = "echo INFOPLIST_KEY_NSCameraUsageDescription = yes";"#),
        ("two-on-one-line",      #"INFOPLIST_KEY_NSCameraUsageDescription = ""; INFOPLIST_KEY_NSMicrophoneUsageDescription = "Record";"#),
        ("mic-only",             #"INFOPLIST_KEY_NSMicrophoneUsageDescription = "Record audio";"#),
    ]

    private static func project(debug: String, release: String) -> String {
        """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tobjectVersion = 56;
        \tobjects = {
        \t\tAA00000000000000000000A1 /* Debug */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t\t\(debug)
        \t\t\t};
        \t\t\tname = Debug;
        \t\t};
        \t\tAA00000000000000000000A2 /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t\t\(release)
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        \t};
        \trootObject = AA00000000000000000000A0;
        }
        """
    }

    /// Apple's parser's answer: every `INFOPLIST_KEY_*UsageDescription` in any `XCBuildConfiguration`,
    /// under the SAME rule the evaluator applies — declared only if no assignment leaves it empty.
    /// Returns nil when plutil could not read the file at all (which the caller treats as a failure,
    /// never as agreement).
    /// The raw `plutil -convert json` result, or nil when the tool is absent or refuses.
    private func oracleRaw(_ path: String) -> Any? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-convert", "json", "-o", "-", path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func oracle(_ path: String) -> Set<String>? {
        guard let root = oracleRaw(path) as? [String: Any],
              let objects = root["objects"] as? [String: Any] else { return nil }
        var real: Set<String> = [], empty: Set<String> = []
        for case let obj as [String: Any] in objects.values
        where (obj["isa"] as? String) == "XCBuildConfiguration" {
            for (rawKey, value) in (obj["buildSettings"] as? [String: Any]) ?? [:] {
                let name = String(rawKey.split(separator: "[", maxSplits: 1,
                                               omittingEmptySubsequences: false)[0])
                guard name.hasPrefix("INFOPLIST_KEY_"), name.hasSuffix("UsageDescription") else { continue }
                let key = String(name.dropFirst("INFOPLIST_KEY_".count))
                // Reuse the evaluator's own emptiness rule — the differential is about PARSING, so the
                // two sides must not differ on what "empty" means.
                let text = (value as? String) ?? ((value as? [String])?.joined() ?? "\(value)")
                if BuildSettingAssignment(name: key, value: text).isEffectivelyEmpty { empty.insert(key) }
                else { real.insert(key) }
            }
        }
        return real.subtracting(empty)
    }

    private var runningOnMacOS: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// Does the `plutil` on this machine actually behave like Apple's? Verified against a trivial
    /// old-style plist rather than assumed from the binary's presence.
    private func plutilSpeaksAppleFlags() -> Bool {
        let probe = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-plutil-probe-\(ProcessInfo.processInfo.processIdentifier).plist")
        defer { try? FileManager.default.removeItem(at: probe) }
        guard (try? "{ a = b; }".write(to: probe, atomically: true, encoding: .utf8)) != nil else { return false }
        guard let out = oracleRaw(probe.path), let obj = out as? [String: Any] else { return false }
        return (obj["a"] as? String) == "b"
    }

    func testEvaluatorAgreesWithApplesOwnParser() throws {
        // A CAPABILITY probe, not a path check, AND a platform guard — as one condition, so there is
        // no unreachable code on either platform.
        //
        // The first version skipped unless `/usr/bin/plutil` existed. The Linux CI image HAS one
        // (libplist's), which does not speak Apple's `-convert json` flags — so the test ran, every
        // generated case "failed to parse", and the battery reported 38 disagreements that were really
        // one missing tool. Asking whether the binary is there is not the same question as whether it
        // can answer.
        //
        // The `checked` assertion at the end of this test is what caught it: 0 cells compared, 38
        // claimed. A differential that cannot say how many cells it actually ran is not reporting a
        // result — which is the same reason the corpus differentials count live cells.
        try XCTSkipUnless(runningOnMacOS && plutilSpeaksAppleFlags(),
                          "Apple's property-list parser is macOS-only, and a `plutil` that does not "
                          + "accept `-convert json` is not the reference parser this compares against")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-bsoracle-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plain = Self.cases.first { $0.0 == "plain" }!.1
        var checked = 0, disagreements: [String] = []

        // Each shape ALONE, and each shape paired with a plain declaration in the OTHER configuration —
        // the Debug-declares/Release-does-not axis, which is where last-assignment-wins used to decide
        // the answer by serialisation order.
        for (label, body) in Self.cases {
            for (variant, debug, release) in [("solo", body, body), ("pair", plain, body)] {
                let path = dir.appendingPathComponent("\(variant)_\(label).pbxproj").path
                try Self.project(debug: debug, release: release).write(toFile: path, atomically: true,
                                                                       encoding: .utf8)
                guard let want = oracle(path) else {
                    // A case plutil cannot read is a broken FIXTURE, not agreement. Failing here is what
                    // stops this battery decaying into a test that compares two empty sets.
                    disagreements.append("\(variant)/\(label): plutil could not parse the generated "
                                         + "project — the fixture is no longer a valid pbxproj")
                    continue
                }
                let got = usageKeysInBuildSettings(try String(contentsOfFile: path, encoding: .utf8))
                checked += 1
                if got == want { continue }
                let over = got.subtracting(want), under = want.subtracting(got)
                if !over.isEmpty {
                    disagreements.append("\(variant)/\(label): CARDINAL SIN — candor declares "
                                         + "\(over.sorted()), Apple's parser does not")
                }
                if !under.isEmpty {
                    disagreements.append("\(variant)/\(label): MISSED — Apple's parser declares "
                                         + "\(under.sorted()), candor does not")
                }
            }
        }

        XCTAssertEqual(checked, Self.cases.count * 2, "some generated cases were not compared")
        XCTAssertTrue(disagreements.isEmpty,
                      "the evaluator disagrees with Apple's parser:\n  "
                      + disagreements.joined(separator: "\n  "))
    }
}
