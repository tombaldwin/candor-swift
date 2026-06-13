// candor-swift — the Swift implementation of candor-spec 0.4.
//
// Architecture mirrors candor-scan (the syntactic reference engine): pass A indexes declarations
// (units, field types, protocols + conformers, imports), pass B collects each function's calls
// with light local type inference (params, typed lets, constructor bindings), propagates effects
// to the least fixpoint, and emits the §2 envelope + §2.2 call-graph sidecar. The §4 trust
// contract is the core: a call through a function-typed value, an unresolvable member, or a local
// protocol's dispatch with no visible conformer contributes Unknown — never silent purity.
// Spec 0.4 MUSTs carried from day one: universal `hash` emission (pkg#qual), the §7.14 κ-coverage
// ledger (imports the classifier doesn't know, named per scan), and literal surfaces
// (hosts/cmds/paths/tables) because the §6.2 policy gate enforces `allow` rules.
//
// Known v0 honesty notes (item 7): the κ table covers the platform frontier (Foundation/Network/
// Dispatch/os + sqlite3) — third-party packages are INVISIBLE and the ledger names them; nested
// named functions attribute lexically to their enclosing unit (over-approximation, the sound
// direction); no CANDOR_DEPS consumption yet (hash is emitted so reports are chainable by others);
// the §7.13 soundness harness is not yet ported.

import Foundation
import SwiftParser
import SwiftSyntax

// ════════════════════════════════════════════════════════════════════════════════════════════════
// CLI
// ════════════════════════════════════════════════════════════════════════════════════════════════

let engineVersion = "candor-swift-0.4.5"

var target = "."
var outPrefix: String? = nil
var policyPath: String? = ProcessInfo.processInfo.environment["CANDOR_POLICY"]
var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIter.next() {
    switch a {
    // A value-taking flag with no following value must FAIL, never silently take a nil: a trailing
    // `--policy` (e.g. `--policy $POL` where $POL expanded empty) would otherwise CLOBBER the
    // CANDOR_POLICY env gate with nil and exit 0 — the §6.2 'gateless green' state. exit 2.
    case "--out":
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --out requires a value\n".data(using: .utf8)!); exit(2)
        }
        outPrefix = v
    case "--policy":
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --policy requires a value\n".data(using: .utf8)!); exit(2)
        }
        policyPath = v
    case "-h", "--help":
        print("""
        candor-swift — Swift effect scanner (candor-spec 0.4)
        USAGE: candor-swift [<dir|file.swift>] [--out <prefix>] [--policy <file>] [--agents]
          writes <prefix>.<package>.Swift.json (report, spec 0.4 envelope) + a .callgraph.json sidecar
          CANDOR_POLICY honoured when --policy absent; exit 1 on violation, 2 on unreadable policy.
          --agents prints the agent contract for THIS build (the embedded AGENTS.md).
        """)
        exit(0)
    case "--agents":
        // The agent contract for THE INSTALLED BUILD, EMBEDDED at compile time (AgentsDoc.swift,
        // generated from AGENTS.md) — doc and engine cannot drift (the spec §2.1 version-trust
        // rule applied to documentation), and unlike a Bundle.module resource it survives a binary
        // copied out of .build (the documented `cp .build/release/candor-swift …` install flow,
        // where the resource bundle is absent and Bundle.module would fatalError before any guard).
        // Canonical header shape `candor-<engine> <version>` (consistent across the family); the
        // envelope keeps the hyphenated `engineVersion` as its build id.
        print("<!-- \(engineVersion.replacingOccurrences(of: "candor-swift-", with: "candor-swift ")) · the agent contract for this installed version -->")
        // default terminator re-adds the single trailing newline a Swift multiline raw string strips
        // before its closing delimiter, so the served body matches AGENTS.md byte-for-byte.
        print(AGENTS_MD)
        exit(0)
    default:
        // An unknown flag must FAIL, not become the scan path (a stale binary handed a newer
        // doc's flag would scan a directory literally named after it; a typo'd --policy would
        // silently drop the gate).
        if a.hasPrefix("-") {
            FileHandle.standardError.write("candor-swift: unknown flag \(a) (see --help)\n".data(using: .utf8)!)
            exit(2)
        }
        target = a
    }
}

let fm = FileManager.default
var isDir: ObjCBool = false
guard fm.fileExists(atPath: target, isDirectory: &isDir) else {
    FileHandle.standardError.write("candor-swift: no such path: \(target)\n".data(using: .utf8)!)
    exit(2)
}
let rootDir = isDir.boolValue ? target : (target as NSString).deletingLastPathComponent

// Production sources only: tests are the harness's effects, not the package's (the family rule).
func isHarnessPath(_ p: String) -> Bool {
    let parts = p.split(separator: "/").map(String.init)
    if (parts.last ?? "") == "Package.swift" { return true } // the manifest is build config (build.rs analog)
    if parts.contains(".build") { return true }              // build artifacts at any depth
    // SPM's special directories (Tests/Plugins/Benchmarks/Examples/Snippets, and *Tests/*TestHelpers
    // targets) are PACKAGE-ROOT siblings of Sources/. A directory with one of those names nested
    // UNDER Sources/<target>/ is ordinary feature code (`Sources/App/Plugins/*.swift`) — excluding
    // it silently drops production sources, the 'invisible, not Unknown' cardinal sin. So a marker
    // counts as harness only when no `Sources` component precedes it.
    let firstSources = parts.firstIndex(of: "Sources") ?? Int.max
    func isMarker(_ s: String) -> Bool {
        s == "Tests" || s.hasSuffix("Tests") || s.hasSuffix("TestHelpers")
            || s == "Benchmarks" || s == "Benchmark" || s == "Plugins" || s == "Examples" || s == "Snippets"
    }
    for (i, c) in parts.enumerated() where i < firstSources && isMarker(c) { return true }
    return false
}
var sourcePaths: [String] = []
if isDir.boolValue {
    if let en = fm.enumerator(atPath: target) {
        for case let rel as String in en {
            if rel.hasSuffix(".swift") && !isHarnessPath(rel) { sourcePaths.append((target as NSString).appendingPathComponent(rel)) }
        }
    }
} else {
    sourcePaths = [target]
}
sourcePaths.sort()
if sourcePaths.isEmpty {
    FileHandle.standardError.write("candor-swift: no Swift sources under \(target)\n".data(using: .utf8)!)
    exit(2)
}

// The package name — the first half of the §2 `hash` join key. Package.swift's name, else the dir.
var pkgName = (rootDir as NSString).lastPathComponent
if let manifest = try? String(contentsOfFile: (rootDir as NSString).appendingPathComponent("Package.swift"), encoding: .utf8),
   let r = manifest.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) {
    let m = String(manifest[r])
    if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
        pkgName = String(m[m.index(after: q1)..<q2])
    }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// κ — the curated classifier (the platform frontier; third-party modules are the LEDGER's job)
// ════════════════════════════════════════════════════════════════════════════════════════════════

// Root-receiver type/name + member -> effect. Verb-precise where a type mixes pure and effectful
// surface (the family discipline: tag the execution boundary, not builders).
let FS_MEMBERS: Set<String> = ["contents", "contentsOfDirectory", "createFile", "removeItem", "copyItem",
    "moveItem", "attributesOfItem", "fileExists", "createDirectory", "subpathsOfDirectory", "isReadableFile",
    "isWritableFile", "replaceItem", "linkItem", "destinationOfSymbolicLink", "createSymbolicLink",
    "enumerator", "subpaths", "changeCurrentDirectoryPath", "currentDirectoryPath", "temporaryDirectory",
    "urls", "url", "homeDirectoryForCurrentUser"]
let NET_MEMBERS: Set<String> = ["dataTask", "data", "upload", "download", "bytes", "webSocketTask",
    "uploadTask", "downloadTask", "streamTask"]
let LOG_MEMBERS: Set<String> = ["trace", "debug", "info", "notice", "warning", "error", "critical", "fault", "log"]
let RAND_ROOTS: Set<String> = ["Int", "UInt", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16",
    "UInt32", "UInt64", "Double", "Float", "Bool", "CGFloat"]
let PROCESS_MEMBERS: Set<String> = ["run", "launch", "waitUntilExit", "terminate", "interrupt", "launchedProcess"]
let DB_FREE_PREFIX = "sqlite3_"
// Static singleton accessors that return an instance of their OWN type (Self by convention):
// `FileManager.default`, `URLSession.shared`, `NSPasteboard.general`, `ProcessInfo.processInfo`,
// `Database.shared` (a local singleton), … Binding one to a `let` must carry the base type so the
// var's later member calls classify — `FileManager.default.removeItem` inline is Fs, but via a
// `let fm = FileManager.default` it dropped to pure (the receiver typed as the bare identifier).
let SINGLETON_ACCESSORS: Set<String> = ["default", "shared", "standard", "current", "general", "processInfo", "main"]

