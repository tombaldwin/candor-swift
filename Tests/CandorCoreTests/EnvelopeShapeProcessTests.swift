import XCTest
import Foundation

/// THE ENVELOPE'S TOP-LEVEL KEY SET, PINNED.
///
/// candor-java has `reportEnvelopeIsExactlyTheContractFieldSet`, candor-ts asserts the same key list, and
/// candor-rust holds its two writers byte-equal. All three REFUSED the ⟨0.27⟩ `resolves` field until it was
/// declared in each of them.
///
/// **candor-swift needed no test change at all** — which is not a sign it was fine, it is a sign nothing was
/// watching. A top-level envelope field could appear or vanish here silently, in the engine whose report a
/// consumer reads exactly like the other three. Found by asking, after the rung had landed, which engines
/// had actually caught it; three had, and the fourth was this one.
///
/// The same asymmetry runs the other way — `NameKeyedStateTests` is candor-swift's own guard and candor-ts
/// has no equivalent, which is why the same class of mistake surfaced there as a crash instead of an
/// assertion. Each engine has guards the others lack, and porting them is cheaper than rediscovering why.
final class EnvelopeShapeProcessTests: XCTestCase {

    func testEnvelopeTopLevelKeySetIsExactlyTheContract() throws {
        let bin = try ProcessHarness.binaryURL(for: EnvelopeShapeProcessTests.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func f() { _ = FileManager.default.contents(atPath: "/tmp/a") }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")

        let env = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
            "report must parse as a JSON object")

        // A new key here is a WIRE CHANGE. Updating this pin is the moment to also update SPEC §2 — the
        // point of an exact set is that the two move together rather than a field arriving in a diff
        // nobody reads.
        // ⟨0.29⟩ `excluded` joined the set, and it belongs with the ALWAYS-emitted keys rather than the
        // optional ones: `[]` is the positive statement "I looked and excluded nothing", and an absent key
        // would mean "this producer cannot answer" (⟨0.26⟩). This pin firing on the rung's first build is
        // the row doing its job. `outOfScope` is NOT here — this scan configures no policy, so nothing was
        // asked and the key is correctly absent.
        XCTAssertEqual(Set(env.keys), ["candor", "package", "functions", "analyzed", "resolves", "excluded"],
                       "envelope top level drifted — update SPEC §2 and this pin TOGETHER, never silently")

        let hdr = try XCTUnwrap(env["candor"] as? [String: Any], "the provenance header must be an object")
        XCTAssertEqual(Set(hdr.keys), ["version", "toolchain", "spec"],
                       "provenance header is exactly version/toolchain/spec (SPEC §2.1)")

        // ⟨0.27⟩ the declaration must be PRESENT and must name what this engine actually computes. Listing
        // a surface it does not compute would turn "unimplemented" into a false "undetermined", which is
        // the inversion the field exists to prevent.
        XCTAssertEqual(env["resolves"] as? [String], ["fs"],
                       "the engine resolves `fs` kinds and must say so (SPEC §2.1)")
    }
}
