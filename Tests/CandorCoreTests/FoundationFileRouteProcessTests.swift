import XCTest
import Foundation

/// **R130, SECOND VEIN — the Foundation file routes that are not `FileManager` and not raw C.**
///
/// The question R130 was sent to answer was "does the Fs rule cover only the ordinary spelling", and the
/// C surface (see `CNativeDisclosureScopeProcessTests`) was only half the answer. Surveying 27 Swift-level
/// routes against the pre-fix binary, one executed fixture each, found a second family reading silent-pure:
///
///   * **the ObjC-bridged content-read constructors.** `String(contentsOfFile:)` was charged and
///     `NSString(contentsOfFile:)` was not, though they take the same label and do the same read.
///     `NSDictionary(contentsOfFile:)` — how a decade of plist-reading Swift is written — likewise.
///     `NSArray(contentsOfFile:)` likewise. The function that classifies these is titled "ONE FUNCTION,
///     BOTH SPELLINGS" and was shared between the bare and module-qualified CALL SITES; it still knew
///     three of the six TYPE spellings of one constructor.
///   * **`NSData.write(toFile:)`**, the bridged twin of the already-charged `Data.write(to:)`.
///   * **`URL`'s five disk-touching members**, on a type that had no κ entry at all because nearly all of
///     it is pure path algebra. `checkResourceIsReachable()` is a `stat` and is THE idiomatic Swift
///     file-existence test — the sibling of `FileManager.fileExists`, which has always been `Fs`.
///   * **`OutputStream(toFileAtPath:)` / `InputStream(fileAtPath:)` / `…(url:)`**, which open a file and
///     could not be told from their in-memory siblings by `kappaFree`'s `(name, argCount)` key.
///   * **`NSURLConnection`**, the pre-URLSession networking class, still all over legacy code.
///
/// GROUND TRUTH EXECUTED for the four Fs rows: each fixture was written as an SPM package, `swift build`-ed
/// and RUN, and printed proof the operation reached the disk — `NSDictionary(contentsOfFile:)` read back
/// one key from a plist it had just written; `checkResourceIsReachable()` returned false then true across
/// a file creation; `OutputStream(toFileAtPath:)` left 8 bytes readable by an independent read;
/// `NSData.write(toFile:)` left 7. Pre-fix, each `doWork` was ABSENT from the report and all five policy
/// forms (`deny Fs`, `deny Unknown`, `deny Fs Unknown`, `deny Fs doWork`, `pure doWork`) exited 0 over the
/// executed write. `NSURLConnection` is ANALYSIS-ONLY and labelled as such: its row was not executed,
/// because doing so needs a live endpoint.
///
/// THE CONTROLS ARE THE POINT OF THE STREAM ARM. `OutputStream(toMemory:)` and `InputStream(data:)` are
/// the same type names at the same arity and touch nothing, so the discriminator has to be the argument
/// LABEL; a control that only asserted "the file form is charged" would pass just as well over a rule
/// that charged every stream ever built.
final class FoundationFileRouteProcessTests: XCTestCase {

    private func scan(_ src: String, name: String) throws -> (fns: [String: [String: Any]], out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        return (try ProcessHarness.fns(ofJson: r.out), r.out + r.err)
    }

    /// §E3, mechanised: every fixture below is type-checked by the real compiler before its report is
    /// read. An absence assertion over a program that does not compile is not weak evidence, it is none.
    private func assertTypechecks(_ src: String, _ label: String) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r130b-tc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f.swift")
        try src.write(to: f, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(URL(fileURLWithPath: "/usr/bin/env"), ["swiftc", "-typecheck", f.path])
        XCTAssertEqual(r.code, 0, "the \(label) fixture must COMPILE (brief §E3): \(r.err)")
    }

    /// DEFECT + CONTROL in one tree: the bridged read constructors beside the `String` spelling that was
    /// always charged, so a regression that killed the whole family is distinguishable from one that
    /// killed only the new names.
    private static let bridgedReads = """
    import Foundation

    public func viaNSString(_ p: String) -> Int { (try? NSString(contentsOfFile: p, encoding: 4))?.length ?? -1 }
    public func viaNSDictionary(_ p: String) -> Int { NSDictionary(contentsOfFile: p)?.count ?? -1 }
    public func viaNSArray(_ p: String) -> Int { NSArray(contentsOfFile: p)?.count ?? -1 }
    public func viaString(_ p: String) -> Int { (try? String(contentsOfFile: p, encoding: .utf8))?.count ?? -1 }
    """

