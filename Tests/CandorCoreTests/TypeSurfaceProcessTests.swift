import XCTest
import Foundation

/// ⟨0.23⟩ `typeSurface.returns` — the factory-bound receiver's DETERMINATION half
/// (SPEC §2, `candor-spec/DEP-RECEIVER-TYPING-DESIGN.md`, candor-rust `a1e53e7`).
///
/// `let c = build(); c.fetch()` types `c` from `build`'s RETURN type, and a PURE `build` is ABSENT from
/// the dependency's report entirely (§2 rule 3) — so no consumer can recover it from the entries. Half 1
/// (`47bb69a`) stopped that reading silent-pure by disclosing `Unknown`; this recovers the effect.
///
/// The fixture is deliberately MODULAR rather than flat, because a flat one is structurally incapable of
/// showing the defect that made rust revert its first attempt: with a leaf-keyed surface, `Conn` and
/// `Mock.Conn` are ONE string, and the PURE `openMock()` charges the real client's `Fs` to a caller that
/// cannot reach it. Swift's namespace has the same door — a type nested in an `enum` — and this fixture
/// walks through it.
final class TypeSurfaceProcessTests: XCTestCase {

    private static let depSource = """
    import Foundation

    // The real client and its PURE factory. A pure fn is ABSENT from the report (§2 rule 3), so its
    // return type can never be recovered from the entries — the whole reason the rung exists.
    public struct Conn {
        public init() {}
        public func send() { _ = FileManager.default.contents(atPath: "/dep-send") }
        // A method whose NAME collides with what EVERY wrapper offers. If a wrapper return published
        // its PAYLOAD, `c.map { … }` on an Optional/Result/Array would key THIS body — which nobody
        // runs. That is what makes the wrapper refusal testable rather than asserted.
        public func map(_ transform: (Int) -> Int) { _ = FileManager.default.contents(atPath: "/dep-map") }
    }
    public func openConn() -> Conn { return Conn() }

    // THE SAME-LEAF SIBLING, nested so both `Conn`s coexist in ONE module. Its members are PURE, so a
    // correct surface resolves to nothing here; a LEAF-keyed one forms the real `Conn`'s keys.
    public enum Mock {
        public struct Conn {
            public init() {}
            public func send() { }
        }
        // …and the BARE spelling, which is what makes the DECLARING-SCOPE resolution testable: written
        // `Conn` here means `Mock.Conn`, and resolving it outward-only yields the real client's type.
        public static func open() -> Conn { return Conn() }
    }
    public func openMock() -> Mock.Conn { return Mock.Conn() }

    // WRAPPER RETURNS. The binding holds the Optional/Result/Array, not a `Conn`.
    public func openOptional() -> Conn? { return Conn() }
    public func openResult() -> Result<Conn, Never> { return .success(Conn()) }
    public func openMany() -> [Conn] { return [Conn()] }
    // A LOCAL GENERIC head. `Box` IS a declared type here, so this is the row that tells "plain
    // nominal" from "any name we can resolve": the spec says publish a plain nominal return only.
    public struct Box<T> {
        public init() {}
        public func map(_ transform: (Int) -> Int) { }
    }
    public func openBoxed() -> Box<Conn> { return Box<Conn>() }

    // THE MOST IDIOMATIC SWIFT FACTORY: it returns a PROTOCOL. The key that names — `DepLib#Sink.save`
    // — is a REQUIREMENT with no body, answerable only by an `interfaceUnion` entry the producer emits
    // under CANDOR_WORKSPACE_CHAIN. The two mechanisms are LAYERED: without the union the lookup misses
    // and falls to half 1's disclosure; with it, the receiver resolves.
    public protocol Sink { func save() }
    public final class FileSink: Sink {
        public init() {}
        public func save() { _ = FileManager.default.contents(atPath: "/dep-sink") }
    }
    public func openSink() -> Sink { return FileSink() }
    """

