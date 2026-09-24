import XCTest
import Foundation

/// SOUNDNESS R572 — AN OVERLOADED CONFORMER MEMBER PLUS A PROTOCOL-EXTENSION DEFAULT DROPPED EVERY
/// CONFORMER'S EFFECTS SILENTLY. A CARDINAL SIN, live in Alamofire.
///
/// The bounded CHA resolved each conformer's witness with a bare `resolveQual("\(conformer).\(member)")`.
/// That is an EXACT-NAME lookup and an overloaded declaration's qual carries a SIGNATURE SUFFIX
/// (`Impl.two(Int)`), so the lookup returned EMPTY for every conformer. `resolvedCount` went to 0 — and
/// the `|| providedEdged` disjunct was TRUE, because the protocol's extension default HAD been matched
/// through the overload table one loop above — so the union branch ran and **unioned empty sets: no
/// edge, and no `Unknown`.** The bare (no-default) twin of the same shape discloses `Unknown`, which is
/// why this survived: the arm that looks broken is the healthy one.
///
/// MEASURED on the fixture below, which `swift build`s and RUNS (§E3) — every arm reaches `sink` and
/// prints. One variable per row; the conformer, the sink and the protocol are identical throughout.
///
///     Req.callTwoDefaulted   member OVERLOADED, default present   inferred []       deny Net exit 0  ← SIN
///     Req.callOneDefaulted   member not overloaded, default       inferred [Net]    deny Net exit 1
///     Req.callOneBare        member not overloaded, no default    inferred [Net]    deny Net exit 1
///     Req.callTwoBare        member OVERLOADED, no default        inferred [Unknown] (disclosed)
///     Req2.callX             PROTOCOL member overloaded, the conformer's is not     [Net]
///
/// THE COMMENT TWELVE LINES ABOVE THE DEFECT said "OVERLOADS RESOLVE HERE EXACTLY AS THEY DO ON THE
/// TYPED-CALL PATH" and cited a corpus A/B for it. That was true of the extension-default half above it
/// and FALSE of the conformer half beneath it — §F1.3 (two implementations of one question) and §K (a
/// claim of correctness suppresses the measurement that would falsify it) in one place. Both halves now
/// go through one closure, `memberTargets`.
///
/// REAL-WORLD REACH: Alamofire's `EventMonitor` is a requirement with an empty extension default and
/// `CompositeEventMonitor`/`ClosureEventMonitor` overload its members — the library's ordinary idiom.
/// Corpus A/B over 7 Swift packages: ADDED 0, REMOVED 0, CHANGED 184, 0 rows losing an effect or a call
/// edge, 84 rows gaining one (Alamofire's `SessionDelegate.urlSession(…)` family +Net, swift-nio's
/// `FileSystemProtocol.openFile` +Fs, `NIOClientTCPBootstrap.connect(…)` +Net, `SocketOptionProvider.*`
/// +Env).
final class OverloadedConformerDispatchProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: OverloadedConformerDispatchProcessTests.self)
    }

    private func run(_ binary: URL, _ args: [String]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT",
                  "CANDOR_WORKSPACE_CHAIN"] {
            environment.removeValue(forKey: k)
        }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let exited = ProcessHarness.exitLatch(p)
        try p.run()
        let outData = ProcessHarness.drain(outPipe)
        let errData = ProcessHarness.drain(errPipe)
        exited.wait()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self),
                p.terminationStatus)
    }

    private static let SINK = "_ = URLSession.shared.dataTask(with: URL(string: \"http://h\")!)"

    /// The 2×2 that isolates R572: {member overloaded, member not} × {extension default, none}, plus the
    /// arm where the PROTOCOL's member is overloaded and the conformer's is not. Verbatim from the
    /// executable package, minus its top-level driver.
    private static var ovlSource: String {
        """
        import Foundation

        public func sink(_ n: Int) -> Int { \(SINK); return n }

        public protocol Mon {
            func one(_ t: Int)
            func two(_ t: Int)
            func two(_ t: String)
        }
        extension Mon {
            public func one(_ t: Int) {}
            public func two(_ t: Int) {}
            public func two(_ t: String) {}
        }
        public final class Impl: Mon {
            public init() {}
            public func one(_ t: Int) { _ = sink(t) }
            public func two(_ t: Int) { _ = sink(t) }
            public func two(_ t: String) { _ = sink(t.count) }
        }

        public protocol Bare {
            func one(_ t: Int)
            func two(_ t: Int)
            func two(_ t: String)
        }
        public final class BareImpl: Bare {
            public init() {}
            public func one(_ t: Int) { _ = sink(t) }
            public func two(_ t: Int) { _ = sink(t) }
            public func two(_ t: String) { _ = sink(t.count) }
        }

        public final class Req {
            public init() {}
            public var mon: Mon?
            public var bare: Bare?
            public func callOneDefaulted() { mon?.one(1) }
            public func callTwoDefaulted() { mon?.two(2) }
            public func callOneBare() { bare?.one(3) }
            public func callTwoBare() { bare?.two(4) }
        }

        public protocol Mon2 { func x(_ a: Int); func x(_ a: String) }
        extension Mon2 {
            public func x(_ a: Int) {}
            public func x(_ a: String) {}
        }
        public final class Impl2: Mon2 {
            public init() {}
            public func x(_ a: Int) { _ = sink(a) }
        }
        public final class Req2 {
            public init() {}
            public var mon: Mon2?
            public func callX() { mon?.x(5) }
        }
        """
    }

    /// THE UNION ARM. `memberTargets` returns `resolveQual`'s bare-name hit UNIONED with the matched
    /// overloads rather than replacing it, because the signature-suffixing pass SKIPS accessor units: a
    /// DEFAULT-ARGUMENT EXPRESSION body is a real unit still carrying the bare name (`DImpl.go` beside
    /// `DImpl.go(Int)`). Substituting instead of unioning DROPS it — measured, that turns `CallD.call`
    /// from `[Net]` into `[]` with `deny Net CallD.call` exit 0, i.e. it introduces a fresh cardinal sin
    /// inside the fix for one. `CallS` is the control: the identical shape whose conformer member is NOT
    /// overloaded, and the assertion is that the two arms AGREE, so this pins parity rather than
    /// blessing the over-approximation.
    private static var defSource: String {
        """
        import Foundation
        public func dsink(_ n: Int) -> Int { \(SINK); return n }

        public protocol D { func go(_ a: Int); func go(_ a: String) }
        extension D {
            public func go(_ a: Int) {}
            public func go(_ a: String) {}
        }
        public final class DImpl: D {
            public init() {}
            public func go(_ a: Int = dsink(1)) { _ = a }
            public func go(_ a: String) { _ = a }
        }

        public protocol S { func go(_ a: Int) }
        extension S { public func go(_ a: Int) {} }
        public final class SImpl: S {
            public init() {}
            public func go(_ a: Int = dsink(2)) { _ = a }
        }

        public final class CallD { public init() {}; public var d: D?; public func call() { d?.go(7) } }
        public final class CallS { public init() {}; public var s: S?; public func call() { s?.go(7) } }
        """
    }

    /// THE FABRICATION CONTROL, for the direction this change does NOT intend. The fix WIDENS a CHA, so
    /// (a) a protocol whose conformers' overloaded members are all pure must stay pure, and (b) a
    /// same-named member on an UNRELATED protocol's conformer must not be picked up.
    private static var pureSource: String {
        """
        import Foundation
        public func psink(_ n: Int) -> Int { \(SINK); return n }

        public protocol Calm { func tick(_ v: Int); func tick(_ v: String) }
        extension Calm {
            public func tick(_ v: Int) {}
            public func tick(_ v: String) {}
        }
        public final class PureCalm: Calm {
            public init() {}
            public func tick(_ v: Int) { _ = v + 1 }
            public func tick(_ v: String) { _ = v.count }
        }

        public protocol Loud { func tick(_ v: Int); func tick(_ v: String) }
        public final class LoudOne: Loud {
            public init() {}
            public func tick(_ v: Int) { _ = psink(v) }
            public func tick(_ v: String) { _ = psink(v.count) }
        }

        public final class CallCalm { public init() {}; public var c: Calm?; public func call() { c?.tick(1) } }
        """
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func render(_ sources: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r572-\(UUID().uuidString)")
        try write(root.appendingPathComponent("Package.swift"), """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Solo", products: [.library(name: "Solo", targets: ["Solo"])],
            targets: [.target(name: "Solo")])
        """)
        for (name, text) in sources {
            try write(root.appendingPathComponent("Sources/Solo/\(name).swift"), text)
        }
        return root
    }

    private func scan(_ sources: [String: String]) throws -> ([String: [String: Any]], URL) {
        let bin = try binaryURL()
        let root = try render(sources)
        let out = root.appendingPathComponent("r")
        let r = try run(bin, [root.path, "--out", out.path])
        XCTAssertEqual(r.code, 0, "scan must succeed; stderr: \(r.err)")
        let doc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.Solo.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (doc?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return (by, root)
    }

    private func eff(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set(by[fn]?["inferred"] as? [String] ?? [])
    }

    private func gate(_ root: URL, _ policy: String) throws -> Int32 {
        let bin = try binaryURL()
        let p = root.appendingPathComponent("p.policy")
        try write(p, policy + "\n")
        return try run(bin, [root.path, "--out", root.appendingPathComponent("g").path,
                             "--policy", p.path]).code
    }

    // ── THE DEFECT ──────────────────────────────────────────────────────────────────────────────

    /// The subject arm. Before the fix: `inferred []`, `unresolved false`, and both `pure` and
    /// `deny Net` exit 0 over a function that executes `URLSession.dataTask`.
    func testAnOverloadedConformerMemberWithAnExtensionDefaultCarriesItsEffect() throws {
        let (by, root) = try scan(["ovl": Self.ovlSource])
        XCTAssertNotNil(by["Req.callTwoDefaulted"],
                        "Req.callTwoDefaulted must not be ABSENT — under ⟨0.21⟩ that is a claim of purity")
        XCTAssertEqual(eff(by, "Req.callTwoDefaulted"), ["Net"],
                       "the overloaded conformer witness reaches URLSession; got \(eff(by, "Req.callTwoDefaulted"))")
        XCTAssertEqual(try gate(root, "deny Net Req.callTwoDefaulted"), 1,
                       "`deny Net Req.callTwoDefaulted` must catch it")
        XCTAssertEqual(try gate(root, "pure Req.callTwoDefaulted"), 1,
                       "`pure Req.callTwoDefaulted` must catch it")
        // the CALLEE that was dropped, named: the argument shape picks the Int arm, not the String one.
        let calls = Set(by["Req.callTwoDefaulted"]?["calls"] as? [String] ?? [])
        XCTAssertTrue(calls.contains("Impl.two(Int)"),
                      "the conformer's witness must be edged by name; got \(calls.sorted())")
    }

    /// THE FOUR CONTROLS that answered correctly before the fix and must still. They are what makes the
    /// subject arm a defect rather than a design: the only variable across the 2×2 is whether the
    /// conformer's member is overloaded.
    func testTheNeighbouringArmsAreUnchanged() throws {
        let (by, root) = try scan(["ovl": Self.ovlSource])
        for fn in ["Req.callOneDefaulted", "Req.callOneBare", "Req2.callX"] {
            XCTAssertEqual(eff(by, fn), ["Net"], "\(fn) must carry Net; got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net \(fn)"), 1, "`deny Net \(fn)` must catch it")
        }
        // `callTwoBare` — overloaded, NO extension default. Pre-fix it was the honest arm (a disclosed
        // `Unknown`); post-fix it resolves precisely. Either answer is sound, silence is not.
        XCTAssertFalse(eff(by, "Req.callTwoBare").isEmpty,
                       "Req.callTwoBare must answer Net or Unknown, never silence")
        XCTAssertEqual(try gate(root, "deny Net Unknown Req.callTwoBare"), 1,
                       "`deny Net Unknown Req.callTwoBare` must catch it either way")
    }

    /// THE UNION ARM (see `defSource`). Substituting the overload set for `resolveQual`'s bare-name hit
    /// instead of unioning it drops the default-argument-expression unit and takes `CallD.call` to `[]`.
    func testADefaultArgumentExpressionUnitSurvivesOverloadResolution() throws {
        let (by, root) = try scan(["def": Self.defSource])
        XCTAssertEqual(eff(by, "CallD.call"), eff(by, "CallS.call"),
                       "the overloaded arm and its non-overloaded twin must agree — got "
                       + "\(eff(by, "CallD.call")) vs \(eff(by, "CallS.call"))")
        XCTAssertEqual(eff(by, "CallD.call"), ["Net"],
                       "both reach `dsink` through a default-argument expression")
        XCTAssertEqual(try gate(root, "deny Net CallD.call"), 1, "`deny Net CallD.call` must catch it")
    }

    // ── THE CONTROL FOR THE DIRECTION THE FIX DID NOT INTEND ────────────────────────────────────

    /// A widened CHA must not fabricate. `CallCalm.call` dispatches `Calm.tick`, whose only conformer's
    /// overloads are pure — and an UNRELATED protocol `Loud` declares the same member with an effectful
    /// conformer. The caller must stay pure (absent from `functions[]`, or present with no effect).
    func testAWidenedChaDoesNotReachAnUnrelatedProtocolsConformers() throws {
        let (by, root) = try scan(["pure": Self.pureSource])
        XCTAssertTrue(eff(by, "CallCalm.call").isEmpty,
                      "CallCalm.call dispatches only pure witnesses; got \(eff(by, "CallCalm.call"))")
        XCTAssertEqual(try gate(root, "deny Net CallCalm.call"), 0,
                       "`deny Net CallCalm.call` must stay green — LoudOne is not a Calm conformer")
        // and the effectful sibling IS reported, so the scan is proven able to fail here (§6).
        XCTAssertEqual(eff(by, "LoudOne.tick(Int)"), ["Net"],
                       "the control is only evidence if the effectful arm is seen; got \(eff(by, "LoudOne.tick(Int)"))")
    }
}
