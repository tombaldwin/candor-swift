import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R651 — **A CONSUMER THAT WRITES AN `extension` ON A DEPENDENCY TYPE SILENCED EVERY MEMBER
/// CALL ON THAT TYPE.**
///
/// `pushType` puts whatever an `extension` extends into `localTypes` (so the extension's OWN members
/// resolve), and deliberately NOT into `declaredTypes` (an extension does not redefine the type).
/// `CallCollector`'s typed-local-receiver branch then fired on `localTypes` membership alone for any
/// member κ does not know, emitting `typed: true` — and `typed` is the exact conjunct the Driver's §2
/// CANDOR_DEPS join is gated on (`if !resolved, !deps.isEmpty, !call.typed`). So the call resolved
/// LOCALLY, found no `Chan.poke` unit, and was DROPPED with nothing asked of the dependency.
///
/// ONE VARIABLE — the presence of a sibling file that extends the dependency's type. Same consumer call
/// site, same dependency, same binary, same policy; both arms compile:
///
///     no sibling file            viaReceiver -> ['Env']   deny Env exit 1
///     + `extension Chan { }`     viaReceiver ABSENT       deny Env exit 0     ← the cardinal sin
///
/// **The failure is TOTAL rather than partial**: with no effect left the function leaves `functions[]`
/// entirely, and under ⟨0.21⟩ its absence from an `analyzed` scan is a positive claim of purity. The
/// trigger is a consumer adding code to its OWN tree, which deletes a disclosure about a dependency —
/// R595's direction with the roles reversed.
///
/// EVERY SPELLING OF THE EXTENSION FIRES, which is why the fix cannot key on what the extension
/// contains: measured at HEAD, an extension adding a method, a computed property, a `static let`, a
/// nested type, a `typealias`, `private`/`fileprivate`, and an EMPTY `extension Chan { }` all produce
/// the identical absent row. The fixtures below therefore use the EMPTY extension — the weakest trigger
/// there is.
///
/// §1b: `CANDOR_R651_OFF=1` restores the pre-fix behaviour, so the two defect rows can be SHOWN to fail
/// without a revert. The controls pass in both arms.
final class ExtensionOnDependencyTypeProcessTests: XCTestCase {

    private struct Arm {
        var rows: [String: Set<String>]
        var dispatchesOn: [String: Set<String>]
        var present: Set<String>
        var depFns: [String]
        var gate: Int32
    }

