import XCTest
import Foundation

/// LOCATOR PROVENANCE — the Apple-platform network/subprocess surface.
///
/// Until this suite, swift extracted a Net host ONLY when the literal was a DIRECT string argument of the
/// establishing call (`NWConnection(host:port:)` — the single idiom conformance PART 4e pins). Every
/// `URLSession` form therefore yielded NO `hosts` (the `URL(string:)` ctor interposes) and every `Process`
/// form yielded NO `cmds` (`launchPath`/`executableURL` are property WRITES, and `run()` takes no argument).
/// rust/java/ts all extract on their equivalents from an inline literal AND from a local binding.
///
/// EVERY mechanism here moves the gate in the RELAXING direction: extracting a host turns a fail-closed
/// `unknown-host` into a CLASSIFIED destination; extracting a command turns an uncertifiable `allow Exec`
/// into a certified one. A bug here does not produce a loud wrong answer, it produces a QUIETER one — the
/// cardinal sin. So each mechanism is pinned in BOTH directions and the negative half is not optional:
/// where the locator is genuinely unrecoverable (a parameter, a runtime concatenation, a `var`) the entry
/// MUST keep `netClass: ["unknown-host"]` / MUST stay uncertifiable, and MUST NOT gain a fabricated
/// literal. `testFailClosed…` is the mirror of every `test…Extracts…` above it.
final class NetLocatorProvenanceProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: NetLocatorProvenanceProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    private func gate(_ src: String, policy: String) throws -> (out: String, err: String, code: Int32) {
        let bin = try ProcessHarness.binaryURL(for: NetLocatorProvenanceProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let policyFile = root.appendingPathComponent("policy.txt")
        try policy.write(to: policyFile, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--json", "--policy", policyFile.path])
    }

    private func hosts(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["hosts"] as? [String] ?? []).sorted()
    }
    private func cmds(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["cmds"] as? [String] ?? []).sorted()
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // MECHANISM 1 — CONSTRUCTOR UNWRAP. `URL(string: "…")` interposed between the literal and the call.
    // ────────────────────────────────────────────────────────────────────────────────────────────────

    /// THE MIRROR, WRITTEN FIRST. A URL built from a PARAMETER is not recoverable: the entry keeps Net,
    /// keeps `unknown-host`, and gains NO host. This is the case the mechanism must not reach.
    func testFailClosedComputedURLKeepsUnknownHost() throws {
        let by = try scan("""
        import Foundation
        func send(to h: String) {
            let t = URLSession.shared.dataTask(with: URL(string: h)!) { _, _, _ in }
            t.resume()
        }
        send(to: "x")
        """)
        XCTAssertEqual(hosts(by, "send"), [], "a parameter-built URL yields NO host — never fabricate")
        XCTAssertEqual(by["send"]?["netClass"] as? [String], ["unknown-host"],
                       "the destination is structurally invisible — the gate must stay fail-closed")
    }

    /// The mirror's second form: a RUNTIME-CONCATENATED URL whose authority is not statically complete.
    func testFailClosedInterpolatedAuthorityKeepsUnknownHost() throws {
        let by = try scan("""
        import Foundation
        func send(h: String) {
            let t = URLSession.shared.dataTask(with: URL(string: "https://\\(h)/v1/track")!) { _, _, _ in }
            t.resume()
        }
        send(h: "x")
        """)
        XCTAssertEqual(hosts(by, "send"), [], "an interpolated AUTHORITY is not a statically-known host")
        XCTAssertEqual(by["send"]?["netClass"] as? [String], ["unknown-host"])
    }

    /// A project's OWN `struct URL` shadows the Foundation ctor — the unwrap must not read a local type's
    /// argument as a network destination (the standing never-fabricate discipline for every κ shadow).
    func testFailClosedLocalURLTypeShadowsTheUnwrap() throws {
        let by = try scan("""
        import Foundation
        struct URL { let string: String; init(string: String) { self.string = string } }
        func send() {
            let c = NWConnection(host: "10.0.0.1", port: 9)
            c.start(queue: .main)
            _ = URL(string: "https://api.segment.io/x")
        }
        send()
        """)
        XCTAssertFalse(hosts(by, "send()").contains("api.segment.io"),
                       "a locally-declared URL type shadows the Foundation ctor — no host from its argument")
    }

    /// THE GAIN. An inline `URL(string:)` feeding `dataTask(with:)` names its destination.
    func testInlineURLCtorExtractsHost() throws {
        let by = try scan("""
        import Foundation
        func track() {
            let t = URLSession.shared.dataTask(with: URL(string: "https://api.segment.io/v1/track")!) { _, _, _ in }
            t.resume()
        }
        track()
        """)
        XCTAssertEqual(hosts(by, "track"), ["api.segment.io"])
        XCTAssertEqual(by["track"]?["netClass"] as? [String], ["known-telemetry"],
                       "⟨0.20⟩ the destination class follows from the host")
    }

