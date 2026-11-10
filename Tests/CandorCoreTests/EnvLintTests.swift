import XCTest
import Foundation
import SwiftSyntax
import SwiftParser

/// SPEC §3.4 ⟨0.42⟩ (SOUNDNESS R1634) — THE REGISTRATION IS THE READ, and this is the source gate that makes it true.
///
/// `Env` (Sources/CandorCore/Env.swift) is the one type through which the engine reads its process environment or builds a
/// child's. There is no list of switch names anywhere: a list is an allowlist and it fails in the absence direction (a
/// switch added without its entry is the silent one). What stops a NEW switch bypassing the record is this lint: it fails
/// on any environment read outside Env.swift, whatever the variable's name is and whether the name is a literal or computed.
///
/// A SwiftSyntax walk, not a regex: a comment or a string that merely MENTIONS `getenv` is not a read (the classifier
/// carries `getenv("HOME")` as a witness string, and prose says it everywhere), while `pi.environment[name]` with a
/// computed name and `let f = getenv` are. What it flags, by token:
///   · a member named `environment` — `ProcessInfo.processInfo.environment`, `ProcessInfo().environment`, a stored
///     `ProcessInfo` alias, and `proc.environment = …` (a child's environment is built through `Env` too), including the
///     key-path form `\ProcessInfo.environment`;
///   · an identifier `getenv` / `secure_getenv` / `setenv` / `unsetenv` / `putenv` / `clearenv` / `environ` /
///     `_NSGetEnviron` in any position (call, module-qualified call, function reference);
///   · a string literal that is exactly one of those names AND is handed to a symbol lookup (`dlsym(h, "getenv")`,
///     `Selector(("environment"))`, `perform`, `NSSelectorFromString`) or names a symbol (`@_silgen_name("getenv")`) — the
///     reflective routes. A bare literal is data, not a read (the classifier's own tables spell these words).
/// NOT covered, stated rather than assumed: a name assembled at run time (`"get" + "env"`) handed to `dlsym`. Nothing in
/// this engine does, and a lint cannot see it; the seeded set below does not pretend otherwise.
final class EnvLintTests: XCTestCase {

    static let forbiddenIdentifiers: Set<String> =
        ["getenv", "secure_getenv", "setenv", "unsetenv", "putenv", "clearenv", "environ", "_NSGetEnviron"]
    static let forbiddenMember = "environment"