/// Classify a member call `root.member(...)` (root = the receiver chain's base identifier or the
/// receiver's inferred TYPE). Returns nil for the pure/unknown surface — never a guess.
func kappaMember(root: String, member: String) -> String? {
    switch root {
    case "FileManager", "FileHandle": return FS_MEMBERS.contains(member) || member == "readToEnd"
        || member == "write" || member == "read" ? "Fs" : nil
    case "URLSession": return NET_MEMBERS.contains(member) ? "Net" : nil
    case "Process": return PROCESS_MEMBERS.contains(member) ? "Exec" : nil
    case "Logger", "OSLog": return LOG_MEMBERS.contains(member) ? "Log" : nil
    case "NSPasteboard", "UIPasteboard": return "Clipboard"
    case "Date": return member == "now" ? "Clock" : nil
    case "ContinuousClock", "SuspendingClock", "DispatchTime": return member == "now" ? "Clock" : nil
    case "NWConnection", "NWListener": return "Net"
    case "NSXPCConnection": return "Ipc"
    // The NIO tier (the vapor probe's pointer: 84 NIOCore imports, all invisible). Verb-precise:
    // channel/bootstrap wiring and socket reads/writes are Net; the pure ByteBuffer/EventLoop
    // future algebra stays out (the builder discipline).
    case "ClientBootstrap", "ServerBootstrap", "DatagramBootstrap", "NIOTSConnectionBootstrap":
        return ["connect", "bind", "withConnectedSocket"].contains(member) ? "Net" : nil
    case "Channel", "ChannelHandlerContext":
        return ["write", "writeAndFlush", "read", "connect", "bind", "close", "flush"].contains(member) ? "Net" : nil
    case "HTTPClient", "AsyncHTTPClient":
        return ["execute", "get", "post", "put", "patch", "delete", "shutdown"].contains(member) ? "Net" : nil
    default:
        if RAND_ROOTS.contains(root) && member == "random" { return "Rand" }
        return nil
    }
}

/// Classify a free-function or constructor call by name.
func kappaFree(name: String, argCount: Int) -> String? {
    switch name {
    case "Date": return argCount == 0 ? "Clock" : nil // Date() reads the clock; Date(timeInterval…) is arithmetic
    case "Process": return "Exec"   // constructing the subprocess handle is the Exec intent (Command::new)
    case "NWConnection", "NWListener": return "Net"
    case "SystemRandomNumberGenerator": return "Rand"
    case "arc4random", "arc4random_uniform", "getentropy": return "Rand"
    case "getenv", "setenv", "unsetenv": return "Env"
    case "NSXPCConnection": return "Ipc"
    case "os_log": return "Log"
    case "posix_spawn", "execv", "execvp": return "Exec"
    case "fopen": return "Fs"
    // NOTE deliberately ABSENT: the bare POSIX names (open/bind/connect/listen/socket/fork/
    // system/mkdir/rename/unlink). As bare Swift identifiers they collide with ordinary local
    // functions — the first real-repo sweep caught GRDB's local `bind(...)` fabricating Net onto
    // its hottest Statement paths (214 fns transitively). Raw syscalls in Swift come through
    // Darwin/Glibc imports the ledger names; under-report beats a wrong label.
    default:
        if name.hasPrefix(DB_FREE_PREFIX) { return "Db" }
        return nil
    }
}

/// Property READS that are effects (no call expression): `ProcessInfo…environment`, `Date.now`,
/// pasteboard accessors. Checked on member-access chains outside call position.
func kappaPropertyRead(root: String, path: [String]) -> String? {
    if root == "ProcessInfo" && path.contains("environment") { return "Env" }
    if root == "Date" && path.contains("now") { return "Clock" }
    if (root == "NSPasteboard" || root == "UIPasteboard") && path.contains("general") { return "Clipboard" }
    return nil
}

/// Refine the `Exec` cliff (spec §4 ⟨0.5⟩): the effects a literal, statically-known subprocess head
/// implies, matched by basename. ADDED to a caller that already carries `Exec` (a subprocess is still
/// spawned — `Exec` is never dropped); an unrecognised head returns [] and keeps the bare cliff. A
/// candor engine reads Fs/Env only — spec §7 item 12 (the analyzer self-boundary) guarantees it, so
/// that case is spec-supplied. Only UNAMBIGUOUS single-effect tools belong here: a multi-modal head
/// (git status local vs git push Net; rsync local vs remote; make/npm run project code) would
/// fabricate the effect for its common case. The reference engines share this table verbatim.
func classifyCommandHead(_ cmd: String) -> [String] {
    switch cmd.split(separator: "/").last.map(String.init) ?? cmd {
    case "curl", "wget", "http", "ssh", "scp", "sftp", "ftp", "telnet": return ["Net"]
    case "psql", "mysql", "sqlite3", "mongosh", "mongo", "redis-cli", "cqlsh", "influx": return ["Db"]
    case "candor", "candor-run.sh", "candor-scan", "candor-query", "candor-java",
         "candor-classify", "candor-report", "cargo-candor": return ["Env", "Fs"]
    default: return []
    }
}

/// Modules the platform frontier owns (κ's actual job) — everything else imported is either in
/// the κ module set or NAMED by the ledger.
let PLATFORM_MODULES: Set<String> = ["Swift", "Foundation", "FoundationNetworking", "FoundationXML",
    "Dispatch", "os", "OSLog", "Darwin", "Glibc", "Musl", "Android", "Bionic", "WASILibc", "WinSDK",
    "CRT", "Builtin", "Combine", "Observation", "SwiftUI", "AppKit", "UIKit", "WatchKit",
    "CoreFoundation", "CoreGraphics", "CoreLocation", "CoreServices", "MobileCoreServices",
    "Security", "SystemConfiguration", "UniformTypeIdentifiers", "CryptoKit", "System",
    "RegexBuilder", "Synchronization", "Testing", "XCTest", "PackageDescription", "PackagePlugin",
    "ucrt", "wasi_pthread", "string_h", "zlibng", "SwiftShims"]
let KAPPA_MODULES: Set<String> = ["Network", "SQLite3", "CoreData",
    "NIOCore", "NIOPosix", "NIOHTTP1", "NIOHTTP2", "NIOSSL", "NIOTransportServices", "AsyncHTTPClient"]

// ════════════════════════════════════════════════════════════════════════════════════════════════
// SQL tables — the SPEC §2 pinned extraction, token-for-token with the other three engines
// ════════════════════════════════════════════════════════════════════════════════════════════════

func tablesInSql(_ sql: String) -> [String] {
    let stmt: Set<String> = ["select", "insert", "update", "delete", "create", "drop", "alter",
        "truncate", "merge", "replace", "with"]
    let skip: Set<String> = ["only", "if", "not", "exists", "table"]
    let stop: Set<String> = ["select", "set", "where", "values", "on", "using", "group", "order",
        "by", "limit", "returning", "as", "inner", "outer", "left", "right", "cross", "lateral",
        "natural", "union", "all", "distinct", "case", "when", "null", "default", "skip",
        "nowait", "of", "from", "join", "into", "update", "delete", "insert"]
    var cleaned = ""
    for ch in sql.lowercased() {
        switch ch {
        case "(", ")", ";": cleaned.append(" ")
        case ",": cleaned.append(" , ")
        default: cleaned.append(ch)
        }
    }
    let toks = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard let first = toks.first, stmt.contains(first) else { return [] }
    func ident(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard let c0 = t.first, c0.isLetter || c0 == "_" else { return nil }
        guard !stop.contains(t) else { return nil }
        guard t.allSatisfy({ $0.isLetter || $0.isNumber || "_.$\"`".contains($0) }) else { return nil }
        return t.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "`", with: "")
    }
    var out: [String] = []
    func push(_ t: String) { if !out.contains(t) { out.append(t) } }
    for (i, tok) in toks.enumerated() {
        let tablePos = tok == "from" || tok == "join" || tok == "into" || tok == "table"
            || ((tok == "update" || tok == "truncate") && i == 0)
        if !tablePos { continue }
        var j = i + 1
        while j < toks.count && skip.contains(toks[j]) { j += 1 }
        guard j < toks.count, let first = ident(toks[j]) else { continue }
        push(first)
        // comma-ADJACENT continuation; an alias breaks the chain (the fabrication guard)
        while j + 2 < toks.count && toks[j + 1] == "," {
            guard let more = ident(toks[j + 2]) else { break }
            push(more)
            j += 2
        }
    }
    return out
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Pass A — declarations: units, field types, protocols, conformers, imports
// ════════════════════════════════════════════════════════════════════════════════════════════════

struct FnInfo {
    var qual: String          // "Type.name" or "name"
    var loc: String
    var params: [String: String] = [:]       // param name -> type name (concrete)
    var fnTypedParams: Set<String> = []      // params of function type
    var fnTypedParamIndex: [String: Int] = [:] // fn-typed param name -> position
    var protoParams: [String: String] = [:]  // param name -> local protocol name
    var arrayParams: [String: String] = [:]  // param name -> ELEMENT type (a `[T]` param, for `for x in p`)
    var dictParams: [String: String] = [:]   // param name -> VALUE type (a `[K: V]` param, for `for (k,v)`)
    var tupleParams: [String: [String: String]] = [:]  // param -> tuple element types (`p.0`/`p.c`)
    var body: Syntax?
    var enclosingType: String?
    var isMain: Bool = false
    var isAccessor: Bool = false   // a computed-property/observer/lazy-init body (spec 0.5 unitKind)
}

func typeName(_ t: TypeSyntax) -> (name: String?, isFunction: Bool) {
    if let id = t.as(IdentifierTypeSyntax.self) { return (id.name.text, false) }
    if let opt = t.as(OptionalTypeSyntax.self) { return typeName(opt.wrappedType) }
    if let att = t.as(AttributedTypeSyntax.self) { return typeName(att.baseType) }
    if t.is(FunctionTypeSyntax.self) { return (nil, true) }
    if let tup = t.as(TupleTypeSyntax.self), tup.elements.count == 1, let only = tup.elements.first {
        return typeName(only.type)
    }
    if let some = t.as(SomeOrAnyTypeSyntax.self) { return typeName(some.constraint) } // `some P` / `any P`
    return (nil, false)
}

