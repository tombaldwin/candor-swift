import XCTest
import Foundation
@testable import CandorCore

/// **SOUNDNESS R786 / R787 / R788 / R789 — ONE SHAPE: A GUARD KEYED ON A MEMBERSHIP TABLE WHERE THE
/// ENGINE ANSWERS THAT SAME QUESTION WITH A RULE, OR WITH A SECOND TABLE, SOMEWHERE ELSE.**
///
/// Four measured silent under-reports, all with executed ground truth, all closed by DERIVATION rather
/// than by adding names. The register's own sentence for the vein — *two tables answer one question and
/// only one gets updated* — is why this file asserts the derivations themselves and not just the
/// behaviour: behaviour tests pin the four spellings that were measured, and the next spelling is the
/// next row. A derivation cannot diverge.
///
///   R787  `fsKind` classified `setAttributes`/`trashItem`/`isExecutableFile`/`isDeletableFile` and
///         `FS_MEMBERS` — the set `kappaMember` consults for a `FileManager` root — did not contain any
///         of them. `FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: p)`
///         produced NO function row and exited 0 under `deny Fs <unit>`, `deny Fs <caller>`, blanket
///         `deny Fs` and `deny Unknown`, while really taking a file from 600 to 777.
///         FIX: `FS_MEMBERS = Set(FS_MEMBER_KINDS.keys)`.
///   R786  `isEstablishingMember` had `Net` and `Fs` arms and `default: return false`, so there was no
///         `Exec` arm at all and `Process.launchedProcess(launchPath:)` — whose program is an ARGUMENT —
///         was treated as a use-verb. `allow Exec in <unit> /bin/ls` exited 0 on the unit and its caller
///         over a caller-chosen command masked by a benign literal sibling.
///         FIX: `PROCESS_MEMBER_ROLES`, read by all three consumers.
///   R788  `NET_MEMBERS` was a nine-name allowlist on a single-purpose networking type and did not know
///         `dataTaskPublisher(for:)`. FIX: a DENYLIST, matching `NWConnection`'s in the same switch.
///   R789  A list of TYPE NAMES cannot express inheritance: `NSMutableDictionary` has no
///         `init(contentsOfFile:)` of its own. FIX: the argument LABEL answers, and Foundation's
///         class-cluster naming answers the arm where the label cannot.
///
/// **THE DIVERGENCE CHECKS BELOW ARE CALIBRATED IN THIS FILE (§1b).** A check that watches two lists
/// agree is the weakest thing here, and an agreement check never shown to fail is the exact shape this
/// register keeps finding in its own gates — so each is a PURE FUNCTION over tables passed in, and each
/// is fed a SEEDED divergent pair and required to report it before it is trusted over the real ones.
final class TableDerivationProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32) {
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
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return (by, r.code)
    }
    private func eff(_ f: [String: Any]?) -> [String] {
        ((f?["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
    }
    private func incomplete(_ f: [String: Any]?) -> [String] {
        ((f?["incomplete"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
    }

    // ── 1. THE DERIVATIONS ───────────────────────────────────────────────────────────────────────
    // These are not style assertions. Each pins a set that USED to be maintained by hand beside the
    // table that answers the same question, and each failure mode was a measured silent under-report.

    func testFsMembersIsDerivedFromTheKindTableAndNotMaintainedBesideIt() {
        XCTAssertEqual(FS_MEMBERS, Set(FS_MEMBER_KINDS.keys),
                       "R787 — FS_MEMBERS must BE the kind table's domain, not a copy of it")
        // The four that were classified and not members. Each is now both, necessarily.
        for m in ["setAttributes", "trashItem", "isExecutableFile", "isDeletableFile"] {
            XCTAssertTrue(FS_MEMBERS.contains(m), "\(m) is classified by fsKind and must be a member")
            XCTAssertFalse(fsKind(root: "FileManager", member: m).isEmpty, "\(m) must keep its direction")
            XCTAssertEqual(kappaMember(root: "FileManager", member: m), "Fs")
            XCTAssertTrue(isEstablishingMember(effect: "Fs", root: "FileManager", member: m),
                          "\(m) takes its path as an argument — a runtime one must mark the surface incomplete")
        }
        // The four that were members and NEVER classified keep exactly their old answer: `[]` is an
        // answer ("member, yes; direction, not claimed"), not a gap. §2 forbids guessing a direction.
        for m in ["temporaryDirectory", "urls", "url", "homeDirectoryForCurrentUser"] {
            XCTAssertTrue(FS_MEMBERS.contains(m))
            XCTAssertEqual(fsKind(root: "FileManager", member: m), [])
        }
        // The prefix/shape rules are deliberately NOT folded into the table: `copy()` and `append` are
        // NSObject / sequence members, and a `FS_MEMBERS` containing them would fabricate `Fs` on
        // `someFileHandle.copy()`. Membership is by NAME; direction may additionally be by SHAPE.
        XCTAssertFalse(FS_MEMBERS.contains("copy"))
        XCTAssertFalse(FS_MEMBERS.contains("append"))
        XCTAssertNil(kappaMember(root: "FileHandle", member: "copy"))
        XCTAssertEqual(fsKind(root: "FileHandle", member: "writeData"), ["write"])   // shape rule intact
        XCTAssertEqual(fsKind(root: "FileHandle", member: "forReadingAtPath"), ["read"])
    }

    func testProcessMembersAndBothLocatorQuestionsReadOneRoleTable() {
        XCTAssertEqual(PROCESS_MEMBERS, Set(PROCESS_MEMBER_ROLES.keys),
                       "R786 — PROCESS_MEMBERS must BE the role table's domain")
        // The program is an ARGUMENT here, so a runtime one is structurally invisible → ESTABLISHING.
        for m in ["launchedProcess", "launchedTaskWithExecutableURL"] {
            XCTAssertEqual(PROCESS_MEMBER_ROLES[m], .argLocator)
            XCTAssertTrue(isEstablishingMember(effect: "Exec", root: "Process", member: m))
        }
        // The program was armed by an earlier property write; `recordProcessRun` reads it there.
        for m in ["run", "launch"] {
            XCTAssertEqual(PROCESS_MEMBER_ROLES[m], .priorLocator)
            XCTAssertFalse(isEstablishingMember(effect: "Exec", root: "Process", member: m))
        }
        // Wait/teardown/live-child control names no program, so it claims none and demands none.
        for m in ["waitUntilExit", "terminate", "interrupt", "suspend", "resume"] {
            XCTAssertEqual(PROCESS_MEMBER_ROLES[m], .control)
            XCTAssertFalse(isEstablishingMember(effect: "Exec", root: "Process", member: m))
        }
        // THE DEFAULT IS FAIL-CLOSED, and this is the assertion that says so. ⟨0.32⟩ already rules that
        // an unmodelled `Process` member is `Exec`; an ALLOWLIST here would answer "not establishing"
        // for that same member and put it back in R786's hole.
        XCTAssertTrue(isEstablishingMember(effect: "Exec", root: "Process", member: "launchedSomethingNobodyHasWrittenYet"))
        XCTAssertFalse(isEstablishingMember(effect: "Exec", root: "URLSession", member: "dataTask"),
                       "the Exec arm is scoped to Process — it must not leak onto other roots")
    }

    func testURLSessionRequestVerbsAreOnePredicateAndTheTaskFamilyIsAPrefixRule() {
        // R788 — κ and the masking guard must never disagree about what a request is. They cannot: they
        // are one function. The union includes the Combine spellings the row is about and a future
        // sibling nobody has written, which the FAMILY PREFIX answers.
        for m in NET_MEMBERS.union(["dataTaskPublisher", "uploadTaskPublisher", "downloadTaskPublisher",
                                    "dataTaskAsyncSomethingAppleShipsNextYear", "webSocketTaskPublisher"]) {
            XCTAssertEqual(kappaMember(root: "URLSession", member: m), "Net", "\(m)")
            XCTAssertTrue(isNetEstablishingMember(root: "URLSession", member: m), "\(m)")
        }
        // THE REFUSED DENYLIST, pinned so it cannot be reintroduced without re-reading the measurement.
        // `kappaMember`'s `root` is the CHAIN ROOT, so a whole-type rule charges every member reached
        // through a value that merely starts at a URLSession — measured over-charges in Alamofire, Nuke
        // and RxCocoa. These three must stay NIL.
        for m in ["defaultCredential", "addOperation", "shouldLogRequest"] {
            XCTAssertNil(kappaMember(root: "URLSession", member: m), "\(m) — R788's refused inversion")
            XCTAssertFalse(isNetEstablishingMember(root: "URLSession", member: m), "\(m)")
        }
        // …and the lifecycle surface the inversion would also have had to carve out.
        for m in ["invalidateAndCancel", "finishTasksAndInvalidate", "configuration", "delegateQueue"] {
            XCTAssertNil(kappaMember(root: "URLSession", member: m), "\(m)")
        }
    }

    func testFoundationMutableBaseIsTheOnlyInheritanceThisEngineClaims() {
        // R789 — the Foundation class-cluster convention, which IS the inheritance.
        XCTAssertEqual(foundationClassKey("NSMutableDictionary"), "NSDictionary")
        XCTAssertEqual(foundationClassKey("NSMutableArray"), "NSArray")
        XCTAssertEqual(foundationClassKey("NSMutableData"), "NSData")
        XCTAssertEqual(foundationClassKey("NSMutableString"), "NSString")
        XCTAssertEqual(foundationClassKey("NSMutableAttributedString"), "NSAttributedString")
        // …and it claims nothing else. A name that merely contains the word is not a cluster member.
        XCTAssertEqual(foundationClassKey("NSDictionary"), "NSDictionary")
        XCTAssertEqual(foundationClassKey("MyNSMutableThing"), "MyNSMutableThing")
        XCTAssertEqual(foundationClassKey("NSMutable"), "NSMutable")   // no suffix ⇒ no claim
        XCTAssertNil(foundationMutableBase("Data"))
    }

    // ── 2. THE DIVERGENCE CHECKS, CALIBRATED ─────────────────────────────────────────────────────
    // Where two tables genuinely must stay separate, the check is a pure function and is SHOWN TO FAIL
    // on a seeded divergence before it is believed over the real tables. An agreement check that has
    // never failed is not a gate.

    /// Every member of `sub` must be a member of `sup`. Returns the offenders, so the failure NAMES them.
    private static func missingFrom(_ sub: Set<String>, _ sup: Set<String>) -> Set<String> {
        sub.subtracting(sup)
    }

    func testTheDivergenceCheckFailsOnASeededDivergence() {
        // CALIBRATION. The check is fed a pair that DOES diverge and must say so — and must name the
        // offender rather than merely returning non-empty, because "some table is wrong" is not a
        // finding anyone can act on.
        let seeded = Self.missingFrom(["fileExists", "aVerbNobodyClassified"], ["fileExists"])
        XCTAssertEqual(seeded, ["aVerbNobodyClassified"])
        // …and it must be SILENT on an agreeing pair, or it would fire on everything and mean nothing.
        XCTAssertEqual(Self.missingFrom(["fileExists"], ["fileExists", "contents"]), [])
    }

    func testEveryUrlDiskVerbHasAnEntryInTheOneKindTable() {
        // `URL_FS_MEMBERS` is a SEPARATE table on purpose: it answers "which members of URL issue a
        // syscall against the receiver's path", which is a different question from "is this name a
        // filesystem verb". But a URL verb with no entry in `FS_MEMBER_KINDS` would publish `Fs` with
        // no direction — R787's shape, one type over — so the subset relation is gated.
        XCTAssertEqual(Self.missingFrom(URL_FS_MEMBERS, FS_MEMBERS), [],
                       "R787 — a URL disk verb with no kind-table entry")
        for m in URL_FS_MEMBERS {
            XCTAssertFalse(fsKind(root: "URL", member: m).isEmpty, "\(m) must carry a direction")
            XCTAssertTrue(isReceiverLocatorMember(effect: "Fs", root: "URL", member: m))
        }
    }

    func testEveryTwoPathVerbIsAMember() {
        // A two-locator entry for a name that is not a member could never fire: the call would not be
        // classified `Fs` in the first place, so the two-path guard would never be asked and a literal
        // source would mask a runtime destination silently. `setUbiquitous` arrived with R787 and this
        // is the check that would have caught it arriving without its entry.
        XCTAssertEqual(Self.missingFrom(Set(FS_TWO_PATH_MEMBERS.keys), FS_MEMBERS), [])
        XCTAssertNotNil(FS_TWO_PATH_MEMBERS["setUbiquitous"])
        XCTAssertEqual(Self.missingFrom(Set(FILES_TWO_PATH_DEST.keys), FILES_MEMBERS), [])
        XCTAssertEqual(Self.missingFrom(FILES_NON_LOCATOR_MEMBERS, FILES_MEMBERS), [])
    }

    func testTheProcessRoleTableDoesNotContradictTheCapabilityDenylist() {
        // A member cannot be both a launch/control verb and a PROVEN-inert one; if it were, the answer
        // would depend on whether the receiver happened to be provable as an invocation value.
        XCTAssertTrue(PROCESS_MEMBERS.isDisjoint(with: PROCESS_PURE_MEMBERS))
        XCTAssertTrue(PROCESS_MEMBERS.isDisjoint(with: PROCESS_ENV_MEMBERS))
    }

    // ── 3. THE BEHAVIOUR, WITH GATE EXITS ON THE UNIT AND ON ITS CALLER ──────────────────────────
    // Each fixture is ISOLATED — one silent call and its caller, no other effect of that kind anywhere
    // — because a mixed fixture cannot answer an isolation question, and a blanket `deny` reading over
    // one is incidental. Function names share no prefix: a scoped rule over a short name also binds
    // longer names sharing that prefix.

    private static let fsSrc = """
    import Foundation
    public func zebra(_ p: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: p)
    }
    public func yankee(_ p: String) { zebra(p) }
    """

    func testR787TheSilentModeChangeIsChargedAndGatesOnUnitAndCaller() throws {
        let s = try scan(Self.fsSrc, name: "R787")
        XCTAssertEqual(eff(s.fns["zebra"]), ["Fs"])
        XCTAssertEqual(eff(s.fns["yankee"]), ["Fs"])
        XCTAssertEqual(incomplete(s.fns["zebra"]), ["Fs"], "the path is a runtime argument")
        XCTAssertEqual(try scan(Self.fsSrc, name: "R787a", policy: "deny Fs zebra").code, 1)
        XCTAssertEqual(try scan(Self.fsSrc, name: "R787b", policy: "deny Fs yankee").code, 1)
        XCTAssertEqual(try scan(Self.fsSrc, name: "R787c", policy: "deny Fs").code, 1)
    }

    private static let netSrc = """
    import Foundation
    import Combine
    public func zebra(_ u: URL) -> AnyPublisher<Data, URLError> {
        return URLSession.shared.dataTaskPublisher(for: u).map(\\.data).eraseToAnyPublisher()
    }
    public func yankee(_ u: URL) -> AnyPublisher<Data, URLError> { return zebra(u) }
    """

    func testR788TheCombineSpellingIsChargedAndGatesOnUnitAndCaller() throws {
        let s = try scan(Self.netSrc, name: "R788")
        XCTAssertEqual(eff(s.fns["zebra"]), ["Net"])
        XCTAssertEqual(eff(s.fns["yankee"]), ["Net"])
        XCTAssertEqual(incomplete(s.fns["zebra"]), ["Net"], "the URL is a runtime argument")
        XCTAssertEqual(try scan(Self.netSrc, name: "R788a", policy: "deny Net zebra").code, 1)
        XCTAssertEqual(try scan(Self.netSrc, name: "R788b", policy: "deny Net yankee").code, 1)
    }

    private static let mutSrc = """
    import Foundation
    public func zebra(_ p: String) -> NSMutableDictionary? { return NSMutableDictionary(contentsOfFile: p) }
    public func yankee(_ p: String) -> NSMutableArray? { return NSMutableArray(contentsOfFile: p) }
    public func xray(_ p: String) -> NSMutableData? { return NSMutableData(contentsOfFile: p) }
    public func whisky(_ p: String) -> NSMutableString? {
        return try? NSMutableString(contentsOfFile: p, encoding: String.Encoding.utf8.rawValue)
    }
    // the LABEL rule, not the name list — a type no table here will ever contain
    public func victor(_ p: String) -> SomeVendorConfig? { return SomeVendorConfig(contentsOfFile: p) }
    public func uniform(_ p: String) -> NSMutableDictionary? { return zebra(p) }
    """

    func testR789TheInheritedInitializerIsChargedThroughTheLabelAndTheClusterName() throws {
        let s = try scan(Self.mutSrc, name: "R789")
        for n in ["zebra", "yankee", "xray", "whisky", "victor", "uniform"] {
            XCTAssertEqual(eff(s.fns[n]), ["Fs"], "\(n) reads a file back")
            XCTAssertEqual(incomplete(s.fns[n]), ["Fs"], "\(n) — the path is a runtime argument")
        }
        XCTAssertEqual(try scan(Self.mutSrc, name: "R789a", policy: "deny Fs zebra").code, 1)
        XCTAssertEqual(try scan(Self.mutSrc, name: "R789b", policy: "deny Fs uniform").code, 1)
        XCTAssertEqual(try scan(Self.mutSrc, name: "R789c", policy: "deny Fs").code, 1)
    }

    private static let execSrc = """
    import Foundation
    public func zebra(_ c: String) {
        _ = Process.launchedProcess(launchPath: "/bin/ls", arguments: [])
        _ = Process.launchedProcess(launchPath: c, arguments: [])
    }
    public func yankee(_ c: String) { zebra(c) }
    """

    func testR786ABenignLiteralNoLongerMasksACallerChosenCommand() throws {
        let s = try scan(Self.execSrc, name: "R786")
        XCTAssertEqual(eff(s.fns["zebra"]), ["Exec"])
        XCTAssertEqual(incomplete(s.fns["zebra"]), ["Exec"],
                       "R786 — one of the two launchPaths is a runtime value")
        XCTAssertEqual(incomplete(s.fns["yankee"]), ["Exec"], "…and it must reach the caller")
        // THE GATE THAT PASSED. `allow Exec <list>` cannot certify a surface whose locator is invisible.
        XCTAssertEqual(try scan(Self.execSrc, name: "R786a", policy: "allow Exec in zebra /bin/ls").code, 1)
        XCTAssertEqual(try scan(Self.execSrc, name: "R786b", policy: "allow Exec in yankee /bin/ls").code, 1)
    }

    // ── 4. THE OVER-CHARGE CONTROLS ──────────────────────────────────────────────────────────────
    // A guard that marks everything is not a fix, and killing a silent under-report is exactly where
    // the next over-charge gets introduced. Every control carries a CLOCK MARKER and is asserted
    // PRESENT with a non-empty effect set — a pure unit is omitted from the report, so "absent" would
    // pass a control that asked nothing.

    private static let ctlSrc = """
    import Foundation
    // NSObject generics on an Fs owner: membership is by NAME, so these must not become Fs.
    public func oscar(_ h: FileHandle) -> Any { _ = Date(); return h.copy() }
    public func papa(_ f: FileManager) -> String { _ = Date(); return f.description }
    // the URLSession denylist carve-outs: lifecycle and configuration send no bytes.
    public func november(_ s: URLSession) { _ = Date(); s.invalidateAndCancel() }
    public func mike(_ s: URLSession) { _ = Date(); s.finishTasksAndInvalidate() }
    public func lima(_ s: URLSession) -> URLSessionConfiguration { _ = Date(); return s.configuration }
    // a Process CONTROL verb names no program: it must not demand one.
    public func kilo(_ p: Process) { _ = Date(); p.waitUntilExit() }
    // the contentsOfFile LABEL rule must not fire on a lowercase free function — that is a call, not a
    // constructor, and it is answered by the ordinary call edge.
    public func juliet(_ p: String) -> Int { _ = Date(); return helper(contentsOfFile: p) }
    func helper(contentsOfFile: String) -> Int { return contentsOfFile.count }
    """

    func testTheNewRulesDoNotChargeWhatTheyShouldNot() throws {
        let s = try scan(Self.ctlSrc, name: "CTL")
        for n in ["oscar", "papa", "november", "mike", "lima", "juliet"] {
            XCTAssertEqual(eff(s.fns[n]), ["Clock"], "\(n) must carry its marker and NOTHING else")
        }
        // `kilo` is the ONE control that legitimately carries an effect, and it is here to pin the
        // OTHER half: ⟨0.32⟩ rules the subprocess capability belongs to the TYPE, so `p.waitUntilExit()`
        // on a received handle is `Exec` and always was. What R786 must not do is make it demand a
        // program it never names — the `.control` role is exactly that carve-out, and an over-broad
        // fail-closed default would have marked this incomplete.
        XCTAssertEqual(eff(s.fns["kilo"]), ["Clock", "Exec"])
        XCTAssertEqual(incomplete(s.fns["kilo"]), [], "a control verb claims no program and demands none")
        XCTAssertEqual(try scan(Self.ctlSrc, name: "CTLa", policy: "deny Fs").code, 0)
        XCTAssertEqual(try scan(Self.ctlSrc, name: "CTLb", policy: "deny Net").code, 0)
    }
}
