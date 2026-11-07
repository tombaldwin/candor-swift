import XCTest
import Foundation

/// SOUNDNESS R1472 — A BARE READ OF A CLOSURE PARAMETER IS THAT PARAMETER, TYPED OR NOT. An untyped closure
/// parameter read bare (`o.map { channel in channel + 1 }`) fell through to `globalReads`, whose local arm matches
/// a global unit by bare name ANYWHERE in the scan — so a library function was charged the effect of a same-named
/// top-level global in an EXAMPLE EXECUTABLE it cannot even import (swift-nio's `DatagramBootstrap.bind` read
/// `NIOChatClient/main.swift`'s `channel`: `Net`/`Clock`). The R1455 T4 typing removed it only where it types the
/// parameter. Every program below was EXECUTED (the Runner deletes the marker files, calls one function, and
/// lists the markers that exist afterwards):
///
///     capturesGlobalOtherParam / capturesGlobalOptionalMap / readsGlobalAsBase  -> /tmp/…-lib-token created
///     readsGlobalAfterClosure / readsGlobalInSiblingClosure                     -> /tmp/…-lib-shade created
///     bareParamOptionalMap / bareParamAny / bareParamBase / shadowsOwnModuleGlobal
///         / nestedClosureReadsOuterParam                                        -> none
///
/// The MUST-STAY-CHARGED rows were written first: a closure that really reads a global it captures (its own
/// parameter named differently, the global as a member base, and the same name as a closure parameter read
/// AFTER that closure and in a SIBLING closure — the parameter's scope ends with its body).
final class ClosureParamBindsBareNameProcessTests: XCTestCase {