    func testTheObjCBridgedContentReadConstructorsAreChargedLikeTheirSwiftSpelling() throws {
        try assertTypechecks(Self.bridgedReads, "bridged-reads")
        let r = try scan(Self.bridgedReads, name: "BridgedReads")
        for fn in ["viaNSString", "viaNSDictionary", "viaNSArray", "viaString"] {
            XCTAssertEqual(ProcessHarness.inferred(r.fns, fn), ["Fs"],
                           "`\(fn)` reads a file off disk (ground truth executed for the NSDictionary "
                           + "arm) — one constructor, six type spellings, and three of them read "
                           + "silent-pure: \(r.out)")
            XCTAssertEqual(r.fns[fn]?["fs"] as? [String], ["read"],
                           "and the DIRECTION the selecting label already proves must be recorded")
        }
    }

    /// DEFECT. The bridged twin of `Data.write(to:)`, which has been charged for two rungs.
    func testNSDataWriteToFileIsChargedLikeDataWriteTo() throws {
        let src = """
        import Foundation

        public func viaNSData(_ p: String) { NSData(data: Data("x".utf8)).write(toFile: p, atomically: true) }
        public func viaData(_ p: String) { try? Data("x".utf8).write(to: URL(fileURLWithPath: p)) }
        """
        try assertTypechecks(src, "bridged-write")
        let r = try scan(src, name: "BridgedWrite")
        for fn in ["viaNSData", "viaData"] {
            XCTAssertEqual(ProcessHarness.inferred(r.fns, fn), ["Fs"], "\(fn): \(r.out)")
            XCTAssertEqual(r.fns[fn]?["fs"] as? [String], ["write"], "\(fn) direction")
        }
    }

    /// DEFECT + CONTROL in one tree. `URL` is mostly pure path algebra, which is exactly why the five
    /// verbs that DO issue a syscall went unnoticed — and exactly why the pure arm must be pinned beside
    /// them: charging the whole type would be the fabrication mirror, and nothing else in the suite would
    /// catch it.
    private static let urlTree = """
    import Foundation

    public func reach(_ p: String) -> Bool { (try? URL(fileURLWithPath: p).checkResourceIsReachable()) ?? false }
    public func meta(_ p: String) -> Bool { (try? URL(fileURLWithPath: p).resourceValues(forKeys: []))?.isDirectory ?? false }
    public func symlinks(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }

    // `checkPromisedItemIsReachable` and `bookmarkData` are Darwin-only — swift-corelibs-foundation's URL
    // has neither, so the unguarded form does not COMPILE on Linux. The guard is here rather than around
    // the assertions because candor reads BOTH `#if` arms unconditionally: the fixture type-checks on
    // both hosts and the rows below stay unconditional, which is the coverage the first cut of this test
    // would have lost. (Caught by `assertTypechecks` on the first Docker run, not by reading.)
    #if canImport(Darwin)
    public func promised(_ p: String) -> Bool { (try? URL(fileURLWithPath: p).checkPromisedItemIsReachable()) ?? false }
    public func bookmark(_ p: String) -> Int { (try? URL(fileURLWithPath: p).bookmarkData())?.count ?? -1 }
    #endif
    public func setMeta(_ p: String) {
        var u = URL(fileURLWithPath: p)
        var v = URLResourceValues()
        v.name = "x"
        try? u.setResourceValues(v)
    }

    // CONTROL — the pure path algebra that is most of URL. Charging these would make every Swift file
    // that builds a path read as a filesystem effect.
    public func pureAlgebra(_ p: String) -> String {
        let u = URL(fileURLWithPath: p).appendingPathComponent("x").deletingLastPathComponent()
        return u.standardized.lastPathComponent + u.pathExtension + String(u.pathComponents.count)
    }
    """

