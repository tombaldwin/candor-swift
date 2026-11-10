import XCTest
import Foundation
@testable import CandorCore

/// SPEC §2 `switches` / §3.4 / §3.3 cause (e) ⟨0.42⟩ (SOUNDNESS R1634), end to end over the BUILT binary. Conformance PART 109
/// pins the cross-engine shape; these pin the properties of THIS engine that no cross-engine cell can see: that every
/// registered switch is read lazily (a clean `gate --report` must not consult a scan-time switch), and that no read bypasses
/// the record.
final class ResultMovingSwitchesTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: ResultMovingSwitchesTests.self) }

    /// Run with every CANDOR_ variable stripped from the inherited environment, plus `env`.
    private func run(_ args: [String], env: [String: String] = [:]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = try bin()
        p.arguments = args
        var e = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CANDOR_") }
        for (k, v) in env { e[k] = v }
        p.environment = e
        let o = Pipe(), er = Pipe()
        p.standardOutput = o; p.standardError = er
        let exited = ProcessHarness.exitLatch(p)
        try p.run()
        let od = ProcessHarness.drain(o), ed = ProcessHarness.drain(er)
        exited.wait()
        return (String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self), p.terminationStatus)
    }

    /// `[1,2,3].shuffled()` draws entropy; CANDOR_R1032_OFF removes that (PART 109's swift fixture).
    private static let fixture = "func mixAll() -> [Int] { [1, 2, 3].shuffled() }\n"
    private static let sw = "CANDOR_R1032_OFF"

    private func report(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    /// The one `<prefix>.<pkg>.Swift.json` a scan wrote next to `prefix` (the package part is the scan target's name).
    private func written(_ d: URL, _ prefix: String) throws -> URL {
        let hits = try FileManager.default.contentsOfDirectory(atPath: d.path)
            .filter { $0.hasPrefix(prefix + ".") && $0.hasSuffix(".Swift.json") && !$0.hasSuffix(".callgraph.json") && !$0.hasSuffix(".hierarchy.json") }
        XCTAssertEqual(hits.count, 1, "reports under \(prefix): \(hits)")
        return d.appendingPathComponent(try XCTUnwrap(hits.first))
    }
    private func fnNames(_ d: [String: Any]) -> [String] { (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String } }

    private func tmp() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-swift-sw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testReportNamesASetAndConsultedSwitchAndSpecIsUnchanged() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("cases.swift"); try Self.fixture.write(to: src, atomically: true, encoding: .utf8)
        let u = try run([src.path, "--out", d.appendingPathComponent("u").path])
        XCTAssertEqual(u.code, 0, u.err)
        let w = try run([src.path, "--out", d.appendingPathComponent("w").path], env: [Self.sw: "1"])
        XCTAssertEqual(w.code, 0, w.err)
        let ur = try report(written(d, "u")), wr = try report(written(d, "w"))
        XCTAssertNil(ur["switches"], "no switch set: the key is OMITTED")
        XCTAssertTrue(fnNames(ur).contains("mixAll"), "control: the unit is present unswitched")
        XCTAssertFalse(fnNames(wr).contains("mixAll"), "the switch must MOVE the result, or nothing here measures anything")
        XCTAssertEqual(wr["switches"] as? [String], [Self.sw])
        XCTAssertEqual((wr["candor"] as? [String: Any])?["spec"] as? String, (ur["candor"] as? [String: Any])?["spec"] as? String,
                       "`spec` is NOT changed (§3.4 (b))")
        // a prefixed variable the engine never consults is not listed, and a clean run does not list the harness's own
        let n = try run([src.path, "--out", d.appendingPathComponent("n").path], env: ["CANDOR_R0_OFF": "1"])
        XCTAssertEqual(n.code, 0)
        XCTAssertNil(try report(written(d, "n"))["switches"])
    }

    func testPolicyRunUnderASwitchRefusesButStillWritesItsReport() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("cases.swift"); try Self.fixture.write(to: src, atomically: true, encoding: .utf8)
        let pol = d.appendingPathComponent("pol"); try "deny Rand mixAll\n".write(to: pol, atomically: true, encoding: .utf8)
        let gj = d.appendingPathComponent("gate.json")
        let ctl = try run([src.path, "--out", d.appendingPathComponent("c").path, "--policy", pol.path, "--gate-json", gj.path])
        XCTAssertEqual(ctl.code, 1, "control: the unswitched policy run fires")
        let r = try run([src.path, "--out", d.appendingPathComponent("r").path, "--policy", pol.path, "--gate-json", gj.path],
                        env: [Self.sw: "1"])
        XCTAssertEqual(r.code, 2, r.err)
        let g = try report(gj)
        XCTAssertEqual(g["ok"] as? Bool, false); XCTAssertEqual(g["refused"] as? Bool, true)
        XCTAssertNil(g["violations"], "a refusal carries NO `violations` key")
        XCTAssertEqual(g["switches"] as? [String], [Self.sw])
        let reason = try XCTUnwrap(g["reason"] as? String)
        XCTAssertTrue(reason.contains(Self.sw) && reason.contains("Unset"), reason)
        XCTAssertEqual(try report(written(d, "r"))["switches"] as? [String], [Self.sw],
                       "the refused run STILL wrote its report, carrying `switches`")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("r.refused.json").path),
                       "no `.refused.json` marker: it would say the written report is stale, and it is not")
        // and the same report through `gate --report` refuses with the same document
        let g2 = d.appendingPathComponent("gate2.json")
        let rr = try run(["gate", "--report", written(d, "r").path, "--policy", pol.path, "--gate-json", g2.path])
        XCTAssertEqual(rr.code, 2, rr.err)
        XCTAssertEqual(try report(g2)["switches"] as? [String], [Self.sw])
    }

    private static let handReport = """
    {"candor":{"version":"handwritten","spec":"0.42"},"package":"app","analyzed":{"count":1,"digest":"0"},
     "functions":[{"fn":"app.f","hash":"app#app.f","inferred":["Fs"],"direct":["Fs"]}]}
    """

    /// §3.4 (a): an engine MUST NOT read every switch at start. Set EVERY registered switch (enumerated from the source: the
    /// names handed to `Env.on` / `Env.value` / `Env.read`, so a new switch is covered without an edit here) and run the
    /// evaluator verbs over a clean report: none may refuse, because none runs the analysis that reads them.
    func testNoRegisteredSwitchIsConsultedByTheEvaluatorVerbs() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let rep = d.appendingPathComponent("h.Swift.json"); try Self.handReport.write(to: rep, atomically: true, encoding: .utf8)
        let pol = d.appendingPathComponent("pol"); try "deny Fs\n".write(to: pol, atomically: true, encoding: .utf8)
        var names = Set<String>()
        let re = try NSRegularExpression(pattern: #"Env\.(?:on|value|read)\(\s*"(CANDOR_[A-Z0-9_]+)""#)
        for f in EnvLintTests.swiftFiles() {
            let s = try String(contentsOf: f, encoding: .utf8)
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) { names.insert(String(s[Range(m.range(at: 1), in: s)!])) }
        }
        XCTAssertGreaterThan(names.count, 150, "the enumeration found too few switches — the regex drifted from the call shape")
        XCTAssertTrue(names.contains(Self.sw))
        var all: [String: String] = [:]
        for n in names { all[n] = "1" }
        let base = ["--report", rep.path, "--policy", pol.path]
        for verb in ["gate", "unverified", "fix-gate"] {
            let plain = try run([verb] + base), set = try run([verb] + base, env: all)
            XCTAssertEqual(set.code, plain.code, "`\(verb)` changed its answer under \(names.count) set switches: \(set.err) \(set.out)")
            XCTAssertFalse(set.out.contains("\"refused\""), "`\(verb)` refused: it consulted a switch it has no reason to read")
        }
        XCTAssertEqual(try run(["gate"] + base, env: all).code, 1, "the control is live: the clean report's `deny Fs` fires")
    }

    func testReportCarryingSwitchesRefusesTheGateAndTheAdvisoryVerbs() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        var j = try JSONSerialization.jsonObject(with: Data(Self.handReport.utf8)) as! [String: Any]
        j["switches"] = ["CANDOR_Z_OFF", "CANDOR_A_OFF"]
        let rep = d.appendingPathComponent("s.Swift.json")
        try JSONSerialization.data(withJSONObject: j).write(to: rep)
        let pol = d.appendingPathComponent("pol"); try "deny Fs\n".write(to: pol, atomically: true, encoding: .utf8)
        let gj = d.appendingPathComponent("g.json")
        let g = try run(["gate", "--report", rep.path, "--policy", pol.path, "--gate-json", gj.path])
        XCTAssertEqual(g.code, 2, "a violation does NOT dominate cause (e): \(g.err)")
        XCTAssertEqual(try report(gj)["switches"] as? [String], ["CANDOR_A_OFF", "CANDOR_Z_OFF"], "code-point sorted")
        for verb in ["unverified", "fix-gate"] {
            for strict in [[], ["--strict"]] {
                let r = try run([verb, "--report", rep.path, "--policy", pol.path] + strict)
                XCTAssertEqual(r.code, 2, "`\(verb) \(strict)` must refuse as the gate does: \(r.err)")
                let doc = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as! [String: Any]
                XCTAssertEqual(doc["refused"] as? Bool, true); XCTAssertEqual(doc["ok"] as? Bool, false)
            }
        }
        // a garbled `switches` is corrupt input, never read as "none"
        j["switches"] = "CANDOR_A_OFF"
        let bad = d.appendingPathComponent("b.Swift.json"); try JSONSerialization.data(withJSONObject: j).write(to: bad)
        XCTAssertEqual(try run(["gate", "--report", bad.path, "--policy", pol.path]).code, 2)
    }

    /// §3.4 (d): a chained report carrying `switches` — the advisory once per package, the verdict key, the exit untouched.
    func testChainedReportCarryingSwitchesGetsTheAdvisoryAndTheExitIsUntouched() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let dep = d.appendingPathComponent("dep/Sources/RatesDep"), app = d.appendingPathComponent("app/Sources/App")
        try FileManager.default.createDirectory(at: dep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"RatesDep\", targets: [.target(name: \"RatesDep\")])\n"
            .write(to: d.appendingPathComponent("dep/Package.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\npublic func hit() { let t = URLSession.shared.dataTask(with: \"http://rates.internal:7070/x\") { _, _, _ in }; t.resume() }\n"
            .write(to: dep.appendingPathComponent("Rates.swift"), atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n"
            .write(to: d.appendingPathComponent("app/Package.swift"), atomically: true, encoding: .utf8)
        try "import RatesDep\npublic func go() { hit() }\n".write(to: app.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        let pol = d.appendingPathComponent("pol"); try "deny Net go\n".write(to: pol, atomically: true, encoding: .utf8)
        let dr = try run([d.appendingPathComponent("dep").path, "--out", d.appendingPathComponent("dep-r").path])
        XCTAssertEqual(dr.code, 0, dr.err)
        let plainDir = d.appendingPathComponent("plain"), injDir = d.appendingPathComponent("inj")
        for x in [plainDir, injDir] { try FileManager.default.createDirectory(at: x, withIntermediateDirectories: true) }
        let src = d.appendingPathComponent("dep-r.RatesDep.Swift.json")
        try FileManager.default.copyItem(at: src, to: plainDir.appendingPathComponent("rates.json"))
        var j = try report(src); j["switches"] = [Self.sw]
        try JSONSerialization.data(withJSONObject: j).write(to: injDir.appendingPathComponent("rates.json"))
        func chain(_ dir: URL, _ tag: String) throws -> (r: (out: String, err: String, code: Int32), g: [String: Any]) {
            let gj = d.appendingPathComponent("\(tag).gate.json")
            let r = try run([d.appendingPathComponent("app").path, "--out", d.appendingPathComponent("\(tag)-r").path,
                             "--policy", pol.path, "--gate-json", gj.path], env: ["CANDOR_DEPS": dir.appendingPathComponent("rates.json").path])
            return (r, try report(gj))
        }
        let p = try chain(plainDir, "p"), i = try chain(injDir, "i")
        XCTAssertEqual(p.r.code, 1, "the join is live: the plain chain fires. \(p.r.err)")
        XCTAssertEqual(i.r.code, p.r.code, "the exit is untouched")
        XCTAssertNil(p.g["switchedDependencies"])
        let sd = try XCTUnwrap(i.g["switchedDependencies"] as? [[String: Any]])
        XCTAssertEqual(sd.count, 1); XCTAssertEqual(sd[0]["package"] as? String, "RatesDep"); XCTAssertEqual(sd[0]["switches"] as? [String], [Self.sw])
        var rest = i.g; rest["switchedDependencies"] = nil
        XCTAssertEqual(NSDictionary(dictionary: rest), NSDictionary(dictionary: p.g), "the rest of the verdict is equal")
        XCTAssertEqual(i.r.err.components(separatedBy: Self.sw).count - 1, 1, "the advisory names the switch ONCE: \(i.r.err)")
        XCTAssertFalse(p.r.err.contains(Self.sw))
    }

    /// In-process: the record is made by the READ, only when the value selects the non-default branch.
    func testEnvRecordsOnlyWhatIsSetAndConsulted() {
        Env.resetConsultedSwitches()
        XCTAssertFalse(Env.on("CANDOR_UNIT_TEST_SURELY_UNSET"))
        _ = Env.read("PATH", isSet: { _ in false })     // read, but the value selects the default branch
        XCTAssertEqual(Env.consultedSwitches(), [])
        _ = Env.read("PATH", isSet: { _ in true })
        XCTAssertEqual(Env.consultedSwitches(), ["PATH"], "calibration: the recorder CAN record")
        _ = Env.trace("HOME"); _ = Env.operatorValue("HOME")
        XCTAssertEqual(Env.consultedSwitches(), ["PATH"], "trace and operator reads are never recorded")
        Env.resetConsultedSwitches()
    }
}