/// The ELEMENT type name of a collection type: `[T]`/`Set<T>`/`Array<T>`/`ContiguousArray<T>` → `T`
/// (peeling Optional/`some`/`any` wrappers). Used to type a `for x in coll`/`coll.forEach { x in … }`
/// iteration variable so its member calls classify — without it, a loop/closure over a typed
/// collection dropped its receiver to pure (a §4 under-report on a very common Swift shape).
func arrayElementName(_ t: TypeSyntax) -> String? {
    if let arr = t.as(ArrayTypeSyntax.self) { return typeName(arr.element).name }
    if let opt = t.as(OptionalTypeSyntax.self) { return arrayElementName(opt.wrappedType) }
    if let att = t.as(AttributedTypeSyntax.self) { return arrayElementName(att.baseType) }
    if let some = t.as(SomeOrAnyTypeSyntax.self) { return arrayElementName(some.constraint) }
    if let gen = t.as(IdentifierTypeSyntax.self), let args = gen.genericArgumentClause,
       ["Array", "Set", "ContiguousArray", "ArraySlice"].contains(gen.name.text),
       let first = args.arguments.first, let at = first.argument.as(TypeSyntax.self) {
        return typeName(at).name
    }
    return nil
}

/// A tuple type's element types keyed by BOTH position (`"0"`, `"1"`) and label (`"c"`): `(c: C, n: Int)`
/// → `["0": "C", "c": "C", "1": "Int", "n": "Int"]`. Types `p.0` / `p.c` member accesses on a tuple.
func tupleElements(_ t: TypeSyntax) -> [String: String] {
    var e = t
    if let opt = e.as(OptionalTypeSyntax.self) { e = opt.wrappedType }
    if let att = e.as(AttributedTypeSyntax.self) { e = att.baseType }
    guard let tup = e.as(TupleTypeSyntax.self), tup.elements.count >= 2 else { return [:] }
    var out: [String: String] = [:]
    for (i, el) in tup.elements.enumerated() {
        guard let tn = typeName(el.type).name else { continue }
        out[String(i)] = tn
        if let label = el.firstName?.text, label != "_" { out[label] = tn }
    }
    return out
}

/// The VALUE type name of a dictionary type: `[K: V]`/`Dictionary<K, V>` → `V` (peeling wrappers).
/// `for (k, v) in dict { v.method() }` iterates (key, value) pairs, so the value carries the type.
func dictValueName(_ t: TypeSyntax) -> String? {
    if let d = t.as(DictionaryTypeSyntax.self) { return typeName(d.value).name }
    if let opt = t.as(OptionalTypeSyntax.self) { return dictValueName(opt.wrappedType) }
    if let att = t.as(AttributedTypeSyntax.self) { return dictValueName(att.baseType) }
    if let some = t.as(SomeOrAnyTypeSyntax.self) { return dictValueName(some.constraint) }
    if let gen = t.as(IdentifierTypeSyntax.self), let args = gen.genericArgumentClause,
       gen.name.text == "Dictionary", args.arguments.count == 2,
       let second = Array(args.arguments).last, let vt = second.argument.as(TypeSyntax.self) {
        return typeName(vt).name
    }
    return nil
}

final class DeclCollector: SyntaxVisitor {
    var file: String
    var converter: SourceLocationConverter
    var fns: [FnInfo] = []
    var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:] // Type -> field -> info
    var fieldArrayElem: [String: [String: String]] = [:]  // Type -> field -> ELEMENT type (`[T]` field)
    var fieldDictValue: [String: [String: String]] = [:]  // Type -> field -> VALUE type (`[K: V]` field)
    var protocolMethods: [String: Set<String>] = [:]   // protocol -> declared method names
    var returnsTmp: [String: String?] = [:]            // fn leaf -> return type (nil = ambiguous)
    var conformers: [String: [String]] = [:]           // protocol -> conforming local types
    var caseAssoc: [String: Set<String>] = [:]         // enum case -> single-associated-value type(s) seen
    var localTypes: Set<String> = []
    var imports: [String] = []
    private var typeStack: [String] = []

    init(file: String, tree: SourceFileSyntax) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    private func loc(_ node: some SyntaxProtocol) -> String {
        let l = node.startLocation(converter: converter)
        return "\(file):\(l.line):\(l.column)"
    }

    private func pushType(_ name: String, inheritance: InheritanceClauseSyntax?) {
        typeStack.append(name)
        localTypes.insert(name)
        for inh in inheritance?.inheritedTypes ?? [] {
            if let pname = typeName(inh.type).name {
                conformers[pname, default: []].append(name)
            }
        }
    }

    // Enum case associated-value types: `case active(Client)` → caseAssoc["active"] = {"Client"}.
    // Used to type a `case .active(let c)` binding (switch/if-case) so `c.method()` resolves. Only the
    // SINGLE-associated-value form is recorded; an unambiguous case name (one assoc type project-wide)
    // is bindable, an ambiguous one (`.success(A)` vs `.success(B)`) is left unbound — never guess.
    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for el in node.elements {
            guard let params = el.parameterClause?.parameters, params.count == 1,
                  let t = typeName(params.first!.type).name else { continue }
            caseAssoc[el.name.text, default: []].insert(t)
        }
        return .visitChildren
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let first = node.path.first { imports.append(first.name.text) }
        return .skipChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // A non-identifier extended type (`extension [Foo]`, `extension Optional<X>`) needs a
        // STABLE name — the old "?" fallback merged every such extension into one phantom unit
        // ("?.name" showed up as a caller in the swift-argument-parser probe), cross-wiring their
        // methods. The trimmed source text is unique per type; spaces drop for qual hygiene.
        let name = typeName(node.extendedType).name
            ?? node.extendedType.trimmedDescription.replacingOccurrences(of: " ", with: "")
        pushType(name, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        var methods = Set<String>()
        for member in node.memberBlock.members {
            if let f = member.decl.as(FunctionDeclSyntax.self) { methods.insert(f.name.text) }
        }
        protocolMethods[node.name.text, default: []].formUnion(methods)
        return .skipChildren
    }

    // Field types (for `self.f()` / `d.f()` resolution and fn-typed-field Unknown) — and ACCESSOR
    // UNITS: a computed getter, get/set block, didSet/willSet observer, or lazy initializer has a
    // BODY that runs (the fuzz probe found all four silently pure — the TS engine's property-arrow
    // hole, Swift edition). Each body collects under `Type.property`; duplicate quals union.
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if let ty = typeStack.last {
            for binding in node.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                let qual = "\(ty).\(name)"
                var accessorBodies: [Syntax] = []
                if let ab = binding.accessorBlock {
                    switch ab.accessors {
                    case .getter(let items): accessorBodies.append(Syntax(items))
                    case .accessors(let list):
                        for acc in list {
                            if let b = acc.body { accessorBodies.append(Syntax(b)) }
                        }
                    }
                }
                if node.modifiers.contains(where: { $0.name.text == "lazy" }), let init0 = binding.initializer {
                    accessorBodies.append(Syntax(init0.value)) // lazy init runs at first ACCESS
                }
                for b in accessorBodies {
                    var info = FnInfo(qual: qual, loc: loc(binding))
                    info.enclosingType = ty
                    info.body = b
                    info.isAccessor = true
                    fns.append(info)
                }
                if let ann = binding.typeAnnotation {
                    let info = typeName(ann.type)
                    fields[ty, default: [:]][name] = info
                    if let elem = arrayElementName(ann.type) { fieldArrayElem[ty, default: [:]][name] = elem }
                    if let val = dictValueName(ann.type) { fieldDictValue[ty, default: [:]][name] = val }
                } else if let initVal = binding.initializer?.value,
                          let call = initVal.as(FunctionCallExprSyntax.self),
                          let ctor = call.calledExpression.as(DeclReferenceExprSyntax.self),
                          ctor.baseName.text.first?.isUppercase == true {
                    fields[ty, default: [:]][name] = (ctor.baseName.text, false)
                }
            }
        }
        return .visitChildren
    }

    private func recordReturn(_ name: String, _ sig: FunctionSignatureSyntax) {
        guard let rt = sig.returnClause.map({ typeName($0.type) }), let tn = rt.name else { return }
        if let existing = returnsTmp[name] {
            if existing != tn { returnsTmp[name] = String?.none } // ambiguous leaf — never guess
        } else {
            returnsTmp[name] = tn
        }
    }

    private func collect(_ name: String, sig: FunctionSignatureSyntax, body: CodeBlockSyntax?, node: some SyntaxProtocol) {
        var info = FnInfo(qual: typeStack.last.map { "\($0).\(name)" } ?? name, loc: loc(node))
        info.enclosingType = typeStack.last
        info.body = body.map { Syntax($0) }
        info.isMain = name == "main"
        // Generic constraints `<T: P>` — a value param typed `T` then dispatches like a `P`-typed param.
        var genericBounds: [String: String] = [:]
        let genClause = Syntax(node).as(FunctionDeclSyntax.self)?.genericParameterClause
            ?? Syntax(node).as(InitializerDeclSyntax.self)?.genericParameterClause
        for gp in genClause?.parameters ?? [] {
            if let it = gp.inheritedType, let bound = typeName(it).name { genericBounds[gp.name.text] = bound }
        }
        for (idx, p) in sig.parameterClause.parameters.enumerated() {
            let pname = (p.secondName ?? p.firstName).text
            let t = typeName(p.type)
            if t.isFunction { info.fnTypedParams.insert(pname); info.fnTypedParamIndex[pname] = idx }
            else if let tn = t.name {
                // resolve a generic param to its protocol BOUND (`x: T` where `<T: Sender>` → dispatch P)
                let resolved = genericBounds[tn] ?? tn
                if protocolMethods[resolved] != nil { info.protoParams[pname] = resolved } else { info.params[pname] = tn }
            }
            else if let elem = arrayElementName(p.type) { info.arrayParams[pname] = elem }  // `p: [T]`
            else if let val = dictValueName(p.type) { info.dictParams[pname] = val }        // `p: [K: V]`
            else { let te = tupleElements(p.type); if !te.isEmpty { info.tupleParams[pname] = te } }  // `p: (A, B)`
        }
        fns.append(info)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        recordReturn(node.name.text, node.signature)
        collect(node.name.text, sig: node.signature, body: node.body, node: node)
        return .skipChildren // nested decls attribute lexically via the body walk (documented)
    }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        collect("init", sig: node.signature, body: node.body, node: node)
        return .skipChildren
    }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Pass B — calls per function, with light local type inference
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// One argument's disposition at a call site: a closure literal (its body is already charged to
/// the passer lexically), a named reference (resolvable to a unit), or opaque.
enum ArgKind { case closure, named(String), opaque }
struct Call { var path: String; var leaf: String; var strArg: String?; var typed: Bool; var args: [ArgKind] = [] }

