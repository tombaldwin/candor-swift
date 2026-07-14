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