    private static let appSource = """
    IMPORT
    // THE ROW: a receiver bound from a dependency's PURE factory.
    public func viaFactory() { let c = openConn(); c.send() }
    // THE QUALIFICATION CONTROL: `openMock` returns `Mock.Conn`, whose `send` is pure.
    public func viaMockFactory() { let c = openMock(); c.send() }
    // THE WRAPPER CONTROLS.
    // Each holds a WRAPPER, and each calls the wrapper's OWN `map` — never `Conn.map`.
    public func viaOptionalFactory() { let c = openOptional(); _ = c.map { $0 } }
    public func viaResultFactory() { let c = openResult(); _ = c.map { $0 } }
    public func viaManyFactory() { let c = openMany(); _ = c.map { $0 } }
    public func viaBoxedFactory() { let c = openBoxed(); _ = c.map { $0 } }
    // The protocol-returning factory — see `Sink`.
    public func viaProtocolFactory() { let s = openSink(); s.save() }
    """

    /// (root, dep, app, ctl) — the split pair plus the ONE-PACKAGE control that proves this is a
    /// boundary defect and not a general limitation of the engine.
    private func makeFixture() throws -> (root: URL, dep: URL, app: URL, ctl: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-typesurface-\(UUID().uuidString)")
        let dep = root.appendingPathComponent("deplib")
        let app = root.appendingPathComponent("app")
        let ctl = root.appendingPathComponent("ctl")
        let fm = FileManager.default
        for (d, t) in [(dep, "DepLib"), (app, "App"), (ctl, "Ctl")] {
            try fm.createDirectory(at: d.appendingPathComponent("Sources/\(t)"), withIntermediateDirectories: true)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "DepLib", targets: [.target(name: "DepLib")])
        """.write(to: dep.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.write(to: dep.appendingPathComponent("Sources/DepLib/Lib.swift"),
                                 atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [.package(path: "../deplib")],
            targets: [.target(name: "App", dependencies: [.product(name: "DepLib", package: "deplib")])]
        )
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "import DepLib")
            .write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Ctl", targets: [.target(name: "Ctl")])
        """.write(to: ctl.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.write(to: ctl.appendingPathComponent("Sources/Ctl/Lib.swift"),
                                 atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "")
            .write(to: ctl.appendingPathComponent("Sources/Ctl/App.swift"), atomically: true, encoding: .utf8)
        return (root, dep, app, ctl)
    }

    private func binaryURL() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    private func report(_ url: URL) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
    }
    private func fns(_ url: URL) throws -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (try report(url)["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { out[n] = f }
        }
        return out
    }
    private func surface(_ url: URL) throws -> [String: String] {
        ((try report(url)["typeSurface"] as? [String: Any])?["returns"] as? [String: String]) ?? [:]
    }
    /// Scan the dep, returning its report path. Deletes the output first — a crashed or stale run
    /// otherwise leaves the previous arm's report to be read back (standing bar item 7).
    private func scanDep(_ bin: URL, _ dep: URL, root: URL) throws -> URL {
        let out = root.appendingPathComponent("dep-r.DepLib.Swift.json")
        try? FileManager.default.removeItem(at: out)
        let r = try ProcessHarness.run(bin, [dep.path, "--out", root.appendingPathComponent("dep-r").path])
        XCTAssertEqual(r.code, 0, "dep scan must succeed; stderr: \(r.err)")
        return out
    }

    // ── THE PRODUCER ────────────────────────────────────────────────────────────────────────────