final class CallCollector: SyntaxVisitor {
    var vars: [String: String]              // local/param -> concrete type
    var fnTyped: Set<String>                // function-typed locals/params
    var opaqueFnLocals: Set<String> = []    // fn-typed LOCALS whose value is opaque (not a visible
                                            // closure): invoking one is §4 Unknown — only fn-typed
                                            // PARAMS can defer to call-site flow (callers pass them).
    var protoTyped: [String: String]        // param -> local protocol
    var arrayElem: [String: String]         // name -> element type of a `[T]` local/param (loop typing)
    var dictElem: [String: String]          // name -> VALUE type of a `[K: V]` local/param (dict loops)
    var tupleElem: [String: [String: String]]  // name -> tuple element types (`p.0` / `p.c`)
    let fields: [String: [String: (name: String?, isFunction: Bool)]]
    let fieldArrayElem: [String: [String: String]]  // Type -> field -> [T] element (self.field loops)
    let fieldDictValue: [String: [String: String]]  // Type -> field -> [K: V] value
    let localTypes: Set<String>
    let localProtocols: Set<String> // local protocol names — a receiver typed as one is DISPATCH
    let returns: [String: String]   // unambiguous factory return types (the candor-scan move)
    let enumCaseValueType: [String: String]  // unambiguous enum case -> associated value type
    var enclosingType: String?
    var calls: [Call] = []
    var directEffects: Set<String> = []
    var unresolved = false
    var why: Set<String> = []
    var hosts: Set<String> = []
    var cmds: Set<String> = []
    var paths: Set<String> = []
    var tables: Set<String> = []
    var protoDispatches: [(proto: String, member: String)] = []
    var propertyEdges: Set<String> = []   // `Type.member` candidates from property READS
    var callbackInvoked: Set<String> = [] // fn-typed params INVOKED — deferred to callback-flow

    init(info: FnInfo, fields: [String: [String: (name: String?, isFunction: Bool)]], localTypes: Set<String>,
         localProtocols: Set<String>, returns: [String: String],
         fieldArrayElem: [String: [String: String]], fieldDictValue: [String: [String: String]],
         enumCaseValueType: [String: String]) {
        self.enumCaseValueType = enumCaseValueType
        self.vars = info.params
        self.fnTyped = info.fnTypedParams
        self.protoTyped = info.protoParams
        self.arrayElem = info.arrayParams
        self.dictElem = info.dictParams
        self.tupleElem = info.tupleParams
        self.fields = fields
        self.fieldArrayElem = fieldArrayElem
        self.fieldDictValue = fieldDictValue
        self.localTypes = localTypes
        self.localProtocols = localProtocols
        self.returns = returns
        self.enclosingType = info.enclosingType
        super.init(viewMode: .sourceAccurate)
    }

    /// Peel the effect-transparent wrappers Swift puts around calls — `try`/`try?`/`await`/`!`/`?`.
    /// (The GRDB interop probe: every `try statement.execute()` receiver failed to type because
    /// the binding's initializer was a TryExpr, not the call itself.)
    static func peel(_ expr: ExprSyntax) -> ExprSyntax {
        var e = expr
        while true {
            if let t = e.as(TryExprSyntax.self) { e = t.expression; continue }
            if let a = e.as(AwaitExprSyntax.self) { e = a.expression; continue }
            if let f = e.as(ForceUnwrapExprSyntax.self) { e = f.expression; continue }
            if let o = e.as(OptionalChainingExprSyntax.self) { e = o.expression; continue }
            if let p = e.as(TupleExprSyntax.self), p.elements.count == 1, let only = p.elements.first {
                e = only.expression; continue
            }
            return e
        }
    }

