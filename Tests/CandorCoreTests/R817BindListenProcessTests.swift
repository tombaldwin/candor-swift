import XCTest
import Foundation

/// SPEC §2 ⟨0.40⟩ — SOUNDNESS R817 / R949, swift's NIO bootstraps. PART 96's swift arms plus the
/// server-bootstrap accept, the NIO ephemeral client and a literal bind beside a benign literal. Each arm is
/// one package with one function `f`; `CANDOR_R817_OFF=1` restores the establishing reading (§1b), under
/// which the four defect rows go back to what PART 96 declared as swift's xfails.
///
/// EXECUTED (`swiftagent-r910/r817/exec`): an `NWListener` accepted a connection and read `hello-r817` from
/// a peer the listener did not choose; an ephemeral UDP client bound to port 0 sent to a literal address.
final class R817BindListenProcessTests: XCTestCase {
    static let benign = "ok.example"
    static let arms: [(name: String, body: String, allow: String, want: Int32)] = [
        // a_litbind — the literal bind is not a destination; the empty surface fails closed
        ("a_litbind", "import NIOCore\nimport NIOPosix\npublic func f(_ g: EventLoopGroup) { _ = DatagramBootstrap(group: g).bind(host: \"10.0.0.5\", port: 9) }",
         "10.0.0.5", 1),
        // b_rtbind — a bind over an already-resolved address marks nothing (CONTROL)
        ("b_rtbind", "import Network\nimport NIOCore\nimport NIOPosix\npublic func f(_ g: EventLoopGroup, _ a: SocketAddress) { _ = NWConnection(host: \"\(benign)\", port: 80, using: .tcp); _ = DatagramBootstrap(group: g).bind(to: a) }",
         benign, 0),
        // e_rtname — a bind handed a runtime NAME resolves it (R949), KEPT through the change
        ("e_rtname", "import Network\nimport NIOCore\nimport NIOPosix\npublic func f(_ g: EventLoopGroup, _ h: String) { _ = NWConnection(host: \"\(benign)\", port: 80, using: .tcp); _ = DatagramBootstrap(group: g).bind(host: h, port: 0) }",
         benign, 1),
        // x_srvlit — a ServerBootstrap bind ACCEPTS: incomplete whatever the address
        ("x_srvlit", "import Network\nimport NIOCore\nimport NIOPosix\npublic func f(_ g: EventLoopGroup) { _ = NWConnection(host: \"\(benign)\", port: 80, using: .tcp); _ = ServerBootstrap(group: g).bind(host: \"0.0.0.0\", port: 8080) }",
         benign, 1),
        // x_srvaddr — …and over a resolved address too
        ("x_srvaddr", "import Network\nimport NIOCore\nimport NIOPosix\npublic func f(_ g: EventLoopGroup, _ a: SocketAddress) { _ = NWConnection(host: \"\(benign)\", port: 80, using: .tcp); _ = ServerBootstrap(group: g).bind(to: a) }",
         benign, 1),
        // x_niocli — the NIO ephemeral client: the connect carries the locator, the bind marks nothing (CONTROL)
        ("x_niocli", "import NIOCore\nimport NIOPosix\npublic func f(_ g: EventLoopGroup, _ a: SocketAddress) { let b: ClientBootstrap = ClientBootstrap(group: g).bind(to: a); _ = b.connect(host: \"10.9.9.9\", port: 53) }",
         "10.9.9.9", 0),
        // x_litbeside — a literal bind beside a benign literal reaches nothing else (CONTROL)
        ("x_litbeside", "import Network\nimport NIOCore\nimport NIOPosix\npublic func f(_ g: EventLoopGroup) { _ = NWConnection(host: \"\(benign)\", port: 80, using: .tcp); _ = DatagramBootstrap(group: g).bind(host: \"10.0.0.5\", port: 9) }",
         benign, 0),
        // c_accept — the Network.framework accept, already conformant (kept)
        ("c_accept", "import Network\npublic func f() { _ = NWConnection(host: \"\(benign)\", port: 80, using: .tcp); _ = try? NWListener(using: .tcp, on: 8080) }",
         benign, 1),
    ]

    private func scan(_ root: URL, policy: String? = nil, env: [String: String] = [:]) throws -> (Int32, [String: Any]?) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        var args = [root.path, "--json"]
        if let policy {
            let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
            try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
            args += ["--policy", pf.path]
        }
        let r = try ProcessHarness.run(bin, args, env: env)
        let d = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        let row = (d?["functions"] as? [[String: Any]])?.first { ($0["fn"] as? String).map { $0 == "f" || $0.hasSuffix(".f") } ?? false }
        return (r.code, row)
    }

    func testTheArms() throws {
        for arm in Self.arms {
            let root = try ProcessHarness.makeFilesPackage(["a.swift": arm.body], name: "T")
            defer { try? FileManager.default.removeItem(at: root) }
            // REACH: the row exists, carries Net, and `deny Net` fails on these bytes
            let (_, row) = try scan(root)
            let r = try XCTUnwrap(row, "\(arm.name): `f` absent — the fixture never reached the engine")
            XCTAssertTrue((r["inferred"] as? [String] ?? []).contains("Net"), "\(arm.name): no Net")
            XCTAssertEqual(try scan(root, policy: "deny Net").0, 1, "\(arm.name): the gate is not shown able to fail")
            let hosts = r["hosts"] as? [String] ?? []
            XCTAssertFalse(hosts.contains { ["10.0.0.5", "0.0.0.0"].contains(String($0.prefix { $0 != ":" })) },
                           "\(arm.name): a bind/listen address entered `hosts`: \(hosts)")
            XCTAssertEqual(try scan(root, policy: "allow Net \(arm.allow)").0, arm.want, "\(arm.name): `allow Net \(arm.allow)`")
        }
    }

    /// §1b — the switch restores the reading PART 96 declared as swift's xfails, so the rows above can fail.
    func testTheSwitchRestoresTheEstablishingReading() throws {
        let off = ["CANDOR_R817_OFF": "1"]
        for (name, policy, released) in [("a_litbind", "allow Net 10.0.0.5", Int32(0)), ("b_rtbind", "allow Net \(Self.benign)", 1),
                                         ("x_niocli", "allow Net 10.9.9.9", 1), ("x_litbeside", "allow Net \(Self.benign)", 1)] {
            let arm = try XCTUnwrap(Self.arms.first { $0.name == name })
            let root = try ProcessHarness.makeFilesPackage(["a.swift": arm.body], name: "T")
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertEqual(try scan(root, policy: policy, env: off).0, released, "\(name) under CANDOR_R817_OFF")
        }
    }
}
