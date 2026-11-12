import XCTest
import Foundation

/// SOUNDNESS R1714 / R1729 — **A `#if` TYPEALIAS ARM BESIDE A `#if` DECLARATION OF THE SAME NAME RESOLVED TO
/// THE DECLARATION ALONE.** SPEC ⟨0.42⟩ (§4, after ⟨0.38⟩'s `use … as X` paragraph): a binding arm and a
/// declaration arm of one name are ONE arm set, resolved as the UNION. `typeAliasArms` held only the binding
/// arms, so `#if os(macOS) typealias Impl = EnvImpl #else enum Impl { … } #endif` recorded ONE arm and the
/// `arms.count > 1` union never ran. EXECUTED with swiftc on macOS (`env: true file: false`) the built arm is the
/// alias, which sets an environment variable and writes no file; the report charged `Fs` only, so
/// `deny Env probe` exited 0 over a real `setenv`. Both written orders. PART 89 b10cfglocal / b11cfglocalrev.
///
/// Every fixture here was EXECUTED before the expectation was written (the ground truth is the built arm's
/// effect on the machine the tests run on); the union asserts BOTH arms, because the unbuilt arm is exactly
/// what a different configuration compiles. Kill switches: `CANDOR_R1714_OFF`, `CANDOR_R1729_OFF` (constructor
/// spelling) — a result-moving switch makes a gate refuse, so these tests read the report, never a verdict.
final class ConditionalMixedArmSetTests: XCTestCase {
    private static let HELPERS = """
    enum FsImpl { static func act() { try? "x".write(toFile: "/tmp/candor-r1714-benign", atomically: true, encoding: .utf8) } }
    enum EnvImpl { static func act() { setenv("CANDOR_R1714", "1", 1) } }
    enum PureImpl { static func act() { _ = 1 + 1 } }
    struct EnvTool { func run() { setenv("CANDOR_R1714", "1", 1) } }
    struct EnvInit { init() { setenv("CANDOR_R1714", "1", 1) } }
    struct FsInit { init() { try? "x".write(toFile: "/tmp/candor-r1714-benign", atomically: true, encoding: .utf8) } }
    """
    private static let FSDECL = "enum Impl { static func act() { try? \"x\".write(toFile: \"/tmp/candor-r1714-benign\", atomically: true, encoding: .utf8) } }"

