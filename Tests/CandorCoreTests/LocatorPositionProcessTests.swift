import XCTest
import Foundation

/// SOUNDNESS R394 — WHICH ARGUMENT IS THE LOCATOR, and why a list of names was the wrong shape.
///
/// `firstStringLiteral` scans the whole argument list. That is right only for a call whose single literal
/// IS its locator, and when it is not, the picker captures a sibling and the engine then treats that as
/// proof of completeness. R381 found this on `getaddrinfo` (a literal port captured as a HOST) and fixed
/// it *for the resolver family only* — so the next call over kept the bug:
/// `shellOut(to: runtimeCmd, at: "/tmp/work")` published `cmds: ["/tmp/work"]`, reporting the WORKING
/// DIRECTORY as the command. A fabrication and a gate bypass at once: `allow Exec /tmp/work` exit 0 over
/// a caller-controlled command.
///
/// The repair is a declared table (`locatorLabelsForFree`) rather than another special case, which also
/// retires the residual recorded on R393 — `fopen` was safe only because `"r"` happens to fail a
/// downstream path-shape test, and luck is not a property to rely on.
final class LocatorPositionProcessTests: XCTestCase {
    private func scan(_ src: String, name: String) throws -> (fns: [String: [String: Any]], out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        return (try ProcessHarness.fns(ofJson: r.out), r.out + r.err)
    }

    /// The DECISION: a non-locator literal must not stand in for the locator.
    func testShellOutWorkingDirectoryIsNotReportedAsTheCommand() throws {
        let src = """
        import Foundation
        public func run(_ cmd: String) throws { _ = try shellOut(to: cmd, at: "/tmp/work") }
        """
        let r = try scan(src, name: "R394Dir")
        let fn = try XCTUnwrap(r.fns["run"], "run absent:\\n\(r.out)")
        XCTAssertNil(fn["cmds"], "the `at:` working directory must never be captured as a command, got \(String(describing: fn["cmds"]))")
        XCTAssertEqual(fn["incomplete"] as? [String], ["Exec"],
                       "a runtime command with no captured locator must fail closed")
    }

    /// CONTROL — a genuine literal command must STILL be captured, or this is blanket over-masking.
    func testLiteralCommandIsStillCapturedFromTheLocatorLabel() throws {
        let src = """
        import Foundation
        public func litCmd() throws { _ = try shellOut(to: "ls -la", at: "/tmp/work") }
        """
        let r = try scan(src, name: "R394Ctl")
        let fn = try XCTUnwrap(r.fns["litCmd"], "litCmd absent:\\n\(r.out)")
        XCTAssertEqual(fn["cmds"] as? [String], ["ls"], "the command HEAD from `to:` must still be captured")
        XCTAssertNil(fn["incomplete"], "a determined command is not incomplete")
    }
}
