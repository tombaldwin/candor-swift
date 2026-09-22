import XCTest
import Foundation

/// **SOUNDNESS R534 — WHERE A PROTOCOL IS *DECLARED* DECIDED WHETHER ITS PARAMETERS WERE TYPED AT ALL.**
///
/// `DeclCollector` recorded a parameter's protocol in `info.protoParams` *or* its type in `info.params`,
/// never both, and the branch that chose between them read `protocolMethods[resolved] != nil` — a map
/// that is per-FILE and filled as that file's walk descends. So the question actually being asked was
/// *"is this protocol spelled ABOVE this function, in this file?"*, and the answer decided which index
/// the parameter reached. The two indexes have DISJOINT consumer sets, so whichever one was populated,
/// the other one's consumers went blind:
///
///   · protocol ABOVE, same file → only `protoParams`. `h?.emit()`, `h!.emit()`, `(h!).emit()`,
///     `h.unsafelyUnwrapped.emit()`, `switch h { case .some(let g) }`, `_ = h?.emit()` and a capturing
///     closure were **ABSENT from `functions[]`** — `deny Net` exit 0 over a real `URLSession` reach.
///   · protocol BELOW or in another file → only `params`. `h.map { $0.emit() }` and
///     `<T: P>(_ h: T?) { if let g = h … }` were **ABSENT** instead — the same hole, mirrored.
///
/// **That mirror is why this test carries all three declaration orders.** A fix that simply always
/// populated `protoParams` would have closed the direction the row was filed from and opened the other;
/// the fixture has to contain both arms of the inversion or it cannot see the trade. The fix populates
/// BOTH maps and backfills `protoParams` in the Driver, where `protocolMethods` is scan-global — so the
/// answer no longer depends on source layout at all, which is the property these three columns pin.
///
/// **It is not always an absence, and that is worse.** `j_mixed` below is PRESENT, affirmative and
/// complete-looking — `inferred: ["Fs"]`, `unresolved: false`, `unknownWhy: null` — while silently
/// omitting the `Net` its optional-chained dispatch reaches. A reader sees a row and believes it.
///
/// Two spellings the same sweep found silent in ALL THREE orders, closed here with it: `<T: P>(_ h: T?)`
/// (`params` records the useless generic name `T`, so only the `protoTyped` path can answer — and two of
/// that map's six consumers did not `peel` the receiver) and `h: P!` (`ImplicitlyUnwrappedOptionalType`
/// appeared NOWHERE in this engine's sources, so every `T!` fell off the end of `typeName` as `nil`).
/// The `T!` peel is scoped to PARAMETERS — see `DeclCollector.parameterTypeName` for the Kingfisher
/// measurement that drew that boundary; `T!` FIELDS and BINDINGS are still untyped and still open.
///
/// MEASURED at `5b6e806` on a 66-arm fixture (22 spellings × 3 declaration orders) in which **every arm
/// compiles and really executes its call** — a `Marker.hit()` counter proved all 66 reach the witness,
/// because an absence assertion over a program that cannot run is asserting something about nothing
/// (§E3). 23 arms were silent or incomplete before the fix; the surviving residual is the ternary-valued
/// receiver, which is a control-flow-merge question and not this row.
final class ProtocolParamDeclOrderProcessTests: XCTestCase {

    /// One protocol, one effectful conformer, one differently-effectful conformer. TWO conformers so a
    /// bounded CHA union (`Fs` + `Env`) is distinguishable from a single-witness answer, and `Env` so a
    /// suppression that dropped one arm could not hide behind the other.
    private static func decls(_ p: String, _ s: String, _ c: String, _ d: String) -> String {
        """
        public protocol \(p) { func emit\(s)() }
        public final class \(c): \(p) {
            public init() {}
            public func emit\(s)() { try? FileManager.default.removeItem(atPath: "/tmp/r534-\(s)") }
        }
        public final class \(d): \(p) {
            public init() {}
            public func emit\(s)() { _ = ProcessInfo.processInfo.environment["HOME"] }
        }
        """
    }

