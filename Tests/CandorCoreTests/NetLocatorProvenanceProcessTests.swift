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

    /// THE DOMINANT POST IDIOM, and the reason a `var` binder is admitted at all: `URLRequest` cannot be
    /// configured without mutation. The writes here are all on the inert allowlist, so the locator stands.
    func testVarRequestBinderWithInertMutationExtractsHost() throws {
        let by = try scan("""
        import Foundation
        func post(body: Data) async throws {
            var req = URLRequest(url: URL(string: "https://api.segment.io/v1/batch")!)
            req.httpMethod = "POST"
            req.httpBody = body
            req.timeoutInterval = 30
            _ = try await URLSession.shared.data(for: req)
        }
        """)
        XCTAssertEqual(hosts(by, "post"), ["api.segment.io"])
        XCTAssertEqual(by["post"]?["netClass"] as? [String], ["known-telemetry"])
    }

    /// THE MIRROR OF THAT ALLOWLIST. `req.url` is the one write that DOES move the destination — the entry
    /// must fall back to fail-closed rather than keep naming the host it was built with.
    func testFailClosedRequestURLRewriteKeepsUnknownHost() throws {
        let by = try scan("""
        import Foundation
        func post(other: URL) async throws {
            var req = URLRequest(url: URL(string: "https://api.segment.io/v1/batch")!)
            req.url = other
            _ = try await URLSession.shared.data(for: req)
        }
        """)
        XCTAssertEqual(hosts(by, "post"), [], "the destination was rewritten — the built host is stale")
        XCTAssertEqual(by["post"]?["netClass"] as? [String], ["unknown-host"])
    }

    /// An `inout` pass hands the callee a reference it may write through.
    func testFailClosedInoutPassKeepsUnknownHost() throws {
        let by = try scan("""
        import Foundation
        func retarget(_ r: inout URLRequest) { r.url = URL(string: "https://evil.example/") }
        func post() async throws {
            var req = URLRequest(url: URL(string: "https://api.segment.io/v1/batch")!)
            retarget(&req)
            _ = try await URLSession.shared.data(for: req)
        }
        """)
        XCTAssertEqual(hosts(by, "post"), [], "the callee may have moved the locator")
    }

    /// THE FLOW-INSENSITIVITY MIRROR — the case the pre-pass exists for. The rebind sits AFTER the call in
    /// the text but BEFORE it in time on the second iteration, so a source-order-only rule would have left a
    /// literal standing for a request the program never sends to that host.
    func testFailClosedLoopCarriedRebindKeepsUnknownHost() throws {
        let by = try scan("""
        import Foundation
        func drain(next: [URL]) async throws {
            var u = URL(string: "https://api.segment.io/v1/batch")!
            for n in next {
                _ = try await URLSession.shared.data(from: u)
                u = n
            }
        }
        """)
        XCTAssertEqual(hosts(by, "drain"), [], "a loop-carried rebind invalidates the binding for the whole body")
        XCTAssertEqual(by["drain"]?["netClass"] as? [String], ["unknown-host"])
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

    /// THE MASKING MIRROR — the reason the launching verb marks `Exec` INCOMPLETE when it cannot read the
    /// program. Before this mechanism the surface was always empty and `allow Exec` failed closed by
    /// accident; the moment a literal can be captured, a benign visible `/bin/sh` would otherwise COVER
    /// for the runtime program spawned beside it and certify the whole function. That is the AS-EFF-008
    /// gate-evasion, and it is the specific way this work could have made the gate quieter.
    func testFailClosedVisibleCommandCannotMaskAnInvisibleOne() throws {
        let src = """
        import Foundation
        func spawn(cmd: String) throws {
            let a = Process()
            a.launchPath = "/bin/sh"
            try a.run()
            let b = Process()
            b.launchPath = cmd
            try b.run()
        }
        try? spawn(cmd: "/bin/ls")
        """
        let by = try scan(src)
        XCTAssertEqual(cmds(by, "spawn"), ["/bin/sh"], "the visible half is still reported")
        let r = try gate(src, policy: "allow Exec /bin/sh")
        XCTAssertEqual(r.code, 1, "the invisible sibling cannot be masked by the visible literal")
        XCTAssertTrue(r.out.contains("structurally-invisible") || r.err.contains("structurally-invisible"),
                      "the masking case has its own AS-EFF-008 wording — got: \(r.out)")
    }

    /// …and the TRANSITIVE form: the invisible spawn sits in a callee. Incompleteness propagates the same
    /// way the literal surface does, so the caller cannot be certified either.
    func testFailClosedInvisibleCommandInCalleeBlocksCallerCertification() throws {
        let r = try gate("""
        import Foundation
        func hidden(cmd: String) throws {
            let p = Process()
            p.launchPath = cmd
            try p.run()
        }
        func caller(cmd: String) throws {
            let p = Process()
            p.launchPath = "/bin/sh"
            try p.run()
            try hidden(cmd: cmd)
        }
        try? caller(cmd: "/bin/ls")
        """, policy: "allow Exec /bin/sh")
        XCTAssertEqual(r.code, 1, "the callee's invisible command reaches the caller — stdout: \(r.out)")
    }

    /// Two literal writes to the same handle over-approximate to BOTH programs — the union is the sound
    /// direction, and neither is dropped in favour of the other.
    func testTwoLiteralWritesRecordBothCommands() throws {
        let by = try scan("""
        import Foundation
        func spawn(useShell: Bool) throws {
            let p = Process()
            if useShell { p.launchPath = "/bin/sh" } else { p.launchPath = "/bin/zsh" }
            try p.run()
        }
        try? spawn(useShell: true)
        """)
        XCTAssertEqual(cmds(by, "spawn"), ["/bin/sh", "/bin/zsh"])
    }

    /// THE FIXTURE THE A/B WROTE. A `SequenceExpr` is FLAT — the parser gives `p.launchPath = "/usr/bin/"
    /// + tool` as [lhs, =, "/usr/bin/", +, tool] — so reading the element after the `=` yielded the literal
    /// `"/usr/bin/"` and reported it as the program. `allow Exec /usr/bin/` would then have certified an
    /// entirely runtime command. Twenty-five fixtures passed through that; a negative control in the
    /// corpus A/B caught it. The concatenation must resolve to NOTHING.
    func testFailClosedConcatenatedLaunchPathClaimsNoCommand() throws {
        let src = """
        import Foundation
        func spawn(tool: String) throws {
            let p = Process()
            p.launchPath = "/usr/bin/" + tool
            try p.run()
        }
        try? spawn(tool: "git")
        """
        let by = try scan(src)
        XCTAssertEqual(cmds(by, "spawn"), [], "a runtime-completed path names no program")
        let r = try gate(src, policy: "allow Exec /usr/bin/")
        XCTAssertEqual(r.code, 1, "the literal PREFIX must not certify the whole command — stdout: \(r.out)")
    }

    /// The same shape with a genuine const head DOES resolve — the refusal above is about the runtime
    /// tail, not about concatenation as such.
    func testConstAnchoredConcatenatedLaunchPathExtractsCmd() throws {
        let by = try scan("""
        import Foundation
        let binDir = "/usr/bin"
        func spawn() throws {
            let p = Process()
            p.launchPath = binDir + "/git"
            try p.run()
        }
        try? spawn()
        """)
        XCTAssertEqual(cmds(by, "spawn"), ["/usr/bin/git"])
    }

    /// The interpolated sibling of the same hazard.
    func testFailClosedInterpolatedLaunchPathClaimsNoCommand() throws {
        let by = try scan("""
        import Foundation
        func spawn(tool: String) throws {
            let p = Process()
            p.launchPath = "/usr/bin/\\(tool)"
            try p.run()
        }
        try? spawn(tool: "git")
        """)
        XCTAssertEqual(cmds(by, "spawn"), [])
    }

    /// A `Process` held in a FIELD is not tracked by the local-binder mechanism, and must therefore stay
    /// fail-closed rather than fall through to a certifiable empty surface.
    func testFailClosedFieldHeldProcessStaysUncertifiable() throws {
        let r = try gate("""
        import Foundation
        final class Runner {
            let p = Process()
            func go() throws {
                p.launchPath = "/bin/sh"
                try p.run()
            }
        }
        try? Runner().go()
        """, policy: "allow Exec /bin/sh")
        XCTAssertEqual(r.code, 1, "a field-held handle is outside the mechanism — claim nothing")
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // THE SHADOW BINDER. A `let p` inside a block is a DIFFERENT binding from the outer `p`, and the
    // exec maps are keyed by NAME. `movedNames` does not see it (a shadow is not a reassignment) and
    // `execLocatorInvisible` does not see it either when the outer handle takes no write at all — so
    // the inner literal stood under the outer name and was reported at the outer launch.
    // ────────────────────────────────────────────────────────────────────────────────────────────────

    /// THE FABRICATION. The launched program comes from the factory; `/bin/phantom` is written to a
    /// binding that is never launched. Reporting it would let `allow Exec /bin/phantom` certify the call.
    func testFailClosedShadowedProcessBinderClaimsNoCommand() throws {
        let by = try scan("""
        import Foundation
        func spawn(make: () -> Process) {
            let p = make()
            if true { let p = Process(); p.launchPath = "/bin/phantom"; _ = p }
            p.launch()
        }
        spawn(make: { Process() })
        """)
        XCTAssertEqual(cmds(by, "spawn"), [],
                       "the inner binding's literal is not the outer handle's program — never fabricate")
    }

    /// …and the gate half: the surface is INCOMPLETE, not empty-and-certifiable.
    func testFailClosedShadowedProcessBinderIsUncertifiable() throws {
        let r = try gate("""
        import Foundation
        func spawn(make: () -> Process) {
            let p = make()
            if true { let p = Process(); p.launchPath = "/bin/phantom"; _ = p }
            p.launch()
        }
        spawn(make: { Process() })
        """, policy: "allow Exec /bin/phantom")
        XCTAssertEqual(r.code, 1, "an unreadable locator must not be certifiable under the shadow's literal")
    }

    /// The PARAMETER form of the same shadow — the outer binder is in the signature, which the body walk
    /// cannot see, so the parameter names travel with the pre-pass.
    func testFailClosedShadowedProcessParameterClaimsNoCommand() throws {
        let by = try scan("""
        import Foundation
        func spawn(p: Process) {
            if true { let p = Process(); p.launchPath = "/bin/phantom"; _ = p }
            p.launch()
        }
        spawn(p: Process())
        """)
        XCTAssertEqual(cmds(by, "spawn"), [], "a body binder shadowing a parameter is the same hazard")
    }

    /// THE MIRROR OF THE REFUSAL, and the reason it is a binder count and not a scope restore. ONE
    /// binder, the locator written inside a conditional block: this is the program the handle runs, and
    /// a rule that dropped writes made inside a nested scope would delete it.
    func testConditionalLaunchPathWriteStillExtractsCmd() throws {
        let by = try scan("""
        import Foundation
        func spawn(flag: Bool) {
            let p = Process()
            if flag { p.launchPath = "/bin/ls" }
            p.launch()
        }
        spawn(flag: true)
        """)
        XCTAssertEqual(cmds(by, "spawn"), ["/bin/ls"],
                       "one binder — a write inside a block is still this handle's program")
    }

    /// THE PRICE, PINNED. Two DISJOINT bindings can share a name (sibling branches), and the refusal is
    /// a binder COUNT, so it drops both of their commands even though `cmds` is a per-FUNCTION surface on
    /// which the union would have been right. Measured cost of the coarse rule: zero rows across five
    /// real packages (pollen, applike, AppTarget, candor-swift, swift-syntax — 8.6k functions), and this
    /// shape. Recorded as a test rather than a comment so that a future scope-aware refinement shows up
    /// here as a deliberate change instead of passing unnoticed.
    func testKnownCostSiblingScopeHandlesShareANameAndBothAreRefused() throws {
        let by = try scan("""
        import Foundation
        func spawn(flag: Bool) {
            if flag {
                let p = Process()
                p.launchPath = "/bin/a"
                p.launch()
            } else {
                let p = Process()
                p.launchPath = "/bin/b"
                p.launch()
            }
        }
        spawn(flag: true)
        """)
        XCTAssertEqual(cmds(by, "spawn"), [],
                       "the coarse binder count cannot tell a shadow from a disjoint reuse of the name")
    }
}
