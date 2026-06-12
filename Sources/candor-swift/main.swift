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

var target = "."
var outPrefix: String? = nil
var policyPath: String? = ProcessInfo.processInfo.environment["CANDOR_POLICY"]
var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIter.next() {
    switch a {
    case "--out": outPrefix = argIter.next()
    case "--policy": policyPath = argIter.next()
    case "-h", "--help":
        print("""
        candor-swift — Swift effect scanner (candor-spec 0.4)
        USAGE: candor-swift [<dir|file.swift>] [--out <prefix>] [--policy <file>]
          writes <prefix>.json (report, spec 0.4 envelope) + <prefix>.callgraph.json
          CANDOR_POLICY honoured when --policy absent; exit 1 on violation, 2 on unreadable policy.
        """)
        exit(0)
    default: target = a
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
    return parts.contains(".build") || parts.contains(where: { $0.hasSuffix("Tests") || $0 == "Tests" })
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
    case "system", "posix_spawn", "execv", "execvp", "fork": return "Exec"
    case "fopen", "open", "unlink", "mkdir", "rmdir", "rename": return "Fs"
    case "socket", "connect", "bind", "listen": return "Net"
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

/// Modules the platform frontier owns (κ's actual job) — everything else imported is either in
/// the κ module set or NAMED by the ledger.
let PLATFORM_MODULES: Set<String> = ["Swift", "Foundation", "FoundationNetworking", "FoundationXML",
    "Dispatch", "os", "OSLog", "Darwin", "Glibc", "Combine", "Observation", "SwiftUI", "AppKit",
    "UIKit", "CoreFoundation", "System", "RegexBuilder", "Synchronization", "Testing", "XCTest"]
let KAPPA_MODULES: Set<String> = ["Network", "SQLite3", "CoreData"]

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
    var protoParams: [String: String] = [:]  // param name -> local protocol name
    var body: CodeBlockSyntax?
    var enclosingType: String?
    var isMain: Bool = false
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

final class DeclCollector: SyntaxVisitor {
    var file: String
    var converter: SourceLocationConverter
    var fns: [FnInfo] = []
    var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:] // Type -> field -> info
    var protocolMethods: [String: Set<String>] = [:]   // protocol -> declared method names
    var conformers: [String: [String]] = [:]           // protocol -> conforming local types
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
        let name = typeName(node.extendedType).name ?? "?"
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

    // Field types (for `self.f()` / `d.f()` resolution and fn-typed-field Unknown).
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if let ty = typeStack.last {
            for binding in node.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                if let ann = binding.typeAnnotation {
                    let info = typeName(ann.type)
                    fields[ty, default: [:]][name] = info
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

    private func collect(_ name: String, sig: FunctionSignatureSyntax, body: CodeBlockSyntax?, node: some SyntaxProtocol) {
        var info = FnInfo(qual: typeStack.last.map { "\($0).\(name)" } ?? name, loc: loc(node))
        info.enclosingType = typeStack.last
        info.body = body
        info.isMain = name == "main"
        for p in sig.parameterClause.parameters {
            let pname = (p.secondName ?? p.firstName).text
            let t = typeName(p.type)
            if t.isFunction { info.fnTypedParams.insert(pname) }
            else if let tn = t.name {
                if protocolMethods[tn] != nil { info.protoParams[pname] = tn } else { info.params[pname] = tn }
            }
        }
        fns.append(info)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
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

struct Call { var path: String; var leaf: String; var strArg: String?; var typed: Bool }

final class CallCollector: SyntaxVisitor {
    var vars: [String: String]              // local/param -> concrete type
    var fnTyped: Set<String>                // function-typed locals/params
    var protoTyped: [String: String]        // param -> local protocol
    let fields: [String: [String: (name: String?, isFunction: Bool)]]
    let localTypes: Set<String>
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

    init(info: FnInfo, fields: [String: [String: (name: String?, isFunction: Bool)]], localTypes: Set<String>) {
        self.vars = info.params
        self.fnTyped = info.fnTypedParams
        self.protoTyped = info.protoParams
        self.fields = fields
        self.localTypes = localTypes
        self.enclosingType = info.enclosingType
        super.init(viewMode: .sourceAccurate)
    }

    /// The receiver chain's root: `FileManager.default.contents` -> ("FileManager", path). A root
    /// identifier resolves through vars (param/let types); `self` resolves to the enclosing type.
    private func rootOf(_ expr: ExprSyntax) -> (root: String?, isVar: Bool, path: [String]) {
        if let dr = expr.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            if n == "self" { return (enclosingType, true, []) }
            if let t = vars[n] { return (t, true, [n]) }
            return (n, false, [n])
        }
        if let ma = expr.as(MemberAccessExprSyntax.self) {
            let inner = ma.base.map { rootOf($0) } ?? (root: nil, isVar: false, path: [])
            return (inner.root, inner.isVar, inner.path + [ma.declName.baseName.text])
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            // `Svc().act()` — a constructor call types the chain; other call results stay unknown.
            if let ctor = call.calledExpression.as(DeclReferenceExprSyntax.self),
               ctor.baseName.text.first?.isUppercase == true {
                return (ctor.baseName.text, true, [ctor.baseName.text])
            }
            return (nil, false, [])
        }
        return (nil, false, [])
    }

    private func firstStringLiteral(_ args: LabeledExprListSyntax) -> String? {
        for a in args {
            if let lit = a.expression.as(StringLiteralExprSyntax.self),
               lit.segments.count == 1, let seg = lit.segments.first?.as(StringSegmentSyntax.self) {
                return seg.content.text
            }
        }
        return nil
    }

    private func recordSurfaces(effect: String, lit: String?) {
        guard let lit else { return }
        switch effect {
        case "Net": hosts.insert(hostPart(lit))
        case "Exec": cmds.insert(lit.split(separator: " ").first.map(String.init) ?? lit)
        case "Fs": if lit.contains("/") || lit.hasPrefix(".") || lit.hasPrefix("~") { paths.insert(lit) }
        case "Db": for t in tablesInSql(lit) { tables.formUnion([t]) }
        default: break
        }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let lit = firstStringLiteral(node.arguments)
        if let dr = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = dr.baseName.text
            if fnTyped.contains(name) {
                // a function-typed parameter invoked: §4 — could be anything
                unresolved = true
                why.insert("callback:\(name)")
            } else if let eff = kappaFree(name: name, argCount: node.arguments.count) {
                directEffects.insert(eff)
                recordSurfaces(effect: eff, lit: lit)
            } else {
                calls.append(Call(path: name, leaf: name, strArg: lit, typed: false))
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
            } else if let rt = base.root, let eff = kappaMember(root: rt, member: member) {
                directEffects.insert(eff)
                recordSurfaces(effect: eff, lit: lit)
            } else if let rt = base.root, localTypes.contains(rt) {
                // typed local receiver: Type.method — resolve to the local unit
                calls.append(Call(path: "\(rt).\(member)", leaf: member, strArg: lit, typed: true))
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

    // effectful property READS (no call): ProcessInfo…environment, Date.now, pasteboards
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.parent?.is(FunctionCallExprSyntax.self) != true {
            let info = rootOf(ExprSyntax(node))
            if let root = info.root, let eff = kappaPropertyRead(root: root, path: info.path) {
                directEffects.insert(eff)
            }
        }
        return .visitChildren
    }

    // `let s = Svc()` / `let s: Svc = …` / `let f = { … }` — local bindings type later calls
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            if let ann = binding.typeAnnotation {
                let t = typeName(ann.type)
                if t.isFunction { fnTyped.insert(name); vars.removeValue(forKey: name) }
                else if let tn = t.name { vars[name] = tn }
            } else if let v = binding.initializer?.value {
                if v.is(ClosureExprSyntax.self) {
                    // visible local closure: body walks lexically; calling it adds nothing
                    fnTyped.remove(name)
                    vars.removeValue(forKey: name)
                } else if let call = v.as(FunctionCallExprSyntax.self),
                          let ctor = call.calledExpression.as(DeclReferenceExprSyntax.self),
                          ctor.baseName.text.first?.isUppercase == true {
                    vars[name] = ctor.baseName.text
                }
            }
        }
        return .visitChildren
    }
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
var protocolMethods: [String: Set<String>] = [:]
var conformers: [String: [String]] = [:]
var localTypes: Set<String> = []
var importCounts: [String: Int] = [:]

var collectors: [DeclCollector] = []
for p in sourcePaths {
    guard let src = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
    let tree = Parser.parse(source: src)
    let rel = p.hasPrefix(rootDir) ? String(p.dropFirst(rootDir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : p
    let c = DeclCollector(file: rel, tree: tree)
    c.walk(tree)
    collectors.append(c)
}
for c in collectors {
    allFns.append(contentsOf: c.fns)
    for (t, fs) in c.fields { fields[t, default: [:]].merge(fs) { a, _ in a } }
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

var direct: [String: Set<String>] = [:]
var edges: [String: Set<String>] = [:]
var unresolvedSet: Set<String> = []
var whyMap: [String: Set<String>] = [:]
var hostsD: [String: Set<String>] = [:], cmdsD: [String: Set<String>] = [:]
var pathsD: [String: Set<String>] = [:], tablesD: [String: Set<String>] = [:]
var locOf: [String: String] = [:]
var entryPoints: Set<String> = []
var kappaSawClassified = false

for f in allFns {
    locOf[f.qual] = f.loc
    if f.isMain { entryPoints.insert(f.qual) }
    edges[f.qual] = edges[f.qual] ?? []
    guard let body = f.body else { continue }
    let cc = CallCollector(info: f, fields: fields, localTypes: localTypes)
    cc.walk(body)
    direct[f.qual, default: []].formUnion(cc.directEffects)
    if !cc.directEffects.isEmpty { kappaSawClassified = true }
    if cc.unresolved { direct[f.qual, default: []].insert("Unknown"); unresolvedSet.insert(f.qual) }
    whyMap[f.qual, default: []].formUnion(cc.why)
    hostsD[f.qual, default: []].formUnion(cc.hosts)
    cmdsD[f.qual, default: []].formUnion(cc.cmds)
    pathsD[f.qual, default: []].formUnion(cc.paths)
    tablesD[f.qual, default: []].formUnion(cc.tables)

    for call in cc.calls {
        if call.typed {
            if byQual.contains(call.path) { edges[f.qual, default: []].insert(call.path) }
        } else if let targets = freeFnByName[call.path], targets.count == 1 {
            edges[f.qual, default: []].insert(targets[0])
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
    if let w = whyMap[qual], !w.isEmpty { e["unknownWhy"] = w.sorted() }
    if let h = hostsAcc[qual], !h.isEmpty { e["hosts"] = h.sorted() }
    if let c = cmdsAcc[qual], !c.isEmpty { e["cmds"] = c.sorted() }
    if let p = pathsAcc[qual], !p.isEmpty { e["paths"] = p.sorted() }
    if let t = tablesAcc[qual], !t.isEmpty, inf.contains("Db") { e["tables"] = t.sorted() }
    entries.append(e)
}
let envelope: [String: Any] = [
    "candor": ["version": "candor-swift-0.4.0", "toolchain": "swiftsyntax", "spec": "0.4"],
    "package": pkgName,
    "functions": entries,
]
var cg: [String: [String]] = [:]
for f in allFns { cg[f.qual] = (edges[f.qual] ?? []).sorted() }  // §2.2: EVERY analyzed fn a key

func writeJson(_ obj: Any, _ path: String) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
}
writeJson(envelope, "\(prefix).json")
writeJson(cg, "\(prefix).callgraph.json")
FileHandle.standardError.write(
    "candor-swift: wrote \(entries.count) effectful functions (\(allFns.count) analyzed, \(sourcePaths.count) files) to \(prefix).json\n".data(using: .utf8)!)

// the κ-coverage ledger: imported modules outside the platform frontier that κ doesn't know —
// INVISIBLE, not Unknown; named per scan (SPEC §7 item 14, canonical marker)
let unlisted = importCounts.filter { !PLATFORM_MODULES.contains($0.key) && !KAPPA_MODULES.contains($0.key) }
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
