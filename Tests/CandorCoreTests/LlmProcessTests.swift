import XCTest
import Foundation

/// End-to-end pins for the SPEC §1 ⟨0.13⟩ `Llm` effect — the model-provider boundary that refines Net the
/// way Db does. Two classification sources (a model-host literal on a Net call; a model-SDK client type)
/// both keep Net, and `Llm` is a first-class boundary effect in the policy grammar (`deny Llm`, `allow Llm`)
/// and the surface. These are properties of the whole scan + gate, so they are pinned at the process layer
/// (mirrors GateProcessTests / KappaFamiliesProcessTests). Parity target: candor-java's Llm reference.
final class LlmProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: LlmProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    /// Run a scan + `--policy` gate over `src`, returning the process result.
    private func gate(_ src: String, policy: String) throws -> (out: String, err: String, code: Int32) {
        let bin = try ProcessHarness.binaryURL(for: LlmProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let policyFile = root.appendingPathComponent("policy.txt")
        try policy.write(to: policyFile, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--json", "--policy", policyFile.path])
    }

    // ── (a) HOST-LITERAL refinement: a model host on a Net call classifies {Net, Llm}; Net never dropped ──
    func testModelHostLiteralRefinesToLlm() throws {
        let by = try scan("""
        import Foundation
        struct Chat {
            func ask() {
                let t = URLSession.shared.dataTask(with: "https://api.anthropic.com/v1/messages") { _, _, _ in }
                t.resume()
            }
        }
        Chat().ask()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Chat.ask"), ["Llm", "Net"],
                       "a request to api.anthropic.com is Llm AND Net (Net never dropped)")
        // the model host is still captured as the Net host surface (Llm rides Net's literal).
        XCTAssertEqual(by["Chat.ask"]?["hosts"] as? [String], ["api.anthropic.com"])
    }

    // an UNKNOWN host stays bare Net — never guessed.
    func testUnknownHostStaysBareNet() throws {
        let by = try scan("""
        import Foundation
        struct Api {
            func call() {
                let t = URLSession.shared.dataTask(with: "https://api.stripe.com/v1/charges") { _, _, _ in }
                t.resume()
            }
        }
        Api().call()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Api.call"), ["Net"],
                       "an unknown host is bare Net — no Llm guess")
    }

    // Ollama's local endpoint (:11434) → Llm WITHOUT capturing the dotless host as a Net literal.
    func testOllamaLocalEndpointIsLlmWithoutHostLiteral() throws {
        let by = try scan("""
        import Foundation
        import Network
        struct Local {
            func run() {
                let c = NWConnection(host: "localhost", port: 11434, using: .tcp)
                c.start(queue: .main)
            }
        }
        Local().run()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Local.run"), ["Llm", "Net"],
                       "localhost:11434 is the local Ollama model endpoint → Llm + Net")
        // parity decision #2: the dotless Ollama host is NOT captured as a Net/Llm security literal, so
        // `allow Llm localhost` has no surface to certify → fails closed (asserted in the gate test below).
        XCTAssertNil(by["Local.run"]?["hosts"], "the dotless Ollama host must not become a Net literal")
    }

    // ── (b) MODEL-SDK surface: any call into a curated model client is {Llm, Net} (no method-name gating) ──
    func testModelSdkSurfaceRefinesToLlm() throws {
        let by = try scan("""
        import Foundation
        import OpenAI
        struct Assistant {
            let client = OpenAI(apiToken: "sk-x")
            func summarize() {
                _ = client.chats(query: .init())
            }
        }
        Assistant().summarize()
        """)
        // the ctor `OpenAI(apiToken:)` and the `client.chats(...)` member both classify Llm + Net.
        XCTAssertEqual(ProcessHarness.inferred(by, "Assistant.summarize"), ["Llm", "Net"],
                       "a call into the OpenAI model client is Llm + Net")
    }

    // a project's OWN type named like a model client shadows the κ table — never a fabrication.
    func testProjectTypeShadowingModelSdkNameStaysPure() throws {
        let by = try scan("""
        import Foundation
        struct OpenAI { func chats() {} }
        func local() { let c = OpenAI(); c.chats() }
        """)
        XCTAssertNil(by["local"], "a project's own OpenAI type is not a model client — classifying it fabricates")
    }

    // ── deny Llm gates a model-reaching function (exit 1; the diagnostic names Llm) ──────────────────
    func testDenyLlmGatesModelReach() throws {
        let r = try gate("""
        import Foundation
        struct Chat {
            func ask() {
                let t = URLSession.shared.dataTask(with: "https://api.openai.com/v1/chat/completions") { _, _, _ in }
                t.resume()
            }
        }
        Chat().ask()
        """, policy: "deny Llm\n")
        XCTAssertEqual(r.code, 1, "deny Llm must gate a model-reaching function — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-006") && r.err.contains("Llm"),
                      "the deny diagnostic must name Llm; stderr: \(r.err)")
    }

    // a plain (non-model) Net function is NOT caught by `deny Llm` — the refinement is specific.
    func testDenyLlmDoesNotGatePlainNet() throws {
        let r = try gate("""
        import Foundation
        struct Api {
            func call() {
                let t = URLSession.shared.dataTask(with: "https://api.stripe.com/v1/charges") { _, _, _ in }
                t.resume()
            }
        }
        Api().call()
        """, policy: "deny Llm\n")
        XCTAssertEqual(r.code, 0, "a non-model Net call carries no Llm — deny Llm must pass; stderr: \(r.err)")
    }

    // ── allow Llm: a masked model host fails CLOSED (its incompleteness keys off Net's) ──────────────
    func testAllowLlmMaskedModelHostFailsClosed() throws {
        // one VISIBLE model host (covered by the allowlist) coexists with a runtime (invisible) host on the
        // same establishing surface — the visible literal must not mask the invisible one (parity decision #3).
        let r = try gate("""
        import Foundation
        struct Chat {
            func ask(_ runtime: String) {
                let a = URLSession.shared.dataTask(with: "https://api.openai.com/v1/chat") { _, _, _ in }
                a.resume()
                let b = URLSession.shared.dataTask(with: runtime) { _, _, _ in }   // invisible host
                b.resume()
            }
        }
        Chat().ask("x")
        """, policy: "allow Llm api.openai.com\n")
        XCTAssertEqual(r.code, 1, "a masked (runtime) model host must fail allow Llm closed — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-008"), "expected the allowlist masking violation; stderr: \(r.err)")
    }

    // ── CONST-STRING PROPAGATION: a const-anchored model host resolves to Llm (parity with candor-java) ──
    // A module/global `let apiBase = "…"` used via interpolation is the STATICALLY-KNOWN host — SPEC §1
    // classifies Llm exactly as an inline literal does. Under-conformance before this: it read bare Net.
    func testConstStringInterpolationResolvesModelHost() throws {
        let by = try scan("""
        import Foundation
        let apiBase = "https://api.openai.com/v1"
        func call() { _ = URLSession.shared.dataTask(with: "\\(apiBase)/chat") { _, _, _ in } }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "call"), ["Llm", "Net"],
                       "a const-anchored interpolation of a model host is Llm + Net")
        XCTAssertEqual(by["call"]?["hosts"] as? [String], ["api.openai.com"],
                       "the resolved const host is captured as the Net literal")
    }

    // a BARE const reference (`dataTask(with: apiBase)`) resolves identically.
    func testConstStringBareReferenceResolvesModelHost() throws {
        let by = try scan("""
        import Foundation
        let apiBase = "https://api.openai.com/v1"
        func call() { _ = URLSession.shared.dataTask(with: apiBase) { _, _, _ in } }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "call"), ["Llm", "Net"],
                       "a bare const reference to a model host is Llm + Net")
        XCTAssertEqual(by["call"]?["hosts"] as? [String], ["api.openai.com"])
    }

    // a CONCATENATION with a const-string left operand (`apiBase + "/chat"`) resolves too.
    func testConstStringConcatResolvesModelHost() throws {
        let by = try scan("""
        import Foundation
        let apiBase = "https://api.openai.com"
        func call() { _ = URLSession.shared.dataTask(with: apiBase + "/chat") { _, _, _ in } }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "call"), ["Llm", "Net"],
                       "a const-left concatenation of a model host is Llm + Net")
        XCTAssertEqual(by["call"]?["hosts"] as? [String], ["api.openai.com"])
    }

    // a LOCAL `let` const (bound inside the same fn body) resolves as well.
    func testLocalConstStringResolvesModelHost() throws {
        let by = try scan("""
        import Foundation
        func call() {
            let base = "https://api.openai.com/v1"
            _ = URLSession.shared.dataTask(with: "\\(base)/chat") { _, _, _ in }
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "call"), ["Llm", "Net"],
                       "a local let string constant anchors the resolved model host")
        XCTAssertEqual(by["call"]?["hosts"] as? [String], ["api.openai.com"])
    }

    // ── CONST-STRING FABRICATION GUARDS: none of these may fabricate Llm — they stay bare Net ────────────
    func testConstStringGuardsNeverFabricateLlm() throws {
        // (1) a non-model const host (`cdn`) — bare/interpolation/concat all stay Net, host cdn.example.com.
        let cdn = try scan("""
        import Foundation
        let cdn = "https://cdn.example.com"
        func interp() { _ = URLSession.shared.dataTask(with: "\\(cdn)/asset") { _, _, _ in } }
        func bare()   { _ = URLSession.shared.dataTask(with: cdn) { _, _, _ in } }
        func concat() { _ = URLSession.shared.dataTask(with: cdn + "/x") { _, _, _ in } }
        """)
        for fn in ["interp", "bare", "concat"] {
            XCTAssertEqual(ProcessHarness.inferred(cdn, fn), ["Net"],
                           "\(fn): a non-model const host must stay bare Net, never Llm")
            XCTAssertEqual(cdn[fn]?["hosts"] as? [String], ["cdn.example.com"])
        }

        // (2) a RUNTIME host (function result) — indeterminate, must not resolve.
        let runtime = try scan("""
        import Foundation
        func config() -> String { return "https://api.openai.com" }
        func call() { let h = config(); _ = URLSession.shared.dataTask(with: "\\(h)/x") { _, _, _ in } }
        """)
        XCTAssertEqual(ProcessHarness.inferred(runtime, "call"), ["Net"],
                       "a runtime host (fn result) must not resolve → bare Net, no Llm")
        XCTAssertNil(runtime["call"]?["hosts"], "an unresolved runtime host captures no literal")

        // (3) a `var` (reassignable) — never treated as a constant.
        let mut = try scan("""
        import Foundation
        var mutBase = "https://api.openai.com"
        func call() { _ = URLSession.shared.dataTask(with: "\\(mutBase)/x") { _, _, _ in } }
        """)
        XCTAssertEqual(ProcessHarness.inferred(mut, "call"), ["Net"],
                       "a var could be reassigned — must not resolve → bare Net, no Llm")
        XCTAssertNil(mut["call"]?["hosts"])

        // (4) an interpolation whose FIRST segment is a LITERAL prefix (the host is the interpolated part,
        // not the const) — must not treat the interpolated tail as a const-anchored host.
        let prefix = try scan("""
        import Foundation
        let suffix = "openai.com"
        func call() { _ = URLSession.shared.dataTask(with: "https://api.\\(suffix)/x") { _, _, _ in } }
        """)
        XCTAssertEqual(ProcessHarness.inferred(prefix, "call"), ["Net"],
                       "a literal prefix before the interpolation is not const-anchored → bare Net")
        XCTAssertNil(prefix["call"]?["hosts"])
    }

    // the positive: allow Llm certifies a scope whose only model host is the allowed one.
    func testAllowLlmCertifiesAllowedModelHost() throws {
        let r = try gate("""
        import Foundation
        struct Chat {
            func ask() {
                let t = URLSession.shared.dataTask(with: "https://api.openai.com/v1/chat") { _, _, _ in }
                t.resume()
            }
        }
        Chat().ask()
        """, policy: "allow Llm api.openai.com\n")
        XCTAssertEqual(r.code, 0, "allow Llm api.openai.com must certify the sole model host — stderr: \(r.err)")
    }
}
