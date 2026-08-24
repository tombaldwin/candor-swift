import XCTest
import Foundation

/// **AN `extension Process` ANYWHERE IN A TARGET ZEROED THE `Process()` CONSTRUCTOR, TARGET-WIDE.**
///
/// The free-call κ arms fenced on `localTypes`, which `pushType` fills from EXTENSIONS as well as from
/// declarations, so one `extension Process { var tag: String … }` made every `Process()` in the package
/// read pure. The member-call path has reasoned correctly about this since the ShellOut cardinal-sin
/// (it fences on `declaredTypes`, because extending a platform type does not make it project code), so
/// the two paths answered the same question differently — the sibling-route shape this project keeps
/// hitting. Filed as an expected-failure ratchet by ⟨0.32⟩ (`fdd8a4b`) and closed here.
///
/// MEASURED, NOT HYPOTHESISED: swift-syntax holds exactly one `extension Process`, and its
/// `ProcessRunner.init` — which constructs a `Process` and arms three of its properties — reported
/// `Env` alone. A class whose only subprocess contact is CONSTRUCTION read pure across the whole
/// package, and `deny Exec` passed over it.
///
/// **THE OBVIOUS FIX IS A REGRESSION AND THAT WAS MEASURED TOO** — ⟨0.32⟩ A/B'd swapping the fence and
/// reverted it. An extension may supply a `convenience init`, in which case the constructor call
/// resolves to a REAL LOCAL UNIT, and the edge to it came from the fall-through arm the swapped fence
/// preempts: 91 firebase-ios-sdk units changed and the majority LOST a true `Env`. So the fix charges κ
/// *and* keeps the edge, by emitting the same `Call` the fall-through arm would have emitted for
/// exactly the set it used to serve. The delta is additive by construction.
///
/// **`testAConvenienceInitKeepsItsLocalEdge` IS THE CONTROL FOR THAT REVERT** — the exact shape the
/// reverted fix broke, written before the fix and asserted as a positive `Env`, not as an afterthought.
/// Every unit carries a CLOCK MARKER so it is PRESENT in the report: a pure function is omitted, and
/// `nil` would pass a control that asked nothing (PART 37 (e)).
final class ExtensionShadowConstructorProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--out", root.appendingPathComponent("r").path]
        if let policy {
            let p = root.appendingPathComponent("deny.pol")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, r.code, r.out + r.err)
    }

    /// THE DEFECT. An extension that declares nothing but a computed property cannot possibly make a
    /// subprocess handle into project code.
    func testAnExtensionDoesNotShadowThePlatformConstructor() throws {
        let src = """
        import Foundation
        extension Process { var tag: String { "t" } }
        func makesOnly() -> Process { _ = Date(); return Process() }
        func makesPipe() -> Pipe { _ = Date(); return Pipe() }
        """
        let r = try scan(src, name: "Ext", policy: "deny Exec\n")
        XCTAssertEqual(r.fns["makesOnly"], ["Clock", "Exec"],
                       "constructing a subprocess handle is `Exec` whether or not the project happens to "
                       + "extend the type")
        XCTAssertEqual(r.fns["makesPipe"], ["Clock", "Ipc"],
                       "the sibling κ ctor in the same file is unaffected — the shadow was TARGET-wide, "
                       + "so this row says the fix did not simply disable the fence")
        XCTAssertEqual(r.code, 1,
                       "THE TEETH: a tree whose only subprocess contact is construction must FAIL "
                       + "`deny Exec`, and it certified clean at exit 0: \(r.out)")
    }

    /// **THE CONTROL FOR THE REVERTED FIX.** An `extension` that supplies a `convenience init` is the
    /// case that made the naive fence-swap wrong: the constructor call resolves to a real local unit
    /// whose body has effects, and dropping the edge to it LOST a true `Env` on 91 firebase-ios-sdk
    /// units. Both spellings of the call — the platform's own `Process()` and the project's
    /// `Process(inheritingEnv:)` — must keep reaching that init.
    func testAConvenienceInitKeepsItsLocalEdge() throws {
        let src = """
        import Foundation
        extension Process {
            convenience init(inheritingEnv argv: [String]) {
                self.init()
                self.environment = ProcessInfo.processInfo.environment
                self.arguments = argv
            }
        }
        func makesViaConvenience() -> Process { _ = Date(); return Process(inheritingEnv: ["-x"]) }
        func makesPlain() -> Process { _ = Date(); return Process() }
        """
        let r = try scan(src, name: "Conv")
        XCTAssertEqual(r.fns["Process.init"], ["Env"],
                       "the extension's convenience init is a unit of this package and reads the parent "
                       + "environment")
        XCTAssertTrue((r.fns["makesViaConvenience"] ?? []).contains("Env"),
                      "THE EDGE THE REVERTED FIX DROPPED: the call resolves to the extension's init and "
                      + "carries its `Env`. Got \(r.fns["makesViaConvenience"] ?? []).")
        XCTAssertTrue((r.fns["makesPlain"] ?? []).contains("Env"),
                      "…and so does the bare spelling, which is how the resolver has always read a ctor "
                      + "call on a locally-extended type. Got \(r.fns["makesPlain"] ?? []).")
        XCTAssertEqual(r.fns["makesViaConvenience"], ["Clock", "Env", "Exec"],
                       "the fix is a UNION, not a swap: the local edge AND the platform capability")
        XCTAssertEqual(r.fns["makesPlain"], ["Clock", "Env", "Exec"], "same for the bare ctor")
    }

    /// THE LOOKALIKE, which the fence must still stop. A project that DECLARES its own `Process` — and
    /// extends it, so both sets hold the name — gains nothing, verdict included.
    func testADeclaredTypeStillShadowsEvenWhenAlsoExtended() throws {
        let src = """
        import Foundation
        final class Process {
            var argv: [String] = []
            init() {}
        }
        extension Process { var tag: String { "t" } }
        func lookalike() -> Process { _ = Date(); let p = Process(); p.argv = ["-x"]; return p }
        """
        let r = try scan(src, name: "Look", policy: "deny Exec\n")
        XCTAssertEqual(r.fns["lookalike"], ["Clock"],
                       "a locally DECLARED type always shadows the platform table — constructing it is "
                       + "project code")
        XCTAssertEqual(r.code, 0, "the lookalike tree under `deny Exec` must PASS: \(r.out)")
    }

    /// A LOCAL FREE FUNCTION of the same name still shadows: the fence that moved is the TYPE one.
    func testALocalFreeFunctionStillShadows() throws {
        let src = """
        import Foundation
        func shellOut(to cmd: String) -> String { _ = Date(); return cmd }
        func callsIt() -> String { _ = Date(); return shellOut(to: "ls") }
        """
        let r = try scan(src, name: "Free", policy: "deny Exec\n")
        XCTAssertEqual(r.fns["callsIt"], ["Clock"],
                       "`shellOut` is a κ free-call entry AND a function this project declares — the "
                       + "project's wins (`localFreeFns`), or every same-named helper fabricates `Exec`")
        XCTAssertEqual(r.code, 0, "and no verdict moves: \(r.out)")
    }

    /// AN EXTENSION-ONLY TYPE κ DOES NOT KNOW keeps behaving exactly as it did: no effect appears, and
    /// the edge to its extension's own init still resolves. This is the row that says the change is
    /// scoped to the κ arms rather than to every constructor in the language.
    func testAnUnknownExtendedTypeIsUnchanged() throws {
        let src = """
        import Foundation
        extension NumberFormatter {
            convenience init(readingLocaleFrom key: String) {
                self.init()
                _ = ProcessInfo.processInfo.environment[key]
            }
        }
        func makesFormatter() -> NumberFormatter { _ = Date(); return NumberFormatter(readingLocaleFrom: "LANG") }
        func makesPlainFormatter() -> NumberFormatter { _ = Date(); return NumberFormatter() }
        """
        let r = try scan(src, name: "Fmt")
        XCTAssertEqual(r.fns["makesFormatter"], ["Clock", "Env"],
                       "κ knows nothing about NumberFormatter, so the only effect is the one the "
                       + "project's own init actually performs")
        XCTAssertEqual(r.fns["makesPlainFormatter"], ["Clock", "Env"],
                       "…and the bare ctor resolves to the same local init, as it always has")
    }

    /// THE OTHER κ CTOR FAMILIES take the same fence, so they get the same row: an
    /// `extension EKEventStore` must not silence calendar access, and an `extension AVCaptureDevice`
    /// must not silence a sensor. Asserted as PARITY with the un-extended spelling of the identical
    /// program — the classifier's answer is its own business (a media-typed capture ctor is
    /// over-disclosed, an EventKit store reaches both entity types), but an extension may not change it.
    func testTheOtherCtorFamiliesTakeTheSameFence() throws {
        let src = """
        import AVFoundation
        import EventKit
        import Foundation
        extension EKEventStore { var tag: String { "t" } }
        func opensStore() -> EKEventStore { _ = Date(); return EKEventStore() }
        func opensDevice() -> AVCaptureDevice? { _ = Date(); return AVCaptureDevice(uniqueID: "front") }
        """
        let plain = """
        import AVFoundation
        import EventKit
        import Foundation
        func opensStore() -> EKEventStore { _ = Date(); return EKEventStore() }
        func opensDevice() -> AVCaptureDevice? { _ = Date(); return AVCaptureDevice(uniqueID: "front") }
        """
        let r = try scan(src, name: "Fam")
        let p = try scan(plain, name: "Plain")
        XCTAssertEqual(r.fns["opensStore"], p.fns["opensStore"],
                       "an extended EventKit store answers as an un-extended one does")
        XCTAssertEqual(r.fns["opensDevice"], p.fns["opensDevice"],
                       "…and so does an extended capture device")
        XCTAssertEqual(r.fns["opensStore"], ["Calendar", "Clock", "Reminders"],
                       "and the shared answer is the over-disclosing one privacy requires — a row here so "
                       + "a collapse to `Clock` on BOTH sides could not pass the parity check above")
        XCTAssertEqual(r.fns["opensDevice"], ["Camera", "Clock", "Mic"],
                       "a capture device constructed with no media type may be either sensor")
    }
}