    /// The receiver chain's root: `FileManager.default.contents` -> ("FileManager", path). A root
    /// identifier resolves through vars (param/let types); `self` resolves to the enclosing type.
    private func rootOf(_ raw: ExprSyntax) -> (root: String?, isVar: Bool, path: [String]) {
        let expr = Self.peel(raw)
        if let dr = expr.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            if n == "self" { return (enclosingType, true, []) }
            if let t = vars[n] { return (t, true, [n]) }
            // IMPLICIT SELF: a bare identifier inside a method body can be a FIELD of the
            // enclosing type (`handler.log(s)` ≡ `self.handler.log(s)`) — the protocol-field probe
            // found dispatchers resolving as raw names and missing the field index entirely.
            if let et = enclosingType, let f = fields[et]?[n], let ft = f.name {
                return (ft, true, [n])
            }
            return (n, false, [n])
        }
        if let ma = expr.as(MemberAccessExprSyntax.self) {
            // tuple element/member: `p.0` / `p.c` where p is a tuple-typed local/param
            if let baseDR = ma.base?.as(DeclReferenceExprSyntax.self),
               let elemType = tupleElem[baseDR.baseName.text]?[ma.declName.baseName.text] {
                return (elemType, true, [])
            }
            let inner = ma.base.map { rootOf($0) } ?? (root: nil, isVar: false, path: [])
            let member = ma.declName.baseName.text
            // WALK THROUGH A FIELD: if the chain so far is a local type with `member` as a stored
            // field, the chain's type becomes the FIELD's type — so `self.client.send()` /
            // `outer.inner.save()` resolve the method on the field's type, not the enclosing type
            // (explicit `self.field.method()` and field-of-field chains otherwise resolved against the
            // wrong type and dropped to pure — the bare-identifier implicit-self path already did this).
            if let rt = inner.root, let f = fields[rt]?[member], let ft = f.name, !f.isFunction {
                return (ft, true, inner.path + [member])
            }
            return (inner.root, inner.isVar, inner.path + [member])
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            // `Svc().act()` — a constructor call types the chain; a FACTORY's unambiguous return
            // type does too (`db.makeStatement(...).execute()` — the GRDB shape).
            if let ctor = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let n = ctor.baseName.text
                if n.first?.isUppercase == true { return (n, true, [n]) }
                if let rt = returns[n] { return (rt, true, [n]) }
            }
            if let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
               let rt = returns[ma.declName.baseName.text] {
                return (rt, true, [ma.declName.baseName.text])
            }
            return (nil, false, [])
        }
        // `coll[i]` — an array subscript yields the element type, a dictionary subscript the value
        // type (`cs[0].send()` / `d["k"]?.send()` resolved against the bare base and dropped to pure).
        if let sub = expr.as(SubscriptCallExprSyntax.self) {
            if let t = elementTypeOf(sub.calledExpression) ?? dictValueOf(sub.calledExpression) {
                return (t, true, [])
            }
        }
        // SwiftParser leaves operators UNFOLDED, so `x as! T` and `cond ? a : b` are SequenceExprs:
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            // `x as! T` / `x as? T` → `[operand, unresolvedAsExpr, typeExpr]`: the type is the result.
            if elems.count == 3, elems[1].is(UnresolvedAsExprSyntax.self),
               let te = elems[2].as(TypeExprSyntax.self), let t = typeName(te.type).name {
                return (t, true, [])
            }
            // `cond ? a : b` → `[cond, unresolvedTernaryExpr(then), elseExpr]`: both arms one type.
            if elems.count == 3, let tern = elems[1].as(UnresolvedTernaryExprSyntax.self) {
                let a = rootOf(tern.thenExpression), b = rootOf(elems[2])
                if let ra = a.root, ra == b.root, a.isVar, b.isVar { return (ra, true, []) }
            }
        }
        return (nil, false, [])
    }

    private func argKinds(_ node: FunctionCallExprSyntax) -> [ArgKind] {
        var kinds: [ArgKind] = node.arguments.map { a in
            let e = Self.peel(a.expression)
            if e.is(ClosureExprSyntax.self) { return .closure }
            if let dr = e.as(DeclReferenceExprSyntax.self) { return .named(dr.baseName.text) }
            return .opaque
        }
        if node.trailingClosure != nil { kinds.append(.closure) }
        for extra in node.additionalTrailingClosures { _ = extra; kinds.append(.closure) }
        return kinds
    }

    private func firstStringLiteral(_ args: LabeledExprListSyntax) -> String? {
        for a in args {
            guard let lit = a.expression.as(StringLiteralExprSyntax.self) else { continue }
            // Concatenate ALL plain segments: the parser may split a literal around escapes, so a
            // single-segment assumption silently dropped multi-line SQL (caught by the four-way
            // conformance differential on this engine's first wiring). An INTERPOLATED literal
            // (any non-plain segment) is runtime-computed — no literal claim, skip it.
            var out = ""
            var pure = true
            for seg in lit.segments {
                if let plain = seg.as(StringSegmentSyntax.self) { out += plain.content.text } else { pure = false; break }
            }
            if pure { return decodeEscapes(out) }
        }
        return nil
    }

    private func recordSurfaces(effect: String, lit: String?) {
        guard let lit else { return }
        switch effect {
        case "Net": hosts.insert(hostPart(lit))
        case "Exec":
            let head = lit.split(separator: " ").first.map(String.init) ?? lit
            cmds.insert(head)
            // a known literal head refines the cliff (curl→Net, candor→Fs/Env); Exec stays
            for e in classifyCommandHead(head) { directEffects.insert(e) }
        case "Fs": if lit.contains("/") || lit.hasPrefix(".") || lit.hasPrefix("~") { paths.insert(lit) }
        case "Db": for t in tablesInSql(lit) { tables.formUnion([t]) }
        default: break
        }
    }

    // The ELEMENT type a sequence yields per iteration. A `[T]` local/param/field; `self.field`; an
    // element-PRESERVING transform (`coll.filter/sorted/reversed/prefix/…`) → coll's element. A
    // literal/computed/transforming (map) sequence is left untyped — never guess.
    private func elementTypeOf(_ expr: ExprSyntax) -> String? {
        let e = Self.peel(expr)
        if let dr = e.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            if let t = arrayElem[n] { return t }
            if let et = enclosingType, let t = fieldArrayElem[et]?[n] { return t }  // implicit-self field
            return nil
        }
        if let ma = e.as(MemberAccessExprSyntax.self),
           ma.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self",
           let et = enclosingType, let t = fieldArrayElem[et]?[ma.declName.baseName.text] {
            return t  // `for x in self.items`
        }
        if let call = e.as(FunctionCallExprSyntax.self),
           let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
           ["filter", "sorted", "reversed", "shuffled", "prefix", "suffix", "dropFirst", "dropLast", "lazy"]
               .contains(ma.declName.baseName.text), let base = ma.base {
            return elementTypeOf(base)  // element-preserving transform → same element type
        }
        return nil
    }

    // The VALUE type a `[K: V]` yields (its `.values`, or the `v` of a `(k, v)` iteration).
    private func dictValueOf(_ expr: ExprSyntax) -> String? {
        let e = Self.peel(expr)
        if let dr = e.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            if let t = dictElem[n] { return t }
            if let et = enclosingType, let t = fieldDictValue[et]?[n] { return t }
        }
        if let ma = e.as(MemberAccessExprSyntax.self),
           ma.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self",
           let et = enclosingType, let t = fieldDictValue[et]?[ma.declName.baseName.text] { return t }
        return nil
    }

    // `for x in coll` / `for (k, v) in dict` / `for (i, x) in coll.enumerated()` — type the iteration
    // variable from the collection so its member calls resolve (else dropped to pure — §4 under-report).
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            if let elem = elementTypeOf(node.sequence) { vars[name] = elem }
        } else if let tup = node.pattern.as(TuplePatternSyntax.self), tup.elements.count == 2,
                  let second = tup.elements.last?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            if let v = dictValueOf(node.sequence) {
                vars[second] = v  // for (key, value) in dict — value carries the type
            } else if let call = Self.peel(node.sequence).as(FunctionCallExprSyntax.self),
                      let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
                      ma.declName.baseName.text == "enumerated", let base = ma.base,
                      let elem = elementTypeOf(base) {
                vars[second] = elem  // for (offset, element) in coll.enumerated()
            }
        }
        return .visitChildren
    }

    // Closure-receiving collection methods that pass each ELEMENT as the closure's first argument:
    // `coll.forEach/map/filter/compactMap/flatMap/first/contains/allSatisfy { x in x.method() }`.
    // Type that closure parameter (or `$0`) from the receiver's element type, so the closure body —
    // which charges lexically to the enclosing unit — resolves the element's member calls.
    private func typeForEachClosureParam(_ node: FunctionCallExprSyntax) {
        guard let ma = node.calledExpression.as(MemberAccessExprSyntax.self),
              ["forEach", "map", "filter", "compactMap", "flatMap", "first", "contains", "allSatisfy"].contains(ma.declName.baseName.text),
              let base = ma.base, let elem = elementTypeOf(base) else { return }
        let closure = node.trailingClosure
            ?? node.arguments.lazy.compactMap { $0.expression.as(ClosureExprSyntax.self) }.first
        guard let closure else { return }
        // explicit `{ x in … }` → first param; shorthand `{ $0.… }` → `$0`
        if let shorthand = closure.signature?.parameterClause?.as(ClosureShorthandParameterListSyntax.self),
           let first = shorthand.first {
            vars[first.name.text] = elem
        } else if let params = closure.signature?.parameterClause?.as(ClosureParameterClauseSyntax.self),
                  let first = params.parameters.first {
            vars[first.firstName.text] = elem
        } else if closure.signature == nil {
            vars["$0"] = elem
        }
    }

    // `case .active(let c):` / `if case .active(let c) = …` — an enum case pattern is parsed as a call
    // `.active(let c)` (leading-dot member, a `let`-binding arg). Type the binding from the case's
    // associated value type so `c.method()` resolves (else it dropped to pure — a §4 under-report).
    private func typeEnumCaseBinding(_ node: FunctionCallExprSyntax) {
        guard let ma = node.calledExpression.as(MemberAccessExprSyntax.self), ma.base == nil,
              let t = enumCaseValueType[ma.declName.baseName.text] else { return }
        for arg in node.arguments {
            if let pat = arg.expression.as(PatternExprSyntax.self),
               let vb = pat.pattern.as(ValueBindingPatternSyntax.self),
               let name = vb.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                vars[name] = t
            }
        }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        typeForEachClosureParam(node)
        typeEnumCaseBinding(node)
        let lit = firstStringLiteral(node.arguments)
        if let dr = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = dr.baseName.text
            if ["Data", "NSData", "String"].contains(name),
               node.arguments.first?.label?.text == "contentsOf" {
                let argText = node.arguments.description
                if argText.contains("fileURLWithPath") {
                    directEffects.insert("Fs")
                } else {
                    directEffects.formUnion(["Fs", "Net"]) // a URL value: file OR remote — one IS true
                }
            } else if opaqueFnLocals.contains(name) {
                // an OPAQUE local fn-typed value invoked (`let cb: () -> Void = stored!; cb()`):
                // its origin is indeterminate and it is NOT a parameter, so call-site flow can
                // never resolve it — §4 Unknown, directly. (Without this it fell through to the
                // param-deferral below and was silently resolved to pure whenever the enclosing
                // function had any caller — a soundness hole the fuzzer's forms didn't cover.)
                unresolved = true
                why.insert("callback:\(name)")
            } else if fnTyped.contains(name) {
                // a function-typed PARAM invoked — DEFERRED to callback-flow resolution: when
                // every visible call site passes a closure (already charged to its passer
                // lexically) or a named function (an edge), the Unknown is redundant; otherwise
                // it stands (§4). The TS engine's callback_named move.
                callbackInvoked.insert(name)
            } else if let eff = kappaFree(name: name, argCount: node.arguments.count) {
                directEffects.insert(eff)
                recordSurfaces(effect: eff, lit: lit)
            } else {
                calls.append(Call(path: name, leaf: name, strArg: lit, typed: false, args: argKinds(node)))
            }
        } else if let ma = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let member = ma.declName.baseName.text
            let base = ma.base.map { rootOf($0) } ?? (root: nil, isVar: false, path: [])
            // a function-typed FIELD invoked (`d.f()` where f: () -> Void) — the unknown_dyn case
            if let rt = base.root, let f = fields[rt]?[member], f.isFunction {
                unresolved = true
                why.insert("dispatch:\(rt).\(member)")
            } else if let pr = ma.base?.as(DeclReferenceExprSyntax.self), protoTyped[pr.baseName.text] != nil {
                // dispatch through a LOCAL protocol-typed param — bounded CHA or honest Unknown
                protoDispatches.append((protoTyped[pr.baseName.text]!, member))
            } else if let rt = base.root, localTypes.contains(rt) {
                // typed local receiver: Type.method — resolve to the local unit. Checked BEFORE the
                // κ classifier: a locally-declared type ALWAYS shadows the platform table, so a
                // project's own `class Channel`/`HTTPClient` (common names) resolves to its real
                // method instead of fabricating Net from the NIO tier (the GRDB `bind` lesson, for
                // member calls). Under-report-don't-fabricate.
                calls.append(Call(path: "\(rt).\(member)", leaf: member, strArg: lit, typed: true, args: argKinds(node)))
            } else if let rt = base.root, localProtocols.contains(rt) {
                // a PROTOCOL-typed receiver reached via a field/let/factory (`self.handler.log()`
                // where `var handler: LogHandler`) — the params-only protoTyped path missed these
                // ENTIRELY (not even Unknown — the density review's lever #1 turned out to be a
                // soundness hole). Same bounded CHA / honest-Unknown as protocol params. Also before
                // κ: a local protocol shadows the platform table.
                protoDispatches.append((rt, member))
            } else if let rt = base.root, let eff = kappaMember(root: rt, member: member) {
                directEffects.insert(eff)
                recordSurfaces(effect: eff, lit: lit)
            } else {
                calls.append(Call(path: member, leaf: member, strArg: lit, typed: false))
            }
        } else if node.calledExpression.is(ClosureExprSyntax.self) {
            // immediately-invoked closure: body walks lexically below — nothing to record
        } else {
            // computed callee (subscript, optional-chained value, …): §4 Unknown
            unresolved = true
            why.insert("call:computed")
        }
        return .visitChildren
    }

    // `guard let c = <expr>` / `if let c = <expr>` — type the unwrapped binding from the initializer
    // (a factory call, subscript, cast, …) so `c.method()` resolves. A shorthand `guard let c` (no
    // initializer) keeps the existing param/var type. The optional is stripped by typing the value.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
           let initVal = node.initializer?.value {
            let info = rootOf(initVal)
            if info.isVar, let t = info.root { vars[name] = t }
            else if let elem = elementTypeOf(initVal) { arrayElem[name] = elem }
        }
        return .visitChildren
    }

    // effectful property READS (no call): κ chains AND local accessor units (computed getters)
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.parent?.is(FunctionCallExprSyntax.self) != true {
            let info = rootOf(ExprSyntax(node))
            if let root = info.root, let eff = kappaPropertyRead(root: root, path: info.path) {
                directEffects.insert(eff)
            }
            // The accessor-unit edge uses the RECEIVER's type (rootOf of the BASE) — NOT the field-walked
            // whole node, whose root would be this property's own value type (`G().v` must edge to `G.v`,
            // the getter unit, not to `Int.v`). rootOf walks fields for method receivers; the terminal
            // property read here wants the type the property is read FROM.
            let recvRoot = node.base.map { rootOf($0).root } ?? info.root
            if let root = recvRoot, localTypes.contains(root) {
                propertyEdges.insert("\(root).\(node.declName.baseName.text)")
            }
        }
        return .visitChildren
    }

    // `let s = Svc()` / `let s: Svc = …` / `let f = { … }` — local bindings type later calls
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            // `let (a, b) = (X(), Y())` — destructure: bind each name from the initializer tuple element
            if let tp = binding.pattern.as(TuplePatternSyntax.self),
               let tupleInit = binding.initializer?.value.as(TupleExprSyntax.self) {
                for (pe, ve) in zip(tp.elements, tupleInit.elements) {
                    guard let n = pe.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                    let info = rootOf(ve.expression)
                    if info.isVar, let t = info.root { vars[n] = t }
                }
                continue
            }
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            if let ann = binding.typeAnnotation {
                if !tupleElements(ann.type).isEmpty { tupleElem[name] = tupleElements(ann.type) }  // `let p: (A, B)`
                let t = typeName(ann.type)
                if t.isFunction {
                    fnTyped.insert(name); vars.removeValue(forKey: name)
                    // A fn-typed local: a VISIBLE closure initializer walks lexically (its effects
                    // are already charged), so it is not opaque; anything else (a field/factory/
                    // force-unwrap value, or no initializer) IS opaque — invoking it is Unknown.
                    if let v0 = binding.initializer?.value, Self.peel(v0).is(ClosureExprSyntax.self) {
                        opaqueFnLocals.remove(name)
                    } else {
                        opaqueFnLocals.insert(name)
                    }
                }
                else if let tn = t.name { vars[name] = tn }
                else if let elem = arrayElementName(ann.type) { arrayElem[name] = elem }  // `let xs: [T]`
                else if let val = dictValueName(ann.type) { dictElem[name] = val }        // `let m: [K: V]`
            } else if let v0 = binding.initializer?.value {
                let v = Self.peel(v0)
                if v.is(ClosureExprSyntax.self) {
                    // visible local closure: body walks lexically; calling it adds nothing
                    fnTyped.remove(name)
                    opaqueFnLocals.remove(name)
                    vars.removeValue(forKey: name)
                } else if v.is(FunctionCallExprSyntax.self) {
                    // ctor or unambiguous factory — one resolver for both (rootOf handles peeling)
                    let info = rootOf(v)
                    if let t = info.root, info.isVar { vars[name] = t }
                    // a collection TRANSFORM result keeps the element type: `let active = cs.filter {…}`
                    // (then `for c in active` resolves). Element-preserving transforms only.
                    else if let elem = elementTypeOf(v0) { arrayElem[name] = elem }
                } else if let ma = v.as(MemberAccessExprSyntax.self),
                          let baseDR = ma.base?.as(DeclReferenceExprSyntax.self),
                          baseDR.baseName.text.first?.isUppercase == true,
                          SINGLETON_ACCESSORS.contains(ma.declName.baseName.text) {
                    // `let fm = FileManager.default` / `URLSession.shared` — a singleton accessor on a
                    // type returns an instance of that type, so the var carries it (else its member
                    // calls resolved against the bare identifier and dropped to pure; the inline
                    // `FileManager.default.removeItem` already classified Fs, the let-bound did not).
                    vars[name] = baseDR.baseName.text
                } else if v.is(SequenceExprSyntax.self) || v.is(SubscriptCallExprSyntax.self) {
                    // `let c = x as! T` / `let c = cond ? a : b` / `let c = cs[0]` — rootOf types these
                    let info = rootOf(v0)
                    if info.isVar, let t = info.root { vars[name] = t }
                }
            }
        }
        return .visitChildren
    }
}