    /// The async `data(from:)` form — the same interposition, a different establishing member.
    func testAsyncDataFromExtractsHost() throws {
        let by = try scan("""
        import Foundation
        func load() async throws {
            let (d, _) = try await URLSession.shared.data(from: URL(string: "https://example.com/x")!)
            _ = d
        }
        """)
        XCTAssertEqual(hosts(by, "load"), ["example.com"])
    }

    /// `URLRequest(url: URL(string:))` — TWO ctors between the literal and the call.
    func testNestedURLRequestExtractsHost() throws {
        let by = try scan("""
        import Foundation
        func post() {
            let t = URLSession.shared.dataTask(with: URLRequest(url: URL(string: "https://api.segment.io/v1/batch")!)) { _, _, _ in }
            t.resume()
        }
        post()
        """)
        XCTAssertEqual(hosts(by, "post"), ["api.segment.io"])
    }

    /// A `relativeTo:` base moves the authority OUT of the `string:` argument. Reading it anyway would
    /// FABRICATE the host `/v1/track` — so the unwrap refuses and the entry stays fail-closed. This is the
    /// case the companion-argument allowlist exists for.
    func testFailClosedRelativeToBaseRefusesTheUnwrap() throws {
        let by = try scan("""
        import Foundation
        func track(base: URL) {
            let t = URLSession.shared.dataTask(with: URL(string: "/v1/track", relativeTo: base)!) { _, _, _ in }
            t.resume()
        }
        """)
        XCTAssertEqual(hosts(by, "track"), [], "the authority lives in `base` — claim nothing")
        XCTAssertEqual(by["track"]?["netClass"] as? [String], ["unknown-host"])
    }

