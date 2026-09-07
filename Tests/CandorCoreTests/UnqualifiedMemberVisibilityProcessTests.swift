import XCTest
import Foundation

/// **SOUNDNESS R265 / R266 / R277 — the three MEMBER arms of the unqualified-call chain claimed calls
/// they cannot see, and keyed two of themselves on the SHORT enclosing type name.**
///
/// R255 reordered these arms in front of the free-function arms on the (true) ground that a VISIBLE
/// member of `self` always beats a module-scope function of the same name. It keyed that decision on
/// `overloadedBases` / `byQual` / `supertypesOf`, **none of which carry access control or file/module
/// scope**, and two of which are keyed on the SHORT type name. Three separate defects follow:
///
/// * **R265 — a member that is NOT VISIBLE at the call site claimed the call.** Swift's unqualified
///   lookup stops at the type scope only when the member is visible there; otherwise it binds the
///   global. 94 cells of a generated 1152-cell matrix regressed against the v0.35.0 artifact:
///   `private` 52, `fileprivate` 28, `internal` 14, **`public` 0** — the visibility axis behaving
///   exactly as the language says, which is the control that this is the right rule. **24 of the 94 are
///   in ONE FILE**: `private` is scoped to the declaring declaration and its same-file extensions, and a
///   SUBCLASS IS NEITHER, so an inherited `private` member is invisible even to a subclass one line
///   below it. A guard written against file PLACEMENT rather than against the language's visibility rule
///   leaves exactly those 24.
/// * **R266 — arms 1 and 3 keyed on the SHORT name, so a nested type collided with an unrelated
///   top-level type of the same short name** and edged into its members. Arm 2 was already path-precise
///   and its comment said so; the two siblings it names were the wrong ones. **Reachable only when the
///   caller is declared in the type's OWN BODY** — an `extension Outer.S` pushes the whole dotted
///   spelling as ONE `typeStack` element, so `enclosingType == enclosingTypePath` there and the
///   collision cannot occur. A 576-cell pass without a call-site axis found ZERO instances of this.
/// * **R277 — and the mirror miss.** Because an extension pushes the dotted spelling whole, a caller in
///   `extension Outer.S` looked up `supertypesOf["Outer.S"]`, a key the DECLARATION side (keyed `"S"`)
///   never writes. The climb returned empty and R255 handed the call to a same-named global. Silent at
///   v0.35.0 as well as at HEAD.
///
/// Every assertion below is RED on the pre-fix binary, verified by reverting the source. The matrix that
/// produced them ran EXECUTED cells with three distinguishable effects — global `Fs`, member `Env`,
/// unrelated same-short-name type `Clock` — so the report names WHICH candidate was bound rather than
/// merely whether an effect appeared.
final class UnqualifiedMemberVisibilityProcessTests: XCTestCase {

