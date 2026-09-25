import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R610 — **A BINDING LAUNDERS THE GUESS THAT R567(a) REFUSES.**
///
/// R567(a) made the §2 key site refuse a receiver whose chain walked through a member this engine could
/// not type, using `rootOf`'s `opaqueHop`. `vars` records a binder's NAME and its ANSWER and not the
/// fact that the answer was a convention — so
///
///     if let l = c.maybeLoop { l.spin() }      // `l` typed `Channel`, the OUTER base
///
/// resolves `l` straight out of `vars` with `opaqueHop` FALSE, the refusal is never asked, and the key
/// is the one R567(a) exists to stop. **Found while re-pricing ⟨0.40⟩**, in nio-ssl's
/// `NIOSSLHandler.swift:631`: `if let syncOptions = context.channel.syncOptions { syncOptions.getOption(…) }`
/// published `swift-nio#ChannelHandlerContext.getOption` and survived R567(a) untouched.
///
/// ONE VARIABLE between the rows: the SPELLING of the receiver — written out, or bound first.
/// Dependency source, consumer body, sink and binary are all held.
///
///     dep: Loop.spin -> Env,  Channel.spin -> Fs,  `Channel.maybeLoop: Loop?`
///       direct          `c.loop.spin()`                           Unknown (R567(a))
///       laundered       `if let l = c.maybeLoop { l.spin() }`      ['Fs']   <- the decoy
///       laundered       `guard let l = c.maybeLoop else {…}; l.spin()`  ['Fs']
///
/// §1b: every assertion FAILS under `CANDOR_R610_OFF=1`, which stops the flag travelling into `vars`.
/// The CONTROL (`l.spin()` on a `Loop`-typed parameter) passes in both.
final class LaunderedReceiverBindingProcessTests: XCTestCase {

    private static let dep = """
    import Foundation
    public final class Loop {
        public init() {}
        public func spin() { _ = ProcessInfo.processInfo.environment["Y"] }
    }
    public final class Channel {
        public let loop = Loop()
        public let maybeLoop: Loop? = nil
        public init() {}
        public func spin() { _ = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) }
    }
    """

    private func run(_ appSource: String)
        throws -> (rows: [String: (inferred: Set<String>, keys: Set<String>)], denyFs: Int32) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r610-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "RatesDep",
            products: [.library(name: "RatesCore", targets: ["RatesCore"])],
            targets: [.target(name: "RatesCore")])
        """)
        try write("dep/Sources/RatesCore/lib.swift", Self.dep)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [.product(name: "RatesCore", package: "dep")])])
        """)
        try write("app/Sources/App/app.swift", appSource)
        try write("fs.policy", "deny Fs\n")

        let depDir = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path,
                                              "--out", depDir.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        let report = depDir.appendingPathComponent("r.RatesDep.Swift.json")
        // §E3 — the DECOY must really be there, or every assertion below is about nothing.
        let depDoc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        var depFns: [String: [String]] = [:]
        for f in (depDoc?["functions"] as? [[String: Any]]) ?? [] {
            depFns[(f["fn"] as? String) ?? "?"] = ((f["inferred"] as? [String]) ?? []).sorted()
        }
        XCTAssertEqual(depFns["Channel.spin"], ["Fs"], "the decoy; dep: \(depFns)")
        XCTAssertEqual(depFns["Loop.spin"], ["Env"], "the truth; dep: \(depFns)")
        for extra in try FileManager.default.contentsOfDirectory(atPath: depDir.path)
        where extra != report.lastPathComponent {
            try FileManager.default.removeItem(at: depDir.appendingPathComponent(extra))
        }

        let out = root.appendingPathComponent("ch")
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", out.path],
                                       env: ["CANDOR_DEPS": depDir.path])
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: (inferred: Set<String>, keys: Set<String>)] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = (Set((f["inferred"] as? [String]) ?? []),
                                                 Set((f["dispatchesOn"] as? [String]) ?? []))
        }
        let g = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                             "--policy", root.appendingPathComponent("fs.policy").path,
                                             "--out", root.appendingPathComponent("g").path],
                                       env: ["CANDOR_DEPS": depDir.path])
        return (rows, g.code)
    }

    func testAnIfLetAndAGuardLetBindingDoNotLaunderTheOuterBaseGuess() throws {
        let r = try run("""
        import RatesCore
        public func launderedIfLet(_ c: Channel) { if let l = c.maybeLoop { l.spin() } }
        public func launderedGuard(_ c: Channel) { guard let l = c.maybeLoop else { return }; l.spin() }
        public func controlDirect(_ l: Loop) { l.spin() }
        """)

        for fn in ["launderedIfLet", "launderedGuard"] {
            let row = r.rows[fn]
            XCTAssertNotNil(row, "\(fn) must still have a row — see R567(a): dropping without disclosing "
                            + "is a ⟨0.21⟩ purity claim")
            XCTAssertFalse(row?.inferred.contains("Fs") ?? true,
                           "\(fn): `Channel.spin` is Fs and is NOT what `l.spin()` reaches. The binding "
                           + "carried the OUTER BASE's type out of `rootOf` and `vars` forgot it was a "
                           + "convention, so R567(a)'s refusal was never asked; got \(row?.inferred ?? [])")
            XCTAssertTrue(row?.keys.isEmpty ?? false,
                          "\(fn): obligation 1 must publish no key — `RatesDep#Channel.spin` names a "
                          + "member the receiver's real type does not have; got \(row?.keys ?? [])")
            XCTAssertEqual(row?.inferred, ["Unknown"],
                           "\(fn): and it must DISCLOSE, the same way the direct spelling does")
        }

        XCTAssertEqual(r.rows["controlDirect"]?.inferred, ["Env"],
                       "CONTROL: a `Loop`-typed parameter is a RESOLVED binding and must keep resolving. "
                       + "A fix that marked every `vars` entry opaque would red here and pass above")
        XCTAssertEqual(r.rows["controlDirect"]?.keys, ["RatesDep#Loop.spin"],
                       "…including its published key; got \(r.rows["controlDirect"]?.keys ?? [])")
        XCTAssertEqual(r.denyFs, 0,
                       "GATE LEVEL: `deny Fs` over a consumer that opens no file exited 1 before this "
                       + "fix — the decoy's effect reaching a policy through a binding")
    }
}