    private func runPair(depSource: String, appFiles: [String: String], deny: String, label: String,
                         env extraEnv: [String: String] = [:]) throws -> Arm {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r651-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "RatesDep",
            products: [.library(name: "RatesCore", targets: ["RatesCore"])],
            targets: [.target(name: "RatesCore")])
        """)
        try write("dep/Sources/RatesCore/lib.swift", depSource)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [.product(name: "RatesCore", package: "dep")])])
        """)
        for (name, text) in appFiles { try write("app/Sources/App/\(name)", text) }
        try write("deny.policy", "\(deny)\n")

        let depDir = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path,
                                              "--out", depDir.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        let report = depDir.appendingPathComponent("r.RatesDep.Swift.json")
        let depDoc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        let depFns = ((depDoc?["functions"] as? [[String: Any]]) ?? [])
            .map { ($0["fn"] as? String) ?? "?" }.sorted()
        for extra in try FileManager.default.contentsOfDirectory(atPath: depDir.path)
        where extra != report.lastPathComponent {
            try FileManager.default.removeItem(at: depDir.appendingPathComponent(extra))
        }

        var env = extraEnv
        env["CANDOR_DEPS"] = depDir.path
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                             "--out", root.appendingPathComponent("ch").path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Set<String>] = [:]
        var dispatches: [String: Set<String>] = [:]
        var present: Set<String> = []
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            let name = (f["fn"] as? String) ?? "?"
            present.insert(name)
            rows[name] = Set((f["inferred"] as? [String]) ?? [])
            dispatches[name] = Set((f["dispatchesOn"] as? [String]) ?? [])
        }
        let g = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                             "--policy", root.appendingPathComponent("deny.policy").path,
                                             "--out", root.appendingPathComponent("g").path], env: env)
        return Arm(rows: rows, dispatchesOn: dispatches, present: present, depFns: depFns, gate: g.code)
    }

    /// The dependency. `Chan.poke` reads the environment; `Chan.quiet` does not, and exists so a control
    /// can prove the join is not firing on everything.
    private static let dep = """
    import Foundation
    open class Chan {
        public init() {}
        open func poke() { _ = ProcessInfo.processInfo.environment["A"] }
    }
    """

    /// The call site, byte-identical in every arm below that uses it.
    private static let caller = """
    import RatesCore
    public func viaReceiver(_ c: Chan) { c.poke() }
    """

    /// The weakest possible trigger — an extension that adds NOTHING. Every richer spelling (a method, a
    /// computed property, a `static let`, a nested type, a `typealias`, `private`/`fileprivate`) was
    /// measured at HEAD and produces the identical absent row.
    private static let emptyExtension = """
    import RatesCore
    extension Chan { }
    """

    // MARK: - the defect

    func testAnExtensionOnADependencyTypeDoesNotSilenceItsMembers() throws {
        let r = try runPair(depSource: Self.dep,
                            appFiles: ["a.swift": Self.caller, "b.swift": Self.emptyExtension],
                            deny: "deny Env", label: "sin")
        XCTAssertEqual(r.depFns, ["Chan.poke"],
                       "§E3 premise: the dependency really does publish the member this join must reach")
        XCTAssertTrue(r.present.contains("viaReceiver"),
                      "ABSENCE IS THE SIN'S SIGNATURE. `analyzed` counts this function, so its omission "
                      + "from `functions[]` is a ⟨0.21⟩ purity claim over a call that reads the "
                      + "environment — not a gap. Present rows: \(r.present.sorted())")
        XCTAssertEqual(r.rows["viaReceiver"], ["Env"],
                       "`c.poke()` reaches the dependency's `Chan.poke`, whose recorded effect is Env. An "
                       + "`extension Chan` in the consumer's own tree must not withdraw that")
        XCTAssertEqual(r.gate, 1, "GATE LEVEL — `deny Env` over a call that reads the environment. Was exit 0")
    }

    /// ⟨0.39⟩ obligation 1 is the SECOND thing the silencing deleted: the consumer's row stopped naming
    /// the abstraction, so no downstream package could join its own implementors onto this call.
    func testTheDispatchKeySurvivesAnExtensionOnTheDependencyType() throws {
        let r = try runPair(depSource: Self.dep,
                            appFiles: ["a.swift": Self.caller, "b.swift": Self.emptyExtension],
                            deny: "deny Env", label: "dispatch")
        XCTAssertEqual(r.dispatchesOn["viaReceiver"], ["RatesDep#Chan.poke"],
                       "the no-extension arm publishes exactly this key; the extension must not delete it")
    }

    // MARK: - the arm that was already green, held constant

    func testControlWithNoExtensionTheJoinAlreadyWorked() throws {
        let r = try runPair(depSource: Self.dep, appFiles: ["a.swift": Self.caller],
                            deny: "deny Env", label: "control-noext")
        XCTAssertEqual(r.rows["viaReceiver"], ["Env"], "the arm that was already green")
        XCTAssertEqual(r.dispatchesOn["viaReceiver"], ["RatesDep#Chan.poke"])
        XCTAssertEqual(r.gate, 1)
    }

    // MARK: - the direction the fix must NOT move (§E, the over-charge controls)

    /// **A GENUINE LOCAL TYPE STILL RESOLVES LOCALLY, AND STILL SHADOWS THE DEPENDENCY.** The dependency
    /// declares a type of the SAME NAME with the SAME member and a DIFFERENT effect, so if local
    /// resolution ever started reaching across the boundary this assertion reads `Fs`, not `Env`. That
    /// is the GRDB `bind` discipline: a project's own declaration wins outright.
    func testControlALocalDeclaredTypeShadowsTheDependencyEntirely() throws {
        let r = try runPair(depSource: """
        import Foundation
        public final class Chan {
            public init() {}
            public func poke() { try? Data().write(to: URL(fileURLWithPath: "/tmp/x")) }
        }
        """, appFiles: ["a.swift": """
        import Foundation
        import RatesCore
        public class Chan {
            public init() {}
            public func poke() { _ = ProcessInfo.processInfo.environment["LOCAL"] }
        }
        public func viaReceiver(_ c: Chan) { c.poke() }
        """], deny: "deny Fs", label: "control-localdecl")
        XCTAssertEqual(r.rows["viaReceiver"], ["Env"],
                       "the LOCAL `Chan.poke` body, not the dependency's. `Fs` here would mean a "
                       + "declared local type had started inheriting a same-named dependency type's "
                       + "effects — a fabrication over project code")
        XCTAssertEqual(r.gate, 0, "`deny Fs` over a local function that writes no file")
    }

    /// **AN `extension` ON A LOCALLY DECLARED TYPE MUST NOT START REACHING FOR THE DEPENDENCY EITHER.**
    /// Same shape as above with the extension added, because the extension is what puts the name into
    /// `localTypes` and a fix keyed on that set could easily catch this case too.
    func testControlAnExtensionOnALocalDeclaredTypeChangesNothing() throws {
        let r = try runPair(depSource: """
        import Foundation
        public final class Chan {
            public init() {}
            public func poke() { try? Data().write(to: URL(fileURLWithPath: "/tmp/x")) }
        }
        """, appFiles: ["a.swift": """
        import Foundation
        import RatesCore
        public class Chan {
            public init() {}
            public func poke() { _ = ProcessInfo.processInfo.environment["LOCAL"] }
        }
        public func viaReceiver(_ c: Chan) { c.poke() }
        """, "b.swift": """
        import RatesCore
        extension Chan { public var tag: Int { 1 } }
        """], deny: "deny Fs", label: "control-localext")
        XCTAssertEqual(r.rows["viaReceiver"], ["Env"], "still the local body")
        XCTAssertEqual(r.gate, 0)
    }

    /// **A MEMBER THE CONSUMER'S OWN EXTENSION PROVIDES STILL RESOLVES TO THAT EXTENSION'S BODY.** This
    /// is the behaviour the `localTypes` branch exists for, and the one a blunt exclusion would break.
    /// The dependency declares the SAME member with a DIFFERENT effect, so a reach across the boundary
    /// is visible as `Fs`.
    func testControlAMemberTheLocalExtensionProvidesResolvesToIt() throws {
        let r = try runPair(depSource: """
        import Foundation
        open class Chan {
            public init() {}
            open func helper() { try? Data().write(to: URL(fileURLWithPath: "/tmp/x")) }
        }
        """, appFiles: ["a.swift": """
        import RatesCore
        public func viaHelper(_ c: Chan) { c.helper() }
        """, "b.swift": """
        import Foundation
        import RatesCore
        extension Chan { public func helper() { _ = ProcessInfo.processInfo.environment["EXT"] } }
        """], deny: "deny Fs", label: "control-extprovides")
        XCTAssertEqual(r.rows["viaHelper"], ["Env"],
                       "the consumer's own extension body. `Fs` would mean the dependency's same-named "
                       + "member had been unioned in over a member the scan can actually read")
        XCTAssertEqual(r.gate, 0)
    }

    /// **AN EXTENSION ON A κ-PLATFORM TYPE IS UNCHANGED.** `extension Data` in the consumer must not
    /// shadow `data.write(to:)` → Fs (the SwiftLint dogfood vein), and the fix must not perturb the
    /// `isFileWrite` / `kappaMember` guards that keep that working.
    func testControlAnExtensionOnAPlatformTypeStillClassifiesKappa() throws {
        let r = try runPair(depSource: Self.dep, appFiles: ["a.swift": """
        import Foundation
        import RatesCore
        public func save(_ d: Data) { try? d.write(to: URL(fileURLWithPath: "/tmp/out")) }
        """, "b.swift": """
        import Foundation
        extension Data { public var tag: Int { 1 } }
        """], deny: "deny Fs", label: "control-kappa")
        XCTAssertEqual(r.rows["save"], ["Fs"], "κ still classifies the file write through the extension")
        XCTAssertEqual(r.gate, 1)
    }

    /// **AND AN EXTENSION ON A STDLIB TYPE GAINS NOTHING.** `s.uppercased()` is a pure stdlib member on a
    /// type the consumer happens to extend; the dependency publishes no `String.uppercased`, so the join
    /// must miss and the function must stay out of `functions[]` — no fabricated effect, no false
    /// `Unknown`. This is the sweep-[33]/[36] direction: a fix that disclosed here would flood every
    /// project that writes `extension String`.
    func testControlAnExtensionOnAStdlibTypeFabricatesNothing() throws {
        let r = try runPair(depSource: Self.dep, appFiles: ["a.swift": """
        import RatesCore
        public func shout(_ s: String) -> String { s.uppercased() }
        """, "b.swift": """
        extension String { public var tag: Int { 1 } }
        """], deny: "deny Unknown", label: "control-stdlib")
        XCTAssertEqual(r.rows["shout"] ?? [], [],
                       "no effect and no Unknown — the join asked `RatesDep#String.uppercased` and the "
                       + "dependency does not answer it, which is the correct miss")
        XCTAssertEqual(r.gate, 0, "`deny Unknown` must not fire on an uppercased String")
    }

    // MARK: - §1b, the kill switch

    /// The calibration (§1b): with `CANDOR_R651_OFF=1` the defect arm reproduces exactly as measured, so
    /// the two rows above are shown to discriminate the fix from its absence rather than asserted to.
    func testKillSwitchRestoresTheSilencing() throws {
        let r = try runPair(depSource: Self.dep,
                            appFiles: ["a.swift": Self.caller, "b.swift": Self.emptyExtension],
                            deny: "deny Env", label: "killswitch", env: ["CANDOR_R651_OFF": "1"])
        XCTAssertFalse(r.present.contains("viaReceiver"),
                       "pre-fix behaviour: the function leaves the report entirely")
        XCTAssertEqual(r.gate, 0, "pre-fix behaviour: `deny Env` exits 0 over a real environment read")
    }
}