    /// §1 ⟨0.13⟩ FOLLOWS FOR FREE — a model host reached through the ctor classifies `Llm` as well as `Net`.
    func testModelHostThroughCtorClassifiesLlm() throws {
        let by = try scan("""
        import Foundation
        func ask() {
            let t = URLSession.shared.dataTask(with: URL(string: "https://api.openai.com/v1/chat")!) { _, _, _ in }
            t.resume()
        }
        ask()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "ask"), ["Llm", "Net"])
        XCTAssertEqual(hosts(by, "ask"), ["api.openai.com"])
    }

    /// …and the mirror of THAT: a non-model host through the same ctor must NOT classify `Llm`.
    func testNonModelHostThroughCtorIsNotLlm() throws {
        let by = try scan("""
        import Foundation
        func ping() {
            let t = URLSession.shared.dataTask(with: URL(string: "https://example.com/v1/chat")!) { _, _, _ in }
            t.resume()
        }
        ping()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "ping"), ["Net"], "a non-model host stays bare Net")
    }

    /// THE GATE CONSEQUENCE that motivates the whole suite: a narrowed `deny Net[known-telemetry]` read
    /// GREEN over a `URLSession` call to a telemetry host. It must now be RED.
    func testDenyTelemetryCatchesURLSessionCall() throws {
        let r = try gate("""
        import Foundation
        func track() {
            let t = URLSession.shared.dataTask(with: URL(string: "https://api.segment.io/v1/track")!) { _, _, _ in }
            t.resume()
        }
        track()
        """, policy: "deny Net[known-telemetry]")
        XCTAssertEqual(r.code, 1, "the narrowed deny must FIRE — stdout: \(r.out) stderr: \(r.err)")
    }

    /// …and the mirror: the SAME policy over an INVISIBLE destination must not fire on the class it cannot
    /// see (`unknown-host` is not `known-telemetry`), which is exactly why the extraction had to be sound.
    func testDenyTelemetryDoesNotFireOnUnknownHost() throws {
        let r = try gate("""
        import Foundation
        func send(to h: String) {
            let t = URLSession.shared.dataTask(with: URL(string: h)!) { _, _, _ in }
            t.resume()
        }
        send(to: "x")
        """, policy: "deny Net[known-telemetry]")
        XCTAssertEqual(r.code, 0, "an unknown host is not the telemetry class — stdout: \(r.out)")
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // MECHANISM 2 — LOCAL-BINDER PROVENANCE. `let u = URL(string: "…")!` then used at the call.
    // ────────────────────────────────────────────────────────────────────────────────────────────────

    /// THE MIRROR, FIRST. A `var` is reassignable, so its value at the call site is not the one we saw
    /// bound — no literal claim (the same discipline the const-string index already applies to strings).
    func testFailClosedVarURLBinderKeepsUnknownHost() throws {
        let by = try scan("""
        import Foundation
        func send(h: String) {
            var u = URL(string: "https://api.segment.io/v1/track")!
            u = URL(string: h)!
            let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
            t.resume()
        }
        send(h: "x")
        """)
        XCTAssertEqual(hosts(by, "send"), [], "a reassignable binder carries no literal claim")
        XCTAssertEqual(by["send"]?["netClass"] as? [String], ["unknown-host"])
    }

    /// The mirror's second form: a `let` bound from a PARAMETER-built URL stays invisible.
    func testFailClosedLetBoundFromParameterKeepsUnknownHost() throws {
        let by = try scan("""
        import Foundation
        func send(h: String) {
            let u = URL(string: h)!
            let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
            t.resume()
        }
        send(h: "x")
        """)
        XCTAssertEqual(hosts(by, "send"), [])
        XCTAssertEqual(by["send"]?["netClass"] as? [String], ["unknown-host"])
    }

    /// THE GAIN. `let u = URL(string: "…")!` then `dataTask(with: u)`.
    func testLetBoundURLExtractsHost() throws {
        let by = try scan("""
        import Foundation
        func track() {
            let u = URL(string: "https://api.segment.io/v1/track")!
            let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
            t.resume()
        }
        track()
        """)
        XCTAssertEqual(hosts(by, "track"), ["api.segment.io"])
        XCTAssertEqual(by["track"]?["netClass"] as? [String], ["known-telemetry"])
    }

    /// The const-anchored spelling composes: a `let` URL built from a module const resolves the same way
    /// the direct-literal Net path already did (PART 4q), now through the ctor.
    func testConstAnchoredURLBinderExtractsHost() throws {
        let by = try scan("""
        import Foundation
        let apiBase = "https://api.openai.com"
        func ask() {
            let u = URL(string: apiBase + "/v1/chat")!
            let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
            t.resume()
        }
        ask()
        """)
        XCTAssertEqual(hosts(by, "ask"), ["api.openai.com"])
        XCTAssertEqual(ProcessHarness.inferred(by, "ask"), ["Llm", "Net"])
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // MECHANISM 3 — PROPERTY-ASSIGNMENT PROVENANCE. `p.launchPath = "/bin/sh"` then `p.run()`.
    // ────────────────────────────────────────────────────────────────────────────────────────────────

    /// THE MIRROR, FIRST. A runtime command must stay UNCERTIFIABLE: `allow Exec` fails closed, because a
    /// certified `allow` over an invisible command is precisely the gate-evasion AS-EFF-008 exists to stop.
    func testFailClosedRuntimeLaunchPathStaysUncertifiable() throws {
        let src = """
        import Foundation
        func spawn(cmd: String) throws {
            let p = Process()
            p.launchPath = cmd
            try p.run()
        }
        try? spawn(cmd: "/bin/ls")
        """
        let by = try scan(src)
        XCTAssertEqual(cmds(by, "spawn"), [], "a parameter command yields NO cmd — never fabricate")
        let r = try gate(src, policy: "allow Exec /bin/sh")
        XCTAssertEqual(r.code, 1, "an invisible command cannot be certified — stdout: \(r.out)")
    }

    /// The mirror's second form: a `var` Process handle rebound between the write and the run.
    func testFailClosedRebindProcessHandleStaysUncertifiable() throws {
        let by = try scan("""
        import Foundation
        func spawn(other: Process) throws {
            var p = Process()
            p.launchPath = "/bin/sh"
            p = other
            try p.run()
        }
        """)
        XCTAssertEqual(cmds(by, "spawn"), [],
                       "the handle was rebound — the earlier write does not describe what runs")
    }

    /// THE GAIN. `launchPath` (the legacy spelling) then `run()`.
    func testLaunchPathExtractsCmd() throws {
        let src = """
        import Foundation
        func spawn() throws {
            let p = Process()
            p.launchPath = "/bin/sh"
            p.arguments = ["-c", "echo hi"]
            try p.run()
        }
        try? spawn()
        """
        let by = try scan(src)
        XCTAssertEqual(cmds(by, "spawn"), ["/bin/sh"])
        let r = try gate(src, policy: "allow Exec /bin/sh")
        XCTAssertEqual(r.code, 0, "a visible command certifies — stdout: \(r.out) stderr: \(r.err)")
    }

    /// `executableURL` (the modern spelling) — the locator arrives through the mechanism-1 ctor unwrap.
    func testExecutableURLExtractsCmd() throws {
        let by = try scan("""
        import Foundation
        func spawn() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            try p.run()
        }
        try? spawn()
        """)
        XCTAssertEqual(cmds(by, "spawn"), ["/usr/bin/env"])
    }

    /// The command-head refinement rides along: a visible `curl` reaches Net, exactly as it does for the
    /// already-supported `posix_spawn("curl …")` form (`classifyCommandHead`).
    func testCommandHeadRefinementFollows() throws {
        let by = try scan("""
        import Foundation
        func spawn() throws {
            let p = Process()
            p.launchPath = "/usr/bin/curl"
            try p.run()
        }
        try? spawn()
        """)
        XCTAssertTrue((ProcessHarness.inferred(by, "spawn") ?? []).contains("Net"),
                      "a visible curl head refines Exec with Net")
    }

    /// …and the mirror of the certification: the SAME `allow Exec` must REJECT a command outside its list.
    func testAllowExecRejectsUnlistedCommand() throws {
        let r = try gate("""
        import Foundation
        func spawn() throws {
            let p = Process()
            p.launchPath = "/bin/rm"
            try p.run()
        }
        try? spawn()
        """, policy: "allow Exec /bin/sh")
        XCTAssertEqual(r.code, 1, "a visible but unlisted command is a violation — stdout: \(r.out)")
    }
}
