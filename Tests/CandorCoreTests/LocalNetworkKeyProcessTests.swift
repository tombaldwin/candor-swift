import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R390 — **THE FOUNDATION HALF OF BONJOUR CHARGED `Net` AND NEVER `LocalNetwork`, AND THE
/// CONSEQUENCE IS A FALSE ANSWER TO A COMPLIANCE QUESTION.**
///
/// The three sites that insert `LocalNetwork` all asked one question — *is a `.bonjour(…)` descriptor
/// among these arguments* — and `NetService`/`NetServiceBrowser` never carry one: their service type is
/// a plain `String` parameter. So `NetServiceBrowser().searchForServices(ofType:inDomain:)` charged
/// `Net` alone, and `privacy-manifest` answered a Bonjour app **"no privacy-sensor reach found; no
/// usage-description keys required."** Measured at 0.38.2 before the fix, with the `NWBrowser` spelling
/// of the SAME browse as the held-constant arm, which reported the key.
///
/// **THIS FILE IS THE VERDICT FIXTURE, NOT THE EFFECT FIXTURE, and that is deliberate.** R390's cost is
/// not a missing row in `functions[]`; it is `privacy-manifest --verify` certifying an `Info.plist` that
/// omits `NSLocalNetworkUsageDescription`. A test that asserted only the effect would pass over a
/// regression in the manifest table or the verify path, and the effect row is what the engine's own
/// summary line prints — so it is the half a reader is most likely to check by eye and the half that
/// proves least. Both halves are asserted here, at the verb.
///
/// The OVER-CHARGE CONTROL is the other half of the row: the declared exclusion for this key
/// (`MANIFEST_EXCLUSIONS`) withheld it precisely because charging every networking app would be a
/// fabrication, so a fix that widens the positive channel must show ordinary networking gaining nothing.
final class LocalNetworkKeyProcessTests: XCTestCase {