    /// FULLY QUALIFIED ON BOTH ENDS, and no wrapper publishes its payload.
    ///
    /// The qualification is not a naming nicety: it is the soundness defect that caused rust's revert.
    /// `Conn` and `Mock.Conn` are two types in ONE module, and a surface that published the leaf would
    /// make them one string — after which the PURE `openMock()` charges the real client's `Fs`.
    ///
    /// The wrapper rows are the second reverted defect: `plainNominalTypeName` refuses them, where
    /// `typeName` (correctly, for its own job) would peel `Conn?` to `Conn`.
    func testProducerPublishesFullyQualifiedPlainNominalReturns() throws {
        let bin = try binaryURL()
        let (root, dep, _, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ts = try surface(try scanDep(bin, dep, root: root))

        XCTAssertEqual(ts["DepLib#openConn"], "DepLib#Conn",
                       "the plain nominal return must publish, keyed and valued in the producing "
                       + "package's own namespace; got \(ts)")
        XCTAssertEqual(ts["DepLib#openMock"], "DepLib#Mock.Conn",
                       "the NESTED type must publish its FULL path — the leaf `DepLib#Conn` is the "
                       + "reverted defect, and it is the real client's key; got \(ts)")
        XCTAssertEqual(ts["DepLib#openSink"], "DepLib#Sink",
                       "a PROTOCOL return publishes its name: `func make() -> SomeProtocol` is the "
                       + "commonest Swift factory, and the key it forms is answerable by the producer's "
                       + "`interfaceUnion` entry; got \(ts["DepLib#openSink"] ?? "nil")")
        XCTAssertEqual(ts["DepLib#Mock.open"], "DepLib#Mock.Conn",
                       "a BARE `-> Conn` written INSIDE `enum Mock` means `Mock.Conn`. Resolving it "
                       + "outward-only finds the top-level `Conn` — the real client — which is rust's "
                       + "defect 1 reached through swift's door; got \(ts["DepLib#Mock.open"] ?? "nil")")
        for wrapper in ["DepLib#openOptional", "DepLib#openResult", "DepLib#openMany", "DepLib#openBoxed"] {
            XCTAssertNil(ts[wrapper],
                         "\(wrapper) returns a WRAPPER — the binding holds the Optional/Result/Array/Box, "
                         + "so publishing the payload keys `map` against a type nobody holds. "
                         + "`openBoxed` is the sharp one: `Box` IS a declared local type, so it is only "
                         + "refused because the spec says PLAIN NOMINAL, not because the name fails to "
                         + "resolve; got \(ts[wrapper] ?? "nil")")
        }
    }

    /// An empty surface OMITS the field, so a report with nothing to say is byte-identical to a
    /// pre-rung one and a ⟨0.22⟩ consumer is unaffected.
    func testEmptySurfaceOmitsTheField() throws {
        let bin = try binaryURL()
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func go() { _ = FileManager.default.contents(atPath: "/x") }
        go()
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        let r = try ProcessHarness.run(bin, [root.path, "--out", out.path])
        XCTAssertEqual(r.code, 0, r.err)
        let env = try report(root.appendingPathComponent("r.App.Swift.json"))
        XCTAssertNil(env["typeSurface"],
                     "a package with no publishable return must not emit the key at all — an empty "
                     + "object is a wire change for a report with nothing to say")
    }

    // ── THE CONSUMER ────────────────────────────────────────────────────────────────────────────

    /// THE ROW, and its ONE-PACKAGE CONTROL. `viaFactory` reads `['Fs']` in a single package; split and
    /// chained it read silent-pure (before half 1) then `Unknown` (after half 1); with the surface it
    /// matches its control exactly. The control is what makes this a BOUNDARY defect rather than a
    /// limit of the engine.
    ///
    /// `viaMockFactory` is the qualification control ON THE CONSUMER SIDE: it must NOT acquire `Fs`.
    /// Relax the producer's exact type-path match to a leaf and this row is the one that fails.
    func testFactoryBoundReceiverResolvesThroughTheSurface() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        let appOut = root.appendingPathComponent("app-r")
        try? FileManager.default.removeItem(at: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertEqual(try ProcessHarness.run(bin, [app.path, "--out", appOut.path],
                                              env: ["CANDOR_DEPS": depReport.path]).code, 0)
        let chained = try fns(root.appendingPathComponent("app-r.App.Swift.json"))

        let ctlOut = root.appendingPathComponent("ctl-r")
        try? FileManager.default.removeItem(at: root.appendingPathComponent("ctl-r.Ctl.Swift.json"))
        XCTAssertEqual(try ProcessHarness.run(bin, [ctl.path, "--out", ctlOut.path]).code, 0)
        let control = try fns(root.appendingPathComponent("ctl-r.Ctl.Swift.json"))

        func eff(_ m: [String: [String: Any]], _ n: String) -> Set<String> {
            Set(m[n]?["inferred"] as? [String] ?? [])
        }
        XCTAssertTrue(eff(control, "viaFactory").contains("Fs"),
                      "CONTROL: in ONE package `let c = openConn(); c.send()` is Fs — without this the "
                      + "chained row proves nothing; got \(control["viaFactory"] ?? [:])")
        XCTAssertTrue(eff(chained, "viaFactory").contains("Fs"),
                      "split + chained must MATCH the control: the dep's `typeSurface` names the bound "
                      + "type and its report already holds `DepLib#Conn.send`; got "
                      + "\(chained["viaFactory"] ?? [:])")
        XCTAssertFalse(eff(chained, "viaMockFactory").contains("Fs"),
                       "viaMockFactory holds a `Mock.Conn`, whose `send` is PURE. Charging the real "
                       + "client's Fs here is the leaf-key fabrication the qualification exists to "
                       + "stop; got \(chained["viaMockFactory"] ?? [:])")
        for wrapper in ["viaOptionalFactory", "viaResultFactory", "viaManyFactory", "viaBoxedFactory"] {
            XCTAssertFalse(eff(chained, wrapper).contains("Fs"),
                           "\(wrapper) calls the WRAPPER's own `map`, never `Conn.map`. Publishing the "
                           + "payload keys the dep's effectful `map` here and charges an Fs this "
                           + "function cannot perform; got \(chained[wrapper] ?? [:])")
        }
    }

    /// A MISS FALLS BACK TO HALF 1'S DISCLOSURE, NEVER TO SILENCE — on `returns` AND on the entry
    /// lookup that follows a `returns` HIT. The second is the one rust shipped wrong: this index DROPS
    /// a key two entries share, so a miss cannot tell "no such method" from "I withdrew the answer",
    /// and a refusal to answer is not a purity claim.
    ///
    /// `viaMockFactory` is the `returns`-HIT-then-entry-MISS row (the surface answers `Mock.Conn`, and
    /// no entry is keyed `DepLib#Mock.Conn.send`); the wrapper rows are the `returns`-MISS rows.
    func testEveryMissStillDiscloses() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let appOut = root.appendingPathComponent("app-r")
        try? FileManager.default.removeItem(at: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertEqual(try ProcessHarness.run(bin, [app.path, "--out", appOut.path],
                                              env: ["CANDOR_DEPS": depReport.path]).code, 0)
        let by = try fns(root.appendingPathComponent("app-r.App.Swift.json"))

        for (miss, kind) in [("viaMockFactory", "a `returns` HIT whose ENTRY lookup missed"),
                             ("viaOptionalFactory", "a `returns` miss (wrapper return, refused)"),
                             ("viaResultFactory", "a `returns` miss (wrapper return, refused)"),
                             ("viaManyFactory", "a `returns` miss (wrapper return, refused)"),
                             ("viaBoxedFactory", "a `returns` miss (generic head, refused)")] {
            let e = by[miss]
            XCTAssertNotNil(e, "\(miss) is ABSENT from the report — under the ⟨0.21⟩ manifest that is a "
                            + "positive PURITY claim, and \(kind) licenses no such claim")
            XCTAssertTrue(Set(e?["inferred"] as? [String] ?? []).contains("Unknown"),
                          "\(miss): \(kind) must fall back to half 1's disclosure; got \(e ?? [:])")
            XCTAssertTrue((e?["unknownWhy"] as? [String] ?? []).contains("dispatch:untyped cross-package receiver"),
                          "\(miss): the disclosure must keep half 1's reason class. (`contains`, not "
                          + "equality: an ordinary §2 join on the FACTORY call itself can legitimately "
                          + "add its own `dep:` reason beside this one.); got \(e ?? [:])")
        }
    }

    /// THE GATE, which is what the whole vein is about: `deny Fs` on identical source goes
    /// ONE PACKAGE exit 1 -> split+chained exit 0 -> now exit 1 again.
    func testDenyGateFlipsBackAcrossTheBoundary() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let policy = root.appendingPathComponent("candor.policy")
        try "deny Fs\n".write(to: policy, atomically: true, encoding: .utf8)

        try? FileManager.default.removeItem(at: root.appendingPathComponent("g.App.Swift.json"))
        let chained = try ProcessHarness.run(bin, [app.path, "--out", root.appendingPathComponent("g").path,
                                                   "--policy", policy.path],
                                             env: ["CANDOR_DEPS": depReport.path])
        try? FileManager.default.removeItem(at: root.appendingPathComponent("gc.Ctl.Swift.json"))
        let single = try ProcessHarness.run(bin, [ctl.path, "--out", root.appendingPathComponent("gc").path,
                                                  "--policy", policy.path])
        XCTAssertEqual(single.code, 1, "CONTROL: one package, `deny Fs` must FAIL; stderr: \(single.err)")
        XCTAssertEqual(chained.code, 1,
                       "split + chained, `deny Fs` must fail the same way — a gate that passes once the "
                       + "code is split and the dep report chained is the whole vein; stderr: \(chained.err)")
    }

    /// THE PROTOCOL FACTORY, AND THE LAYERING. `openSink() -> Sink` publishes `DepLib#Sink`, and the key
    /// that forms — `DepLib#Sink.save` — names a REQUIREMENT with no body. Both directions are asserted
    /// because each alone is satisfiable by a wrong implementation:
    ///   - dep scanned PLAIN: nothing can answer, so the row must fall to half 1's DISCLOSURE. Resolving
    ///     it from anywhere else would mean the key was answered by a guess.
    ///   - dep scanned with CANDOR_WORKSPACE_CHAIN: the union entry answers it and the row RESOLVES.
    /// That is the layering the work queue records for swift's row 3 — the surface says WHICH type, the
    /// union says what that type's requirement runs, and neither substitutes for the other.
    func testProtocolFactoryIsLayeredWithTheInterfaceUnion() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        func consumerEffects(union: Bool) throws -> Set<String> {
            let depOut = root.appendingPathComponent("d\(union)")
            try? FileManager.default.removeItem(at: root.appendingPathComponent("d\(union).DepLib.Swift.json"))
            XCTAssertEqual(try ProcessHarness.run(bin, [dep.path, "--out", depOut.path],
                                                  env: union ? ["CANDOR_WORKSPACE_CHAIN": "1"] : [:]).code, 0)
            let appOut = root.appendingPathComponent("a\(union)")
            try? FileManager.default.removeItem(at: root.appendingPathComponent("a\(union).App.Swift.json"))
            XCTAssertEqual(try ProcessHarness.run(
                bin, [app.path, "--out", appOut.path],
                env: ["CANDOR_DEPS": root.appendingPathComponent("d\(union).DepLib.Swift.json").path]).code, 0)
            let by = try fns(root.appendingPathComponent("a\(union).App.Swift.json"))
            return Set(by["viaProtocolFactory"]?["inferred"] as? [String] ?? [])
        }
        let plain = try consumerEffects(union: false)
        XCTAssertFalse(plain.contains("Fs"),
                       "with no union entry NOTHING can answer `DepLib#Sink.save` — resolving it anyway "
                       + "means the key was answered by a guess; got \(plain)")
        XCTAssertTrue(plain.contains("Unknown"),
                      "…and the unanswerable key must DISCLOSE, never fall silent; got \(plain)")
        let unioned = try consumerEffects(union: true)
        XCTAssertTrue(unioned.contains("Fs"),
                      "with the producer's `interfaceUnion` entry the same key resolves — the surface "
                      + "names WHICH type, the union says what its requirement runs; got \(unioned)")
    }

    /// A STALE producer's surface is NOT read. §2.1 says a report from a different engine version is not
    /// trusted; keying the consumer through a type claim we just refused to believe would smuggle a
    /// stale answer back in under another field, so the row falls to the disclosure instead.
    func testStaleReportSurfaceIsNotTrusted() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        var env = try report(depReport)
        var prov = env["candor"] as? [String: Any] ?? [:]
        prov["version"] = "candor-swift-0.0.0-not-this-build"
        env["candor"] = prov
        let staled = root.appendingPathComponent("dep-stale.json")
        try JSONSerialization.data(withJSONObject: env, options: [.prettyPrinted, .sortedKeys])
            .write(to: staled)

        try? FileManager.default.removeItem(at: root.appendingPathComponent("s.App.Swift.json"))
        XCTAssertEqual(try ProcessHarness.run(bin, [app.path, "--out", root.appendingPathComponent("s").path],
                                              env: ["CANDOR_DEPS": staled.path]).code, 0)
        let by = try fns(root.appendingPathComponent("s.App.Swift.json"))
        XCTAssertFalse(Set(by["viaFactory"]?["inferred"] as? [String] ?? []).contains("Fs"),
                       "a STALE producer's typeSurface must not resolve the receiver; got "
                       + "\(by["viaFactory"] ?? [:])")
        XCTAssertTrue(Set(by["viaFactory"]?["inferred"] as? [String] ?? []).contains("Unknown"),
                      "…and it must still DISCLOSE rather than fall silent; got \(by["viaFactory"] ?? [:])")
        // The REASON is what distinguishes "the surface was not read" from "the surface was read and the
        // entry behind it was distrusted". Both yield Unknown; only the first is true, and a consumer
        // scoping `deny E Unknown[dispatch]` vs `Unknown[dep-stale]` acts on the difference.
        XCTAssertEqual(by["viaFactory"]?["unknownWhy"] as? [String],
                       ["dispatch:untyped cross-package receiver"],
                       "a stale producer's surface must not be consulted at all, so the disclosure keeps "
                       + "half 1's reason — reading it and then inheriting the entry's `dep-stale:` "
                       + "reason means the type claim WAS believed; got \(by["viaFactory"] ?? [:])")
    }

