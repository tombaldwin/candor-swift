import XCTest
import Foundation

/// PROCESS-layer pins over the ⟨0.26⟩ HIERARCHY SIDECAR MANIFEST (SPEC §2.2).
///
/// The rung: the sidecar's KEY SET is its manifest. A type WITH a key was indexed and its array is the
/// complete list of supertypes this pass could see — `[]` is a real answer. A type with NO key was never
/// analysed, and no claim about it is available. Before the rung the two were spelled identically
/// (absent), so a consumer walking up a chain that ran off the indexed set read that absence as "no
/// supertypes" and answered a subtype question NO — a positive claim about a type it had never been told
/// about. Measured in candor-java and candor-ts as a reacher silently vanishing from a disclosure.
///
/// This engine is a PRODUCER only — it ships no `callers` verb — so what is pinned here is the emitted
/// KEY SET, which is the half a consumer's correctness rests on. The consumer half lives in candor-java
/// (`Query.subtypeOf`) and candor-ts (`query-core.subtypeOf`).
///
/// Two things the old emitter got wrong, both visible as MISSING KEYS:
///   1. it inverted `conformers`, so only a type that HAS a supertype got a key at all;
///   2. protocols are deliberately held out of `conformers` (a protocol name there pollutes the
///      concrete-dispatch CHA and its `impls.count == conf.count` guard), and their `protocol Sub: Sup`
///      edges live in a separate map the sidecar never read — so a `Impl: Mid`, `Mid: Base` chain
///      dead-ended at `Mid`, which had no key.
final class SidecarManifestProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: SidecarManifestProcessTests.self)
    }

    /// A package exercising every shape the key set has to distinguish: a two-level protocol chain, a
    /// concrete conformer, a type with no supertype at all, and a type whose supertype is NON-LOCAL.
    private func makeFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-sidecar-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        protocol Base { func op() }
        protocol Mid: Base {}
        struct Impl: Mid { func op() { _ = try? String(contentsOfFile: "/etc/hosts") } }
        struct Loner { func idle() {} }
        class Sub: NSObject { func go() {} }
        """.write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private func sidecar(at root: URL) throws -> [String: [String]] {
        let out = root.appendingPathComponent("r")
        let p = Process()
        p.executableURL = try binaryURL()
        p.arguments = [root.path, "--out", out.path]
        var env = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT"] {
            env.removeValue(forKey: k)
        }
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let exited = ProcessHarness.exitLatch(p)
        try p.run()
        _ = ProcessHarness.drain(outPipe)
        _ = ProcessHarness.drain(errPipe)
        exited.wait()
        XCTAssertEqual(p.terminationStatus, 0)
        let data = try Data(contentsOf: root.appendingPathComponent("r.App.Swift.hierarchy.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String]])
    }

    func testEveryIndexedTypeCarriesAKeyIncludingSupertypelessOnes() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try sidecar(at: root)

        // A SUPERTYPELESS type is INDEXED, and says so with an empty array. Pre-rung it was absent, which
        // is the same spelling as "never analysed" — this is the whole rung in one assertion.
        XCTAssertEqual(h["Loner"], [], "an indexed type with no supertype must key to [], not be absent")
        XCTAssertEqual(h["Base"], [], "a root PROTOCOL must key to [] — it is indexed like any other type")

        // The two-level chain walks END TO END. `Mid` is the link that used to be missing entirely, so
        // `Impl <: Base` was unanswerable for a relation this pass actually knows.
        XCTAssertEqual(h["Impl"], ["Mid"])
        XCTAssertEqual(h["Mid"], ["Base"], "super-protocol edges must reach the sidecar; they live in a "
                       + "map held out of `conformers` on purpose and were never read here")

        // THE NEGATIVE CONTROL, and the reason the key set is seeded from `declaredTypes` rather than
        // `localTypes`: a NON-LOCAL supertype stays ABSENT. This pass cannot see a platform type's own
        // supertypes, so `"NSObject": []` would be exactly the false purity-shaped claim the rung removes
        // — the chain beyond `NSObject` is genuinely unanswerable and must stay spelled that way.
        XCTAssertEqual(h["Sub"], ["NSObject"])
        XCTAssertNil(h["NSObject"], "a NON-LOCAL supertype was never indexed and must NOT be claimed as []")

        // And no phantoms: the key set is exactly the locally-declared types (protocols included).
        XCTAssertEqual(Set(h.keys), ["Base", "Mid", "Impl", "Loner", "Sub"])
    }
}
