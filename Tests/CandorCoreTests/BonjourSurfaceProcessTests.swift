import XCTest
import Foundation

/// SOUNDNESS R385, THE NET HALF — IN-TREE AT LAST, AND THE REASON IT IS IN-TREE IS THE ROW.
///
/// The fix set `incompleteSurfaces` directly at the three sites that insert a bonjour `Net` effect,
/// because that effect is recorded on a path which reaches NONE of the nine `recordSurfaces` call
/// sites — which is why four earlier attempts edited establishing PREDICATES, built clean, kept the
/// suite green, and changed nothing.
///
/// **THE SUITE IS PROVEN BLIND TO THIS BRANCH.** Those four inert attempts all passed 1133 tests, and
/// the fix commit itself changed no test file while claiming a fixture that was never added to the
/// tree — so the closure rested on a hand-run described in a commit message. A release panel caught
/// that. This file is the fixture the row was always owed: without it, a regression here is invisible
/// to everything except someone re-running a shell command from memory.
final class BonjourSurfaceProcessTests: XCTestCase {
    private func scan(_ src: String, name: String, policy: String? = nil)
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

    /// A browse has no destination a host surface can express, so the surface is INCOMPLETE and a
    /// benign sibling literal must not certify it. Measured before the fix: `hosts:['api.stripe.com']
    /// incomplete:NONE` and `allow Net api.stripe.com` exit 0.
    func testABonjourBrowseMarksItsNetSurfaceIncomplete() throws {
        let src = """
        import Foundation
        import Network
        func browse(_ callerType: String) {
            let url = URL(string: "https://api.stripe.com/v1/charges")!
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            let b = NWBrowser(for: .bonjour(type: callerType, domain: nil), using: .tcp)
            b.start(queue: .main)
        }
        """
        let r = try scan(src, name: "BonjourInc")
        let inc = (r.fns["browse"]?["incomplete"] as? [String]) ?? []
        XCTAssertTrue(inc.contains("Net"),
                      "R385: a bonjour browse has no expressible destination, so its Net surface is "
                      + "INCOMPLETE. Without this the sibling URLSession literal certifies it: \(r.out)")

        // CALIBRATION — the gate must be able to fail, or the next assertion proves nothing.
        XCTAssertEqual(try scan(src, name: "BonjourDeny", policy: "deny Net\n").code, 1)
        // THE BYPASS ITSELF.
        XCTAssertEqual(try scan(src, name: "BonjourAllow", policy: "allow Net api.stripe.com\n").code, 1,
                       "allow Net <the benign literal> must NOT certify a runtime-typed browse")
    }

    /// THE FABRICATION CONTROL, and it is half the row: a bonjour `type:` is a SERVICE TYPE, not a
    /// host. Capturing it would invent a destination — which is exactly how R381's first cut put
    /// "443" into `hosts`. Establishing-yes / capture-NO, ⟨0.29⟩'s bind/listen rule.
    func testALiteralBonjourTypeIsNeverCapturedAsAHost() throws {
        let r = try scan("""
        import Foundation
        import Network
        func literalBrowse() {
            let b = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
            b.start(queue: .main)
        }
        """, name: "BonjourLit")
        XCTAssertNil(r.fns["literalBrowse"]?["hosts"],
                     "a service type is not a host; capturing it fabricates a destination: \(r.out)")
        XCTAssertTrue(((r.fns["literalBrowse"]?["incomplete"] as? [String]) ?? []).contains("Net"),
                      "a literal service type still leaves the DESTINATION surface incomplete: \(r.out)")
    }

    /// R385's THIRD ROOT, and the one a release panel flagged as unmeasured: `NetService` is asserted
    /// `isOpaqueLocatorFree` in ClassifierTests, and `kappaMember` gives it `Net` for any non-pure
    /// verb — but it appears in NONE of the three patched sites, which test only `NWBrowser` and
    /// `NetServiceBrowser`. That is R348's shape (a predicate entry nothing reaches) inside the fix
    /// whose own commit message names R348 as the trap it avoided. This test settles it by measurement.
    func testNetServiceResolveMarksItsNetSurfaceIncomplete() throws {
        let src = """
        import Foundation
        func resolveIt(_ svc: NetService) {
            let url = URL(string: "https://api.stripe.com/v1/charges")!
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            svc.resolve(withTimeout: 5)
        }
        """
        let r = try scan(src, name: "NetSvcInc")
        XCTAssertTrue((((r.fns["resolveIt"]?["incomplete"] as? [String]) ?? []).contains("Net")),
                      "R385 third root: NetService.resolve reaches the network with no expressible "
                      + "destination, so a benign sibling literal must not certify it: \(r.out)")
        XCTAssertEqual(try scan(src, name: "NetSvcAllow", policy: "allow Net api.stripe.com\n").code, 1,
                       "allow Net <benign literal> must not certify NetService.resolve")
    }

