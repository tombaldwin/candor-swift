// CandorCore — the PURE, side-effect-free cores of candor-swift, factored out of the executable's
// main.swift so they can be unit-tested directly (an executable target can't be `@testable import`ed).
// Two clusters live here, both stateless: (1) the κ classifier — the curated platform-frontier tables +
// the member/free/property classifiers + the §6.2 Exec-head refinement + the SPEC §2 SQL-table
// extraction; (2) the SwiftSyntax TYPE helpers (name/element/tuple/dict-value) used by Pass A's local
// type inference. Nothing here touches the scan's mutable state — the Resolver and driver stay in the
// executable and `import CandorCore`.

import Foundation
import SwiftSyntax

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Production-source filter
// ════════════════════════════════════════════════════════════════════════════════════════════════

// Production sources only: tests are the harness's effects, not the package's (the family rule).
public func isHarnessPath(_ p: String) -> Bool {
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

// ════════════════════════════════════════════════════════════════════════════════════════════════
// κ — the curated classifier (the platform frontier; third-party modules are the LEDGER's job)
// ════════════════════════════════════════════════════════════════════════════════════════════════

// Root-receiver type/name + member -> effect. Verb-precise where a type mixes pure and effectful
// surface (the family discipline: tag the execution boundary, not builders).
public let FS_MEMBERS: Set<String> = ["contents", "contentsOfDirectory", "createFile", "removeItem", "copyItem",
    "moveItem", "attributesOfItem", "fileExists", "createDirectory", "subpathsOfDirectory", "isReadableFile",
    "isWritableFile", "replaceItem", "linkItem", "destinationOfSymbolicLink", "createSymbolicLink",
    "enumerator", "subpaths", "changeCurrentDirectoryPath", "currentDirectoryPath", "temporaryDirectory",
    "urls", "url", "homeDirectoryForCurrentUser",
    // contentsEqual reads BOTH files byte-by-byte; attributesOfFileSystem statfs's the live volume —
    // real Fs I/O that read silent-pure under the covered-module floor (model the member, not drop coverage).
    "contentsEqual", "attributesOfFileSystem"]
public let NET_MEMBERS: Set<String> = ["dataTask", "data", "upload", "download", "bytes", "webSocketTask",
    "uploadTask", "downloadTask", "streamTask"]
public let LOG_MEMBERS: Set<String> = ["trace", "debug", "info", "notice", "warning", "error", "critical", "fault", "log"]
public let RAND_ROOTS: Set<String> = ["Int", "UInt", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16",
    "UInt32", "UInt64", "Double", "Float", "Bool", "CGFloat"]
public let PROCESS_MEMBERS: Set<String> = ["run", "launch", "waitUntilExit", "terminate", "interrupt",
                                           "launchedProcess", "launchedTaskWithExecutableURL"]
public let DB_FREE_PREFIX = "sqlite3_"
// sqlite3_* C functions that READ RESIDENT handle/statement state — they touch no database, issue no
// query, advance no row: statement/column/param METADATA, change/rowid counters, error + version state,
// backup progress. The `sqlite3_` prefix rule would paint them Db (a pure introspection getter reported
// effectful — the cardinal sin; a SQLite.swift sweep caught Statement.description/columnCount/columnNames,
// Connection.description/readonly/changes, Backup.pageCount all fabricating Db). They are subtracted FIRST.
// NOT here (stay Db — real query work / result consumption): open*/exec/prepare*/step/reset/finalize,
// the bind_* value setters, and column_text/int/double/blob/value/bytes/type (they read the stepped row).
public let SQLITE_PURE_INTROSPECTION: Set<String> = [
    "sqlite3_sql", "sqlite3_expanded_sql", "sqlite3_normalized_sql",
    "sqlite3_stmt_readonly", "sqlite3_stmt_busy", "sqlite3_stmt_isexplain",
    "sqlite3_column_count", "sqlite3_data_count",
    "sqlite3_column_name", "sqlite3_column_name16",
    "sqlite3_column_decltype", "sqlite3_column_decltype16",
    "sqlite3_column_database_name", "sqlite3_column_table_name", "sqlite3_column_origin_name",
    "sqlite3_bind_parameter_count", "sqlite3_bind_parameter_name", "sqlite3_bind_parameter_index",
    "sqlite3_db_filename", "sqlite3_db_readonly", "sqlite3_db_handle", "sqlite3_get_autocommit",
    "sqlite3_changes", "sqlite3_changes64", "sqlite3_total_changes", "sqlite3_total_changes64",
    "sqlite3_last_insert_rowid",
    "sqlite3_errmsg", "sqlite3_errmsg16", "sqlite3_errcode", "sqlite3_extended_errcode", "sqlite3_errstr",
    "sqlite3_libversion", "sqlite3_libversion_number", "sqlite3_sourceid",
    "sqlite3_backup_pagecount", "sqlite3_backup_remaining",
]
// Static singleton accessors that return an instance of their OWN type (Self by convention):
// `FileManager.default`, `URLSession.shared`, `NSPasteboard.general`, `ProcessInfo.processInfo`,
// `Database.shared` (a local singleton), … Binding one to a `let` must carry the base type so the
// var's later member calls classify — `FileManager.default.removeItem` inline is Fs, but via a
// `let fm = FileManager.default` it dropped to pure (the receiver typed as the bare identifier).
public let SINGLETON_ACCESSORS: Set<String> = ["default", "shared", "standard", "current", "general", "processInfo", "main"]
// NSPasteboard/UIPasteboard methods that READ no clipboard data and WRITE nothing — capability/metadata
// queries (the whole-owner Clipboard rule fabricated on them; sweep [33]). Subtracted FIRST, like
// SQLITE_PURE_INTROSPECTION. Real verbs stay Clipboard: writeObjects/setString/setData/clearContents/
// declareTypes/string(forType:)/data(forType:)/readObjects(forClasses:)/pasteboardItems/prepareForNewContents.
public let PASTEBOARD_PURE_QUERIES: Set<String> = ["canReadObject", "canReadItem", "availableType"]
// NWConnection/NWListener members that perform NO network I/O on their own: cancel/forceCancel tear the
// connection down, batch{} brackets other calls (sweep [34]). Real verbs stay Net: send/receive/
// receiveMessage/start/restart/cancelCurrentEndpoint.
public let NW_PURE_VERBS: Set<String> = ["cancel", "forceCancel", "batch"]

/// Classify a member call `root.member(...)` (root = the receiver chain's base identifier or the
/// receiver's inferred TYPE). Returns nil for the pure/unknown surface — never a guess.
public func kappaMember(root: String, member: String) -> String? {
    switch root {
    case "FileManager", "FileHandle": return FS_MEMBERS.contains(member) || member == "readToEnd"
        || member == "write" || member == "read" ? "Fs" : nil
    case "URLSession": return NET_MEMBERS.contains(member) ? "Net" : nil
    case "Process": return PROCESS_MEMBERS.contains(member) ? "Exec" : nil
    case "Logger", "OSLog": return LOG_MEMBERS.contains(member) ? "Log" : nil
    case "NSPasteboard", "UIPasteboard":
        // PURE capability/metadata queries read no clipboard data — exclude them (the whole-owner rule
        // fabricated Clipboard on these, the cardinal sin; sweep [33]). Unknown verbs stay Clipboard
        // (sound over-approx). `.types`/`.changeCount`/`.name` are PROPERTY reads handled elsewhere.
        return PASTEBOARD_PURE_QUERIES.contains(member) ? nil : "Clipboard"
    case "Date": return member == "now" ? "Clock" : nil
    case "ContinuousClock", "SuspendingClock", "DispatchTime": return member == "now" ? "Clock" : nil
    case "NWConnection", "NWListener":
        // cancel/forceCancel TEAR DOWN (no bytes), batch{} is a pure grouping bracket (the I/O is in the
        // closure, attributed separately) — the whole-owner rule fabricated Net on them (sweep [34]).
        // send/receive/start/restart stay Net; unknown verbs stay Net (sound over-approx).
        return NW_PURE_VERBS.contains(member) ? nil : "Net"
    case "NSXPCConnection": return "Ipc"
    // CoreData persistence: NSManagedObjectContext.save/fetch/execute/count and the store-load/coordinator
    // verbs hit the SQLite store — Db. The builder/algebra surface (NSFetchRequest construction, predicates,
    // object property reads) is not a verb here, so it stays pure (the builder discipline).
    case "NSManagedObjectContext":
        return ["save", "fetch", "execute", "count", "performFetch", "executeFetchRequest"].contains(member) ? "Db" : nil
    case "NSPersistentContainer", "NSPersistentStoreCoordinator":
        return ["loadPersistentStores", "execute", "addPersistentStore", "performBackgroundTask"].contains(member) ? "Db" : nil
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

// The Net forms whose DESTINATION is (conceptually) carried by THIS call — the URL/host is an argument
// of the call itself (`URLSession.data(from:)`, `bootstrap.connect(host:)`, `HTTPClient.get(url:)`,
// `NWConnection(host:)`). For these, a Net classification with NO captured host literal means the endpoint
// is structurally INVISIBLE (a runtime-built URL/host), so the fn's Net surface is INCOMPLETE — it can't
// be certified against an `allow Net <hosts>` allowlist even when a *sibling* call's benign host IS
// visible, else the benign literal MASKS the invisible forbidden endpoint (the masking gate-evasion;
// candor-java 0.5.29 / candor-rust / candor-ts share this). USE-verbs on an already-established socket
// (`Channel.write/read/flush`, an `NWConnection` instance's `.send/.receive`) are NOT here: their
// destination was fixed at connect/ctor time — possibly in ANOTHER function that captured the host — so a
// missing literal at the use-site is the legitimate split-construct/use shape, never the masking signal.
public func isNetEstablishingMember(root: String, member: String) -> Bool {
    switch root {
    case "URLSession": return NET_MEMBERS.contains(member)
    case "ClientBootstrap", "ServerBootstrap", "DatagramBootstrap", "NIOTSConnectionBootstrap":
        return ["connect", "bind", "withConnectedSocket"].contains(member)
    case "Channel", "ChannelHandlerContext": return ["connect", "bind"].contains(member) // write/read/flush = USE
    case "HTTPClient", "AsyncHTTPClient":
        return ["execute", "get", "post", "put", "patch", "delete"].contains(member)     // shutdown = teardown
    default: return false
    }
}
/// The free-call/ctor Net forms whose host is an argument of the construction (`NWConnection(host:)`).
public func isNetEstablishingFree(name: String) -> Bool {
    return name == "NWConnection" || name == "NWListener"
}

// The masking guard generalizes from Net to ALL FOUR allowlisted effects (Net/Fs/Exec/Db): for each, a
// classify at an ESTABLISHING form (the resource LOCATOR — host / path / command / SQL — is conceptually an
// argument of THIS call) with no captured literal means the locator is structurally INVISIBLE, so the
// effect's surface is incomplete and the gate must fail closed (else a benign co-literal masks the runtime
// destination — the AS-EFF-008 evasion, fixed for Net only in 0.5.12; sweep [14]/[15]). USE-verbs whose
// locator was fixed earlier (a FileHandle's read/write — path set at the ctor; a Process's run — command
// set via .executableURL/.arguments properties) are NOT establishing: a missing literal there is the
// legitimate split-construct/use shape. Net/Fs reach establishing MEMBER forms in κ; Exec/Db establish at
// FREE calls (posix_spawn/execv*, sqlite3_*).
public func isEstablishingMember(effect: String, root: String, member: String) -> Bool {
    switch effect {
    case "Net": return isNetEstablishingMember(root: root, member: member)
    case "Fs":  return root == "FileManager" && FS_MEMBERS.contains(member) // atPath:/at:/to: is an arg;
        // FileHandle.read/write are USE (the path was fixed at the FileHandle(for…:) ctor) — not establishing.
    default:    return false
    }
}
public func isEstablishingFree(effect: String, name: String) -> Bool {
    switch effect {
    case "Net":  return isNetEstablishingFree(name: name)
    case "Fs":   return name == "FileHandle" || name == "fopen"                       // path arg
    case "Exec": return name == "posix_spawn" || name == "execv" || name == "execvp"  // path arg (Process() ctor
        // takes NO command — set via .executableURL/.arguments — so the ctor is not establishing)
    case "Db":   return name.hasPrefix(DB_FREE_PREFIX)                                // sqlite3_exec/prepare take SQL
    default:     return false
    }
}

/// Classify a free-function or constructor call by name.
public func kappaFree(name: String, argCount: Int) -> String? {
    switch name {
    case "Date": return argCount == 0 ? "Clock" : nil // Date() reads the clock; Date(timeInterval…) is arithmetic
    case "NSDate": return argCount == 0 ? "Clock" : nil // the legacy twin of Date() (no-arg = current time)
    case "CACurrentMediaTime", "mach_absolute_time": return "Clock" // monotonic clock reads (QuartzCore / mach)
    case "NSLog": return "Log"  // Foundation structured logging to the unified log/ASL (not plain stdout)
    case "Pipe": return "Ipc"   // constructs an OS pipe for inter-process stdio wiring (the IPC intent)
    case "UUID": return argCount == 0 ? "Rand" : nil  // UUID() draws v4 entropy; UUID(uuidString:) is a pure parse
    case "FileHandle": return argCount > 0 ? "Fs" : nil // FileHandle(forReadingAtPath:/forWritingTo:/…) OPENS an
        // fd (Fs). The member read/write surface is handled in kappaMember; the std accessors
        // (.standardError/.standardOutput) are zero-arg STATIC properties, not this ctor, so they stay pure.
    case "Process": return "Exec"   // constructing the subprocess handle is the Exec intent (Command::new)
    case "NWConnection", "NWListener": return "Net"
    case "SystemRandomNumberGenerator": return "Rand"
    case "arc4random", "arc4random_uniform", "getentropy": return "Rand"
    case "getenv", "setenv", "unsetenv": return "Env"
    // DNS resolution is Net (rust/java/ts all classify it; swift floored it silently — sweep [20]). These
    // are POSIX/Darwin/Glibc free calls; the call site already shadow-guards a local fn of the same name.
    case "getaddrinfo", "getnameinfo", "gethostbyname", "gethostbyname2", "gethostbyaddr",
         "gethostbyname_r", "gethostbyaddr_r", "getaddrinfo_a": return "Net"
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
        if SQLITE_PURE_INTROSPECTION.contains(name) { return nil }   // resident-state read — never Db
        if name.hasPrefix(DB_FREE_PREFIX) { return "Db" }
        return nil
    }
}

/// Property READS that are effects (no call expression): `ProcessInfo…environment`, `Date.now`,
/// pasteboard accessors. Checked on member-access chains outside call position.
public func kappaPropertyRead(root: String, path: [String]) -> String? {
    if root == "ProcessInfo" && path.contains("environment") { return "Env" }
    if root == "ProcessInfo" && path.contains("systemUptime") { return "Clock" } // monotonic clock read
    if root == "ProcessInfo" && path.contains("hostName") { return "Env" }       // machine-identity read
    if root == "Date" && path.contains("now") { return "Clock" }
    // ContinuousClock/SuspendingClock `.now` — the idiomatic Swift 5.7+ monotonic-clock read is the
    // PROPERTY form (`ContinuousClock().now`, `clock.now`, `ContinuousClock.now`), not a `.now()` call.
    if (root == "ContinuousClock" || root == "SuspendingClock") && path.contains("now") { return "Clock" }
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
public func classifyCommandHead(_ cmd: String) -> [String] {
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
public let PLATFORM_MODULES: Set<String> = ["Swift", "Foundation", "FoundationNetworking", "FoundationXML",
    "Dispatch", "os", "OSLog", "Darwin", "Glibc", "Musl", "Android", "Bionic", "WASILibc", "WinSDK",
    "CRT", "Builtin", "Combine", "Observation", "SwiftUI", "AppKit", "UIKit", "WatchKit",
    "CoreFoundation", "CoreGraphics", "CoreLocation", "CoreServices", "MobileCoreServices",
    "Security", "SystemConfiguration", "UniformTypeIdentifiers", "CryptoKit", "System",
    "RegexBuilder", "Synchronization", "Testing", "XCTest", "PackageDescription", "PackagePlugin",
    "ucrt", "wasi_pthread", "string_h", "zlibng", "SwiftShims"]
public let KAPPA_MODULES: Set<String> = ["Network", "SQLite3", "CoreData",
    "NIOCore", "NIOPosix", "NIOHTTP1", "NIOHTTP2", "NIOSSL", "NIOTransportServices", "AsyncHTTPClient"]

// ════════════════════════════════════════════════════════════════════════════════════════════════
// SQL tables — the SPEC §2 pinned extraction, token-for-token with the other three engines
// ════════════════════════════════════════════════════════════════════════════════════════════════

public func tablesInSql(_ sql: String) -> [String] {
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
// SwiftSyntax TYPE helpers — Pass A's local type inference (name / array-element / tuple / dict-value)
// ════════════════════════════════════════════════════════════════════════════════════════════════

public func typeName(_ t: TypeSyntax) -> (name: String?, isFunction: Bool) {
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
public func arrayElementName(_ t: TypeSyntax) -> String? {
    if let arr = t.as(ArrayTypeSyntax.self) { return typeName(arr.element).name }
    if let opt = t.as(OptionalTypeSyntax.self) { return arrayElementName(opt.wrappedType) }
    if let att = t.as(AttributedTypeSyntax.self) { return arrayElementName(att.baseType) }
    if let some = t.as(SomeOrAnyTypeSyntax.self) { return arrayElementName(some.constraint) }
    if let gen = t.as(IdentifierTypeSyntax.self), let args = gen.genericArgumentClause,
       // The async-sequence/task-group element is also the FIRST generic argument: `for await x in s`
       // over an `AsyncStream<E>`/`AsyncThrowingStream<E, _>`/`TaskGroup<E>`/`ThrowingTaskGroup<E, _>`
       // yields an `E` — without these the loop var was untyped and `x.member()` read silent-pure (a
       // structured-concurrency consumer hole found by a Swift-concurrency sweep).
       ["Array", "Set", "ContiguousArray", "ArraySlice",
        "AsyncStream", "AsyncThrowingStream", "TaskGroup", "ThrowingTaskGroup"].contains(gen.name.text),
       let first = args.arguments.first, let at = first.argument.as(TypeSyntax.self) {
        return typeName(at).name
    }
    return nil
}

/// A tuple type's element types keyed by BOTH position (`"0"`, `"1"`) and label (`"c"`): `(c: C, n: Int)`
/// → `["0": "C", "c": "C", "1": "Int", "n": "Int"]`. Types `p.0` / `p.c` member accesses on a tuple.
public func tupleElements(_ t: TypeSyntax) -> [String: String] {
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
public func dictValueName(_ t: TypeSyntax) -> String? {
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