/// SwiftSyntax segment text is SOURCE-ACCURATE: `"a\nb"` arrives with a literal backslash-n.
/// The four-way conformance differential caught this on the engine's FIRST wiring (the Java
/// space-escape bug's twin: multi-line SQL glued, quoted identifiers kept their backslashes).
func decodeEscapes(_ raw: String) -> String {
    var out = ""
    var it = raw.makeIterator()
    while let c = it.next() {
        guard c == "\\", let n = it.next() else { out.append(c); continue }
        switch n {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "0": out.append("\0")
        case "\\": out.append("\\")
        case "\"": out.append("\"")
        case "'": out.append("'")
        default: out.append(c); out.append(n) // unknown escape (\u{…} etc.): keep raw, never guess
        }
    }
    return out
}

func hostPart(_ s: String) -> String {
    var h = s
    for scheme in ["https://", "http://", "wss://", "ws://", "tcp://"] where h.hasPrefix(scheme) {
        h = String(h.dropFirst(scheme.count))
    }
    if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
    return h
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Drive the two passes
// ════════════════════════════════════════════════════════════════════════════════════════════════

var allFns: [FnInfo] = []
var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:]
var fieldArrayElem: [String: [String: String]] = [:]
var fieldDictValue: [String: [String: String]] = [:]
var caseAssocAll: [String: Set<String>] = [:]
var protocolMethods: [String: Set<String>] = [:]
var conformers: [String: [String]] = [:]
var localTypes: Set<String> = []
var returnsIdx: [String: String] = [:]
var importCounts: [String: Int] = [:]
// The package's OWN target modules (SPM convention: Sources/<TargetName>/) — an internal import is
// local code the walk already analyzes, not a third-party blind spot (the sweep's ledger noise:
// swift-log importing its own Logging target read as unknown).
var internalModules: Set<String> = [pkgName]
for sub in ["Sources", "Source"] {
    let p = (rootDir as NSString).appendingPathComponent(sub)
    if let entries = try? fm.contentsOfDirectory(atPath: p) {
        for e in entries where !e.hasPrefix(".") { internalModules.insert(e) }
    }
}
// Non-Sources layouts (GRDB/, Alamofire's Source/*.swift): the manifest's own TARGET names are
// the internal-module ground truth — and ONLY target declarations: a bare `name:` regex also
// swallowed `.product(name: "NIOCore", …)` dependency products, silencing exactly the third-party
// modules the κ ledger exists to name (vapor's whole NIO surface vanished from the disclosure).
if let manifest = try? String(contentsOfFile: (rootDir as NSString).appendingPathComponent("Package.swift"), encoding: .utf8) {
    var search = manifest[...]
    while let r = search.range(of: #"\.(executableTarget|testTarget|target|plugin|macro)\(\s*name:\s*"([^"]+)""#,
                               options: .regularExpression) {
        let m = String(search[r])
        if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
            internalModules.insert(String(m[m.index(after: q1)..<q2]))
        }
        search = search[r.upperBound...]
    }
}