    // MARK: - SOUNDNESS R392 / R391 — the two CTOR sites, and why nothing in this file could see them

    /// **SOUNDNESS R392 — THE FIXTURE A COMMENT CLAIMED AND THE TREE DID NOT HAVE.**
    ///
    /// `CallCollector.chargeModuleQualifiedSpelling`'s bonjour arm carried *"THIS SITE IS NOT REACHED BY
    /// THE MEASURED FIXTURES … so it carries its own fixture rather than being left as an untested
    /// guess"*. It did not. MEASURED at HEAD by the guard-deletion test (brief attack C): deleting that
    /// site's `incompleteSurfaces.insert("Net")` left **1229 tests, 0 failures** — and deleting the BARE
    /// ctor site's copy did too. Only the MEMBER site's copy was protected, by the two tests above.
    ///
    /// **WHY EVERY EXISTING BONJOUR FIXTURE WAS BLIND TO BOTH, and it is brief attack A.2 exactly.**
    /// Every one of them constructs the browser AND calls a verb on it in the same function
    /// (`b.start(queue:)`, `svc.resolve(withTimeout:)`). The member site then inserts `Net` into
    /// `incompleteSurfaces` for that same function, so the ctor sites' inserts are MASKED — present or
    /// absent, the row reads identically. The discriminator is a function that constructs and RETURNS,
    /// with the verb called elsewhere, which is ordinary factory code.
    ///
    /// **AND THE SITE IS LIVE, not cosmetic.** With the module-qualified insert deleted, this exact
    /// fixture reported `hosts:["api.stripe.com"]` with `incomplete` ABSENT and
    /// `allow Net api.stripe.com` exited **0** over a Bonjour registration whose service name is
    /// caller-controlled — the benign sibling literal certifying the invisible one, i.e. the masking
    /// gate-evasion R385 exists to close, reopened through the one spelling nothing measured.
    func testR392TheModuleQualifiedBonjourCtorAloneMarksItsNetSurfaceIncomplete() throws {
        let src = """
        import Foundation
        import Network
        public func makeBrowser(_ t: String) -> NWBrowser {
            let url = URL(string: "https://api.stripe.com/v1/charges")!
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            return Network.NWBrowser(for: .bonjour(type: t, domain: nil), using: .tcp)
        }
        public func makeService(_ n: String) -> NetService {
            let url = URL(string: "https://api.stripe.com/v1/charges")!
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            return Foundation.NetService(domain: "local.", type: "_http._tcp", name: n, port: 80)
        }
        """
        let r = try scan(src, name: "BonjourModQualCtor")
        for fn in ["makeBrowser", "makeService"] {
            XCTAssertTrue(((r.fns[fn]?["incomplete"] as? [String]) ?? []).contains("Net"),
                          "R392: the MODULE-QUALIFIED bonjour ctor must mark its own Net surface "
                          + "incomplete — no verb is called here, so nothing else will: \(r.out)")
        }
        // CALIBRATION — the gate must be able to fail, or the assertion below proves nothing.
        XCTAssertEqual(try scan(src, name: "BonjourModQualDeny", policy: "deny Net\n").code, 1)
        // THE BYPASS. Measured at exit 0 with the site's insert deleted.
        XCTAssertEqual(try scan(src, name: "BonjourModQualAllow",
                                policy: "allow Net api.stripe.com\n").code, 1,
                       "allow Net <the benign sibling literal> must NOT certify a module-qualified "
                       + "Bonjour registration with a caller-supplied service name")
    }