    /// The 22 spellings, rendered for one declaration order. `pfx` prefixes every function name so all
    /// three orders can be asserted out of ONE scan — the scan is then the thing held constant, and the
    /// only difference between the columns is where the protocol sits.
    private static func arms(_ pfx: String, _ p: String, _ s: String, _ c: String) -> String {
        """
        public func \(pfx)_optchain(_ h: \(p)?) { h?.emit\(s)() }
        public func \(pfx)_force(_ h: \(p)?) { h!.emit\(s)() }
        public func \(pfx)_parenforce(_ h: \(p)?) { (h!).emit\(s)() }
        public func \(pfx)_unsafeunw(_ h: \(p)?) { h.unsafelyUnwrapped.emit\(s)() }
        public func \(pfx)_switchsome(_ h: \(p)?) { switch h { case .some(let g): g.emit\(s)(); case .none: break } }
        public func \(pfx)_discardopt(_ h: \(p)?) { _ = h?.emit\(s)() }
        public func \(pfx)_iuo(_ h: \(p)!) { h.emit\(s)() }
        public func \(pfx)_genopt<T: \(p)>(_ h: T?) { h?.emit\(s)() }
        public func \(pfx)_arrfirst(_ hs: [\(p)]) { hs.first?.emit\(s)() }
        public func \(pfx)_arropt(_ hs: [\(p)?]) { hs[0]?.emit\(s)() }
        public func \(pfx)_optmap(_ h: \(p)?) { h.map { $0.emit\(s)() } }
        public func \(pfx)_geniflet<T: \(p)>(_ h: T?) { if let g = h { g.emit\(s)() } }
        public func \(pfx)_closure(_ h: \(p)?) { let f = { h?.emit\(s)() }; f() }
        public func \(pfx)_opaque(_ h: some \(p)) { h.emit\(s)() }
        public func \(pfx)_opaqueopt(_ h: (some \(p))?) { h?.emit\(s)() }
        public func \(pfx)_anyexist(_ h: any \(p)) { h.emit\(s)() }
        public func \(pfx)_anyexistopt(_ h: (any \(p))?) { h?.emit\(s)() }
        public func \(pfx)_mixed(_ h: \(p)?) { _ = ProcessInfo.processInfo.processIdentifier; h?.emit\(s)() }
        public func \(pfx)_c_plain(_ h: \(p)) { h.emit\(s)() }
        public func \(pfx)_c_iflet(_ h: \(p)?) { if let g = h { g.emit\(s)() } }
        public func \(pfx)_c_ctor(_ x: Int) { \(c)().emit\(s)() }
        """
    }

    private static let ARMS = [
        "optchain", "force", "parenforce", "unsafeunw", "switchsome", "discardopt", "iuo", "genopt",
        "arrfirst", "arropt", "optmap", "geniflet", "closure", "opaque", "opaqueopt", "anyexist",
        "anyexistopt", "mixed",
    ]
    /// Charged at `5b6e806`, in every order, BEFORE this fix existed. A change that made everything
    /// charge — or nothing — cannot pass while these are asserted alongside the arms.
    private static let CONTROLS = ["c_plain", "c_iflet", "c_ctor"]

