import XCTest
import Foundation

/// A NAME-KEYED FACT MUST NOT OUTLIVE THE BINDING THAT SET IT — the fifth instance of swift's own
/// recurring shape (`71de627`, `83cd607`, `42093b6`), found by auditing the maps the catch-all binder
/// does NOT cover rather than by waiting for a report to be wrong.
///
/// `clearBinding` covered `vars`/`arrayElem`/`opaqueElem`/`dictElem`/`tupleElem` and `shadowName` covered
/// `monoNames`/`depBoundLocals`. Two more name-keyed maps were covered by neither, and both leaked in the
/// FABRICATION direction — the one the other flags do not produce:
///
///   `protoTyped`        the LOCAL-protocol CHA. `func f(_ j: Job, _ xs: [String]) { for j in xs { j.run() } }`
///                       charged the conformer's Env to a call on a String.
///   `localConstStrings` the const-anchored literal surfaces. A shadowed `let u = "https://…"` attributed
///                       that host to a `dataTask` whose address is a runtime value — and `hosts` is what
///                       an `allow`/`forbid` host rule matches on.
///
/// EVERY ROW HAS ITS RENAME CONTROL. Identical bodies with the binder renamed is the only thing that
/// separates "the flag leaked" from "this binder was never typed anyway" — the distinction `42093b6`
/// recorded after a scoping fix that changed nothing.
final class BinderShadowProcessTests: XCTestCase {

    private func scan(_ src: String, _ name: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return by
    }

    private static let protoSrc = """
    import Foundation
    protocol Job { func run() }
    protocol Conv { func asThing() -> Int }
    struct RealJob: Job { func run() { print(ProcessInfo.processInfo.environment["X"] ?? "") } }
    struct S1: Conv { func asThing() -> Int { print(ProcessInfo.processInfo.environment["X"] ?? ""); return 1 } }

    // the fabrication, and its rename control
    func loopShadow(_ j: Job, _ xs: [String]) { for j in xs { j.run() } }
    func loopNoShadow(_ j: Job, _ xs: [String]) { for t in xs { t.run() } }
    // the genuine parameter must still dispatch — before AND after a shadowing block
    func control(_ j: Job) { j.run() }
    func restoredAfterBlock(_ j: Job, _ xs: [String]) {
        for j in xs { _ = j }
        j.run()
    }
    // THE ORDERING ROW: the dispatch lives in the INITIALIZER of a binding that rebinds the same name,
    // so the old binding is still live while the initializer is walked. Alamofire's
    // `URLRequest.init(url: any URLConvertible …)` is `let url = try url.asURL()`, exactly this.
    func selfRebind(_ u: Conv) {
        let u = u.asThing()
        _ = u
    }
    func selfRebindControl(_ u: Conv) { _ = u.asThing() }
    // …and a rebind that does NOT mention the name must still invalidate the protocol type
    func typedRebind(_ u: Conv, _ s: String) {
        let u = s
        _ = u.asThing()
    }
    func typedRebindNoShadow(_ u: Conv, _ s: String) {
        let t = s
        _ = t.asThing()
    }
    """

    func testALoopBinderDoesNotInheritTheProtocolTypeOfTheParameterItShadows() throws {
        let by = try scan(Self.protoSrc, "Proto")
        XCTAssertEqual(by["control"]?["inferred"] as? [String], ["Env"],
                       "the trigger must be live, or every row below is vacuous")
        XCTAssertNil(by["loopShadow"],
                     "the loop binder is a String — charging the conformer's Env to `j.run()` is a fabrication")
        XCTAssertNil(by["loopNoShadow"], "the rename control: same body, different binder name")
        XCTAssertEqual(by["typedRebind"]?["inferred"] as? [String] ?? [], [],
                       "a typed rebind also stops the protocol type applying")
        XCTAssertNil(by["typedRebindNoShadow"])
    }

    /// THE SECOND FIXTURE, and it is the one that decided where the clear lives. Putting `protoTyped`
    /// in `shadowName` closes the fabrication above and sends this row from `['Env']` to ABSENT — the
    /// cardinal sin, traded in for its mirror. Measured on Alamofire as a real lost disclosure.
    func testTheReachInARebindingInitializerSurvives() throws {
        let by = try scan(Self.protoSrc, "Proto")
        XCTAssertEqual(by["selfRebindControl"]?["inferred"] as? [String], ["Env"])
        XCTAssertEqual(by["selfRebind"]?["inferred"] as? [String], ["Env"],
                       "`let u = u.asThing()` resolves through the binding it replaces — clearing before "
                       + "the initializer is walked loses a real reach (Alamofire URLRequest.init)")
        XCTAssertEqual(by["restoredAfterBlock"]?["inferred"] as? [String], ["Env"],
                       "the enclosing scope restores the protocol type past the shadowing block")
    }

    private static let constSrc = """
    import Foundation
    func hostLiteral() {
        let t = URLSession.shared.dataTask(with: "https://telemetry.example.com/beacon") { _, _, _ in }
        t.resume()
    }
    func hostConst() {
        let u = "https://telemetry.example.com/beacon"
        let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
        t.resume()
    }
    func hostConstShadowed(_ xs: [String]) {
        let u = "https://telemetry.example.com/beacon"
        _ = u
        for u in xs {
            let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
            t.resume()
        }
    }
    func hostConstNotShadowed(_ xs: [String]) {
        let u = "https://telemetry.example.com/beacon"
        _ = u
        for v in xs {
            let t = URLSession.shared.dataTask(with: v) { _, _, _ in }
            t.resume()
        }
    }
    func hostConstRestoredAfterLoop(_ xs: [String]) {
        let u = "https://telemetry.example.com/beacon"
        for u in xs { _ = u }
        let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
        t.resume()
    }
    """

    func testAShadowedConstStringDoesNotAnchorALiteralHost() throws {
        let by = try scan(Self.constSrc, "Const")
        let host = ["telemetry.example.com"]
        // the trigger, both directly and through the const — or the row below asserts nothing
        XCTAssertEqual(by["hostLiteral"]?["hosts"] as? [String], host)
        XCTAssertEqual(by["hostConst"]?["hosts"] as? [String], host)
        // the fabrication and its rename control
        XCTAssertNil(by["hostConstShadowed"]?["hosts"],
                     "the loop binder's URL is a runtime value — a literal endpoint here is fabricated")
        XCTAssertNil(by["hostConstNotShadowed"]?["hosts"], "the rename control")
        for fn in ["hostConstShadowed", "hostConstNotShadowed"] {
            XCTAssertEqual(by[fn]?["inferred"] as? [String], ["Net"], "\(fn): the Net effect itself stands")
        }
        // the second direction: the const must survive the shadowing loop and still anchor below it
        XCTAssertEqual(by["hostConstRestoredAfterLoop"]?["hosts"] as? [String], host,
                       "the enclosing scope restores the const past the loop")
    }
}