    private func report(_ root: URL, _ name: String, policy: String?)
        throws -> (fns: [String: [String]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
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

    // ── 1. R265, CROSS-FILE: a `private` member cannot claim a call made from another file ────────
    // The global does Fs and the member does Env, so the two are DISTINGUISHABLE: the report names
    // which one was bound rather than only whether an effect appeared. EXECUTED: the file is really
    // deleted, through the global.
    func testAPrivateMemberDoesNotClaimACallFromAnotherFile() throws {
        let root = try ProcessHarness.makeFilesPackage([
            "a.swift": """
            import Foundation
            func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            class C { private func wipe(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
            class Pub { public func wipe(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
            """,
            "b.swift": """
            import Foundation
            extension C { func caller(_ p: String) { wipe(p) } }
            extension Pub { func caller(_ p: String) { wipe(p) } }
            """,
            "main.swift": "C().caller(\"/tmp/vis-a\"); Pub().caller(\"/tmp/vis-b\")\n",
        ], name: "VisFile")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try report(root, "VisFile", policy: "deny Fs C.caller\n")
        XCTAssertEqual(r.fns["C.caller"], ["Fs"],
                       "THE DEFECT: `private func wipe` is INVISIBLE from another file, so Swift binds "
                       + "the effectful global and the file is really deleted: \(r.out)")
        XCTAssertEqual(r.fns["Pub.caller"], ["Env"],
                       "THE CONTROL, one modifier over: a `public` member IS visible, so R255's ordering "
                       + "must still stand and the member's Env must win: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs C.caller`, SCOPED to the caller, must FAIL: \(r.out)")
    }

    // ── 2. R265, SAME FILE: `private` is not inherited-visible, even one line below ───────────────
    // The 24 cells a file-placement guard would leave. `fileprivate` in the same file IS visible — the
    // discriminating twin, in the same scan, so this is not one assertion in isolation.
    func testAPrivateInheritedMemberIsInvisibleToASubclassInTheSameFile() throws {
        let root = try ProcessHarness.makeFilesPackage([
            "a.swift": """
            import Foundation
            func zap(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            class BaseP { private func zap(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
            class SubP: BaseP { func caller(_ p: String) { zap(p) } }
            func fzap(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            class BaseF { fileprivate func fzap(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
            class SubF: BaseF { func caller(_ p: String) { fzap(p) } }
            SubP().caller("/tmp/vis-c"); SubF().caller("/tmp/vis-d")
            """,
        ], name: "VisSame")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try report(root, "VisSame", policy: "pure SubP.caller\n")
        XCTAssertEqual(r.fns["SubP.caller"], ["Fs"],
                       "THE DEFECT, SAME FILE: `private` is scoped to the declaring declaration and its "
                       + "same-file extensions — a SUBCLASS is neither, so Swift binds the global: \(r.out)")
        XCTAssertEqual(r.fns["SubF.caller"], ["Env"],
                       "THE DISCRIMINATOR, one modifier over in the same scan: `fileprivate` IS visible "
                       + "to a subclass in the same file, so the member must still win: \(r.out)")
        XCTAssertEqual(r.code, 1, "`pure SubP.caller` must FAIL: \(r.out)")
    }

    // ── 3. R265, CROSS-MODULE: `internal` does not cross a module boundary; `public` does ─────────
    func testAnInternalMemberDoesNotClaimACallFromAnotherModule() throws {
        let root = try ProcessHarness.makeLibExePackage(lib: [
            "core.swift": """
            import Foundation
            public func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            public class Int1 { public init() {}
                                internal func wipe(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
            public class Pub1 { public init() {}
                                public func wipe(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
            """,
        ], exe: [
            "main.swift": """
            import Foundation
            import Core
            extension Int1 { func caller(_ p: String) { wipe(p) } }
            extension Pub1 { func caller(_ p: String) { wipe(p) } }
            Int1().caller("/tmp/vis-e"); Pub1().caller("/tmp/vis-f")
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try report(root, "App", policy: "deny Fs Int1.caller\n")
        XCTAssertEqual(r.fns["Int1.caller"], ["Fs"],
                       "THE DEFECT, CROSS-MODULE: an `internal` member is invisible outside its module, "
                       + "so Swift binds the public global: \(r.out)")
        XCTAssertEqual(r.fns["Pub1.caller"], ["Env"],
                       "THE CONTROL: a `public` member IS visible across the boundary: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs Int1.caller` must FAIL: \(r.out)")
    }

    // ── 4. R266: a nested type must not reach an unrelated top-level type of the same SHORT name ──
    // Distinguishable by effect: the nested hierarchy's member does Env, the unrelated same-short-named
    // type's does Clock. The caller sits in the type's OWN BODY — the only site where `enclosingType` is
    // the short name and the collision is reachable at all.
    func testANestedTypeDoesNotInheritFromAnUnrelatedSameShortNamedType() throws {
        let root = try ProcessHarness.makeFilesPackage([
            "a.swift": """
            import Foundation
            func run(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            enum Outer {
                class Base { func run(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
                class S: Base { func caller(_ p: String) { run(p) } }
            }
            class Other { func run(_ p: String) { _ = Date().timeIntervalSince1970 } }
            class S: Other {}
            Outer.S().caller("/tmp/vis-g")
            """,
        ], name: "VisNest")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try report(root, "VisNest", policy: "deny Clock Outer.S.caller\n")
        XCTAssertEqual(r.fns["Outer.S.caller"], ["Env"],
                       "THE DEFECT: the caller must reach ITS OWN base's Env and NOT the unrelated "
                       + "top-level `S`'s Clock — a fabrication over a same-SHORT-name collision: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Clock Outer.S.caller` must PASS: \(r.out)")
    }

    // ── 5. R277: a caller in an EXTENSION of a nested type still reaches its INHERITED member ─────
    // An `extension Outer.S` pushes the dotted spelling as ONE type-stack element, so the climb looked
    // up `supertypesOf["Outer.S"]` — a key the declaration side (keyed "S") never writes — got nothing,
    // and R255 handed the call to the same-named global. Silent at v0.35.0 too.
    func testAnExtensionOfANestedTypeReachesItsInheritedMember() throws {
        let root = try ProcessHarness.makeFilesPackage([
            "a.swift": """
            import Foundation
            func run(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            enum Outer {
                class Base { func run(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
                class S: Base {}
            }
            extension Outer.S { func caller(_ p: String) { run(p) } }
            Outer.S().caller("/tmp/vis-h")
            """,
        ], name: "VisExtNest")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try report(root, "VisExtNest", policy: "deny Fs Outer.S.caller\n")
        XCTAssertEqual(r.fns["Outer.S.caller"], ["Env"],
                       "THE DEFECT: the visible inherited member is what Swift binds and what runs — the "
                       + "global's Fs must not be charged in its place: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Fs Outer.S.caller` must PASS — nothing is deleted: \(r.out)")
    }

    // ── 6. OVER-CHARGE CONTROL: the fix must not make ordinary visible members fall to the global ──
    // The direction a visibility filter fails in if it is too strict: declining a member arm Swift DOES
    // bind reintroduces R255's silence. Four visible spellings, all of which must still bind the member.
    func testEveryVISIBLESpellingStillBindsTheMember() throws {
        let root = try ProcessHarness.makeFilesPackage([
            "a.swift": """
            import Foundation
            func w1(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            class A1 { private func w1(_ p: String) { _ = ProcessInfo.processInfo.environment[p] }
                       func caller(_ p: String) { w1(p) } }
            func w2(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            class B2 { fileprivate func w2(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
            extension B2 { func caller(_ p: String) { w2(p) } }
            func w3(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            class C3 { func w3(_ p: String) { _ = ProcessInfo.processInfo.environment[p] } }
            class D3: C3 { func caller(_ p: String) { w3(p) } }
            func w4(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
            class E4 { func w4(_ p: String) { _ = ProcessInfo.processInfo.environment[p] }
                       func w4(_ q: Int) { _ = q } }
            class F4: E4 { func caller(_ p: String) { w4(p) } }
            A1().caller("/tmp/vis-i"); B2().caller("/tmp/vis-j")
            D3().caller("/tmp/vis-k"); F4().caller("/tmp/vis-l")
            """,
        ], name: "VisKeep")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try report(root, "VisKeep", policy: "deny Fs\n")
        XCTAssertEqual(r.fns["A1.caller"], ["Env"], "own-class `private`, same file — visible: \(r.out)")
        XCTAssertEqual(r.fns["B2.caller"], ["Env"],
                       "`fileprivate` reached from an extension in the SAME file — visible: \(r.out)")
        XCTAssertEqual(r.fns["D3.caller"], ["Env"], "inherited `internal`, same module — visible: \(r.out)")
        XCTAssertEqual(r.fns["F4.caller"], ["Env"],
                       "inherited and OVERLOADED, same module — visible, and must still route through "
                       + "the overload matcher rather than vanishing: \(r.out)")
    }
}