    private func makePackage() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-r1472-\(UUID().uuidString)")
        let fm = FileManager.default
        for d in ["Lib", "Decoy"] {
            try fm.createDirectory(at: root.appendingPathComponent("Sources/\(d)"), withIntermediateDirectories: true)
        }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "R1472Pkg", targets: [
            .target(name: "Lib"),
            .executableTarget(name: "Decoy"),
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        let channel: Int = { FileManager.default.createFile(atPath: "/tmp/r1472-decoy-channel", contents: nil); return 1 }()
        print(channel)
        """.write(to: root.appendingPathComponent("Sources/Decoy/main.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public let token: Int = { FileManager.default.createFile(atPath: "/tmp/r1472-lib-token", contents: nil); return 7 }()
        public let shade: Int = { FileManager.default.createFile(atPath: "/tmp/r1472-lib-shade", contents: nil); return 9 }()
        """.write(to: root.appendingPathComponent("Sources/Lib/Globals.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        func apply<T>(_ v: T, _ f: (T) -> Int) -> Int { f(v) }
        func applyAny(_ v: Any, _ f: (Any) -> Int) -> Int { f(v) }
        public func capturesGlobalOtherParam() -> Int { return apply(1) { x in token + (x as Int) } }
        public func capturesGlobalOptionalMap() -> Int { let o: Int? = 2; return o.map { x in x + token } ?? 0 }
        public func readsGlobalAfterClosure() -> Int { let a = apply(3) { shade in shade + 1 }; return a + shade }
        public func readsGlobalInSiblingClosure() -> Int {
          let a = apply(3) { shade in shade + 1 }
          let b = apply(4) { y in y + shade }
          return a + b
        }
        public func readsGlobalAsBase() -> Int { return apply(1) { x in token.signum() + (x as Int) } }
        public func bareParamOptionalMap() -> Int { let o: Int? = 2; return o.map { channel in channel + 1 } ?? 0 }
        public func bareParamAny() -> Int { return applyAny(5) { channel in (channel as? Int) ?? 0 } }
        public func bareParamBase() -> Int { let o: Int? = 2; return o.map { channel in channel.signum() } ?? 0 }
        public func shadowsOwnModuleGlobal() -> Int { let o: Int? = 2; return o.map { shade in shade * 2 } ?? 0 }
        public func nestedClosureReadsOuterParam() -> Int {
          let o: Int? = 2
          return o.map { shade in apply(0) { _ in shade } } ?? 0
        }
        public protocol Conn { func connect() }
        public final class FileConn: Conn {
          public init() {}
          public func connect() { FileManager.default.createFile(atPath: "/tmp/r1472-conn", contents: nil) }
        }
        public struct Future<T> {
          let v: T
          public init(_ v: T) { self.v = v }
          public func whenSuccess(_ f: (T) -> Void) { f(v) }
        }
        public func connectsThroughDroppedCall() -> Int {
          let fut = Future<(Conn, Int)>((FileConn(), 1))
          fut.whenSuccess { (channel, r) in channel.connect() }
          return 0
        }
        public func connectsBesideAParamRead() -> Int {
          let fut = Future<(Conn, Int)>((FileConn(), 1))
          let o: Int? = 2
          let n = o.map { channel in channel + 1 } ?? 0
          fut.whenSuccess { (c, r) in c.connect() }
          return n
        }
        """.write(to: root.appendingPathComponent("Sources/Lib/Lib.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private func scan(_ root: URL, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: ClosureParamBindsBareNameProcessTests.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    static let realReads = ["capturesGlobalOtherParam", "capturesGlobalOptionalMap", "readsGlobalAfterClosure",
                            "readsGlobalInSiblingClosure", "readsGlobalAsBase"]
    static let paramReads = ["bareParamOptionalMap", "bareParamAny", "bareParamBase", "shadowsOwnModuleGlobal",
                             "nestedClosureReadsOuterParam"]

    func testAClosureThatReallyReadsAGlobalStaysCharged() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in Self.realReads {
            XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) reads a Lib global (executed) — \(by[fn] ?? [:])")
        }
    }

    func testABareClosureParameterReadNeverReachesASameNamedGlobal() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in Self.paramReads {
            // `Unknown` from the generic `apply`'s callback flow may stand; the global's `Fs` must not.
            XCTAssertFalse(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) reads only its closure parameter (executed: no marker) — \(by[fn] ?? [:])")
        }
    }

    /// THE FLOOR (both functions EXECUTED: each creates the marker). `connectsThroughDroppedCall` really creates `/tmp/r1472-conn` (executed), through `channel.connect()` on
    /// an untyped closure parameter — a call R1455 drops with no edge and no `Unknown`. v0.41.3 charged the row `Fs`
    /// only through the false edge to the Decoy's `channel`; removing that edge must not leave the row silent, so the
    /// dropped call discloses (`dispatch:<untyped>.connect`) wherever the release's edge would have formed.
    func testADroppedCallOnTheParameterDisclosesWhereTheFalseEdgeWas() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        // `connectsBesideAParamRead` is the same with the drop on ANOTHER receiver in the unit (RxSwift's
        // `countDownDuration`: the false edge from a bare `value`, the real callee behind a dropped `base.rx.…` call).
        let by = try scan(root)
        let off = try scan(root, env: ["CANDOR_R1472_OFF": "1"])
        for fn in ["connectsThroughDroppedCall", "connectsBesideAParamRead"] {
            let why = { (b: [String: [String: Any]]) in (b[fn]?["unknownWhy"] as? [String]) ?? [] }
            XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains("Unknown") == true, "\(fn): \(by[fn] ?? [:])")
            XCTAssertTrue(why(by).contains("dispatch:<untyped>.connect"), "\(fn): the dropped call must disclose: \(why(by))")
            XCTAssertFalse(why(off).contains("dispatch:<untyped>.connect"), "\(fn): the release carries no such disclosure: \(why(off))")
            XCTAssertTrue(ProcessHarness.inferred(off, fn)?.contains("Fs") == true, "\(fn): release charges Fs via the false edge")
        }
    }

    /// The kill switch restores v0.41.3's reading, so the row above is shown able to fail on this fixture.
    func testKillSwitchRestoresTheReleaseCharge() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root, env: ["CANDOR_R1472_OFF": "1"])
        for fn in Self.paramReads {
            XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) under CANDOR_R1472_OFF — \(by[fn] ?? [:])")
        }
    }
}