    private func scanAllThreeOrders() throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makeFilesPackage([
            // 1. protocol declared ABOVE the call sites, same file
            "above.swift": "import Foundation\n\n"
                + Self.decls("PA", "A", "CA", "DA") + "\n" + Self.arms("ab", "PA", "A", "CA"),
            // 2. protocol declared BELOW the call sites, same file
            "below.swift": "import Foundation\n\n"
                + Self.arms("be", "PB", "B", "CB") + "\n" + Self.decls("PB", "B", "CB", "DB"),
            // 3. protocol in a DIFFERENT file entirely
            "xproto.swift": "import Foundation\n\n" + Self.decls("PX", "X", "CX", "DX"),
            "xcalls.swift": "import Foundation\n\n" + Self.arms("xf", "PX", "X", "CX"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        _ = try ProcessHarness.run(bin, [root.path, "--out", out.path])
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.App.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return by
    }

    // ── 1. EVERY SPELLING, IN EVERY DECLARATION ORDER ────────────────────────────────────────────
    func testProtocolParamIsTypedWhereverTheProtocolIsDeclared() throws {
        let by = try scanAllThreeOrders()
        for (pfx, order) in [("ab", "protocol ABOVE, same file"),
                             ("be", "protocol BELOW, same file"),
                             ("xf", "protocol in ANOTHER file")] {
            for ctl in Self.CONTROLS {
                let inf = (by["\(pfx)_\(ctl)"]?["inferred"] as? [String]) ?? []
                XCTAssertTrue(inf.contains("Fs"),
                              "CONTROL \(pfx)_\(ctl) (\(order)) must charge Fs — it did at 5b6e806")
            }
            for a in Self.ARMS {
                let fn = "\(pfx)_\(a)"
                let inf = (by[fn]?["inferred"] as? [String]) ?? []
                XCTAssertTrue(by[fn] != nil,
                              "R534: \(fn) (\(order)) is ABSENT from functions[] — that absence IS the purity claim")
                XCTAssertTrue(inf.contains("Fs"),
                              "R534: \(fn) (\(order)) must charge Fs, got \(inf)")
            }
        }
    }

    // ── 2. THE ANSWER MUST NOT DEPEND ON SOURCE LAYOUT ───────────────────────────────────────────
    //
    // The sharpest statement of the row, and the one a future narrowing would break first: the three
    // columns are the SAME program written three ways, so any difference between them is an artefact of
    // where a `protocol` keyword was typed. Asserted as EQUALITY of effect sets rather than as a list of
    // expected values, so it keeps its teeth if the vocabulary ever grows.
    func testTheThreeDeclarationOrdersAgreeArmForArm() throws {
        let by = try scanAllThreeOrders()
        func effects(_ fn: String) -> Set<String> { Set((by[fn]?["inferred"] as? [String]) ?? []) }
        for a in Self.ARMS + Self.CONTROLS {
            let above = effects("ab_\(a)"), below = effects("be_\(a)"), cross = effects("xf_\(a)")
            XCTAssertEqual(above, below,
                           "R534: \(a) answers differently with the protocol ABOVE (\(above.sorted())) "
                           + "than BELOW (\(below.sorted())) — same program, different source layout")
            XCTAssertEqual(below, cross,
                           "R534: \(a) answers differently same-file (\(below.sorted())) than cross-file "
                           + "(\(cross.sorted())) — same program, different source layout")
        }
    }

    // ── 3. THE AFFIRMATIVE ROW, WHICH IS WORSE THAN THE ABSENCE ──────────────────────────────────
    //
    // `*_mixed` reaches BOTH a direct `Env` and, through the optional-chained dispatch, `Fs`. Before the
    // fix the ABOVE column published `["Env"]` with `unresolved: false` and no `unknownWhy` — a present,
    // complete-looking row that silently drops half its reach. The `c_plain` control in the same scan is
    // what makes this an assertion about the OPTIONAL binder rather than about the effect pair.
    // ── 4. THE FIX'S OWN FAILURE DIRECTION: A REBOUND NAME KEEPS ITS PROTOCOL ────────────────────
    //
    // `protoTyped` is consulted BEFORE `vars` at every dispatch and property-read site, and
    // `visit(VariableDeclSyntax)` used to SKIP clearing it whenever the initializer mentioned the name —
    // the `var u = u.asURL()` shape. So `func enc(_ r: Conv) { var r = r.asReq(); _ = r.headers }` read
    // `r.headers` through `Conv`, which declares no such member, and the effectful `Req.headers` accessor
    // was dropped: `enc` read PURE. That exemption was correct when written (SwiftSyntax walked the
    // pattern before the initializer) and expired when R98 moved the initializer walk to the top of the
    // visitor — a stale ordering fact, not a judgement call.
    //
    // MEASURED with ONE variable, where the protocol is declared: at `5b6e806` the protocol-BELOW
    // spelling charged and the protocol-ABOVE spelling was ALREADY silent. That is why it belongs to this
    // row: making `protoParams` order-independent without this would have spread the silent arm to all
    // three orders. `selfrename` is the control the clear must not break.
    func testARebindDoesNotKeepTheParameterSProtocolType() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makeFilesPackage([
            "above.swift": """
            import Foundation
            public protocol ConvA { func asReqA() -> ReqA }
            public struct ReqA { public var headers: Int { try? FileManager.default.removeItem(atPath: "/tmp/r534-a"); return 0 } }
            public struct ImplA: ConvA { public init() {}; public func asReqA() -> ReqA { ReqA() } }
            public func ab_rebind(_ r: ConvA) { var r = r.asReqA(); _ = r.headers; r = ReqA() }
            public func ab_selfrename(_ r: ConvA) { let r = r; _ = r.asReqA() }
            public func ab_control(_ x: ReqA) { _ = x.headers }
            """,
            "below.swift": """
            import Foundation
            public func be_rebind(_ r: ConvB) { var r = r.asReqB(); _ = r.headers; r = ReqB() }
            public func be_selfrename(_ r: ConvB) { let r = r; _ = r.asReqB() }
            public func be_control(_ x: ReqB) { _ = x.headers }
            public protocol ConvB { func asReqB() -> ReqB }
            public struct ReqB { public var headers: Int { try? FileManager.default.removeItem(atPath: "/tmp/r534-b"); return 0 } }
            public struct ImplB: ConvB { public init() {}; public func asReqB() -> ReqB { ReqB() } }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        _ = try ProcessHarness.run(bin, [root.path, "--out", out.path])
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.App.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        for pfx in ["ab", "be"] {
            XCTAssertTrue(((by["\(pfx)_control"]?["inferred"] as? [String]) ?? []).contains("Fs"),
                          "CONTROL \(pfx)_control must charge Fs")
            XCTAssertTrue(((by["\(pfx)_rebind"]?["inferred"] as? [String]) ?? []).contains("Fs"),
                          "R534: \(pfx)_rebind must charge Fs — a name rebound to a CONCRETE type must "
                          + "stop resolving through the parameter's protocol")
            // …and the clear must not break the rename that keeps the protocol.
            XCTAssertTrue(((by["\(pfx)_selfrename"]?["calls"] as? [String]) ?? []).contains(where: {
                $0.hasSuffix(".asReq\(pfx == "ab" ? "A" : "B")")
            }), "R534: \(pfx)_selfrename lost its protocol dispatch — `let r = r` is a rename, not a retype")
        }
    }

    // ── 5. THE SIBLING `TypedRebindShadowProcessTests` WAS NOT HANDED (§A.2) ─────────────────────
    //
    // That suite's `nestedFuncShadow` — `func f(_ j: Job) { func inner(_ j: Ctx) { j.run() } }` must not
    // charge `RealJob.run` — declares `protocol Job` at the TOP of its fixture, so it only ever exercised
    // the protocol-ABOVE order, where a protocol-typed parameter was absent from `vars` and the leak it
    // guards was latent. In the BELOW and cross-file orders `params` HAS always been populated, so the
    // fabrication was live there at `5b6e806` and no fixture looked. R534 makes all three orders agree,
    // which means this control has to be asserted in all three or it is again pinning one of them.
    //
    // `vars` is function-wide and not in `ShadowSave`, so the clear is SCOPED per FunctionDecl id and
    // given back at `visitPost`: `outerAfter` is the mirror control — the enclosing parameter's own
    // dispatch must survive the nested func, or the fabrication has been traded for a miss.
    func testANestedFuncsParameterDoesNotInheritTheOuterProtocol() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        func decls(_ s: String) -> String {
            """
            public protocol J\(s) { func run\(s)() }
            public struct Real\(s): J\(s) {
                public init() {}
                public func run\(s)() { try? FileManager.default.removeItem(atPath: "/tmp/r534-n\(s)") }
            }
            public struct Ctx\(s) { public init() {}; public func run\(s)() {} }
            """
        }
        func arms(_ pfx: String, _ s: String) -> String {
            """
            public func \(pfx)_nestedShadow(_ j: J\(s)) { func inner(_ j: Ctx\(s)) { j.run\(s)() }; inner(Ctx\(s)()) }
            public func \(pfx)_nestedRenamed(_ j: J\(s)) { func inner(_ q: Ctx\(s)) { q.run\(s)() }; inner(Ctx\(s)()) }
            public func \(pfx)_outerAfter(_ j: J\(s)) { func inner(_ j: Ctx\(s)) { j.run\(s)() }; inner(Ctx\(s)()); j.run\(s)() }
            """
        }
        let root = try ProcessHarness.makeFilesPackage([
            "above.swift": "import Foundation\n" + decls("A") + "\n" + arms("ab", "A"),
            "below.swift": "import Foundation\n" + arms("be", "B") + "\n" + decls("B"),
            "xproto.swift": "import Foundation\n" + decls("X"),
            "xcalls.swift": "import Foundation\n" + arms("xf", "X"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        _ = try ProcessHarness.run(bin, [root.path, "--out", out.path])
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.App.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        for pfx in ["ab", "be", "xf"] {
            let shadow = Set((by["\(pfx)_nestedShadow"]?["inferred"] as? [String]) ?? [])
            let renamed = Set((by["\(pfx)_nestedRenamed"]?["inferred"] as? [String]) ?? [])
            XCTAssertFalse(shadow.contains("Fs"),
                           "R534: \(pfx)_nestedShadow charged Fs — the NESTED `Ctx` parameter was "
                           + "dispatched over the OUTER protocol's conformers")
            XCTAssertEqual(shadow, renamed,
                           "\(pfx): the rename control — the only difference is the name collision")
            XCTAssertTrue(((by["\(pfx)_outerAfter"]?["inferred"] as? [String]) ?? []).contains("Fs"),
                          "R534: \(pfx)_outerAfter lost the ENCLOSING parameter's own dispatch — the "
                          + "nested-func scope must be given back, not cleared outward")
        }
    }

    func testMixedRowDoesNotLookCompleteWhileDroppingHalfItsReach() throws {
        let by = try scanAllThreeOrders()
        for pfx in ["ab", "be", "xf"] {
            let row = by["\(pfx)_mixed"]
            XCTAssertNotNil(row, "R534: \(pfx)_mixed absent")
            let inf = Set((row?["inferred"] as? [String]) ?? [])
            XCTAssertTrue(inf.isSuperset(of: ["Env", "Fs"]),
                          "R534: \(pfx)_mixed published \(inf.sorted()) — an affirmative row that omits "
                          + "the optional-chained dispatch's reach is believed, where an absence is at "
                          + "least questioned")
        }
    }
}