    private final class Finder: SyntaxVisitor {
        var found: [String] = []
        let conv: SourceLocationConverter
        init(_ conv: SourceLocationConverter) { self.conv = conv; super.init(viewMode: .sourceAccurate) }
        private func note(_ node: some SyntaxProtocol, _ what: String) {
            found.append("line \(node.startLocation(converter: conv).line): \(what)")
        }
        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            let n = node.declName.baseName.text
            if n == EnvLintTests.forbiddenMember { note(node, "member `.environment`") }
            if EnvLintTests.forbiddenIdentifiers.contains(n) { note(node, "member `.\(n)`") }
            return .visitChildren
        }
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            let n = node.baseName.text
            if EnvLintTests.forbiddenIdentifiers.contains(n) { note(node, "reference `\(n)`") }
            return .visitChildren
        }
        override func visit(_ node: KeyPathPropertyComponentSyntax) -> SyntaxVisitorContinueKind {
            if node.declName.baseName.text == EnvLintTests.forbiddenMember { note(node, "key path `\\.environment`") }
            return .visitChildren
        }
        /// A string is a REFLECTIVE route only where it is handed to a symbol lookup (`dlsym`, `Selector`,
        /// `NSSelectorFromString`, `perform`) or names a symbol (`@_silgen_name`, `@_cdecl`). A bare literal that happens to
        /// spell one of these words is data — the classifier carries `["ProcessInfo": ["environment"]]` to recognise the
        /// code it SCANS, and reading that table is not reading the environment.
        override func visit(_ node: StringSegmentSyntax) -> SyntaxVisitorContinueKind {
            let t = node.content.text
            guard t == EnvLintTests.forbiddenMember || EnvLintTests.forbiddenIdentifiers.contains(t) else { return .visitChildren }
            var p: Syntax? = node.parent
            while let cur = p {
                if let call = cur.as(FunctionCallExprSyntax.self) {
                    let callee = call.calledExpression.trimmedDescription
                    if ["dlsym", "Selector", "NSSelectorFromString", "perform", "NSClassFromString"].contains(where: { callee == $0 || callee.hasSuffix("." + $0) }) {
                        note(node, "string literal \"\(t)\" handed to `\(callee)` (a reflective route)"); break
                    }
                }
                if let a = cur.as(AttributeSyntax.self), ["_silgen_name", "_cdecl"].contains(a.attributeName.trimmedDescription) {
                    note(node, "string literal \"\(t)\" in `@\(a.attributeName.trimmedDescription)`"); break
                }
                p = cur.parent
            }
            return .visitChildren
        }
    }

    static func violations(in source: String) -> [String] {
        let tree = Parser.parse(source: source)
        let f = Finder(SourceLocationConverter(fileName: "x.swift", tree: tree))
        f.walk(tree)
        return f.found
    }

    /// `Sources/` of this package, found from this file's own path.
    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    static func swiftFiles() -> [URL] {
        let en = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    // ── the gate ────────────────────────────────────────────────────────────────────────────────────────

    func testNoEnvironmentReadOutsideEnvSwift() throws {
        let files = Self.swiftFiles()
        XCTAssertGreaterThan(files.count, 20, "the walk found no sources — a lint over nothing passes vacuously")
        var bad: [String] = []
        var sawEnv = false
        for f in files {
            if f.lastPathComponent == "Env.swift", f.deletingLastPathComponent().lastPathComponent == "CandorCore" {
                sawEnv = true; continue
            }
            for v in Self.violations(in: try String(contentsOf: f, encoding: .utf8)) { bad.append("\(f.lastPathComponent) \(v)") }
        }
        XCTAssertTrue(sawEnv, "Sources/CandorCore/Env.swift was not found — the exemption is for exactly that file")
        XCTAssertEqual(bad, [], "an environment read outside Env.swift: route it through Env (switch / trace / operator), "
                       + "so that a result-moving switch is RECORDED by the read itself (SPEC §3.4)")
    }

    /// The exemption is the ONLY reason Env.swift passes: shown by linting it.
    func testEnvSwiftIsTheOnlyExemption() throws {
        let env = Self.sourcesRoot.appendingPathComponent("CandorCore/Env.swift")
        XCTAssertFalse(Self.violations(in: try String(contentsOf: env, encoding: .utf8)).isEmpty,
                       "Env.swift reads the environment; if the lint finds nothing in it the lint is blind")
    }

    // ── the lint can fail: seeded spellings, each of which MUST be flagged ─────────────────────────────

    static let seeded: [(String, String)] = [
        ("subscript, literal name", #"let v = ProcessInfo.processInfo.environment["CANDOR_X"]"#),
        ("subscript, dynamic name", "func f(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }"),
        ("whole dictionary", "let e = ProcessInfo.processInfo.environment"),
        ("fresh ProcessInfo()", "let e = ProcessInfo().environment"),
        ("module-qualified", "let e = Foundation.ProcessInfo.processInfo.environment"),
        ("through an alias", "let pi = ProcessInfo.processInfo\nlet e = pi.environment"),
        ("enumerated", "for (k, v) in ProcessInfo.processInfo.environment { print(k, v) }"),
        ("filtered", #"let c = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("CANDOR_") }"#),
        ("child env assignment", "func f(_ p: Process, _ e: [String: String]) { p.environment = e }"),
        ("getenv call", #"let p = getenv("CANDOR_X")"#),
        ("module-qualified getenv", #"let p = Darwin.getenv("CANDOR_X")"#),
        ("getenv, dynamic name", "func f(_ n: String) { _ = getenv(n) }"),
        ("function reference", "let f = getenv"),
        ("setenv", #"setenv("A", "b", 1)"#),
        ("unsetenv", #"unsetenv("A")"#),
        ("putenv", "func f(_ s: UnsafeMutablePointer<CChar>) { putenv(s) }"),
        ("environ global", "let e = environ"),
        ("_NSGetEnviron", "let e = _NSGetEnviron()"),
        ("key path", #"let k = \ProcessInfo.environment"#),
        ("dlsym by name", #"let h = dlsym(handle, "getenv")"#),
        ("silgen_name", "@_silgen_name(\"getenv\") func g(_ n: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?"),
        ("selector", #"let s = Selector(("environment"))"#),
    ]

    func testEverySeededSpellingIsFlagged() {
        XCTAssertGreaterThanOrEqual(Self.seeded.count, 20)
        for (label, src) in Self.seeded {
            XCTAssertFalse(Self.violations(in: src).isEmpty, "the lint is BLIND to: \(label) — `\(src)`")
        }
    }

    /// …and does not cry wolf: prose, strings that merely mention the words, and unrelated `ProcessInfo` members.
    func testCleanSpellingsAreNotFlagged() {
        let clean = [
            "// ProcessInfo.processInfo.environment[\"X\"] and getenv(\"HOME\") in a comment",
            "/// reads the environment via setenv",
            #"let s = "ProcessInfo.processInfo.environment is how a switch is read""#,
            ##"let w = #"getenv("HOME")"#"##,
            #"let table = ["ProcessInfo": ["environment"], "getenv": [""]]"#,
            "let pid = ProcessInfo.processInfo.processIdentifier",
            "let a = ProcessInfo.processInfo.arguments",
            "let v = Env.on(\"CANDOR_X\")",
            "let environmentName = \"x\"",
        ]
        for src in clean { XCTAssertEqual(Self.violations(in: src), [], "false positive on: \(src)") }
    }

    /// A SHIPPED file with ONE read appended is red, and the file as shipped is green.
    func testShippedFileWithOneReadAppendedFails() throws {
        let f = Self.sourcesRoot.appendingPathComponent("candor-swift/Gate.swift")
        let src = try String(contentsOf: f, encoding: .utf8)
        XCTAssertEqual(Self.violations(in: src), [])
        XCTAssertFalse(Self.violations(in: src + "\nlet newSwitch = ProcessInfo.processInfo.environment[\"CANDOR_NEW_OFF\"] != nil\n").isEmpty)
    }
}
