import XCTest
import Foundation

/// SOUNDNESS R507 (= [[R497]]'s class, which candor-java closed first) — `path` RESOLVED A FUNCTION
/// SELECTOR BY UNANCHORED SUBSTRING AND ANSWERED ABOUT THE FIRST MATCH.
///
/// The old resolution was `names.first { $0 == fnArg } ?? names.first { $0.contains(fnArg) }`, and the
/// comment beside it said it *"mirrors the Rust reference"* — the copy inherited the defect along with
/// the design. Two faults compound. (1) The fallback is an UNANCHORED substring, so
/// `ProfileCredentialsProvider` matches INSIDE `InstanceProfileCredentialsProvider`. (2) With several
/// matches it PICKS THE FIRST rather than refusing. Measured in candor-java on `auth-2.25.60`:
/// `path ProfileCredentialsProvider.resolveCredentials Exec` printed *"InstanceProfileCredentials-
/// Provider.resolveCredentials does not perform Exec"* at exit 0 — a confident NEGATIVE about a function
/// nobody asked about, while the function actually asked about performs `Exec`.
///
/// NOTE THE ASYMMETRY THAT IS THE WHOLE DEFECT: `path` ALREADY refuses at exit 2 when ZERO functions
/// match. Only MANY was answered silently — which is why this survived: conformance pins the zero case.
///
/// The fixture reproduces the java shape in Swift's own qual grammar: a NESTED enum gives a three-segment
/// qual, so the selector is a proper suffix of the subject and a literal substring of a sibling.
final class PathSelectorAmbiguityProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: PathSelectorAmbiguityProcessTests.self)
    }

    private func run(_ binary: URL, _ args: [String], cwd: URL? = nil) throws
        -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT"] {
            environment.removeValue(forKey: k)
        }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let exited = ProcessHarness.exitLatch(p)
        try p.run()
        let o = ProcessHarness.drain(outPipe), e = ProcessHarness.drain(errPipe)
        exited.wait()
        return (String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self), p.terminationStatus)
    }

    /// THE SUBJECT performs Exec. THE DECOY's name CONTAINS the subject's selector and does not. A THIRD
    /// shares the bare leaf, so `resolveCredentials` alone is genuinely ambiguous. All three carry an
    /// effect deliberately: a PURE function is absent from the report (§2 rule 3), and a fixture whose
    /// decoys are absent cannot reproduce a defect about picking between candidates.
    private static let source = """
    import Foundation
    public enum credentials {
        public enum ProfileCredentialsProvider {
            public static func resolveCredentials() { try? Process().run() }
        }
        public enum InstanceProfileCredentialsProvider {
            public static func resolveCredentials() { _ = ProcessInfo.processInfo.environment["AWS_REGION"] }
        }
        public enum AnonymousCredentialsProvider {
            public static func resolveCredentials() { _ = ProcessInfo.processInfo.environment["NONE"] }
        }
    }
    """

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r507-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Sources/R507")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "R507", products: [.library(name: "R507", targets: ["R507"])],
            targets: [.target(name: "R507")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.source.write(to: src.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        return root
    }

    func testAnAnchoredSelectorAnswersAboutTheFunctionActuallyAskedAbout() throws {
        let bin = try binaryURL()
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        XCTAssertEqual(try run(bin, [root.path, "--out", out.path]).code, 0)

        // BASELINE — the decoy really is in the report, and really does NOT perform Exec. Without this
        // the assertion below could pass because the decoy was absent, which is a different fixture.
        let doc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.R507.Swift.json"))) as? [String: Any]
        var by: [String: [String]] = [:]
        for case let f as [String: Any] in (doc?["functions"] as? [Any]) ?? [] {
            by[f["fn"] as? String ?? ""] = f["inferred"] as? [String] ?? []
        }
        XCTAssertEqual(by["credentials.InstanceProfileCredentialsProvider.resolveCredentials"], ["Env"])
        XCTAssertEqual(by["credentials.ProfileCredentialsProvider.resolveCredentials"], ["Exec"])

        // THE DEFECT, and the answer it must give now: `ProfileCredentialsProvider.resolveCredentials` is
        // a SEGMENT-ANCHORED suffix of exactly one qual and a bare substring of the other, so the ladder
        // resolves it to the subject. Pre-fix this printed a confident negative about the decoy at exit 0.
        let r = try run(bin, ["path", "ProfileCredentialsProvider.resolveCredentials", "Exec",
                              "--report", out.path])
        XCTAssertEqual(r.code, 0, "an unambiguously anchored selector is answerable; stderr: \(r.err)")
        XCTAssertTrue(r.out.contains("credentials.ProfileCredentialsProvider.resolveCredentials"),
                      "the answer must be about the function ASKED about; got: \(r.out)")
        XCTAssertFalse(r.out.contains("InstanceProfileCredentialsProvider"),
                       "…and never about the longer identifier it is a substring of; got: \(r.out)")
        XCTAssertFalse(r.out.contains("does not perform"),
                       "the subject performs Exec — a negative here is a FALSE NEGATIVE ON THE REAL "
                       + "QUESTION, not merely a wrong subject; got: \(r.out)")
    }

    func testAGenuinelyAmbiguousSelectorRefusesAndNamesTheCandidates() throws {
        let bin = try binaryURL()
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        XCTAssertEqual(try run(bin, [root.path, "--out", out.path]).code, 0)

        let r = try run(bin, ["path", "resolveCredentials", "Exec", "--report", out.path])
        XCTAssertEqual(r.code, 2,
                       "three functions match the bare leaf equally well — answering about one of them "
                       + "is a claim about a function the user did not ask about. `path` already refuses "
                       + "at exit 2 on ZERO matches; MANY was the half answered silently. "
                       + "stdout: \(r.out) stderr: \(r.err)")
        let said = r.out + r.err
        for n in ["credentials.ProfileCredentialsProvider.resolveCredentials",
                  "credentials.InstanceProfileCredentialsProvider.resolveCredentials",
                  "credentials.AnonymousCredentialsProvider.resolveCredentials"] {
            XCTAssertTrue(said.contains(n), "the refusal must NAME the candidates — a refusal the user "
                          + "cannot act on is a dead end; missing \(n) in: \(said)")
        }
    }

    /// THE ZERO-MATCH HALF IS UNCHANGED, and it is the arm conformance already pins — asserted here so a
    /// future change to the ladder cannot quietly turn a refusal into an empty answer.
    func testNoMatchStillRefuses() throws {
        let bin = try binaryURL()
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        XCTAssertEqual(try run(bin, [root.path, "--out", out.path]).code, 0)
        let r = try run(bin, ["path", "noSuchFunctionAnywhere", "Exec", "--report", out.path])
        XCTAssertEqual(r.code, 2, "stdout: \(r.out) stderr: \(r.err)")
    }

    /// AN EXACT MATCH IS PREFERRED OVER A BARE SUFFIX, so refusing is never the answer to a question that
    /// has exactly one right answer: the full qual resolves even though two siblings also carry the leaf.
    func testAnExactQualIsNeverAmbiguous() throws {
        let bin = try binaryURL()
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        XCTAssertEqual(try run(bin, [root.path, "--out", out.path]).code, 0)
        let r = try run(bin, ["path", "credentials.ProfileCredentialsProvider.resolveCredentials", "Exec",
                              "--report", out.path])
        XCTAssertEqual(r.code, 0, "stderr: \(r.err)")
        XCTAssertTrue(r.out.contains("Exec source"), "got: \(r.out)")
    }
}