    func testURLsFiveDiskTouchingMembersAreChargedAndItsPathAlgebraIsNot() throws {
        try assertTypechecks(Self.urlTree, "url-members")
        let r = try scan(Self.urlTree, name: "UrlMembers")
        for (fn, kind) in [("reach", "read"), ("promised", "read"), ("meta", "read"),
                           ("bookmark", "read"), ("symlinks", "read"), ("setMeta", "write")] {
            XCTAssertEqual(ProcessHarness.inferred(r.fns, fn), ["Fs"],
                           "`\(fn)` issues a filesystem syscall — `checkResourceIsReachable()` is a stat "
                           + "and the sibling of `FileManager.fileExists`, which has always been Fs: \(r.out)")
            XCTAssertEqual(r.fns[fn]?["fs"] as? [String], [kind], "`\(fn)` direction")
        }
        XCTAssertNil(r.fns["pureAlgebra"],
                     "`appendingPathComponent`/`standardized`/`pathComponents` touch NO disk — a κ root "
                     + "must stay verb-precise or every path-building function in Swift gains Fs: \(r.out)")
    }

    /// DEFECT + CONTROL in one tree, and the control is load-bearing here: `InputStream(fileAtPath:)` and
    /// `InputStream(data:)` are the same name at the same arity, so only the LABEL separates a file open
    /// from an in-memory stream. A rule keyed on `(name, argCount)` — which is all `kappaFree` can see —
    /// cannot express this, which is why the arm lives beside `chargeContentsCtor` instead.
    private static let streamTree = """
    import Foundation

    public func outFile(_ p: String) { OutputStream(toFileAtPath: p, append: false)?.open() }
    public func outURL(_ p: String) { OutputStream(url: URL(fileURLWithPath: p), append: false)?.open() }
    public func inFile(_ p: String) { InputStream(fileAtPath: p)?.open() }
    public func inURL(_ p: String) { InputStream(url: URL(fileURLWithPath: p))?.open() }

    // CONTROLS — same types, same arity, no disk.
    public func outMemory() { OutputStream(toMemory: ()).open() }
    public func inMemory() { InputStream(data: Data()).open() }
    """

    func testFileBackedStreamConstructorsAreChargedAndInMemoryOnesAreNot() throws {
        try assertTypechecks(Self.streamTree, "stream-ctors")
        let r = try scan(Self.streamTree, name: "StreamCtors")
        for (fn, kind) in [("outFile", "write"), ("outURL", "write"), ("inFile", "read"), ("inURL", "read")] {
            XCTAssertEqual(ProcessHarness.inferred(r.fns, fn), ["Fs"],
                           "`\(fn)` opens a real file (ground truth executed for the toFileAtPath arm — "
                           + "8 bytes read back by an independent read): \(r.out)")
            XCTAssertEqual(r.fns[fn]?["fs"] as? [String], [kind], "`\(fn)` direction")
        }
        XCTAssertNil(r.fns["outMemory"],
                     "`OutputStream(toMemory:)` writes to a Data buffer — charging it would mean the arm "
                     + "keyed on the TYPE rather than on the label it claims to read: \(r.out)")
        XCTAssertNil(r.fns["inMemory"],
                     "`InputStream(data:)` reads from memory — same: \(r.out)")
    }

    /// DEFECT — ANALYSIS-ONLY, and separated from the executed rows deliberately (brief §J: "analysed and
    /// found clean" and "attacked and survived" must never share a list). Executing this row needs a live
    /// endpoint, so what is pinned is the classification, not a run.
    func testNSURLConnectionRequestVerbsAreChargedNetAnalysisOnly() throws {
        // Darwin-guarded for the same reason as the URL tree: `NSURLConnection` does not exist in
        // swift-corelibs-foundation and `URLRequest` lives in FoundationNetworking there. candor reads
        // both `#if` arms, so the assertions below are unconditional on both hosts.
        let src = """
        import Foundation

        #if canImport(Darwin)
        public func legacyGet(_ u: URL) -> Data? {
            return try? NSURLConnection.sendSynchronousRequest(URLRequest(url: u), returning: nil)
        }

        // CONTROL — `canHandle(_:)` is a static predicate over a URLRequest and opens no socket.
        public func canDo(_ u: URL) -> Bool { NSURLConnection.canHandle(URLRequest(url: u)) }
        #endif
        """
        try assertTypechecks(src, "nsurlconnection")
        let r = try scan(src, name: "LegacyNet")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "legacyGet"), ["Net"],
                       "the pre-URLSession request verb issues the request: \(r.out)")
        XCTAssertNil(r.fns["canDo"],
                     "and the static predicate beside it must not — a whole-type rule here would charge "
                     + "Net to a function that only inspects a request: \(r.out)")
    }
}