    private func probeEffects(_ src: String, name: String) throws -> [String] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\n" + Self.HELPERS + "\n" + src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        let fns = try ProcessHarness.fns(ofJson: r.out)
        guard let p = fns["probe"] else { return [] }          // ABSENT = pure
        return ((p["inferred"] as? [String]) ?? []).sorted()
    }

    func testAliasBesideLocalDeclarationIsTheUnionInBothWrittenOrders() throws {
        let a = try probeEffects("#if os(macOS)\ntypealias Impl = EnvImpl\n#endif\n#if !os(macOS)\n\(Self.FSDECL)\n#endif\npublic func probe() { Impl.act() }", name: "R1714A")
        let b = try probeEffects("#if !os(macOS)\ntypealias Impl = EnvImpl\n#endif\n#if os(macOS)\n\(Self.FSDECL)\n#endif\npublic func probe() { Impl.act() }", name: "R1714B")
        XCTAssertEqual(a, ["Env", "Fs"], "built arm is the alias (Env), the unbuilt arm is the declaration (Fs)")
        XCTAssertEqual(b, ["Env", "Fs"], "…and the same program with the arms written the other way round")
    }

    func testEverySpellingOfTheDeclarationArmAndEveryConditionForm() throws {
        for kind in ["enum", "struct", "final class"] {
            let decl = "\(kind) Impl { static func act() { try? \"x\".write(toFile: \"/tmp/candor-r1714-benign\", atomically: true, encoding: .utf8) } }"
            for cond in ["os(macOS)", "arch(arm64)", "canImport(Foundation)", "os(macOS) && !os(Linux)"] {
                let e = try probeEffects("#if \(cond)\ntypealias Impl = EnvImpl\n#else\n\(decl)\n#endif\npublic func probe() { Impl.act() }",
                                         name: "R1714K")
                XCTAssertEqual(e, ["Env", "Fs"], "\(kind) / \(cond)")
            }
        }
        // #elseif chain, nested #if, declaration extended in ANOTHER conditional extension
        let chain = try probeEffects("#if os(Linux)\n\(Self.FSDECL)\n#elseif os(macOS)\ntypealias Impl = EnvImpl\n#else\nenum Impl { static func act() {} }\n#endif\npublic func probe() { Impl.act() }", name: "R1714C")
        XCTAssertEqual(chain, ["Env", "Fs"])
        let nested = try probeEffects("#if os(macOS)\n#if arch(arm64) || arch(x86_64)\ntypealias Impl = EnvImpl\n#endif\n#endif\n#if !os(macOS)\n\(Self.FSDECL)\n#endif\npublic func probe() { Impl.act() }", name: "R1714N")
        XCTAssertEqual(nested, ["Env", "Fs"])
    }

    func testInstanceAndConstructorSpellingsOfTheMixedSet() throws {
        let fsRun = "struct Impl { func run() { try? \"x\".write(toFile: \"/tmp/candor-r1714-benign\", atomically: true, encoding: .utf8) } }"
        for body in ["Impl().run()", "let i = Impl(); i.run()"] {
            let e = try probeEffects("#if os(macOS)\ntypealias Impl = EnvTool\n#else\n\(fsRun)\n#endif\npublic func probe() { \(body) }", name: "R1714I")
            XCTAssertEqual(e, ["Env", "Fs"], body)
        }
        let p = try probeEffects("#if os(macOS)\ntypealias Impl = EnvTool\n#else\n\(fsRun)\n#endif\nfunc probe(_ i: Impl) { i.run() }", name: "R1714P")
        XCTAssertEqual(p, ["Env", "Fs"], "param typed through the mixed set")
        // R1729 — a bare constructor, mixed and two-binding spellings
        let ctorMixed = try probeEffects("#if os(macOS)\ntypealias Impl = EnvInit\n#else\nstruct Impl { init() { try? \"x\".write(toFile: \"/tmp/candor-r1714-benign\", atomically: true, encoding: .utf8) } }\n#endif\npublic func probe() { _ = Impl() }", name: "R1729M")
        XCTAssertEqual(ctorMixed, ["Env", "Fs"])
        let ctorTwo = try probeEffects("#if os(macOS)\ntypealias Impl = EnvInit\n#else\ntypealias Impl = FsInit\n#endif\npublic func probe() { _ = Impl() }", name: "R1729T")
        XCTAssertEqual(ctorTwo, ["Env", "Fs"], "two BINDING arms over a constructor: the member-call union never saw a bare `Impl()`")
    }

    func testProtocolDeclarationArmAndAGenericAlias() throws {
        let proto = try probeEffects("#if os(macOS)\ntypealias Impl = EnvTool\n#else\nprotocol Impl { func run() }\n#endif\n#if !os(macOS)\nstruct FsConf: Impl { func run() { try? \"x\".write(toFile: \"/tmp/candor-r1714-benign\", atomically: true, encoding: .utf8) } }\n#endif\nfunc probe(_ i: Impl) { i.run() }", name: "R1714Q")
        XCTAssertEqual(proto, ["Env", "Fs"], "protocol arm: the conformer's Fs (CHA) and the alias arm's Env")
        let gen = try probeEffects("protocol Acts { static func act() }\nextension EnvImpl: Acts {}\nstruct Wrap<T: Acts> { static func act() { T.act() } }\n#if os(macOS)\ntypealias Impl = Wrap<EnvImpl>\n#else\n\(Self.FSDECL)\n#endif\npublic func probe() { Impl.act() }", name: "R1714G")
        XCTAssertEqual(gen, ["Env", "Fs"])
    }

    // ── the controls: nothing may be charged that neither arm does ───────────────────────────────────

    func testPureArmsStayPureAndUnrelatedNamesDoNotJoin() throws {
        XCTAssertEqual(try probeEffects("#if os(macOS)\ntypealias Impl = PureImpl\n#else\nenum Impl { static func act() { _ = 2 } }\n#endif\npublic func probe() { Impl.act() }", name: "R1714Z"), [],
                       "both arms pure: the union adds nothing")
        // the declaration is UNCONDITIONAL and the alias lives in another scope: not an arm set
        XCTAssertEqual(try probeEffects("enum Scope { typealias Impl = PureImpl\n static func go() { Impl.act() } }\n#if !os(macOS)\n#if os(Linux)\ntypealias Other = EnvImpl\n#endif\n#endif\npublic func probe() { Scope.go() }", name: "R1714U"), [])
        // the RxSwift shape: a `#if` class beside a `#if` alias to a framework type no κ entry answers. The lone
        // spelling is no effect and no disclosure, so the mixed set is neither (resolution, not a hedge).
        XCTAssertEqual(try probeEffects("#if os(Linux)\nfinal class Lk: NSRecursiveLock {}\n#else\ntypealias Lk = NSRecursiveLock\n#endif\npublic func probe() { _ = Lk() }", name: "R1714L"), [])
        // an unconditional alias, one arm, is unchanged
        XCTAssertEqual(try probeEffects("typealias Impl = EnvImpl\npublic func probe() { Impl.act() }", name: "R1714S"), ["Env"])
    }
}