    private func scanToReport(_ src: String, name: String) throws -> (binary: URL, prefix: String, cleanup: () -> Void) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-ln-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let prefix = outDir.appendingPathComponent("report").path
        let r = try ProcessHarness.run(bin, [root.path, "--out", prefix])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return (bin, prefix, {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outDir)
        })
    }

    private func scanJSON(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--json"]
        if let policy {
            let p = root.appendingPathComponent("p.pol")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        return (try ProcessHarness.fns(ofJson: r.out), r.code, r.out + r.err)
    }

    private func writePlist(_ keys: [String], _ dir: URL) throws -> String {
        var body = ""
        for k in keys { body += "\t<key>\(k)</key>\n\t<string>because</string>\n" }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)</dict>
        </plist>
        """
        let url = dir.appendingPathComponent("Info-\(UUID().uuidString).plist")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// The legacy Foundation browse, ALONE in its package — no `NWBrowser` anywhere to supply the key.
    private let legacyBrowse = """
    import Foundation
    public func browse(_ t: String) {
        let b = NetServiceBrowser()
        b.searchForServices(ofType: t, inDomain: "local.")
    }
    """

    /// THE ROW'S OWN REPRO, AS A VERDICT. `privacy-manifest --verify` against an `Info.plist` with no
    /// local-network key must report it UNDER-DECLARED and exit non-zero. Before the fix this exited 0
    /// with `ok:true` — the tool affirmatively telling a Bonjour app its manifest was complete.
    func testR390VerifyRefusesAPlistMissingTheLocalNetworkKey() throws {
        let (bin, prefix, cleanup) = try scanToReport(legacyBrowse, name: "R390Verify")
        defer { cleanup() }
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()

        // GENERATE — the key is required at all.
        let g = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--json"])
        XCTAssertEqual(g.code, 0, g.err)
        let gd = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(g.out.utf8)) as? [String: Any])
        XCTAssertTrue((gd["reached"] as? [String])?.contains("LocalNetwork") == true,
                      "R390: a NetServiceBrowser search IS local-network reach: \(g.out)")
        XCTAssertEqual((gd["required"] as? [String: [String]])?["LocalNetwork"],
                       ["NSLocalNetworkUsageDescription"], g.out)

        // VERIFY against a plist that declares nothing — the false verdict this row is about.
        let empty = try writePlist([], dir)
        let v = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", empty, "--json"])
        let vd = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(v.out.utf8)) as? [String: Any])
        XCTAssertEqual(vd["ok"] as? Bool, false,
                       "R390: verify must NOT certify an Info.plist with no NSLocalNetworkUsageDescription "
                       + "over a Bonjour browse: \(v.out)")

        // CALIBRATION — the verify is able to answer ok:true, so the assertion above is not vacuous.
        let full = try writePlist(["NSLocalNetworkUsageDescription"], dir)
        let ok = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", full, "--json"])
        XCTAssertEqual(ok.code, 0, ok.err)
        XCTAssertEqual(
            (try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ok.out.utf8)) as? [String: Any]))["ok"] as? Bool,
            true, "the declared plist must verify clean, or the refusal above proves nothing: \(ok.out)")
    }

    /// TWO SPELLINGS OF ONE BROWSE MUST ANSWER THE SAME. This is the row's comparison with its one
    /// variable — the API spelling — held explicit in the test rather than in a commit message.
    /// `deny LocalNetwork` is the calibrated gate: before the fix it exited 1 on the `NWBrowser` arm
    /// and 0 on the `NetServiceBrowser` arm.
    func testR390BothSpellingsOfOneBrowseAnswerIdentically() throws {
        let modern = """
        import Foundation
        import Network
        public func browse(_ t: String) {
            let b = NWBrowser(for: .bonjour(type: t, domain: nil), using: .tcp)
            b.start(queue: .main)
        }
        """
        for (label, src) in [("legacy", legacyBrowse), ("modern", modern)] {
            let r = try scanJSON(src, name: "R390Eff\(label)")
            XCTAssertTrue((ProcessHarness.inferred(r.fns, "browse") ?? []).contains("LocalNetwork"),
                          "R390 [\(label)]: an mDNS browse is local-network reach: \(r.out)")
            XCTAssertEqual(try scanJSON(src, name: "R390Deny\(label)", policy: "deny LocalNetwork\n").code, 1,
                           "R390 [\(label)]: `deny LocalNetwork` must fire on a Bonjour browse: \(r.out)")
        }
    }

    /// THE WHOLE FOUNDATION SURFACE, NOT THE ONE VERB THE ROW MEASURED — R346's rule, which this
    /// engine has paid for repeatedly: a fix written from the spelling in hand leaves the siblings.
    /// `publish()`, `resolve(withTimeout:)`, the domain searches and the bare constructors are all
    /// mDNS, and all of them were silent on the key.
    func testR390EveryFoundationBonjourSpellingCharges() throws {
        let src = """
        import Foundation
        public func a1(_ t: String) { let b = NetServiceBrowser(); b.searchForServices(ofType: t, inDomain: "local.") }
        public func a2() { let b = NetServiceBrowser(); b.searchForBrowsableDomains() }
        public func a3(_ t: String) { let s = NetService(domain: "local.", type: t, name: "n", port: 8080); s.publish() }
        public func a4(_ s: NetService) { s.resolve(withTimeout: 5) }
        public func a5(_ t: String) { _ = NetService(domain: "local.", type: t, name: "n", port: 1) }
        public func a6() { _ = NetServiceBrowser() }
        """
        let r = try scanJSON(src, name: "R390Family")
        for fn in ["a1", "a2", "a3", "a4", "a5", "a6"] {
            XCTAssertTrue((ProcessHarness.inferred(r.fns, fn) ?? []).contains("LocalNetwork"),
                          "R390: \(fn) is mDNS by the TYPE it uses: \(r.out)")
        }
    }

    /// THE NETWORK-FRAMEWORK TAIL. `NWConnection(to: .service(name:type:domain:interface:))` and
    /// `NWListener(service: .init(name:type:))` are the same mDNS registration spelled on the types
    /// that ALSO serve ordinary networking, so the type rule cannot reach them and the `.bonjour`
    /// descriptor match did not either — neither spelling contains the token. The discriminator is the
    /// signature: a nested constructor carrying BOTH `name:` and `type:` IS the Bonjour service
    /// descriptor, whichever of `service` / `Service` / `init` it is spelled with.
    func testR390NetworkFrameworkServiceDescriptorsCharge() throws {
        let src = """
        import Foundation
        import Network
        public func b1(_ n: String) {
            let c = NWConnection(to: .service(name: n, type: "_http._tcp", domain: "local.", interface: nil), using: .tcp)
            c.start(queue: .main)
        }
        public func b2() {
            let l = try? NWListener(service: .init(name: "n", type: "_http._tcp"), using: .tcp)
            l?.start(queue: .main)
        }
        public func b3() {
            let l = try? NWListener(service: NWListener.Service(name: "n", type: "_http._tcp"), using: .tcp)
            l?.start(queue: .main)
        }
        """
        let r = try scanJSON(src, name: "R390NWService")
        for fn in ["b1", "b2", "b3"] {
            XCTAssertTrue((ProcessHarness.inferred(r.fns, fn) ?? []).contains("LocalNetwork"),
                          "R390 tail: \(fn) registers/resolves a Bonjour service: \(r.out)")
        }
    }

    /// THE MODULE-QUALIFIED SPELLING MUST ANSWER IDENTICALLY. `CallCollector`'s own doc states the rule
    /// (a qualified ctor and a bare one are one program), and the bonjour charge sites are duplicated
    /// across the qualified and bare paths precisely so the two cannot drift — R429's signature is two
    /// spellings of one program disagreeing. The control is the qualified ctor with a REAL host, which
    /// must still gain nothing.
    func testR390TheModuleQualifiedSpellingAnswersIdentically() throws {
        let src = """
        import Foundation
        import Network
        public func bare(_ n: String) {
            let c = NWConnection(to: .service(name: n, type: "_http._tcp", domain: "local.", interface: nil), using: .tcp)
            c.start(queue: .main)
        }
        public func qualified(_ n: String) {
            let c = Network.NWConnection(to: .service(name: n, type: "_http._tcp", domain: "local.", interface: nil), using: .tcp)
            c.start(queue: .main)
        }
        public func qualBrowser(_ t: String) {
            let b = Foundation.NetServiceBrowser()
            b.searchForServices(ofType: t, inDomain: "local.")
        }
        public func qualCtlHost() {
            let c = Network.NWConnection(host: "api.stripe.com", port: 443, using: .tls)
            c.start(queue: .main)
        }
        """
        let r = try scanJSON(src, name: "R390Qual")
        for fn in ["bare", "qualified", "qualBrowser"] {
            XCTAssertTrue((ProcessHarness.inferred(r.fns, fn) ?? []).contains("LocalNetwork"),
                          "R390: \(fn) — a module qualifier does not change what the program does: \(r.out)")
        }
        XCTAssertFalse((ProcessHarness.inferred(r.fns, "qualCtlHost") ?? []).contains("LocalNetwork"),
                       "the qualified control must gain nothing either: \(r.out)")
    }

    /// **THE OVER-CHARGE CONTROL, AND IT IS HALF THE ROW.** `NSLocalNetworkUsageDescription` was
    /// withheld from this engine's manifest table for a stated reason — *"not separable by type
    /// (NWBrowser/NWConnection also serve ordinary networking)"* — so a fix that widens the positive
    /// channel is only sound if ordinary networking still gains nothing. Every arm here reaches `Net`
    /// through a form the fix touches (the same κ ctor arm, the same descriptor scan, the same roots)
    /// and none of them is local-network.
    ///
    /// `k6` is the one that would bite a real project rather than a fixture: a project's OWN type
    /// spelled `Widget(name:type:)` matches the `name:`+`type:` signature exactly. It gains nothing
    /// because the descriptor question is asked only where κ has ALREADY answered `Net`, and a locally
    /// declared type shadows the platform table before that — the shadow discipline this file relies on
    /// and therefore asserts.
    func testR390NonBonjourNetFormsGainNoLocalNetworkKey() throws {
        let src = """
        import Foundation
        import Network
        public func k1() { let c = NWConnection(host: "api.stripe.com", port: 443, using: .tls); c.start(queue: .main) }
        public func k2() { let u = URL(string: "https://api.stripe.com/v1")!; URLSession.shared.dataTask(with: u) { _,_,_ in }.resume() }
        public func k3() { let l = try? NWListener(using: .tcp, on: 8080); l?.start(queue: .main) }
        public func k4(_ h: String) { var r: UnsafeMutablePointer<addrinfo>?; _ = getaddrinfo(h, "443", nil, &r) }
        public func k5() { let b = NWBrowser(for: .applicationService(name: "svc"), using: .tcp); b.start(queue: .main) }
        public func k6() { _ = Widget(name: "w", type: "gadget") }
        struct Widget { let name: String; let type: String }
        """
        let r = try scanJSON(src, name: "R390Ctl")
        for fn in ["k1", "k2", "k3", "k4", "k5", "k6"] {
            XCTAssertFalse((ProcessHarness.inferred(r.fns, fn) ?? []).contains("LocalNetwork"),
                           "R390 over-charge: \(fn) is ordinary networking — charging the local-network "
                           + "key here is the fabrication the manifest exclusion was written about: \(r.out)")
        }
        // NON-VACUOUSNESS: these arms DO reach the network, so the assertions above are about the
        // REFINEMENT and not about a scan that saw nothing. (`k6` is pure and absent by design.)
        for fn in ["k1", "k2", "k3", "k4", "k5"] {
            XCTAssertTrue((ProcessHarness.inferred(r.fns, fn) ?? []).contains("Net"),
                          "\(fn) must still be Net, or the LocalNetwork control proves nothing: \(r.out)")
        }
        XCTAssertNil(r.fns["k6"], "a project's own Widget(name:type:) is pure: \(r.out)")
    }

    /// The type authority itself, and its boundary. `NWBrowser`/`NWConnection`/`NWListener` must NOT be
    /// mDNS-only — the manifest exclusion's stated reason is true of them, and making the type the
    /// evidence there is precisely the fabrication it forbids.
    func testR390MdnsOnlyRootBoundary() {
        XCTAssertTrue(isMdnsOnlyRoot("NetService"))
        XCTAssertTrue(isMdnsOnlyRoot("NetServiceBrowser"))
        for n in ["NWBrowser", "NWConnection", "NWListener", "URLSession", "getaddrinfo"] {
            XCTAssertFalse(isMdnsOnlyRoot(n),
                           "\(n) also serves ordinary networking — the DESCRIPTOR decides it, not the type")
        }
    }
}
