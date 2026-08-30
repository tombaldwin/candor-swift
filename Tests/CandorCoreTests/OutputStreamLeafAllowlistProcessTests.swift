import XCTest
import Foundation

/// `modelOutputStreamCall` (CallCollector.swift) models the WRITER side of formatting: `print`/
/// `debugPrint`/`dump(_:to:)` and `value.write(to:)` accept a destination stream through a `to:`-labeled
/// `inout` argument, and the stream's `TextOutputStream.write(_:)` witness runs as a side effect of the
/// call even though no source line spells `stream.write(...)` directly. The mechanism edges the CALLER to
/// `<streamType>.write` whenever it sees a `to:` inout argument — but only after first checking the call's
/// own leaf name against an explicit allowlist:
///
///     guard let leaf, ["print", "debugPrint", "dump", "write"].contains(leaf) else { return }
///
/// This is the guard that keeps the mechanism SCOPED to the four spellings that actually trigger the
/// implicit stream write. Without it, `modelOutputStreamCall` fires for ANY call carrying a `to:`-labeled
/// inout argument of a local type, unconditionally asserting that type's `write` method runs — a
/// fabricated edge with no source justification whenever an unrelated method happens to take a
/// `to:` inout parameter of a type that ALSO happens to declare a method literally named `write` (a
/// realistic coincidence: any type adopting `TextOutputStream` must declare exactly that method). The
/// local-free-function/nested-func shadow check two lines below this guard does NOT close the gap: it
/// only recognises the CURRENT module's free functions and the current unit's nested funcs, so a plain
/// MEMBER method — `widget.configure(to: &box)` — sails past both checks once the leaf allowlist is gone.
///
/// Measured: with the allowlist deleted, `swift build`, `swift test` (945/945), `smoke.sh`,
/// `fabrication_probe.py`, `fuzz.py` and `ci/self-gate.sh` all stayed green — this suite is what makes
/// deleting it RED.
final class OutputStreamLeafAllowlistProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: OutputStreamLeafAllowlistProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    /// THE GUARD ITSELF. `Widget.configure(to:)` is an ordinary method wholly unrelated to text output; it
    /// never calls `box.write()`. The ONLY reason a fabricated edge could ever land on `Box.write` is the
    /// coincidence that `to:` is also the label `print`/`dump` use for their stream argument — the leaf
    /// allowlist is what tells the two apart.
    func testUnrelatedToLabeledInoutCallFabricatesNoWriteEdge() throws {
        let by = try scan("""
        import Foundation
        final class Box {
            func write() {
                let t = Process()
                t.launchPath = "/bin/sh"
                try? t.run()
            }
        }
        final class Widget {
            func configure(to box: inout Box) { }
        }
        func caller() {
            var b = Box()
            let w = Widget()
            w.configure(to: &b)
        }
        """)
        XCTAssertNil(by["caller"], "an unrelated `to:`-labeled call must fabricate no effect at all — got \(String(describing: by["caller"]))")
    }

    /// THE POSITIVE CONTROL — proves the mechanism itself still fires for the real idiom: `dump(_:to:)`
    /// against a genuine `TextOutputStream` DOES drive that stream's `write`.
    func testDumpToLocalStreamStillEdgesItsWrite() throws {
        let by = try scan("""
        import Foundation
        final class Sink: TextOutputStream {
            func write(_ string: String) {
                let t = Process()
                t.launchPath = "/bin/sh"
                try? t.run()
            }
        }
        func caller() {
            var s = Sink()
            dump("hello", to: &s)
        }
        """)
        XCTAssertEqual((ProcessHarness.inferred(by, "caller") ?? []), ["Exec"],
                       "dump(_:to:) must still drive the stream's write — the allowlist must not overcorrect")
    }
}
