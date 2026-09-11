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
}