var collectors: [DeclCollector] = []
for p in sourcePaths {
    guard let src = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
    let tree = Parser.parse(source: src)
    let rel = p.hasPrefix(rootDir) ? String(p.dropFirst(rootDir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : p
    let c = DeclCollector(file: rel, tree: tree)
    c.walk(tree)
    collectors.append(c)
}
var returnsTmp: [String: String?] = [:]
for c in collectors {
    for (k, v) in c.returnsTmp {
        if let existing = returnsTmp[k] {
            if existing != v { returnsTmp[k] = String?.none }
        } else {
            returnsTmp[k] = v
        }
    }
    allFns.append(contentsOf: c.fns)
    for (t, fs) in c.fields { fields[t, default: [:]].merge(fs) { a, _ in a } }
    for (t, fs) in c.fieldArrayElem { fieldArrayElem[t, default: [:]].merge(fs) { a, _ in a } }
    for (t, fs) in c.fieldDictValue { fieldDictValue[t, default: [:]].merge(fs) { a, _ in a } }
    for (cn, ts) in c.caseAssoc { caseAssocAll[cn, default: []].formUnion(ts) }
    for (pn, ms) in c.protocolMethods { protocolMethods[pn, default: []].formUnion(ms) }
    for (pn, ts) in c.conformers { conformers[pn, default: []].append(contentsOf: ts) }
    localTypes.formUnion(c.localTypes)
    for m in c.imports { importCounts[m, default: 0] += 1 }
}

// name indexes for resolution — UNAMBIGUOUS only (the family's never-guess rule)
var freeFnByName: [String: [String]] = [:]
var byQual: Set<String> = []
for f in allFns {
    byQual.insert(f.qual)
    if f.enclosingType == nil { freeFnByName[f.qual, default: []].append(f.qual) }
}

for (k, v) in returnsTmp { if let t = v { returnsIdx[k] = t } }
// An enum case binds a value type only when it is UNAMBIGUOUS project-wide (one assoc type) —
// the same "never guess on an ambiguous leaf" discipline as the returns index.
var enumCaseValueType: [String: String] = [:]
for (cn, ts) in caseAssocAll where ts.count == 1 { enumCaseValueType[cn] = ts.first! }

var direct: [String: Set<String>] = [:]
var edges: [String: Set<String>] = [:]
var unresolvedSet: Set<String> = []
var whyMap: [String: Set<String>] = [:]
var hostsD: [String: Set<String>] = [:], cmdsD: [String: Set<String>] = [:]
var pathsD: [String: Set<String>] = [:], tablesD: [String: Set<String>] = [:]
var locOf: [String: String] = [:]
var entryPoints: Set<String> = []
var kappaSawClassified = false
var callsiteArgs: [String: [[ArgKind]]] = [:]   // resolved target -> each call site's arg kinds
var deferredCallbacks: [String: (indexes: Set<Int>, names: Set<String>)] = [:]

let localProtocolNames = Set(protocolMethods.keys)  // loop-invariant: build once, not per fn
for f in allFns {
    locOf[f.qual] = f.loc
    if f.isMain { entryPoints.insert(f.qual) }
    edges[f.qual] = edges[f.qual] ?? []
    guard let body = f.body else { continue }
    let cc = CallCollector(info: f, fields: fields, localTypes: localTypes,
                           localProtocols: localProtocolNames, returns: returnsIdx,
                           fieldArrayElem: fieldArrayElem, fieldDictValue: fieldDictValue,
                           enumCaseValueType: enumCaseValueType)
    cc.walk(body)
    // accessor units: a property READ of a known accessor unit is an edge (the reader inherits
    // the getter's effects — `c.data` reaching the Fs inside `var data: Data { … }`)
    edges[f.qual, default: []].formUnion(cc.propertyEdges.filter { byQual.contains($0) })
    direct[f.qual, default: []].formUnion(cc.directEffects)
    if !cc.directEffects.isEmpty { kappaSawClassified = true }
    if cc.unresolved { direct[f.qual, default: []].insert("Unknown"); unresolvedSet.insert(f.qual) }
    whyMap[f.qual, default: []].formUnion(cc.why)
    hostsD[f.qual, default: []].formUnion(cc.hosts)
    cmdsD[f.qual, default: []].formUnion(cc.cmds)
    pathsD[f.qual, default: []].formUnion(cc.paths)
    tablesD[f.qual, default: []].formUnion(cc.tables)

    // fn-typed params INVOKED: defer to callback-flow (resolved after all call sites are known)
    if !cc.callbackInvoked.isEmpty {
        var idxs = Set<Int>()
        for n in cc.callbackInvoked {
            if let i = f.fnTypedParamIndex[n] { idxs.insert(i) }
        }
        deferredCallbacks[f.qual] = (idxs, cc.callbackInvoked)
    }
    for call in cc.calls {
        if call.typed {
            if byQual.contains(call.path) {
                edges[f.qual, default: []].insert(call.path)
                callsiteArgs[call.path, default: []].append(call.args)
            }
        } else if let targets = freeFnByName[call.path], targets.count == 1 {
            edges[f.qual, default: []].insert(targets[0])
            callsiteArgs[targets[0], default: []].append(call.args)
        } else if localTypes.contains(call.path), byQual.contains("\(call.path).init") {
            // `_ = C0()` — a constructor call edges to the declared init (the fuzzer's init_wired
            // form caught this silent-pure hole on the harness's FIRST run: effects wired in an
            // initializer vanished — the same hole the TS engine's got-dogfood found in ctors).
            edges[f.qual, default: []].insert("\(call.path).init")
        } else if f.enclosingType != nil, byQual.contains("\(f.enclosingType!).\(call.leaf)") {
            // an unqualified call inside a type body reaches the sibling method
            edges[f.qual, default: []].insert("\(f.enclosingType!).\(call.leaf)")
        }
        // otherwise: unresolvable bare member — stays out (under-report, never a guess); the κ
        // ledger and Unknown rules above carry the honesty.
    }

    // Bounded CHA over local protocols (SPEC §4, 0.4): the protocol is local and declares the
    // method; resolve ≤12 conformers, otherwise honest Unknown.
    for d in cc.protoDispatches {
        guard protocolMethods[d.proto]?.contains(d.member) == true else { continue }
        let impls = (conformers[d.proto] ?? []).filter { byQual.contains("\($0).\(d.member)") }
        if !impls.isEmpty && impls.count <= 12 && impls.count == (conformers[d.proto] ?? []).count {
            for t in impls { edges[f.qual, default: []].insert("\(t).\(d.member)") }
        } else {
            direct[f.qual, default: []].insert("Unknown")
            unresolvedSet.insert(f.qual)
            whyMap[f.qual, default: []].insert("dispatch:\(d.proto).\(d.member)")
        }
    }
}

// Callback-flow resolution (the TS engine's callback_named, the Rust closure-flow slice): a
// deferred fn-typed-param invocation drops its Unknown iff EVERY visible call site passes a
// closure literal (charged to its passer lexically) or a NAMED local function (edged here).
// No visible call site, a missing arg, or an opaque value: the §4 Unknown stands.
for (fq, info) in deferredCallbacks {
    let sites = callsiteArgs[fq] ?? []
    var resolved = !sites.isEmpty
    var namedTargets: Set<String> = []
    outer: for site in sites {
        for idx in info.indexes {
            guard idx < site.count else { resolved = false; break outer }
            switch site[idx] {
            case .named(let n):
                if let t = freeFnByName[n], t.count == 1 { namedTargets.insert(t[0]) }
                else { resolved = false; break outer }
            case .closure, .opaque:
                // a CLOSURE arg stays opaque for the deferral (the Rust/TS rule — its body is
                // charged to the passer, but the receiver still executes an unaddressable value:
                // the §4 Unknown stands; the fuzzer caught the looser reading red-handed)
                resolved = false; break outer
            }
        }
    }
    if resolved {
        edges[fq, default: []].formUnion(namedTargets)
    } else {
        direct[fq, default: []].insert("Unknown")
        unresolvedSet.insert(fq)
        for n in info.names { whyMap[fq, default: []].insert("callback:\(n)") }
    }
}

// fixpoint: effects + literal surfaces propagate over edges
func propagate(_ seed: [String: Set<String>], over edges: [String: Set<String>]) -> [String: Set<String>] {
    var acc = seed
    var changed = true
    while changed {
        changed = false
        for (caller, callees) in edges {
            for callee in callees {
                guard let add = acc[callee], !add.isEmpty else { continue }
                let before = acc[caller]?.count ?? 0
                acc[caller, default: []].formUnion(add)
                if (acc[caller]?.count ?? 0) != before { changed = true }
            }
        }
    }
    return acc
}
let inferred = propagate(direct, over: edges)
let hostsAcc = propagate(hostsD, over: edges), cmdsAcc = propagate(cmdsD, over: edges)
let pathsAcc = propagate(pathsD, over: edges), tablesAcc = propagate(tablesD, over: edges)

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Report (§2 envelope, spec 0.4) + sidecar (§2.2) + receipt + κ ledger (§7.14)
// ════════════════════════════════════════════════════════════════════════════════════════════════

let prefix = outPrefix ?? (rootDir as NSString).appendingPathComponent(".candor/report")
try? fm.createDirectory(atPath: (prefix as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

let accessorQuals = Set(allFns.filter { $0.isAccessor }.map { $0.qual })
var entries: [[String: Any]] = []
for qual in inferred.keys.sorted() {
    let inf = inferred[qual] ?? []
    if inf.isEmpty { continue }
    var e: [String: Any] = [
        "fn": qual,
        "loc": locOf[qual] ?? "",
        "inferred": inf.sorted(),
        "direct": (direct[qual] ?? []).sorted(),
        "declared": [], "undeclared": [], "overdeclared": [],
        "unresolved": inf.contains("Unknown"),
        "hash": "\(pkgName)#\(qual)",   // 0.4 MUST: every report is chainable
        "calls": (edges[qual] ?? []).sorted(),
    ]
    if entryPoints.contains(qual) { e["entryPoint"] = true }
    if accessorQuals.contains(qual) { e["unitKind"] = "accessor" }  // spec 0.5 draft, informative
    if let w = whyMap[qual], !w.isEmpty { e["unknownWhy"] = w.sorted() }
    if let h = hostsAcc[qual], !h.isEmpty { e["hosts"] = h.sorted() }
    if let c = cmdsAcc[qual], !c.isEmpty { e["cmds"] = c.sorted() }
    if let p = pathsAcc[qual], !p.isEmpty { e["paths"] = p.sorted() }
    if let t = tablesAcc[qual], !t.isEmpty, inf.contains("Db") { e["tables"] = t.sorted() }
    entries.append(e)
}
let envelope: [String: Any] = [
    "candor": ["version": engineVersion, "toolchain": "swiftsyntax", "spec": "0.4"],
    "package": pkgName,
    "functions": entries,
]
var cg: [String: [String]] = [:]
for f in allFns { cg[f.qual] = (edges[f.qual] ?? []).sorted() }  // §2.2: EVERY analyzed fn a key

func writeJson(_ obj: Any, _ path: String) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    // `.atomic`: Foundation writes to an auxiliary file and renames into place, so a concurrent reader
    // (a cross-engine candor-query / candor-ts merging this report as a sibling) never observes a
    // half-written file — the same write invariant the Rust and TS backends now hold (write_atomic).
    try! data.write(to: URL(fileURLWithPath: path), options: .atomic)
}
// Family filename shape `<prefix>.<pkg>.Swift.json` — what candor_report::report_files DISCOVERS,
// so the unmodified candor-query binary works on Swift reports (this engine's whole consumption
// story; caught by the first query-interop probe: `show` couldn't find a `<prefix>.json`). The
// pkg segment is dot-sanitized (`GRDB.swift` would otherwise split the <crate>.<kind> parse).
let fileSafePkg = pkgName.replacingOccurrences(of: ".", with: "-")
let reportPath = "\(prefix).\(fileSafePkg).Swift.json"
writeJson(envelope, reportPath)
writeJson(cg, "\(prefix).\(fileSafePkg).Swift.callgraph.json")
FileHandle.standardError.write(
    "candor-swift: wrote \(entries.count) effectful functions (\(allFns.count) analyzed, \(sourcePaths.count) files) to \(reportPath)\n".data(using: .utf8)!)

// the κ-coverage ledger: imported modules outside the platform frontier that κ doesn't know —
// INVISIBLE, not Unknown; named per scan (SPEC §7 item 14, canonical marker)
let unlisted = importCounts.filter { !PLATFORM_MODULES.contains($0.key) && !KAPPA_MODULES.contains($0.key) && !internalModules.contains($0.key) }
    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
if !unlisted.isEmpty {
    let shown = unlisted.prefix(8).map { "\($0.key) (\($0.value) import\($0.value == 1 ? "" : "s"))" }.joined(separator: ", ")
    let more = unlisted.count > 8 ? " + \(unlisted.count - 8) more" : ""
    FileHandle.standardError.write(
        ("candor-swift: κ doesn't know \(unlisted.count) module\(unlisted.count == 1 ? "" : "s") this code imports — "
         + "effects through \(unlisted.count == 1 ? "it are" : "them are") INVISIBLE (not Unknown): \(shown)\(more)\n").data(using: .utf8)!)
}
_ = kappaSawClassified

// ════════════════════════════════════════════════════════════════════════════════════════════════
// §6.2 policy gate (deny / pure / allow / forbid) — token-for-token with the family parsers
// ════════════════════════════════════════════════════════════════════════════════════════════════

let EFFECTS: Set<String> = ["Net", "Fs", "Db", "Exec", "Env", "Clock", "Ipc", "Log", "Rand", "Clipboard"]
let ALLOW_EFFECTS: Set<String> = ["Net", "Exec", "Fs", "Db"]

struct DenyRule { var effects: [String]; var scope: String; var raw: String }
struct AllowRule { var effect: String; var scope: String; var values: [String]; var raw: String }
struct ForbidRule { var from: String; var to: String; var raw: String }

func warnRule(_ why: String, _ line: String) {
    FileHandle.standardError.write("candor: ignoring policy rule (\(why)): \(line)\n".data(using: .utf8)!)
}

func parsePolicy(_ text: String) -> (deny: [DenyRule], allow: [AllowRule], forbid: [ForbidRule]) {
    var deny: [DenyRule] = [], allow: [AllowRule] = [], forbid: [ForbidRule] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let t = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        switch t[0] {
        case "deny":
            var effects: [String] = []; var scope = ""
            for tok in t.dropFirst() {
                if EFFECTS.contains(tok) || tok == "Unknown" { effects.append(tok) } else { scope = tok; break }
            }
            if effects.isEmpty { warnRule("deny names no known effect", line); continue }
            deny.append(DenyRule(effects: effects.sorted(), scope: scope, raw: line))
        case "pure":
            deny.append(DenyRule(effects: [], scope: t.count > 1 ? t[1] : "", raw: line))
        case "allow":
            guard t.count >= 3 else { warnRule("allow names no values", line); continue }
            guard ALLOW_EFFECTS.contains(t[1]) else {
                warnRule("allow supports only Net hosts / Exec commands / Fs paths / Db tables", line); continue
            }
            var scope = ""; var vi = 2
            if t[2] == "in" { scope = t.count > 3 ? t[3] : ""; vi = 4 }
            let values = Array(t.dropFirst(vi))
            if values.isEmpty { warnRule("allow names no values", line); continue }
            allow.append(AllowRule(effect: t[1], scope: scope, values: values.sorted(), raw: line))
        case "forbid":
            let a = t.count > 1 ? t[1] : "", arrow = t.count > 2 ? t[2] : "", b = t.count > 3 ? t[3] : ""
            if a.isEmpty || arrow != "->" || b.isEmpty { warnRule("want `forbid <scope> -> <scope>`", line); continue }
            forbid.append(ForbidRule(from: a, to: b, raw: line))
        default:
            warnRule("unknown rule kind", line)
        }
    }
    return (deny, allow, forbid)
}

/// §6.2 scope match: segment run over ".", last segment a prefix.
func scopeMatches(_ name: String, _ scope: String) -> Bool {
    if scope.isEmpty { return true }
    let segs = name.split(separator: ".").map(String.init)
    let parts = scope.split(separator: ".").map(String.init)
    if parts.isEmpty || parts.count > segs.count { return false }
    let last = parts[parts.count - 1], initParts = parts.dropLast()
    outer: for i in 0...(segs.count - parts.count) {
        for (k, ip) in initParts.enumerated() where segs[i + k] != ip { continue outer }
        if segs[i + parts.count - 1].hasPrefix(last) { return true }
    }
    return false
}

func cmdBase(_ c: String) -> String { c.split(separator: "/").last.map(String.init) ?? c }
func pathCovered(_ allowed: String, _ reached: String) -> Bool {
    if reached.contains("..") { return false }
    if allowed == reached { return true }
    let a = allowed.hasSuffix("/") ? allowed : allowed + "/"
    return reached.hasPrefix(a)
}
func dbTableCovered(_ allowed: String, _ reached: String) -> Bool {
    let a = allowed.lowercased(), r = reached.lowercased()
    if a.hasSuffix(".*") { return r.hasPrefix(String(a.dropLast(2)) + ".") }
    return a == r
}
func literalAllowed(_ effect: String, _ reached: String, _ values: [String]) -> Bool {
    switch effect {
    case "Net": return values.contains { hostPart($0) == hostPart(reached) }
    case "Exec": return values.contains { cmdBase($0) == cmdBase(reached) }
    case "Fs": return values.contains { pathCovered($0, reached) }
    case "Db": return values.contains { dbTableCovered($0, reached) }
    default: return false
    }
}

if let pp = policyPath {
    guard let text = try? String(contentsOfFile: pp, encoding: .utf8) else {
        FileHandle.standardError.write("candor-swift: policy \(pp) could not be read; gate NOT enforced\n".data(using: .utf8)!)
        exit(2)
    }
    let pol = parsePolicy(text)
    var violations: [String] = []
    for qual in inferred.keys.sorted() {
        let inf = inferred[qual] ?? []
        if inf.isEmpty { continue }
        for r in pol.deny where scopeMatches(qual, r.scope) {
            let hits = r.effects.isEmpty ? inf.sorted() : inf.sorted().filter { r.effects.contains($0) }
            if !hits.isEmpty {
                violations.append("[AS-EFF-006] `\(qual)` performs { \(hits.joined(separator: ", ")) }, forbidden by policy: `\(r.raw)`")
            }
        }
        for r in pol.allow where scopeMatches(qual, r.scope) && inf.contains(r.effect) {
            let surface: Set<String>
            switch r.effect {
            case "Net": surface = hostsAcc[qual] ?? []
            case "Exec": surface = cmdsAcc[qual] ?? []
            case "Db": surface = tablesAcc[qual] ?? []
            default: surface = pathsAcc[qual] ?? []
            }
            if surface.isEmpty {
                violations.append("[AS-EFF-008] `\(qual)` performs \(r.effect) with no visible literal — the surface cannot be certified: `\(r.raw)`")
            } else {
                let bad = surface.filter { !literalAllowed(r.effect, $0, r.values) }.sorted()
                if !bad.isEmpty {
                    violations.append("[AS-EFF-008] `\(qual)` reaches { \(bad.joined(separator: ", ")) } outside the allowlist: `\(r.raw)`")
                }
            }
        }
    }
    for r in pol.forbid {
        for fn in cg.keys.sorted() where scopeMatches(fn, r.from) {
            var seen: Set<String> = [fn], stack = cg[fn] ?? []
            while let cur = stack.popLast() {
                if !seen.insert(cur).inserted { continue }
                if scopeMatches(cur, r.to) {
                    violations.append("[AS-EFF-009] `\(fn)` (scope `\(r.from)`) transitively reaches `\(cur)` in forbidden scope `\(r.to)`: `\(r.raw)`")
                    break
                }
                stack.append(contentsOf: cg[cur] ?? [])
            }
        }
    }
    for v in violations { print(v) }
    if violations.isEmpty {
        FileHandle.standardError.write("candor-swift: policy ✓\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("candor-swift: \(violations.count) policy violation(s)\n".data(using: .utf8)!)
        exit(1)
    }
}