    // ── TWO COVERED IMPORTS ANSWERING THE SAME BARE FN KEY ──────────────────────────────────────

    /// `depCallee` is a BARE name, because an idiomatic Swift call into a dependency carries no module.
    /// So EVERY covered import of the file is asked the same fn key, and two libraries may both export
    /// a `build`. Gating only on `hits.count == 1` — the ENTRY lookup — let one of two different
    /// answers be picked whenever the other package's type happened to have no entry for the member.
    ///
    /// Alpha publishes `build -> Alpha#Client` whose `fetch` is `Fs` with `/etc/secrets` in `paths`;
    /// Beta publishes `build -> Beta#Stub` whose `fetch` is PURE and therefore absent. The consumer
    /// calls BETA's overload, `surfaced` holds two types, `hits` holds one — and the caller was charged
    /// Alpha's effect AND its path literal, with `unresolved` left false so nothing disclosed it. rust's
    /// reverted defect 1 (a leaf-keyed collapse of two distinct types), reappearing ACROSS packages.
    ///
    /// THE SECOND FIXTURE IS `viaUnique`, and it is what the fix must not break: BOTH packages are
    /// imported and covered, and only ONE answers `openAlpha`. That must still resolve — a guard keyed
    /// on "the file imports more than one covered package" would pass the row above and silently kill
    /// every real recovery in a multi-dependency file, which is the whole shape of standing-bar item 0.
    private func makeTwoDepFixture() throws -> (root: URL, alpha: URL, beta: URL, app: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-twodep-\(UUID().uuidString)")
        let fm = FileManager.default
        let alpha = root.appendingPathComponent("alpha"), beta = root.appendingPathComponent("beta")
        let app = root.appendingPathComponent("app")
        for (d, t) in [(alpha, "Alpha"), (beta, "Beta"), (app, "App")] {
            try fm.createDirectory(at: d.appendingPathComponent("Sources/\(t)"), withIntermediateDirectories: true)
        }
        for (d, t) in [(alpha, "Alpha"), (beta, "Beta")] {
            try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "\(t)", targets: [.target(name: "\(t)")])
            """.write(to: d.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        }
        try """
        import Foundation
        public struct Client {
            public init() {}
            public func fetch() { _ = FileManager.default.contents(atPath: "/etc/secrets") }
        }
        public func build() -> Client { return Client() }
        public func openAlpha() -> Client { return Client() }
        """.write(to: alpha.appendingPathComponent("Sources/Alpha/Lib.swift"), atomically: true, encoding: .utf8)
        // Beta's `build` takes an argument, so the consumer's call is UNAMBIGUOUS SWIFT while candor —
        // which records only the callee's bare name — sees the same key both packages publish.
        try """
        public struct Stub {
            public init() {}
            public func fetch() { }
        }
        public func build(_ name: String) -> Stub { return Stub() }
        """.write(to: beta.appendingPathComponent("Sources/Beta/Lib.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [.package(path: "../alpha"), .package(path: "../beta")],
            targets: [.target(name: "App", dependencies: [.product(name: "Alpha", package: "alpha"),
                                                          .product(name: "Beta", package: "beta")])]
        )
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Alpha
        import Beta
        // BETA's factory. Alpha cannot be reached from here at all.
        public func viaColliding() { let c = build("x"); c.fetch() }
        // …and the row the fix must keep: only ALPHA publishes `openAlpha`, with both packages covered.
        public func viaUnique() { let c = openAlpha(); c.fetch() }
        """.write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)
        return (root, alpha, beta, app)
    }

    func testTwoCoveredImportsAnsweringOneFnKeyRefuseToGuess() throws {
        let bin = try binaryURL()
        let (root, alpha, beta, app) = try makeTwoDepFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for (d, n) in [(alpha, "Alpha"), (beta, "Beta")] {
            try? fm.removeItem(at: root.appendingPathComponent("\(n.lowercased())-r.\(n).Swift.json"))
            XCTAssertEqual(try ProcessHarness.run(
                bin, [d.path, "--out", root.appendingPathComponent("\(n.lowercased())-r").path]).code, 0)
        }
        let depSpec = root.appendingPathComponent("alpha-r.Alpha.Swift.json").path
            + "," + root.appendingPathComponent("beta-r.Beta.Swift.json").path
        try? fm.removeItem(at: root.appendingPathComponent("app-r.App.Swift.json"))
        let r = try ProcessHarness.run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                                       env: ["CANDOR_DEPS": depSpec])
        XCTAssertEqual(r.code, 0, r.err)
        let by = try fns(root.appendingPathComponent("app-r.App.Swift.json"))

        // THE SECOND FIXTURE FIRST: the unique key must still resolve, with both packages covered.
        XCTAssertTrue(Set(by["viaUnique"]?["inferred"] as? [String] ?? []).contains("Fs"),
                      "viaUnique: only Alpha answers `openAlpha`, so the answer IS unambiguous and must "
                      + "still resolve — refusing whenever a file imports two covered packages would "
                      + "kill every real recovery in a multi-dependency file; got \(by["viaUnique"] ?? [:])")

        let colliding = by["viaColliding"]
        XCTAssertFalse(Set(colliding?["inferred"] as? [String] ?? []).contains("Fs"),
                       "viaColliding calls BETA's `build`, whose `Stub.fetch` is pure. Charging Alpha's "
                       + "Fs is a leaf-keyed collapse of two distinct types across packages — §2 rule 1 "
                       + "says a key two entries share is DROPPED, never picked from; got \(colliding ?? [:])")
        XCTAssertFalse((colliding?["paths"] as? [String] ?? []).contains("/etc/secrets"),
                       "…and the literal SURFACE travels with the effect, so the fabrication put another "
                       + "package's path literal on this function too; got \(colliding ?? [:])")
        XCTAssertNotNil(colliding, "viaColliding must not be ABSENT — under the ⟨0.21⟩ manifest that is a "
                        + "positive purity claim, and refusing to answer licenses no such claim")
        XCTAssertTrue(Set(colliding?["inferred"] as? [String] ?? []).contains("Unknown"),
                      "refusing an ambiguous answer falls back to half 1's DISCLOSURE, never to silence; "
                      + "got \(colliding ?? [:])")
        XCTAssertTrue((colliding?["unknownWhy"] as? [String] ?? [])
                        .contains("dispatch:untyped cross-package receiver"),
                      "…and it keeps half 1's reason class; got \(colliding ?? [:])")
    }
}
