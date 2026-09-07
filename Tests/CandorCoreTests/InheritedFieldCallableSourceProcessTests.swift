import XCTest
import Foundation

/// **SOUNDNESS R268 — AN INHERITED STORED PROPERTY WAS NOT A CALLABLE / CONTAINER SOURCE, so iterating
/// it read SILENT-PURE: no row, no `Unknown`, nothing.**
///
/// R211/R192/R215 made a container or callable field of `self` a callable source, so
/// `for c in cbs { c(p) }` over `let cbs: [(String) -> Void]` is disclosed as `Unknown callback:`. The
/// three indexes those fixes read — `fields` (through `fieldIsCallable`), `fieldArrayElem` and
/// `fieldDictValue` — are keyed on the enclosing type and were consulted with `enclosingType` alone, so
/// they NEVER CLIMBED `supertypesOf`. The method-call path (R134) climbs; the property-ACCESSOR path
/// climbs and asserts in its own comment that it does so "exactly as the method-call path does". Three
/// paths answer *"what does this member hold"*; one did not.
///
/// Measured on a generated 126-cell matrix, every cell compiled and EXECUTED: **36 cells where an
/// inherited container field really invokes a stored closure that deletes a file and the enclosing
/// function is ABSENT from `functions[]` entirely**, while the OWN-TYPE spelling of the same program is
/// correctly `Unknown`. Every sub-axis failed — one and two levels of inheritance, `[T]` element /
/// `[K: V]` value / plain callable, and the bare, `self.`- and `let`-copy spellings.
///
/// **THE ROW'S EXCULPATING CLAUSE WAS WRONG, AND IT WAS A FIX BOUNDARY.** It said "the inherited
/// COMPUTED property is correct, which is the drift." True of the property-ACCESSOR path — an effectful
/// getter reached from a subclass is charged at every depth — and FALSE of a computed property that
/// VENDS CALLABLES, which is silent exactly like the stored `let`. **18 of the 36 are computed.** A fix
/// written to that sentence climbs for stored fields only and leaves half the class open. The real drift
/// is OWN-TYPE DISCLOSED vs INHERITED ABSENT, not stored vs computed — which is why both cases below
/// carry their own-type twin in the SAME SCAN as the discriminator.
final class InheritedFieldCallableSourceProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--out", root.appendingPathComponent("r").path]
        if let policy {
            let p = root.appendingPathComponent("pol.txt")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        let d = try? JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, r.code, r.out + r.err)
    }

    // ── 1. THE DEFECT: an inherited STORED array of callables, one and two levels up ──────────────
    // `Own.run` is the discriminator IN THE SAME SCAN: identical body, field declared locally, always
    // disclosed. EXECUTED — every one of these really deletes its probe file.
    func testAnInheritedStoredContainerFieldIsACallableSource() throws {
        let src = """
        import Foundation
        func bomb(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        class Own { let cbs: [(String) -> Void] = [bomb]
                    func run(_ p: String) { for c in cbs { c(p) } } }
        class Base1 { let cbs: [(String) -> Void] = [bomb] }
        class Sub1: Base1 { func run(_ p: String) { for c in cbs { c(p) } } }
        class Base2 { let cbs: [(String) -> Void] = [bomb] }
        class Mid2: Base2 {}
        class Sub2: Mid2 { func run(_ p: String) { for c in self.cbs { c(p) } } }
        Own().run("/tmp/inh-a"); Sub1().run("/tmp/inh-b"); Sub2().run("/tmp/inh-c")
        """
        let r = try scan(src, name: "InhField", policy: "deny Fs Unknown Sub1.run\n")
        XCTAssertEqual(r.fns["Own.run"], ["Unknown"],
                       "THE DISCRIMINATOR: the own-type spelling was always disclosed — it is what the "
                       + "inherited spellings must match: \(r.out)")
        XCTAssertEqual(r.fns["Sub1.run"], ["Unknown"],
                       "THE DEFECT, one level up: an inherited stored container really invokes a closure "
                       + "that deletes the file, and had NO ROW AT ALL: \(r.out)")
        XCTAssertEqual(r.fns["Sub2.run"], ["Unknown"],
                       "THE DEFECT, two levels up and `self.`-qualified — the climb is transitive: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown Sub1.run`, SCOPED, must FAIL: \(r.out)")
    }

    // ── 2. THE CLAUSE THE ROW GOT WRONG: a COMPUTED property that VENDS CALLABLES ─────────────────
    // Distinct from the property-ACCESSOR path (case 3), which was already correct. This is the half a
    // fix written to "the inherited computed property is correct" would have left open.
    func testAnInheritedComputedPropertyVendingCallablesIsAlsoASource() throws {
        let src = """
        import Foundation
        func bomb(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        class OwnC { var cbs: [(String) -> Void] { [bomb] }
                     func run(_ p: String) { for c in cbs { c(p) } } }
        class BaseC { var cbs: [String: (String) -> Void] { ["k": bomb] } }
        class SubC: BaseC { func run(_ p: String) { for (_, c) in cbs { c(p) } } }
        class BaseF { var cb: (String) -> Void { bomb } }
        class SubF: BaseF { func run(_ p: String) { let z = cb; z(p) } }
        OwnC().run("/tmp/inh-d"); SubC().run("/tmp/inh-e"); SubF().run("/tmp/inh-f")
        """
        let r = try scan(src, name: "InhComputed", policy: "deny Fs Unknown SubC.run\n")
        XCTAssertEqual(r.fns["OwnC.run"], ["Unknown"], "THE DISCRIMINATOR, own type: \(r.out)")
        XCTAssertEqual(r.fns["SubC.run"], ["Unknown"],
                       "THE DEFECT the row's wording excluded: an inherited COMPUTED property vending "
                       + "callables — a `[K: V]` here — is silent exactly like the stored `let`: \(r.out)")
        XCTAssertEqual(r.fns["SubF.run"], ["Unknown"],
                       "and the plain inherited callable read through a `let` copy: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown SubC.run` must FAIL: \(r.out)")
    }

    // ── 3. THE PATH THAT WAS ALREADY RIGHT — the drift, pinned so it cannot silently reverse ─────
    // An inherited COMPUTED property whose GETTER performs the effect is charged precisely (`Fs`, not
    // `Unknown`) at every depth. This is what the row's clause was actually about, and keeping it in the
    // suite is what makes case 2 a distinction rather than a contradiction.
    func testAnInheritedEffectfulAccessorWasAlreadyChargedPrecisely() throws {
        let src = """
        import Foundation
        class BaseA { var t: Int { try? FileManager.default.removeItem(atPath: "/tmp/inh-g"); return 1 } }
        class MidA: BaseA {}
        class SubA: MidA { func run() { _ = t } }
        SubA().run()
        """
        let r = try scan(src, name: "InhAccessor", policy: "deny Fs SubA.run\n")
        XCTAssertEqual(r.fns["SubA.run"], ["Fs"],
                       "the property-ACCESSOR path climbs and charges precisely — the half of the drift "
                       + "that was never broken: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs SubA.run` must FAIL: \(r.out)")
    }

    // ── 4. OVER-CHARGE CONTROL: an OVERRIDE wins, and a pure twin gains no effect ─────────────────
    // The flattening is additive and writes only where the subtype declares nothing itself, so an
    // override must still shadow the base's field. And the pure twin — identical shape, a field of
    // callables that do nothing — must not gain an EFFECT (a disclosure is not an effect).
    func testAnOverridingFieldWinsAndAPureTwinGainsNoEffect() throws {
        let src = """
        import Foundation
        func bomb(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        func calm(_ p: String) { _ = p.count }
        class BaseO { var cbs: [(String) -> Void] { [bomb] } }
        class SubO: BaseO { override var cbs: [(String) -> Void] { [calm] }
                            func run(_ p: String) { for c in cbs { c(p) } } }
        class BaseQ { let cbs: [(String) -> Void] = [calm] }
        class SubQ: BaseQ { func run(_ p: String) { for c in cbs { c(p) } } }
        SubO().run("/tmp/inh-h"); SubQ().run("/tmp/inh-i")
        """
        // SCOPED to the callers, deliberately: a blanket `deny Fs` fails here for a reason that has
        // nothing to do with the flattening — `bomb` is a real Fs function in the same file and carries
        // its own row. Reading that exit as evidence about these two callers is the "caught only
        // INCIDENTALLY" trap the four-policy-form rule exists to stop.
        let r = try scan(src, name: "InhOverride", policy: "deny Fs SubO.run\n")
        XCTAssertEqual(r.fns["SubO.run"], ["Unknown"],
                       "OVERRIDE WINS: the flattening writes only where the subtype declares nothing "
                       + "itself, so `SubO.cbs` shadows the base's and no Fs is fabricated: \(r.out)")
        XCTAssertEqual(r.fns["SubQ.run"], ["Unknown"],
                       "PURE TWIN: the shape still discloses that the callee is unresolved, and that "
                       + "disclosure must not become an EFFECT: \(r.out)")
        XCTAssertEqual(r.code, 0,
                       "`deny Fs SubO.run`, SCOPED to the caller, must PASS — the overriding field holds "
                       + "a pure callable and the flattening fabricated no Fs: \(r.out)")
    }
}