    /// **R392'S SIBLING, AND THE BRIEF SAYS TO WRITE THE ONE YOU WERE NOT HANDED.** The row named the
    /// module-qualified site; the guard-deletion sweep found the BARE ctor site equally unprotected, for
    /// the identical reason. Measured with that site's insert deleted: `incomplete` absent and
    /// `allow Net api.stripe.com` exit **0** on this fixture.
    func testR392TheBareBonjourCtorAloneMarksItsNetSurfaceIncomplete() throws {
        let src = """
        import Foundation
        import Network
        public func makeBrowserBare(_ t: String) -> NWBrowser {
            let url = URL(string: "https://api.stripe.com/v1/charges")!
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            return NWBrowser(for: .bonjour(type: t, domain: nil), using: .tcp)
        }
        public func makeServiceBare(_ n: String) -> NetService {
            let url = URL(string: "https://api.stripe.com/v1/charges")!
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            return NetService(domain: "local.", type: "_http._tcp", name: n, port: 80)
        }
        """
        let r = try scan(src, name: "BonjourBareCtor")
        for fn in ["makeBrowserBare", "makeServiceBare"] {
            XCTAssertTrue(((r.fns[fn]?["incomplete"] as? [String]) ?? []).contains("Net"),
                          "R392 sibling: the BARE bonjour ctor must mark its own Net surface "
                          + "incomplete with no verb in the function: \(r.out)")
        }
        XCTAssertEqual(try scan(src, name: "BonjourBareCtorDeny", policy: "deny Net\n").code, 1)
        XCTAssertEqual(try scan(src, name: "BonjourBareCtorAllow",
                                policy: "allow Net api.stripe.com\n").code, 1,
                       "allow Net <the benign sibling literal> must NOT certify a bare Bonjour "
                       + "registration with a caller-supplied service name")
    }

    /// **SOUNDNESS R391 — THE THIRD ROOT, AS BEHAVIOUR RATHER THAN AS LIST MEMBERSHIP.**
    ///
    /// `NetServiceBrowser` is in every bonjour list in this engine and was, until this test, in no
    /// fixture that could fail if it left one: `ClassifierTests` asserts it is `isOpaqueLocatorFree`,
    /// which is a statement about a list. R391's whole complaint is that the tests pinned the LIST.
    ///
    /// With `isBonjourRoot` as the one authority the three charge sites now consult, removing a name
    /// from it removes the branch — so this test, and the two above, are what make the authority
    /// load-bearing. Calibrated by deleting `"NetService"` from `isBonjourRoot` and confirming this file
    /// goes red.
    func testR391TheThirdBonjourRootIsPinnedByBehaviour() throws {
        let src = """
        import Foundation
        public func makeBrowser(_ t: String) -> NetServiceBrowser {
            let url = URL(string: "https://api.stripe.com/v1/charges")!
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            return NetServiceBrowser()
        }
        public func searchIt(_ b: NetServiceBrowser, _ t: String) {
            let url = URL(string: "https://api.stripe.com/v1/charges")!
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
            b.searchForServices(ofType: t, inDomain: "local.")
        }
        """
        let r = try scan(src, name: "NetSvcBrowserRoot")
        for fn in ["makeBrowser", "searchIt"] {
            XCTAssertTrue(((r.fns[fn]?["incomplete"] as? [String]) ?? []).contains("Net"),
                          "R391: NetServiceBrowser browses the local network with no destination a host "
                          + "surface can express — \(fn) must read INCOMPLETE: \(r.out)")
            XCTAssertTrue(((r.fns[fn]?["inferred"] as? [String]) ?? []).contains("LocalNetwork"),
                          "R390: and it is mDNS by type: \(r.out)")
        }
        XCTAssertEqual(try scan(src, name: "NetSvcBrowserDeny", policy: "deny Net\n").code, 1)
        XCTAssertEqual(try scan(src, name: "NetSvcBrowserAllow",
                                policy: "allow Net api.stripe.com\n").code, 1,
                       "allow Net <the benign sibling literal> must not certify an mDNS browse")
    }

    /// **THE FABRICATION CONTROL FOR THE CTOR-ONLY SHAPE.** The tests above assert an INCOMPLETE
    /// surface; per this family's rule that killing a silence is where fabrication is introduced, the
    /// direction they do not intend needs its own control. An ordinary host-bearing `NWConnection`
    /// constructed and returned — the discriminator against `NWBrowser`, same framework, same ctor shape
    /// — must still publish its real host and must NOT read incomplete, or the rule above would withhold
    /// every destination this engine exists to publish.
    func testACtorOnlyHostBearingNetFormStillPublishesItsHost() throws {
        let r = try scan("""
        import Foundation
        import Network
        public func makeConn() -> NWConnection {
            return NWConnection(host: "api.stripe.com", port: 443, using: .tls)
        }
        """, name: "BonjourCtl")
        XCTAssertEqual(r.fns["makeConn"]?["hosts"] as? [String], ["api.stripe.com:443"],
                       "the control must keep publishing a REAL host: \(r.out)")
        XCTAssertFalse(((r.fns["makeConn"]?["incomplete"] as? [String]) ?? []).contains("Net"),
                       "a visible host is a COMPLETE surface: \(r.out)")
        XCTAssertFalse(((r.fns["makeConn"]?["inferred"] as? [String]) ?? []).contains("LocalNetwork"),
                       "ordinary networking is not mDNS: \(r.out)")
    }
}
