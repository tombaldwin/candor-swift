import XCTest
import Foundation
@testable import CandorCore

/// ⟨0.32⟩ **ONE CAPABILITY, EVERY SPELLING — the standing gate on `CAPABILITY_SPELLINGS`.**
///
/// THE VEIN. Foundation ships most process/filesystem/clock capabilities twice: a receiver-rooted
/// spelling (`FileManager.default.temporaryDirectory`) and a C-era FREE FUNCTION doing exactly the same
/// thing (`NSTemporaryDirectory()`). This engine modelled them in two separate tables keyed two different
/// ways, and nothing made the two agree — so a capability was repeatedly charged at one spelling and
/// SILENT at its twin, which under ⟨0.21⟩ is a positive purity claim about the caller. A cardinal sin,
/// and six of them shipped at once.
///
/// THE INSTANCE THAT NAMES IT: `f419648` closed the argv divergence under the message "argv is Env — the
/// divergence is closed four-way", and closed it for `CommandLine.arguments` only. `ProcessInfo
/// .processInfo.arguments` — the same value, the same channel, one table over — kept reading pure, and
/// `pure <fn>` exited 0 over a function that reads argv. A fix that left its own class open.
///
/// **THIS FILE IS THE MECHANISM, not five assertions about five names.** It enumerates
/// `CAPABILITY_SPELLINGS` — the table both classifiers now read — and asserts that EVERY witness of a row
/// reports that row's effect. So a row whose free column is empty fails as soon as its witnesses
/// disagree; a spelling that regresses fails on the next run; and a new capability has nowhere to be
/// added EXCEPT a row, where the other column is visibly waiting. The known limit, stated rather than
/// left to be assumed: this cannot see a capability nobody modelled in either spelling. That is the κ
/// coverage ledger's job, and the ledger discloses it rather than certifying it pure.
///
/// SOURCE-LEVEL, DELIBERATELY. Every row here scans a GENERATED fixture with the shipped binary and reads
/// the report. A check that walked the existing call graph could not see a missing EDGE, which is the
/// shape of this defect exactly.
final class CapabilitySpellingParityProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// Scan a one-file package and return `fn name -> inferred effects`, with functions ABSENT from the
    /// report reported as `[]` — because under ⟨0.21⟩ absent IS the purity claim, and a test that only
    /// looked at what the report contains could not assert a silent under-report at all.
    private func effects(of source: String) throws -> [String: [String]] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-spelling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.target(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try source.write(to: src.appendingPathComponent("Probe.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(try bin(), [root.path, "--json"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        guard let d = r.out.data(using: .utf8),
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let fns = o["functions"] as? [[String: Any]] else {
            XCTFail("not a §2 report: \(r.out)"); return [:]
        }
        var out: [String: [String]] = [:]
        for f in fns {
            let qual = f["fn"] as? String ?? ""
            out[String(qual.split(separator: ".").last ?? "")] = f["inferred"] as? [String] ?? []
        }
        return out
    }

    // ── THE BATTERY ───────────────────────────────────────────────────────────────────────────────

    /// EVERY WITNESS OF EVERY ROW, in one scan. Generated from the table rather than listed here, so the
    /// battery grows with the table and a row cannot be added without being measured.
    func testEverySpellingOfACapabilityReportsTheSameEffect() throws {
        var src = """
        import Foundation
        #if canImport(Darwin)
        import Darwin
        #endif
        #if canImport(QuartzCore)
        import QuartzCore
        #endif

        """
        var expected: [String: (effect: String, spelling: String, capability: String)] = [:]
        for (i, row) in CAPABILITY_SPELLINGS.enumerated() {
            for (j, w) in row.witnesses.enumerated() {
                let fn = "w\(i)_\(j)"
                src += "public func \(fn)() -> Any { \(w) }\n"
                expected[fn] = (row.effect, w, row.capability)
            }
        }
        // A PURE CONTROL in the same fixture: if the whole scan broke, this row would go red too, and a
        // battery that cannot distinguish "the engine fabricates" from "the engine died" proves nothing.
        src += "public func pureControl(_ a: Int) -> Int { a + 1 }\n"

        let got = try effects(of: src)
        XCTAssertNotNil(got["pureControl"] == nil ? [] : got["pureControl"],
                        "the fixture must have been scanned at all")
        XCTAssertTrue((got["pureControl"] ?? []).isEmpty,
                      "the pure control must stay pure: \(got["pureControl"] ?? [])")

        var missing: [String] = []
        for (fn, exp) in expected.sorted(by: { $0.key < $1.key }) {
            let eff = got[fn] ?? []
            if !eff.contains(exp.effect) {
                missing.append("  \(exp.spelling)  →  \(eff.isEmpty ? "ABSENT (= the ⟨0.21⟩ purity claim)" : eff.joined(separator: "+"))"
                               + "   [expected \(exp.effect) — \(exp.capability)]")
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "these spellings do NOT report their capability's effect, so a caller of them "
                      + "certifies PURE while a caller of their twin does not:\n" + missing.joined(separator: "\n"))
    }

    /// THE NAMED INSTANCE, kept as its own row so the failure that started this reads by name in a test
    /// list rather than as one line of a battery's diff. `pure <fn>` exited 0 over it.
    func testProcessInfoArgumentsIsEnvLikeItsCommandLineTwin() throws {
        let got = try effects(of: """
        import Foundation
        public func viaProcessInfo() -> [String] { ProcessInfo.processInfo.arguments }
        public func viaCommandLine() -> [String] { CommandLine.arguments }
        """)
        XCTAssertEqual(got["viaProcessInfo"] ?? [], ["Env"],
                       "argv is argv whichever door it comes through: \(got)")
        XCTAssertEqual(got["viaCommandLine"] ?? [], ["Env"], "the twin, unchanged: \(got)")
    }

    // ── THE OVER-CHARGE CONTROLS ──────────────────────────────────────────────────────────────────
    //
    // MEASURED IN THIS PROJECT: 4 defects in 5 fabrication-fixes, 2 of them cardinal sins — killing an
    // under-report is exactly where the opposite failure gets introduced. Every row below is a program
    // that must NOT move.

    /// A PROJECT'S OWN `func NSUserName()` MUST NOT GAIN AN EFFECT. The call-site shadow guard
    /// (`localFreeFns`) is what makes it safe to name Foundation free functions in κ at all; the same
    /// guard has covered `NSLog`/`Pipe`/`CACurrentMediaTime` since the ShellOut cardinal sin, and the new
    /// rows inherit it rather than re-implementing it — but "inherits" is a claim, so it is measured.
    func testAProjectsOwnFreeFunctionOfTheSameNameStaysPure() throws {
        let got = try effects(of: """
        import Foundation
        func NSUserName() -> String { "nobody" }
        func NSHomeDirectory() -> String { "/nowhere" }
        func NSTemporaryDirectory() -> String { "/nowhere/tmp" }
        func CFAbsoluteTimeGetCurrent() -> Double { 0 }
        public func callsOwnUser() -> String { NSUserName() }
        public func callsOwnHome() -> String { NSHomeDirectory() }
        public func callsOwnTemp() -> String { NSTemporaryDirectory() }
        public func callsOwnClock() -> Double { CFAbsoluteTimeGetCurrent() }
        """)
        for fn in ["callsOwnUser", "callsOwnHome", "callsOwnTemp", "callsOwnClock"] {
            XCTAssertTrue((got[fn] ?? []).isEmpty,
                          "\(fn) calls the PROJECT's function of that name, which does nothing of the "
                          + "kind — κ must not answer for it: \(got[fn] ?? [])")
        }
    }

    /// A PROJECT TYPE NAMED `ProcessInfo` MUST NOT EITHER. The property-read path fences on
    /// `declaredTypes` — a REAL local declaration shadows κ, while an `extension ProcessInfo` does NOT
    /// (that fence is the real-world vein where one extension zeroed Env detection package-wide). Both
    /// halves are posed here, because a control that only checks the shadow would pass a change that
    /// re-broke the extension half.
    func testAProjectTypeOfTheSameNameShadowsTheTableAndAnExtensionDoesNot() throws {
        let shadowed = try effects(of: """
        import Foundation
        struct ProcessInfo { static let processInfo = ProcessInfo(); let arguments: [String] = []
                             let userName = ""; let processName = "" }
        public func readsOwnArgv() -> [String] { ProcessInfo.processInfo.arguments }
        public func readsOwnUser() -> String { ProcessInfo.processInfo.userName }
        """)
        XCTAssertTrue((shadowed["readsOwnArgv"] ?? []).isEmpty,
                      "a REAL local `struct ProcessInfo` shadows κ: \(shadowed["readsOwnArgv"] ?? [])")
        XCTAssertTrue((shadowed["readsOwnUser"] ?? []).isEmpty,
                      "…and so does its `userName`: \(shadowed["readsOwnUser"] ?? [])")

        let extended = try effects(of: """
        import Foundation
        extension ProcessInfo { var candorNote: String { "x" } }
        public func stillReadsRealArgv() -> [String] { ProcessInfo.processInfo.arguments }
        """)
        XCTAssertEqual(extended["stillReadsRealArgv"] ?? [], ["Env"],
                       "an EXTENSION of the platform type is not a declaration of it — extending "
                       + "`ProcessInfo` must not zero argv detection package-wide: \(extended)")
    }

    /// A STORED FIELD NAMED LIKE A CAPABILITY PROPERTY MUST NOT FABRICATE. The property path keys on the
    /// RECEIVER's type plus the terminal member, not on the field-walked whole node — so `self.arguments`
    /// where `arguments: [String]` is a plain stored property is a pure read. Widening the new rows to a
    /// bare member-name match would light this up across every real codebase.
    func testAStoredFieldNamedLikeACapabilityPropertyStaysPure() throws {
        let got = try effects(of: """
        import Foundation
        public struct Command {
            public let arguments: [String] = []
            public let processName: String = ""
            public let userName: String = ""
            public func readArgs() -> [String] { self.arguments }
            public func readName() -> String { self.processName }
            public func readUser() -> String { self.userName }
        }
        """)
        for fn in ["readArgs", "readName", "readUser"] {
            XCTAssertTrue((got[fn] ?? []).isEmpty,
                          "\(fn) reads an ordinary stored field: \(got[fn] ?? [])")
        }
    }

    /// THE ARITY GATE SURVIVED THE MOVE. `Date()` reads the clock; `Date(timeInterval:since:)` is
    /// arithmetic on a value you already have, and charging it would put `Clock` on every date
    /// computation in the corpus. The gate used to be a hand-written `case` and now travels on the table
    /// row, so it is asserted rather than assumed to have come along.
    func testTheArityGateTravelsWithTheTableRow() throws {
        let got = try effects(of: """
        import Foundation
        public func readsClock() -> Date { Date() }
        public func doesArithmetic(_ d: Date) -> Date { Date(timeInterval: 60, since: d) }
        """)
        XCTAssertEqual(got["readsClock"] ?? [], ["Clock"], "the no-arg form reads the clock: \(got)")
        XCTAssertTrue((got["doesArithmetic"] ?? []).isEmpty,
                      "…and the arithmetic form must not: \(got["doesArithmetic"] ?? [])")
    }

    /// THE NAMES DELIBERATELY LEFT OUT STAY OUT — the denylist half of `CAPABILITY_SPELLINGS`' own note,
    /// as a row rather than as prose. `time`/`random` are ultra-common words a project is likelier to
    /// declare than to import; `getpid`/`getuid` are a capability NO member spelling in this engine
    /// charges, so the parity rule does not reach them and one engine must not mint it alone.
    func testTheCollisionProneAndUnmodelledFreeNamesAreNotCharged() throws {
        let got = try effects(of: """
        import Foundation
        #if canImport(Darwin)
        import Darwin
        #endif
        public func viaTime() -> Int { Int(time(nil)) }
        public func viaPid() -> Int32 { getpid() }
        public func viaUid() -> UInt32 { getuid() }
        public func viaRootDir() -> String { NSOpenStepRootDirectory() }
        """)
        for fn in ["viaTime", "viaPid", "viaUid", "viaRootDir"] {
            XCTAssertTrue((got[fn] ?? []).isEmpty,
                          "\(fn) is deliberately absent from the table — see its note: \(got[fn] ?? [])")
        }
    }
}
