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

/// Does this file's TEXT mark it as a test? `import XCTest` (or `import Testing`) is unambiguous —
/// production code never imports either.
///
/// `isHarnessPath` reads the PATH, and SPM's conventions are directory-shaped: `Tests/`, `*Tests/`,
/// `*TestHelpers/`. An app whose tests live BESIDE their sources — `.../AuthenticatorKeyCapture/
/// AuthenticatorKeyCaptureCoordinatorTests.swift` — defeats every one of them, so its test code was
/// analysed as production. Measured on Bitwarden: a bare `AVCaptureSession()` in a test `setUp()` was
/// the sole evidence for "your app reaches Mic but declares no NSMicrophoneUsageDescription" — unit
/// test code cited as proof that a SHIPPING manifest is wrong.
///
/// The check is on the IMPORT and deliberately not on the filename: a file called `ABTests.swift` is
/// A/B-testing production code, and excluding it would silently drop real sources, which is the
/// cardinal sin this filter must never commit to avoid a false alarm.
public func isTestSource(_ text: String) -> Bool {
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(400) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("import ") else { continue }
        let mod = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
        if mod == "XCTest" || mod == "Testing" { return true }
    }
    return false
}

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

// ⟨0.21⟩ COMPLETENESS MANIFEST — an opaque, within-engine-stable fingerprint of a SORTED qual set:
// FNV-1a 64-bit over the newline-joined UTF-8 quals, lowercase zero-padded 16-hex. Dependency-free +
// deterministic: it changes iff the set changes, so a same-engine re-scan of unchanged input agrees.
// NOT cryptographic and NOT cross-engine comparable (qualifiers differ) — a re-scan-agreement check.
// Ported byte-for-byte from candor-java's ReportWriter.fnv1aHex (UInt64 overflow-wrapping `&*`/`&+`/`^`).
public func fnv1aHex(_ sortedQuals: [String]) -> String {
    var h: UInt64 = 0xcbf29ce484222325           // FNV offset basis
    let prime: UInt64 = 0x100000001b3            // FNV prime
    for q in sortedQuals {
        for b in q.utf8 {
            h ^= UInt64(b)
            h = h &* prime
        }
        h ^= UInt64(0x0a)                        // the '\n' separator (matches java's `h ^= '\n'`)
        h = h &* prime
    }
    // `%llx` (NOT `%x`): Swift's String(format:) reads `%x` as a 32-bit C `unsigned int`, which would
    // TRUNCATE the 64-bit hash to its low 32 bits. `%llx` reads the full UInt64 — matching java's `%016x`
    // over a `long`, so the SPEC describes ONE algorithm across engines.
    return String(format: "%016llx", h)
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// κ — the curated classifier (the platform frontier; third-party modules are the LEDGER's job)
// ════════════════════════════════════════════════════════════════════════════════════════════════

// Root-receiver type/name + member -> effect. Verb-precise where a type mixes pure and effectful
// surface (the family discipline: tag the execution boundary, not builders).
/// SPEC §2 `fs` — for a call ALREADY classified `Fs`, the read/write direction its verb implies.
/// Returns `["read"]`, `["write"]`, `["read","write"]`, or `[]` when the verb does not say.
///
/// THE EMPTY CASE IS THE WHOLE DISCIPLINE. §2: *"when `Fs` is reached but its kind is unknown … the field
/// MUST be omitted rather than guessed. An empty or partial `fs` would be read as a positive claim ('reads
/// but never writes'), which is the §4 trust contract's forbidden direction."* So a verb this table does
/// not recognise contributes NOTHING, and a function whose Fs comes from an unrecognised verb — or
/// transitively from a callee — carries no `fs` at all. Omission says "Fs, kind undetermined"; a present
/// `fs` is an affirmative classification.
///
/// This is a syntactic refinement of an effect candor already proved, NOT a soundness claim: getting the
/// direction wrong misreports a detail, getting the EFFECT wrong is the cardinal sin, and these are
/// different failures. Deliberately the same shape and vocabulary as candor-java's `fsKind` — the surface
/// is spec'd four-way, so two engines inventing two verb tables for one field is how a shared field stops
/// meaning one thing.
public func fsKind(root: String, member: String) -> [String] {
    // Two-locator copies/moves read the source and write the destination — both, in one call.
    if member == "copyItem" || member == "moveItem" || member == "replaceItem" || member == "replaceItemAt"
        || member == "linkItem" { return ["read", "write"] }
    switch member {
    // WRITE — mutates the disk.
    case "createFile", "removeItem", "createDirectory", "createSymbolicLink", "write", "writeToFile",
         "changeCurrentDirectoryPath", "setAttributes", "trashItem", "unlinkItem", "truncate",
         "createTempFile", "createTempDirectory", "SecItemAdd", "SecItemUpdate", "SecItemDelete":
        return ["write"]
    // READ — observes the disk without mutating it. Metadata probes are reads: `fileExists` is an I/O
    // syscall that leaks whether a path is there, which is the detail the surface exists to expose.
    case "contents", "contentsOfDirectory", "attributesOfItem", "fileExists", "subpathsOfDirectory",
         "isReadableFile", "isWritableFile", "isExecutableFile", "isDeletableFile",
         "destinationOfSymbolicLink", "enumerator", "subpaths", "currentDirectoryPath",
         "contentsEqual", "attributesOfFileSystem", "read", "readToEnd", "readData", "readDataToEndOfFile",
         "SecItemCopyMatching":
        return ["read"]
    default: break
    }
    // A FileHandle OPENED for one direction reveals it by the initializer label; a bare `FileHandle(...)`
    // does not, and gets no claim. Same shape as java's `<init>` arm.
    if root == "FileHandle" {
        if member.hasPrefix("forReading") { return ["read"] }
        if member.hasPrefix("forWriting") || member.hasPrefix("forUpdating") { return ["write"] }
    }
    if member.hasPrefix("write") || member == "append" { return ["write"] }
    if member.hasPrefix("read") { return ["read"] }
    return []   // the verb does not say — make NO claim (§2)
}

public let FS_MEMBERS: Set<String> = ["contents", "contentsOfDirectory", "createFile", "removeItem", "copyItem",
    "moveItem", "attributesOfItem", "fileExists", "createDirectory", "subpathsOfDirectory", "isReadableFile",
    "isWritableFile", "replaceItem", "linkItem", "destinationOfSymbolicLink", "createSymbolicLink",
    "enumerator", "subpaths", "changeCurrentDirectoryPath", "currentDirectoryPath", "temporaryDirectory",
    "urls", "url", "homeDirectoryForCurrentUser",
    // contentsEqual reads BOTH files byte-by-byte; attributesOfFileSystem statfs's the live volume —
    // real Fs I/O that read silent-pure under the covered-module floor (model the member, not drop coverage).
    "contentsEqual", "attributesOfFileSystem", "replaceItemAt"]

// The FileManager members that take TWO (or more) path locators — a SOURCE and a DESTINATION — each
// conceptually an argument of THIS call. The single-path establishing guard (capture the FIRST literal,
// mark Fs incomplete only if NO literal exists) fails OPEN here: a literal source MASKS a runtime
// destination (`copyItem(atPath: "/tmp/ok", toPath: dst)`), so the masked dst evades an `allow Fs`
// allowlist (the AS-EFF-008 two-path gate-evasion). For these the gate must inspect EVERY locator: it
// is incomplete unless ALL locators are static literals. Maps member -> the ORDERED set of accepted
// locator label-spellings (path AND url forms); `replaceItemAt`'s source is the FIRST positional
// (unlabeled) arg, encoded as the empty-string label "".
public let FS_TWO_PATH_MEMBERS: [String: [Set<String>]] = [
    "copyItem":           [["atPath", "at"], ["toPath", "to"]],
    "moveItem":           [["atPath", "at"], ["toPath", "to"]],
    "linkItem":           [["atPath", "at"], ["toPath", "to"]],
    "createSymbolicLink": [["atPath", "at"], ["withDestinationPath", "withDestinationURL"]],
    "contentsEqual":      [["atPath"], ["andPath"]],
    "replaceItem":        [["at"], ["withItemAt"]],
    "replaceItemAt":      [[""], ["withItemAt"]],
]
public let NET_MEMBERS: Set<String> = ["dataTask", "data", "upload", "download", "bytes", "webSocketTask",
    "uploadTask", "downloadTask", "streamTask"]
// κ batch — the COVERED-MODULE silent-pure sweep (2026-07-09). Foundation/Security are PLATFORM_MODULES:
// they get no ledger naming and no Unknown, so an unmodeled effectful member there reads SILENT-PURE —
// the exact covered-module cardinal-sin shape (candor-java's Panache lesson, Swift edition). Modeled → Fs:
//   • UserDefaults — a FILE-BACKED local store (a plist under Library/Preferences); every read/write verb
//     touches (or schedules a touch of) that file. Fs, not Db — the family reserves Db for query-capable
//     datastores (FAMILY DECISION, 2026-07-09).
//   • SecItem* Keychain free functions (kappaFree) — the system SECURE STORE (a SQLite-backed system
//     service, but not query-capable from the API) → Fs, same decision.
//   • Bundle RESOURCE LOOKUPS (url/path(forResource:) & plurals) — a live on-disk stat/search → Fs.
// DELIBERATE NON-MODELS (checked, not forgotten): NotificationCenter (in-process pub/sub — no effect in
// the vocabulary); CLLocationManager (location has no vocabulary match); Bundle METADATA property reads
// (bundleIdentifier/infoDictionary/bundlePath — served from the already-loaded in-memory Info.plist, not
// a disk verb); UserDefaults(suiteName:) ctor (the ACCESS verbs below carry the effect — modeling the
// handle ctor would double-report and `Bundle(for:)`-style in-memory ctors would risk fabrication).
// Verb-precise (the family discipline); a project's OWN `UserDefaults`/`Bundle` type shadows via
// declaredTypes, a local `func SecItemAdd` via localFreeFns — never a fabrication on project code.
public let USER_DEFAULTS_MEMBERS: Set<String> = ["set", "object", "string", "stringArray", "array",
    "dictionary", "data", "bool", "integer", "float", "double", "url", "value", "removeObject",
    "synchronize", "register", "dictionaryRepresentation",
    "persistentDomain", "setPersistentDomain", "removePersistentDomain"]
public let BUNDLE_RESOURCE_MEMBERS: Set<String> = ["url", "urls", "path", "paths"]
// (the Keychain SecItem* free functions live as explicit kappaFree cases — one source of truth)
// JohnSundell's `Files` package (a third-party Fs wrapper the κ ledger discloses as `invisible` on
// every consuming app — Publish reaches 81 of them). The `File`/`Folder`/`Storage` types' OWN API does
// the syscalls: read/write/append/delete/move/copy/rename and the create* factories. The Files-specific
// verbs are modeled; the PATH/NAME/URL property reads and the `subfolders`/`files` SEQUENCE builders stay
// out (lazy iterators, not a verb here — the builder discipline). `File`/`Folder` are common type names,
// so a project's OWN `struct File` (in declaredTypes) shadows this — never a fabrication on a local type.
public let FILES_MEMBERS: Set<String> = ["read", "readAsString", "readAsInt", "readAsDictionary",
    "write", "append", "delete", "move", "moveContents", "copy", "rename", "empty",
    "createFile", "createFileIfNeeded", "createSubfolder", "createSubfolderIfNeeded", "managedBy"]
public let LOG_MEMBERS: Set<String> = ["trace", "debug", "info", "notice", "warning", "error", "critical", "fault", "log"]
public let RAND_ROOTS: Set<String> = ["Int", "UInt", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16",
    "UInt32", "UInt64", "Double", "Float", "Bool", "CGFloat"]
public let PROCESS_MEMBERS: Set<String> = ["run", "launch", "waitUntilExit", "terminate", "interrupt",
                                           "launchedProcess", "launchedTaskWithExecutableURL"]
public let DB_FREE_PREFIX = "sqlite3_"
// sqlite3_* C functions that READ RESIDENT handle/statement state — they touch no database, issue no
// query, advance no row: statement/column/param METADATA, change/rowid counters, error + version state,
// backup progress. The `sqlite3_` prefix rule would paint them Db (a pure introspection getter reported
// effectful — a fabrication, the precision failure; a SQLite.swift sweep caught Statement.description/columnCount/columnNames,
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
/// The same convention spelled as a METHOD: `AVAudioSession.sharedInstance()`, `X.shared()`. Kept apart
/// from SINGLETON_ACCESSORS because the syntax differs (a call, not a member read) and so does the risk:
/// a parenthesised static could be any factory, so only the conventional singleton names qualify, and
/// only when the type has not recorded a real return type for them.
public let SINGLETON_FACTORY_METHODS: Set<String> = ["sharedInstance", "shared", "default", "current"]
// NSPasteboard/UIPasteboard methods that READ no clipboard data and WRITE nothing — capability/metadata
// queries (the whole-owner Clipboard rule fabricated on them; sweep [33]). Subtracted FIRST, like
// SQLITE_PURE_INTROSPECTION. Real verbs stay Clipboard: writeObjects/setString/setData/clearContents/
// declareTypes/string(forType:)/data(forType:)/readObjects(forClasses:)/pasteboardItems/prepareForNewContents.
public let PASTEBOARD_PURE_QUERIES: Set<String> = ["canReadObject", "canReadItem", "availableType"]
// NWConnection/NWListener members that perform NO network I/O on their own: cancel/forceCancel tear the
// connection down, batch{} brackets other calls (sweep [34]). Real verbs stay Net: send/receive/
// receiveMessage/start/restart/cancelCurrentEndpoint.
public let NW_PURE_VERBS: Set<String> = ["cancel", "forceCancel", "batch"]

// ════════════════════════════════════════════════════════════════════════════════════════════════
// SPEC §1 ⟨0.13⟩ `Llm` — the model-provider boundary (refines Net the way `Db` refines a jdbc URL)
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// Known machine-learning MODEL-provider hosts — the SPEC §1 ⟨0.13⟩ `Llm` host-literal refinement: a
/// statically-known Net request to one of these classifies `Llm` IN ADDITION to `Net` (Net is never
/// dropped — a model call IS network I/O), just as a jdbc URL classifies `Db`. Matched by host,
/// case-insensitive; a SUBDOMAIN of a listed host counts. The four reference engines share this table
/// VERBATIM (candor-java's `Literals.MODEL_HOSTS`) so the `Net` boundary refines to `Llm` identically. An
/// UNKNOWN host stays bare `Net` — never guessed. Curated STARTER set; the §7 coverage ledger discloses an
/// uncovered provider like any other.
public let MODEL_HOSTS: Set<String> = [
    "api.openai.com",
    "api.anthropic.com",
    "generativelanguage.googleapis.com",
    "api.mistral.ai",
    "api.cohere.ai", "api.cohere.com",
    "api.groq.com",
    "api.together.xyz",
    "api.perplexity.ai",
    "openrouter.ai",
]

/// Whether an endpoint HOST literal is a known model provider (case-insensitive; a subdomain of a
/// `MODEL_HOSTS` entry counts). Strips a `:port` suffix first. Two special forms carry their own rule:
/// any host whose port is 11434 is a local Ollama endpoint (`localhost:11434`, `127.0.0.1:11434`); and an
/// AWS Bedrock runtime host `bedrock*-runtime.<region>.amazonaws.com` (host contains "bedrock" AND ends
/// `.amazonaws.com`). Mirrors candor-java's `Literals.isModelHost` exactly.
public func isModelHost(_ hostLiteral: String) -> Bool {
    let host = hostPart(hostLiteral).lowercased()
    // Ollama is a LOCAL endpoint: :11434 → Llm ONLY on a loopback host (max-review r3 parity — "any host
    // on :11434" fabricated Llm on unrelated internal services on that port).
    if let colon = hostLiteral.range(of: ":", options: .backwards),
       hostLiteral[colon.upperBound...] == "11434" {
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
    if MODEL_HOSTS.contains(host) { return true }
    for m in MODEL_HOSTS where host.hasSuffix("." + m) { return true } // a subdomain of a known model host
    // AWS Bedrock runtime: the FIRST label is the model-inference service (bedrock-runtime.<region>.
    // amazonaws.com), NOT the substring "bedrock" (which caught the S3 bucket `bedrock-backups.s3.…`) and
    // NOT the control-plane `bedrock.<region>.amazonaws.com`.
    if host.hasSuffix(".amazonaws.com") {
        let first = host.split(separator: ".").first.map(String.init) ?? ""
        if first == "bedrock-runtime" || first == "bedrock-agent-runtime" { return true }
    }
    return false
}

/// ⟨0.20⟩ Curated telemetry / analytics / APM hosts — the `Net` destination-class `known-telemetry` set
/// (NET-DESTINATION-CLASS-DESIGN.md), shared VERBATIM with the sibling engines (java `Literals.TELEMETRY_HOSTS`
/// / rust `TELEMETRY_HOSTS` / ts), like `MODEL_HOSTS`. A benign observability endpoint. Matched by host,
/// case-insensitive; a SUBDOMAIN of a listed host counts. Tight, high-precision STARTER set — mis-including
/// an exfil-capable host would under-gate `deny Net[unknown-host]`.
public let TELEMETRY_HOSTS: Set<String> = [
    "sentry.io",
    "bugsnag.com",
    "rollbar.com",
    "segment.io", "segment.com",
    "mixpanel.com",
    "amplitude.com",
    "google-analytics.com", "analytics.google.com",
    "datadoghq.com", "datadoghq.eu",
    "newrelic.com", "nr-data.net",
    "honeycomb.io",
    "logtail.com",
    // ⟨0.20.1⟩ corpus-grown (a real-repo dogfood): more single-purpose analytics / session-replay / RUM
    // providers — vendor-specific product domains only (no general-purpose host), so no under-gate risk.
    "posthog.com", "plausible.io", "usefathom.com", "heapanalytics.com",
    "fullstory.com", "hotjar.com", "logrocket.com",
    "cloudflareinsights.com",
]

/// Subdomain-aware membership of a `host[:port]` literal in a host `set` (mirrors java `Literals.hostInSet`).
public func hostInSet(_ hostLiteral: String, _ set: Set<String>) -> Bool {
    let host = hostPart(hostLiteral).lowercased()
    if set.contains(host) { return true }
    for e in set where host.hasSuffix("." + e) { return true }
    return false
}

/// Whether an endpoint HOST literal is a known telemetry/analytics/APM host (`TELEMETRY_HOSTS`).
public func isTelemetryHost(_ hostLiteral: String) -> Bool { hostInSet(hostLiteral, TELEMETRY_HOSTS) }

/// ⟨0.20⟩ The `Net` DESTINATION CLASS of a host literal (NET-DESTINATION-CLASS-DESIGN.md): `known-telemetry`
/// (curated), `known-partner` (config `net-partner` OR a model host — a declared-ish external API), else
/// `unknown-host` — the HONEST default (candor makes no claim; the security gate bites this). `partners` is a
/// per-project set (config-declared). Never fabricated onto a safe class: an unresolved host is unknown-host.
/// Mirrors candor-java's `Literals.netDestClass`.
public func netDestClass(_ hostLiteral: String, _ partners: Set<String>) -> String {
    if isTelemetryHost(hostLiteral) { return "known-telemetry" }
    if hostInSet(hostLiteral, partners) || isModelHost(hostLiteral) { return "known-partner" }
    return "unknown-host"
}

/// ⟨0.20⟩ The closed `Net` destination-class vocabulary, for the `deny Net[<dest…>]` policy filter.
public let NET_DEST_CLASSES: Set<String> = ["known-telemetry", "known-partner", "unknown-host"]

/// ⟨0.20⟩ The `Net` destination classes an fn reaches — the SINGLE derivation shared by the report's
/// `netClass` field and the gate: an exact host-literal match (`netDestClass`) for the visible (transitive)
/// hosts, plus the fail-closed `unknown-host` when the Net surface is masked (`netIncomplete`) OR carries no
/// visible host (a runtime endpoint). Call only for an fn with Net; returns sorted. Mirrors java/rust/ts.
public func netClassesOf(_ hosts: [String], netIncomplete: Bool, partners: Set<String>) -> [String] {
    var classes = Set(hosts.map { netDestClass($0, partners) })
    if netIncomplete || hosts.isEmpty { classes.insert("unknown-host") }
    return classes.sorted()
}

/// Curated model-provider SDK modules — the SPEC §1 ⟨0.13⟩ `Llm` model-SDK surface. A call into one of
/// these clients' types dispatches a request → `Llm` + `Net` (the caller adds Net; the client IS network
/// I/O). Keyed by the distinctive CLIENT TYPE NAME the module exports (candor-swift's syntactic engine
/// keys κ on type names, not resolved owners — the same mechanism as `NWConnection`/`HTTPClient`). Mirrors
/// candor-java's `Rules.MODEL_SDK_PACKAGES` decision — NO method-name gating: ANY call into a model-SDK
/// client type is a model dispatch (these clients are single-purpose). A curated STARTER set matching the
/// Swift ecosystem; the §7 coverage ledger discloses an uncovered provider package like any other:
///   • `OpenAI`             — MacPaw/OpenAI (module OpenAI)
///   • `AnthropicClient`, `AnthropicSwiftClient`, `SwiftAnthropic` — swift-anthropic / AnthropicSwiftSDK
///   • `BedrockRuntimeClient`, `BedrockRuntime` — the swift-aws-sdk Bedrock runtime module
///   • `LLM`, `LangChain`   — langchain-swift invoke surfaces
///   • `LanguageModelSession`, `SystemLanguageModel` — Apple's on-device FoundationModels (Apple
///     Intelligence). An on-device model call is still `Llm` (the local-inference-counts decision, SPEC §1).
///     NOTE (flagged for review): the FoundationModels client type names are the current public API
///     (`LanguageModelSession`/`SystemLanguageModel`); confirm against the shipped SDK — a rename here only
///     UNDER-reports (never fabricates on a project type, which `declaredTypes` shadows).
/// A project's OWN type of one of these names shadows this via `declaredTypes`/`localTypes` — never a
/// fabrication on local code, exactly like `Channel`/`HTTPClient`.
public let MODEL_SDK_TYPES: Set<String> = [
    "OpenAI",
    "AnthropicClient", "AnthropicSwiftClient", "SwiftAnthropic",
    "BedrockRuntimeClient", "BedrockRuntime",
    "LLM", "LangChain",
    "LanguageModelSession", "SystemLanguageModel",
]

// ════════════════════════════════════════════════════════════════════════════════════════════════
// `privacy/1` SPEC EXTENSION (SPEC-EXTENSION-privacy.md) — Apple privacy-sensor effects
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// The `privacy/1` per-effect type→effect table: a call whose receiver/argument TYPE is a curated
/// privacy-source type carries that effect (SPEC-EXTENSION-privacy.md "Classification"). Keyed by the
/// distinctive framework TYPE NAME (candor-swift's syntactic engine keys κ on type names — the same
/// mechanism as `MODEL_SDK_TYPES`/`NWConnection`). NO method-name gating: any call into one of these
/// single-purpose sensor types IS the sensor access. A project's OWN type of one of these names shadows
/// this via `declaredTypes`/`localTypes` (the anti-fabrication rule, exactly like the model-SDK types) —
/// a local `CLLocationManager` is not CoreLocation's. A curated STARTER set; the §7 coverage ledger
/// discloses an uncovered privacy framework like any other. UNKNOWN/ambiguous receivers stay pure —
/// never guessed (a fabricated `Camera` on a QR-decode helper is the precision failure the probe fences).
///
/// AVCaptureDevice / AVCaptureSession are AMBIGUOUS: the video path is Camera, the audio path is Mic
/// (discriminated by the `.audio`/`.video` media-type argument on `AVCaptureDevice.default(for:)` /
/// `.devices(for:)`). This table classifies the DEFAULT (Camera). The finer discrimination is layered ON
/// TOP at the call site (`privacyCaptureEffects`, driven by the media-type arg the syntactic engine CAN
/// see): a statically-visible `.audio` classifies Mic, `.video` classifies Camera, and an AMBIGUOUS
/// capture (a bare `AVCaptureSession`, or a media-type argument that is not statically visible) classifies
/// BOTH Camera AND Mic. That over-disclosure is DELIBERATE and is the opposite trade-off from the Llm/Net
/// host case: for a privacy manifest a MISSED sensor (App-Store-rejection-shaped under-declaration) is the
/// costly error, so an ambiguous capture declares both rather than silently miss one — whereas an unknown
/// Net host stays bare `Net`, never fabricated to `Llm`. (The precision fence still holds for a genuinely
/// UNKNOWN receiver — that stays pure; the over-disclosure is only within a CONFIRMED capture type.)
///
/// AVAudioRecorder is unambiguously `Mic`. AVAudioEngine is NOT here — it is a general audio-graph type
/// (playback, synthesis, mixing, effects); only its `.inputNode` touches the microphone, so a bare
/// AVAudioEngine used for PLAYBACK must not fabricate `Mic`. The mic-specific `AVAudioEngine.inputNode`
/// access is member-gated in `kappaPropertyRead` instead (finding 4). This is the opposite direction from
/// the capture-ambiguity over-disclosure above BECAUSE AVAudioEngine is PREDOMINANTLY not-mic: gating on
/// the mic-specific member is right, over-disclosing every playback engine as Mic would be a fabrication.
/// Member-gated families that ADD to their type's effect rather than replacing it.
///
/// `requestTemporaryFullAccuracyAuthorization` needs its own key AND the ordinary Location one — Apple
/// requires both — but `kappaMember` returns a single effect, so resolving it to `LocationTemporary`
/// silently DROPPED `Location`. The comment justifying the member-first order said "the general Location
/// key is still charged by every other call on the manager", which assumes the manager's constructor is
/// in scan: with an INJECTED manager (`func f(_ m: CLLocationManager)`) it is not, and `deny E Location`
/// flips green. Third instance today of a refinement swallowing what it refines.
public let PRIVACY_MEMBER_ALSO: [String: [String: String]] = [
    "CLLocationManager": ["requestTemporaryFullAccuracyAuthorization": "Location"],
]

/// Privacy families whose ENTRY POINT is a member on a SHARED type — see `kappaMember`. Separate from
/// PRIVACY_SDK_TYPES because charging the whole type would fabricate: HKObjectType vends every HealthKit
/// type, so only `clinicalType` names the clinical-records resource.
public let PRIVACY_MEMBER_TYPES: [String: [String: String]] = [
    "HKObjectType": ["clinicalType": "ClinicalRecords"],
    // `requestTemporaryFullAccuracyAuthorization` has its OWN key, on a manager already modelled as
    // Location — so it must be member-gated, or every location app would be charged the temporary key.
    "CLLocationManager": ["requestTemporaryFullAccuracyAuthorization": "LocationTemporary"],
    "HKSampleType": ["clinicalType": "ClinicalRecords"],
    // `GKLocalPlayer.local.authenticate` is the FIRST LINE of every Game Center game and requires no
    // key; Apple attaches NSGKFriendListUsageDescription to the friends APIs alone. Charging the type
    // made every Game Center title report a missing key it does not need — and GKLocalPlayer is not
    // single-purpose, which is this table's own stated bar for member-gating.
    "GKLocalPlayer": ["loadFriends": "GameCenterFriends",
                      "loadFriendsAuthorizationStatus": "GameCenterFriends",
                      "loadChallengeableFriends": "GameCenterFriends",
                      "loadFriendsList": "GameCenterFriends"],
]

public let PRIVACY_SDK_TYPES: [String: String] = [
    // Location — CoreLocation (the sensor-accessing MANAGER/updater/geocoder; CLLocation itself is a value
    // type carrying already-read coordinates, so it is NOT here) + MapKit user-tracking.
    "CLLocationManager": "Location", "CLLocationUpdate": "Location",
    // CLGeocoder is NOT here: it converts a coordinate or address the CALLER supplies, "in conjunction
    // with, or independent of" MapKit, and needs only network access. The NSLocation* keys govern
    // reading the USER's location, which a geocoder never does. wikipedia-ios reverse-geocodes in a
    // view model and was charged Location for it.
    "MKUserTrackingMode": "Location",
    // Camera — AVFoundation capture (bare AVCaptureDevice/Session DEFAULT to Camera; the media-type arg
    // refines to Mic/Camera, and an ambiguous capture over-discloses BOTH — see the ambiguity note and
    // `privacyCaptureEffects`) + UIImagePickerController (its camera source).
    "AVCaptureDevice": "Camera", "UIImagePickerController": "Camera",
    // ARKit and VisionKit — CAMERA BY ANOTHER FRAMEWORK'S DOOR, and the tables were AVFoundation-shaped
    // so neither was here. An ARKit app or a document scanner verified CLEAN with "0 effects", exit 0,
    // against an empty plist — and ARKit does not merely get rejected, it TRAPS at runtime without
    // NSCameraUsageDescription. The "conditional on N uncovered modules" line did fire, but it fires on
    // apps whose AVFoundation use IS modelled too, so it carries no signal a reader can act on while the
    // exit code says clean. A whole category of camera app (every AR app, every scanner) was invisible.
    "ARSession": "Camera", "ARWorldTrackingConfiguration": "Camera", "ARFaceTrackingConfiguration": "Camera",
    "ARBodyTrackingConfiguration": "Camera", "ARImageTrackingConfiguration": "Camera",
    "ARGeoTrackingConfiguration": "Camera", "ARObjectScanningConfiguration": "Camera",
    "ARPositionalTrackingConfiguration": "Camera", "ARSCNView": "Camera", "ARView": "Camera",
    "VNDocumentCameraViewController": "Camera", "DataScannerViewController": "Camera",
    // Mic — the unambiguous audio-capture type. (AVAudioEngine is NOT here — mic-gated on `.inputNode`
    // in kappaPropertyRead; a bare playback engine must not fabricate Mic. See the note above.)
    "AVAudioRecorder": "Mic",
    // ── privacy/3 (2026-08-05) ────────────────────────────────────────────────────────────────────────
    // Added after FETCHING Apple's protected-resources list, which documents 56 usage-description keys
    // where candor modelled 26. Each family below landed only after a recall fixture measured the miss.
    // NFC — Core NFC reader sessions.
    "NFCNDEFReaderSession": "Nfc", "NFCTagReaderSession": "Nfc", "NFCVASReaderSession": "Nfc",
    // Fall detection — a CoreMotion surface with its OWN key, distinct from NSMotionUsageDescription.
    "CMFallDetectionManager": "FallDetection",
    // SensorKit — research sensor streams.
    "SRSensorReader": "SensorKit", "SRFetchRequest": "SensorKit",
    // Clinical health records — a HealthKit surface with its own key, separate from Share/Update.
    "HKClinicalType": "ClinicalRecords", "HKClinicalRecord": "ClinicalRecords",
    // FileProvider — vending a file-provider domain.
    "NSFileProviderManager": "FileProvider", "NSFileProviderDomain": "FileProvider",
    // System extensions — installing a driver / network / endpoint-security extension.
    "OSSystemExtensionRequest": "SystemExtension",
    // Apple events — driving another app (macOS automation).
    "NSAppleScript": "AppleEvents", "NSAppleEventDescriptor": "AppleEvents",
    // TV provider — single sign-on to a subscription.
    "VSAccountManager": "VideoSubscriber",
    // Game Center friends.
    // ── privacy/4 (2026-08-05) ────────────────────────────────────────────────────────────────────────
    // Focus status — whether the user is in a Focus mode.
    "INFocusStatusCenter": "FocusStatus",
    // Wallet identity — reading an ID document.
    "PKIdentityRequest": "Identity", "PKIdentityDocument": "Identity",
    "PKIdentityAuthorizationController": "Identity",
    // FinanceKit — financial data stored in Wallet.
    "FinanceStore": "FinancialData",
    // visionOS ARKit data providers. Each has its OWN key, and they are distinct types, so the split is
    // precise rather than a guess: hands vs world-sensing vs the main camera.
    "HandTrackingProvider": "HandsTracking",
    "PlaneDetectionProvider": "WorldSensing", "SceneReconstructionProvider": "WorldSensing",
    "ImageTrackingProvider": "WorldSensing",
    "CameraFrameProvider": "MainCamera",
    // Accessory tracking (visionOS) — AccessoryTrackingProvider / AccessoryAnchor, both confirmed.
    "AccessoryTrackingProvider": "AccessoryTracking", "AccessoryAnchor": "AccessoryTracking",
    // System administration (macOS) — Open Directory. Apple's own page for the key links
    // `ODRecordSetValue`, so the directory-record surface is what it means by "manipulate the system
    // configuration"; ODNode/ODSession are the same surface's entry points.
    "ODRecord": "SystemAdministration", "ODNode": "SystemAdministration",
    "ODSession": "SystemAdministration",
    // System-audio capture — Core Audio process taps, which Apple's key page links directly.
    "CATapDescription": "AudioCapture",
    // Contacts — the address book.
    "CNContactStore": "Contacts",
    // OUT-OF-PROCESS PICKERS REQUIRE NO KEY, and Apple says so in terms. CNContactPickerViewController:
    // "The app using contact picker view does not need access to the user's contacts and the user will
    // not be prompted for 'grant permission' access. The app has access only to the user's final
    // selection." Charging the key told Bitwarden-class apps their shipping manifest was wrong.
    // Reported, not required — the MotionRaw shape: the reach is real, the manifest requirement is not.
    "CNContactPickerViewController": "ContactsPicker",
    // Photos — the photo library.
    "PHPhotoLibrary": "Photos", "PHAsset": "Photos", "PHImageManager": "Photos",
    // PHPicker is the same out-of-process design as the contacts picker — it exists so an app can offer
    // photo selection WITHOUT photo-library authorization. Recorded as suspected on 2026-08-07 when the
    // evidence was not citable; the contacts-picker page states the principle for the picker family, and
    // Kingfisher's demo (which reaches PHPicker and declares the key nowhere) is the corroborating
    // measurement. Keyless, not dropped.
    "PHPickerViewController": "PhotosPicker",
    // Notify — user-attention / notifications.
    "UNUserNotificationCenter": "Notify",

    // ── privacy/2 (2026-08-04) ───────────────────────────────────────────────────────────────────────
    // The first wave covered six sensors, which was not enough to answer the question the product surface
    // asks. A real app (pollen) declares Motion and two HealthKit keys, and `privacy-manifest --verify`
    // said NOTHING about them in either direction — neither required nor flagged as unused — because the
    // effects did not exist. An `exit 0` that means "the six I model are declared" reads as "your plist is
    // right", which is the absence-is-a-claim shape this project keeps closing elsewhere.
    //
    // Every type below is SINGLE-PURPOSE, which is the bar for no-method-gating: any call into it IS the
    // access. Value types that merely CARRY already-read data are excluded on the CLLocation precedent
    // (HKQuantity, CMDeviceMotion, EKEvent, CBUUID …) — holding a reading is not taking one.
    // Health — HealthKit. The store plus the query/session types that read or write samples.
    "HKHealthStore": "Health", "HKSampleQuery": "Health", "HKObserverQuery": "Health",
    "HKAnchoredObjectQuery": "Health", "HKStatisticsQuery": "Health", "HKStatisticsCollectionQuery": "Health",
    "HKActivitySummaryQuery": "Health", "HKWorkoutSession": "Health", "HKWorkoutBuilder": "Health",
    "HKLiveWorkoutBuilder": "Health", "HKHeartbeatSeriesBuilder": "Health",
    // Motion — CoreMotion. The MANAGERS/recorders that start the sensors (CMDeviceMotion/CMAccelerometerData
    // are value types carrying an already-taken reading, so they are not here).
    // WHICH CoreMotion CLASSES REQUIRE THE KEY IS NOT ALL OF THEM, and mapping them uniformly produced a
    // FALSE requirement on a shipping app: a corpus run reported WordPress-iOS as under-declared for
    // NSMotionUsageDescription, and the reach was `CMMotionManager.startDeviceMotionUpdates()`.
    //
    // Apple's own key page (fetched 2026-08-06) names exactly four APIs — CMSensorRecorder, CMPedometer,
    // CMMotionActivityManager, CMMovementDisorderManager — and CMAltimeter and CMHeadphoneMotionManager
    // reference the key on their own pages. CMMotionManager references NO usage key: raw accelerometer,
    // gyroscope and device-motion streams need none and prompt for nothing.
    //
    // So the raw stream gets its OWN effect with no key, exactly as `Notify` does. The access is still
    // REPORTED — it is real sensor use and a reader should see it — but it is not a manifest requirement,
    // and asserting one is the fabrication that makes a verify untrustworthy.
    "CMMotionManager": "MotionRaw",
    "CMPedometer": "Motion", "CMAltimeter": "Motion", "CMMotionActivityManager": "Motion",
    "CMHeadphoneMotionManager": "Motion", "CMSensorRecorder": "Motion",
    // Apple lists this one on the key page and candor mapped it NOWHERE — an under-report on a
    // documented API, found by reading the list rather than trusting the table.
    "CMMovementDisorderManager": "Motion",
    // Calendar / Reminders — EventKit. `EKEventStore` serves BOTH and the choice is per-call
    // (`EKEntityType.event` vs `.reminder`), so it is ambiguous exactly like AVCaptureDevice and is handled
    // by `privacyEventKitEffects` below — it is NOT in this table. The single-purpose UI types are.
    "EKEventEditViewController": "Calendar", "EKCalendarChooser": "Calendar",
    // Bluetooth — CoreBluetooth. Scanning or advertising; both gate on the same key family.
    "CBCentralManager": "Bluetooth", "CBPeripheralManager": "Bluetooth",
    // Speech — on-device/server speech recognition (distinct from Mic: the AUDIO capture is Mic, the
    // RECOGNITION is a separate authorization with its own key, and an app can do either without the other).
    "SFSpeechRecognizer": "Speech", "SFSpeechAudioBufferRecognitionRequest": "Speech",
    "SFSpeechURLRecognitionRequest": "Speech",
    // Biometrics — LocalAuthentication. NSFaceIDUsageDescription is required for Face ID; Touch ID needs no
    // key, and LAContext cannot tell you which the device has, so this over-discloses on a Touch-ID-only
    // device. Deliberate, and the same direction as the capture ambiguity: a missing key is the costly error.
    "LAContext": "Biometrics",
    // MediaLibrary — the user's Apple Music / media library (NOT AVFoundation playback of your own assets).
    "MPMediaLibrary": "MediaLibrary", "MPMediaQuery": "MediaLibrary", "MPMusicPlayerController": "MediaLibrary",
    "MPMediaPickerController": "MediaLibrary",
    // HomeKit — the user's home accessories.
    "HMHomeManager": "HomeKit", "HMAccessoryBrowser": "HomeKit",
    // Tracking — App Tracking Transparency (the IDFA prompt).
    "ATTrackingManager": "Tracking",
    // NearbyInteraction — UWB ranging with nearby devices.
    "NISession": "NearbyInteraction",
    // Siri — donating to / requesting Siri authorization.
    // NSSiriUsageDescription is required for "APIs that SEND USER DATA TO SIRI" — the authorization
    // flow, which is `INPreferences.requestSiriAuthorization`. INVoiceShortcutCenter manages the app's
    // OWN shortcuts and names no key on its page; charging it told firefox-ios and focus-ios — two
    // shipping browsers that declare no Siri key and never request Siri authorization — that their
    // manifests were wrong.
    "INPreferences": "Siri",
]

/// `privacy/2` — for a call ALREADY classified as a privacy effect, the read/write direction its verb
/// implies. Same contract as `fsKind`: `["read"]`, `["write"]`, `["read","write"]`, or `[]` when the verb
/// does not say.
///
/// WHY THIS EXISTS AT ALL. Apple distinguishes direction in three key families and candor collapsed all
/// three: HealthKit's Share (read) vs Update (write), Photos' full library vs Add-only, and Calendars'
/// full vs write-only. Treating each pair as interchangeable ALTERNATIVES means an app that both reads and
/// writes HealthKit passes a verify while declaring only Share — and is then rejected by Apple. The verify
/// was sound on presence and silent on direction; this is the direction half.
///
/// THE EMPTY CASE IS STILL THE DISCIPLINE. An unrecognised verb contributes nothing, and a privacy effect
/// with no determined direction keeps the OLD behaviour exactly: any acceptable key satisfies it. So this
/// can only ever ADD a requirement where the direction was proved, never invent one where it was not.
/// The full `privacy/2` effect vocabulary, for cheap membership tests at a call site. Kept beside the
/// type table so a vocabulary rung updates one place.
/// THE canonical sensor vocabulary. It was duplicated in SIX places (this, ReportModel's
/// PRIVACY_EFFECTS, PrivacyManifestCLI's privacyEffects, main.swift's effect list, Policy's EFFECTS and
/// Surface's salience switch) — so adding privacy/3's nine families to the type table and the key map
/// changed NOTHING until all six moved. A vocabulary with six copies is six places to forget the tenth
/// family, and the failure is silent: the effect is computed and then dropped for not being on a list.
/// The other five now derive from this one.
/// The `extensions` value the engine discloses for this wave. ONE constant, in CandorCore so the TESTS
/// can import it: it used to be a literal in the report writer and a SECOND literal in a test, so
/// bumping the wave turned the suite red on a version-coupled assertion — a class this project has
/// already paid for across six repos. The next bump moves this line and nothing else.
/// HOW each modelled key is determined — §6 of CONSTANT-PROVENANCE-DESIGN.md.
///
/// The point is NOT precision, it is RECALL: what has to be true for the key to be emitted at all.
///
///   `type`       a curated type name appears. Recall-complete by construction.
///   `argument`   an enum/descriptor argument refines it — and an UNREADABLE argument OVER-discloses
///                (`privacyCaptureEffects`, `privacyAudioSessionEffects`), so recall is complete too.
///   `member`     a specific member name on a shared type. Recall-complete.
///   `constant`   a path/URI CLASS decides it, so an undetermined value means the key can be MISSED.
///                This is the only lossy basis, and the only one that needs a count beside it.
///   `entitlement` read from a manifest, not from code.
///   `none`       no code signal is modelled.
///
/// This exists so that reaching 57/57 does not silently delete the "here are the keys I do not check"
/// warning while coverage WITHIN several keys is still partial. The disclosure changes axis from WHICH
/// keys to HOW COMPLETELY, and a key resolved by `constant` must always report its undetermined count.
/// PATH CLASS — which protected folder a file path falls in. CONSTANT-PROVENANCE-DESIGN.md rung 1.
///
/// CLASSES, NOT STRINGS: the answer needed is not the path, it is which protected folder it is under, so
/// a proved PREFIX decides it and the unknowable tail is irrelevant. That is what turns a string-solver
/// problem into a table lookup.
///
/// Returns a SET because `/Volumes/…` is genuinely both — macOS cannot tell a removable disk from a
/// mounted network share by path alone, and on a privacy manifest a false prompt costs a confused user
/// while a false silence costs a rejection. Over-disclose, exactly as an ambiguous capture does.
///
/// Returns EMPTY for the app sandbox and for anything unrecognised — an ordinary file write must not
/// invent a folder requirement. The undetermined case is not represented here at all: it is the ABSENCE
/// of a determined path, counted and disclosed by the verify (§6), never guessed at from this side.
/// HOST CLASS — is this endpoint on the LOCAL network? The host axis of CONSTANT-PROVENANCE-DESIGN.md.
///
/// `.local` is mDNS by definition, and link-local / RFC1918 literals are LAN addresses by definition.
/// Everything else — including every computed or unresolvable host — returns EMPTY, because charging
/// NSLocalNetworkUsageDescription to every networking app is exactly the fabrication that kept this key
/// unmodelled. The residue is disclosed, not guessed.
public func hostClasses(_ host: String) -> Set<String> {
    let h = host.split(separator: ":").first.map(String.init) ?? host
    if h.hasSuffix(".local") || h.hasSuffix(".local.") { return ["LocalNetwork"] }
    // ONLY an actual IPv4 literal. `hasPrefix("10.")` alone matched `10.media.tumblr.com` and
    // `192.168.example.com` — numbered CDN subdomains are real, and charging them the local-network key
    // is a fabrication on ordinary public traffic.
    let labels = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let isIPv4 = labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    if isIPv4 {
        if h.hasPrefix("169.254.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") { return ["LocalNetwork"] }
        // 224.0.0.0/4 is the whole multicast range, not the /24 the first cut matched — 239.255.255.250
        // is SSDP/UPnP, the second-most-common LAN-discovery literal after mDNS.
        if let first = Int(labels[0]), (224...239).contains(first) { return ["LocalNetwork"] }
        if h.hasPrefix("172."), let n = Int(labels[1]), (16...31).contains(n) { return ["LocalNetwork"] }
    }
    // IPv6 link-local. The port-strip above splits on ":", which mangles a v6 literal, so test the raw
    // host too rather than the stripped one.
    let raw = host.lowercased()
    if raw.hasPrefix("fe80:") || raw.hasPrefix("[fe80:") || raw.hasPrefix("ff02:") || raw.hasPrefix("[ff02:") {
        return ["LocalNetwork"]
    }
    return []
}

public func pathClasses(_ path: String) -> Set<String> {
    // Normalise the two spellings of home: `~/Desktop` and `/Users/<name>/Desktop`.
    // NORMALISE the spellings macOS actually produces before matching. All three of these are real paths
    // to the same protected folder and all three were classified as NOTHING — and because they ARE
    // determined, the ⊤ count could not report them either: a missing key with no disclosure, which the
    // design's §4.4 contract forbids outright.
    var p = path
    if p.hasPrefix("/System/Volumes/Data/") { p = String(p.dropFirst("/System/Volumes/Data".count)) }
    if p.hasPrefix("/private/") { p = String(p.dropFirst("/private".count)) }
    if p.hasPrefix("~") { p = "/Users/_" + p.dropFirst() }
    // `/Users/Shared` is NOT a home directory — it is the shared, unprotected one, and rewriting it to
    // `/Users/_` charged `/Users/Shared/Documents/x` the Documents key. A fixed non-home name, so this is
    // a fabrication on an unambiguous input rather than a judgement call.
    if let r = p.range(of: #"(?i)^/Users/[^/]+"#, options: .regularExpression),
       String(p[r]).lowercased() != "/users/shared" { p = "/Users/_" + p[r.upperBound...] }
    if p.hasPrefix("/Volumes/") { return ["RemovableVolume", "NetworkVolume"] }
    // ANOTHER APP'S BUNDLE / ANOTHER APP'S CONTAINER. Apple names no API for these two keys because
    // there isn't one — reading another app's bundle is ordinary file I/O, and it is the PATH that makes
    // it protected. That is precisely what a path class is for, so they need no new mechanism at all.
    if p.hasPrefix("/Applications/") && p.contains(".app/") { return ["AppBundles"] }
    if p.hasPrefix("/Users/_/Library/Containers/") { return ["AppData"] }
    for (prefix, cls) in [("/net/", "NetworkVolume"), ("smb://", "NetworkVolume"),
                          ("afp://", "NetworkVolume"), ("nfs://", "NetworkVolume")]
    where p.hasPrefix(prefix) { return [cls] }
    for (folder, cls) in [("Desktop", "FolderDesktop"), ("Documents", "FolderDocuments"),
                          ("Downloads", "FolderDownloads")]
    where p.lowercased() == "/users/_/" + folder.lowercased()
       || p.lowercased().hasPrefix("/users/_/" + folder.lowercased() + "/") { return [cls] }
    return []
}

/// `FileManager.urls(for:in:)`'s search-path argument → the same classes. Rung 2, and the CANONICAL
/// spelling: real code asks for `.desktopDirectory` far more often than it writes the path out.
public func searchPathClasses(_ member: String?) -> Set<String> {
    switch member {
    case "desktopDirectory":   return ["FolderDesktop"]
    case "downloadsDirectory": return ["FolderDownloads"]
    // `.documentDirectory` is DELIBERATELY ABSENT. On iOS it returns the app's OWN sandbox Documents
    // directory — the single commonest file-storage line in iOS development — and
    // NSDocumentsFolderUsageDescription is a macOS TCC key that does not exist there. Mapping it made
    // `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)` exit 1 on essentially
    // every iOS app, demanding a key the platform has no concept of. Same over-fire for a SANDBOXED
    // macOS app, where it also resolves inside the container.
    //
    // The other two are safe because they have no sandbox meaning: `.desktopDirectory` and
    // `.downloadsDirectory` name the real user folders or nothing. A LITERAL `/Users/x/Documents/…`
    // still classifies (rung 1) — that spelling is unambiguous in a way the enum is not.
    default: return []   // every other search path is unprotected or app-scoped — never guess a folder
    }
}

/// ENTITLEMENT → REQUIRED USAGE-DESCRIPTION KEY.
///
/// A DIFFERENT KIND OF EVIDENCE, and the verify says so rather than folding it in. Everything else this
/// extension reports comes from analysing code; this comes from reading a second manifest and comparing
/// it with the first. Both are useful and only one is candor's usual claim, so a finding sourced here is
/// labelled at the point of output — presenting a plist diff as a code analysis would misrepresent what
/// was actually checked.
///
/// It exists because some protected capabilities have NO call site at all. `NSCriticalMessaging` is the
/// clear case: Apple's page for it links no symbol, because the capability is granted by an entitlement
/// and the API it unlocks is ordinary messaging code. No amount of call-graph analysis will ever see it.
public let ENTITLEMENT_REQUIRED_KEYS: [String: String] = [
    "com.apple.developer.messages.critical-messaging": "NSCriticalMessagingUsageDescription",
]

public let PRIVACY_KEY_BASIS: [String: String] = {
    var m: [String: String] = [:]
    for e in PRIVACY_EFFECTS_ORDER { m[e] = "type" }
    // refined by a readable argument; unreadable over-discloses, so recall stays complete
    // Camera/Mic ARE argument-refined (the capture media type, the audio-session category). Calendar and
    // Reminders are NOT: `EKEventStore` is a plain type match and their read/write split comes from the
    // METHOD NAME via `privacyKind(member:)` — which is the `member` basis this table already uses for
    // ClinicalRecords and LocationTemporary. Labelling 5 keys `argument` overstated the strongest basis
    // in a breakdown whose entire purpose is being accurate about HOW something was determined.
    for e in ["Camera", "Mic"] { m[e] = "argument" }
    for e in ["Calendar", "Reminders"] { m[e] = "member" }
    // a member on a type that is shared with another family
    for e in ["ClinicalRecords", "LocationTemporary"] { m[e] = "member" }
    // read from a MANIFEST, never from code — labelled separately in the output
    m["CriticalMessaging"] = "entitlement"
    // the LOSSY basis: an undetermined path means the key can be MISSED, so §6 always prints a count
    for e in ["FolderDesktop", "FolderDocuments", "FolderDownloads", "RemovableVolume",
              "NetworkVolume", "LocalNetwork"] {
        m[e] = "constant"
    }
    return m
}()

// CONSOLIDATED to a single unpublished wave. Development ran through four increments in two days
// (six→eighteen sensors + direction, Apple's real key list, the remaining type-nameable families, path
// and host classes) and each bumped this constant. But `privacy/1` is the only version any RELEASE has
// ever carried — v0.25.0 and v0.26.0 both ship it — so `privacy/2`, `/3`, `/4` and `/5` never existed
// for a consumer. Publishing four wave numbers that nothing was ever built against would be describing
// our git history as if it were their upgrade path. It ships as ONE wave; the increments survive as
// narrative in CHANGELOG.md and SPEC-EXTENSION-privacy.md, where they are history rather than contract.
public let PRIVACY_EXTENSION_ID = "privacy/2"

public let PRIVACY_EFFECTS_ORDER: [String] = [
    "Location", "Camera", "Mic", "Contacts", "Photos", "Notify",
    "Health", "Motion", "Calendar", "Reminders", "Bluetooth", "Speech",
    "Biometrics", "MediaLibrary", "HomeKit", "Tracking", "NearbyInteraction", "Siri",
    // privacy/3 (2026-08-05) — appended, never interleaved, so existing output ordering is unchanged.
    "Nfc", "FallDetection", "SensorKit", "FileProvider", "SystemExtension", "AppleEvents",
    "VideoSubscriber", "GameCenterFriends", "ClinicalRecords",
    // privacy/4 (2026-08-05) — every type name below was verified against Apple's docs JSON first.
    "FocusStatus", "Identity", "FinancialData", "HandsTracking", "WorldSensing", "MainCamera",
    "LocationTemporary", "AccessoryTracking", "SystemAdministration", "AudioCapture",
    "AppBundles", "AppData", "CriticalMessaging",
    // constant-basis (path class) — CONSTANT-PROVENANCE-DESIGN.md
    "FolderDesktop", "FolderDocuments", "FolderDownloads", "RemovableVolume", "NetworkVolume",
    "LocalNetwork",
    // privacy/4 (2026-08-06) — appended. The raw CoreMotion stream, split from `Motion` because Apple
    // requires NSMotionUsageDescription for the stored/derived APIs and not for CMMotionManager.
    "MotionRaw",
    // privacy/4 (2026-08-07) — the OUT-OF-PROCESS SYSTEM PICKERS. Apple states for the contacts picker
    // that the app "does not need access" and is never prompted; PHPicker is the same design. The reach
    // is reported (a policy can `deny ContactsPicker`) and no Info.plist key is required.
    "ContactsPicker", "PhotosPicker",
]

public let PRIVACY_EFFECTS_ALL: Set<String> = Set(PRIVACY_EFFECTS_ORDER)

/// Effects SPLIT OUT of a broader one, and the effect they used to be part of.
///
/// A split narrows every existing policy that named the parent, SILENTLY. An operator who wrote
/// `deny Motion` to mean "no CoreMotion in this layer" now passes a `CMMotionManager` reach, and nothing
/// tells them: the rule still binds, still evaluates, still reports no violation. That is a gate the
/// operator believes is on — the same shape as the zero-match rule ⟨0.24⟩ §3.1 made disclosable, one
/// level up, and the same remedy applies. Not a violation (the narrowing is deliberate and correct —
/// Apple requires no key for the raw stream), but never silent.
public let EFFECT_SPLIT_PARENT: [String: String] = [
    "MotionRaw": "Motion",
]


/// EVERY usage-description key Apple documents under "protected resources", verbatim.
///
/// FETCHED, not recalled — from Apple's own docs JSON (`developer.apple.com/tutorials/data/documentation/
/// bundleresources/protected-resources.json`) on 2026-08-05. That matters, because the first version of
/// this disclosure was hand-compiled from memory: it named 14 unmodelled keys when the real number was
/// 30, so **the warning about the gap itself under-reported the gap by more than half**. A disclosure
/// that under-states is the same defect as a report that under-states, one level up.
///
/// The unmodelled set is DERIVED from this minus `privacyKeyMap`, never hand-maintained, so it cannot
/// silently fall behind again — add a key to the model and it leaves the disclosure automatically.
/// `PrivacyKeyUniverseTests` pins the arithmetic.
///
/// One key is here that the page does not list: NSFocusStatusUsageDescription. It is real (Focus status
/// sharing) and documented elsewhere; kept, and flagged, rather than dropped because it did not appear
/// in one source.
public let APPLE_PRIVACY_KEYS: [(key: String, why: String)] = [
    ("NFCReaderUsageDescription", "not modelled"),
    ("NSAccessoryTrackingUsageDescription", "visionOS surface; not modelled"),
    ("NSAppBundlesUsageDescription", "enterprise/managed surface; not modelled"),
    ("NSAppDataUsageDescription", "enterprise/managed surface; not modelled"),
    ("NSAppleEventsUsageDescription", "not modelled"),
    ("NSAppleMusicUsageDescription", "not modelled"),
    ("NSAudioCaptureUsageDescription", "visionOS surface; not modelled"),
    ("NSBluetoothAlwaysUsageDescription", "not modelled"),
    ("NSBluetoothPeripheralUsageDescription", "not modelled"),
    ("NSCalendarsFullAccessUsageDescription", "not modelled"),
    ("NSCalendarsUsageDescription", "not modelled"),
    ("NSCalendarsWriteOnlyAccessUsageDescription", "not modelled"),
    ("NSCameraUsageDescription", "not modelled"),
    ("NSContactsUsageDescription", "not modelled"),
    ("NSCriticalMessagingUsageDescription", "NO PUBLIC API NAMES IT — Apple's page for this key links no symbol at all. It gates an entitlement for emergency SMS, so the evidence is a .entitlements file, not a call site"),
    ("NSDesktopFolderUsageDescription", "triggered by PATH, not by API — needs value provenance"),
    ("NSDocumentsFolderUsageDescription", "triggered by PATH, not by API — needs value provenance"),
    ("NSDownloadsFolderUsageDescription", "triggered by PATH, not by API — needs value provenance"),
    ("NSEnterpriseMCAMUsageDescription", "enterprise/managed surface; not modelled"),
    ("NSFaceIDUsageDescription", "not modelled"),
    ("NSFallDetectionUsageDescription", "not modelled"),
    ("NSFileProviderDomainUsageDescription", "not modelled"),
    ("NSFileProviderPresenceUsageDescription", "RESEARCHED 2026-08-05 AND GENUINELY UNDETERMINABLE: Apple's key page links no symbol, the FileProvider framework index contains no presence/known-folder/materialised symbol, and no entitlement names it either. It is not a table row anyone forgot — there is nothing in code to see. The verify raises it CONDITIONALLY where a file provider exists, which is the most that can be said"),
    ("NSFinancialDataUsageDescription", "enterprise/managed surface; not modelled"),
    ("NSGKFriendListUsageDescription", "not modelled"),
    ("NSHandsTrackingUsageDescription", "visionOS surface; not modelled"),
    ("NSHealthClinicalHealthRecordsShareUsageDescription", "not modelled"),
    ("NSHealthShareUsageDescription", "not modelled"),
    ("NSHealthUpdateUsageDescription", "not modelled"),
    ("NSHomeKitUsageDescription", "not modelled"),
    ("NSIdentityUsageDescription", "not modelled"),
    ("NSLocalNetworkUsageDescription", "not separable by type (NWBrowser/NWConnection also serve ordinary networking) and the key travels with an entitlement this engine does not read; the bonjour-descriptor and .local-host spellings are tractable — CONSTANT-PROVENANCE-DESIGN.md step 3"),
    ("NSLocationAlwaysAndWhenInUseUsageDescription", "not modelled"),
    ("NSLocationAlwaysUsageDescription", "not modelled"),
    ("NSLocationTemporaryUsageDescription", "a temporary-accuracy REQUEST on a modelled Location manager; the key is purpose-string-keyed, not API-keyed"),
    ("NSLocationUsageDescription", "not modelled"),
    ("NSLocationWhenInUseUsageDescription", "not modelled"),
    ("NSMainCameraUsageDescription", "visionOS surface; not modelled"),
    ("NSMicrophoneUsageDescription", "not modelled"),
    ("NSMotionUsageDescription", "not modelled"),
    ("NSNearbyInteractionAllowOnceUsageDescription", "the allow-once variant of a modelled key; not separable at the call site"),
    ("NSNearbyInteractionUsageDescription", "not modelled"),
    ("NSNetworkVolumesUsageDescription", "triggered by PATH, not by API — needs value provenance"),
    ("NSPhotoLibraryAddUsageDescription", "not modelled"),
    ("NSPhotoLibraryUsageDescription", "not modelled"),
    ("NSRemindersFullAccessUsageDescription", "not modelled"),
    ("NSRemindersUsageDescription", "not modelled"),
    ("NSRemovableVolumesUsageDescription", "triggered by PATH, not by API — needs value provenance"),
    ("NSSensorKitUsageDescription", "not modelled"),
    ("NSSiriUsageDescription", "not modelled"),
    ("NSSpeechRecognitionUsageDescription", "not modelled"),
    ("NSSystemAdministrationUsageDescription", "not modelled"),
    ("NSSystemExtensionUsageDescription", "not modelled"),
    ("NSUserTrackingUsageDescription", "not modelled"),
    ("NSVideoSubscriberAccountUsageDescription", "not modelled"),
    ("NSWorldSensingUsageDescription", "visionOS surface; not modelled"),
    ("NSFocusStatusUsageDescription", "not modelled (documented outside the protected-resources page)"),
]

/// The keys candor does NOT model — Apple's universe minus what `privacyKeyMap` can emit. Derived.
public var PRIVACY_UNMODELLED_KEYS: [(key: String, why: String)] {
    let modelled = Set(privacyKeyMap.values.flatMap { $0 })
    return APPLE_PRIVACY_KEYS.filter { !modelled.contains($0.key) }
}

public let privacyKeyMap: [String: [String]] = [
    // privacy/3 (2026-08-05) — added after FETCHING Apple's protected-resources list and finding candor
    // modelled 26 of the 56 keys it documents. Each landed only after a recall fixture measured the miss.
    "Nfc": ["NFCReaderUsageDescription"],
    "FallDetection": ["NSFallDetectionUsageDescription"],
    "SensorKit": ["NSSensorKitUsageDescription"],
    "FileProvider": ["NSFileProviderDomainUsageDescription"],
    "SystemExtension": ["NSSystemExtensionUsageDescription"],
    "AppleEvents": ["NSAppleEventsUsageDescription"],
    "VideoSubscriber": ["NSVideoSubscriberAccountUsageDescription"],
    "GameCenterFriends": ["NSGKFriendListUsageDescription"],
    "ClinicalRecords": ["NSHealthClinicalHealthRecordsShareUsageDescription"],
    // privacy/4
    "FocusStatus": ["NSFocusStatusUsageDescription"],
    "Identity": ["NSIdentityUsageDescription"],
    "FinancialData": ["NSFinancialDataUsageDescription"],
    "HandsTracking": ["NSHandsTrackingUsageDescription"],
    "WorldSensing": ["NSWorldSensingUsageDescription"],
    // The enterprise variant is the SAME `CameraFrameProvider` surface under a managed entitlement —
    // Apple's page for NSEnterpriseMCAM links the very same "Accessing the main camera" article. Which of
    // the two keys applies is an entitlement fact this engine cannot read, and `privacyKeyMap` is a list
    // whose members are ALTERNATIVES, so declaring either satisfies the requirement. Exactly the
    // NearbyInteraction allow-once shape.
    "MainCamera": ["NSMainCameraUsageDescription", "NSEnterpriseMCAMUsageDescription"],
    "AccessoryTracking": ["NSAccessoryTrackingUsageDescription"],
    "SystemAdministration": ["NSSystemAdministrationUsageDescription"],
    "AudioCapture": ["NSAudioCaptureUsageDescription"],
    "AppBundles": ["NSAppBundlesUsageDescription"],
    "AppData": ["NSAppDataUsageDescription"],
    // entitlement-sourced (see ENTITLEMENT_REQUIRED_KEYS) — no call site exists for it
    "CriticalMessaging": ["NSCriticalMessagingUsageDescription"],
    // constant-basis: decided by the PATH, so these always report an undetermined count beside them (§6)
    "FolderDesktop": ["NSDesktopFolderUsageDescription"],
    "FolderDocuments": ["NSDocumentsFolderUsageDescription"],
    "FolderDownloads": ["NSDownloadsFolderUsageDescription"],
    "RemovableVolume": ["NSRemovableVolumesUsageDescription"],
    "NetworkVolume": ["NSNetworkVolumesUsageDescription"],
    "LocalNetwork": ["NSLocalNetworkUsageDescription"],
    "LocationTemporary": ["NSLocationTemporaryUsageDescription"],
    "Location": ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription",
                 "NSLocationAlwaysUsageDescription", "NSLocationUsageDescription"],
    "Camera": ["NSCameraUsageDescription"],
    "Mic": ["NSMicrophoneUsageDescription"],
    "Contacts": ["NSContactsUsageDescription"],
    "Photos": ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"],
    "Notify": [],

    // ── privacy/2 ────────────────────────────────────────────────────────────────────────────────────
    // A key list is a set of ACCEPTABLE alternatives — any one present satisfies the effect. That is the
    // established semantic (Location has four), and it is what keeps a verify from inventing an
    // under-declaration it cannot substantiate.
    //
    // The limit that buys, stated rather than buried: HealthKit's two keys are not alternatives in Apple's
    // model — Share gates READING and Update gates WRITING — and this engine does not discriminate read
    // from write at the call site, so an app that only declares Share and also writes samples passes here
    // and is rejected by Apple. Same for the EventKit pairs. Narrowing that needs per-call direction
    // analysis; until then the verify is sound on PRESENCE and silent on DIRECTION, and says so.
    "Health": ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription"],
    "Motion": ["NSMotionUsageDescription"],
    // No key: Apple's NSMotionUsageDescription page does not list CMMotionManager, and its own page
    // references no usage key. Reported as reach, never as a requirement — see the sensor table.
    "MotionRaw": [],
    "ContactsPicker": [], "PhotosPicker": [],
    "Calendar": ["NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription",
                 "NSCalendarsWriteOnlyAccessUsageDescription"],
    "Reminders": ["NSRemindersUsageDescription", "NSRemindersFullAccessUsageDescription"],
    "Bluetooth": ["NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription"],
    "Speech": ["NSSpeechRecognitionUsageDescription"],
    "Biometrics": ["NSFaceIDUsageDescription"],
    "MediaLibrary": ["NSAppleMusicUsageDescription"],
    "HomeKit": ["NSHomeKitUsageDescription"],
    "Tracking": ["NSUserTrackingUsageDescription"],
    "NearbyInteraction": ["NSNearbyInteractionUsageDescription",
                          // Apple accepts EITHER spelling; the allow-once variant is a developer choice
                          // about the prompt, not a distinguishable call site. `privacyKeyMap` is a list
                          // and the verify is satisfied by any member, so this needs no new family.
                          "NSNearbyInteractionAllowOnceUsageDescription"],
    "Siri": ["NSSiriUsageDescription"],
]

/// `privacy/2` — the DIRECTION-SENSITIVE key families. Apple distinguishes reading from writing in exactly
/// three places, and treating each pair as interchangeable alternatives is what let an app that both reads
/// and writes HealthKit pass while declaring only Share.
///
/// Consulted only when the direction was PROVED. An effect with no determined direction falls through to
/// `privacyKeyMap` — i.e. to the pre-`privacy/2` any-key semantics — so this can only ever ADD a
/// requirement where a verb said, never invent one where none did.
public let privacyKeyMapByDirection: [String: [String: [String]]] = [
    // Share gates READING samples, Update gates WRITING them. An app doing both needs both keys, which is
    // the case this table exists for.
    "Health": ["read":  ["NSHealthShareUsageDescription"],
               "write": ["NSHealthUpdateUsageDescription"]],
    // The Add-only key permits writing and nothing else; the full key permits both, so it satisfies a
    // write too. Reading REQUIRES the full key — Add-only does not grant it.
    "Photos": ["read":  ["NSPhotoLibraryUsageDescription"],
               "write": ["NSPhotoLibraryAddUsageDescription", "NSPhotoLibraryUsageDescription"]],
    // iOS 17 split calendars into full and write-only. Write-only does not grant reading.
    "Calendar": ["read":  ["NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription"],
                 "write": ["NSCalendarsWriteOnlyAccessUsageDescription",
                           "NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"]],
]

public func privacyKind(root: String, member: String, toShareIsNil: Bool? = nil) -> [String] {
    switch member {
    // ── writes: the call mutates the user's store ────────────────────────────────────────────────────
    case "save", "saveObject", "saveObjects", "delete", "deleteObjects", "deleteObject",
         "remove", "removeCalendar", "removeEvent", "removeReminder",
         "add", "addSamples", "addMetadata", "addWorkoutEvents",
         "creationRequestForAsset", "creationRequestForAssetFromImage", "creationRequestForAssetFromVideo",
         "requestWriteOnlyAccessToEvents", "saveCalendar", "commit", "finishWorkout", "endCollection":
        return ["write"]
    // ── reads: the call observes without mutating ────────────────────────────────────────────────────
    case "execute", "fetchAssets", "fetchAssetsWithLocalIdentifiers", "fetchTopLevelUserCollections",
         "requestImage", "requestImageDataAndOrientation", "requestAVAsset", "requestPlayerItem",
         "events", "reminders", "calendars", "calendarItems", "calendarItem",
         "predicateForEvents", "predicateForReminders", "predicateForIncompleteReminders",
         "predicateForCompletedReminders", "requestFullAccessToEvents", "requestFullAccessToReminders",
         "preferredUnits", "statisticsQuery", "biologicalSex", "dateOfBirthComponents", "bloodType",
         "unifiedContacts", "unifiedContact", "enumerateContacts", "authorizationStatus":
        return ["read"]
    // `performChanges` is the Photos WRITE transaction wrapper — the change requests inside it are what
    // mutate, and the block body is analysed on its own, but the wrapper itself only ever exists to write.
    case "performChanges", "performChangesAndWait":
        return ["write"]
    default: break
    }
    // `requestAuthorization(toShare:read:)` names both sides in one call — but the discriminating argument
    // is NOT always runtime. `toShare: nil` is the canonical read-only spelling and is right there in the
    // source, so treating this as unconditionally ambiguous charged every read-only HealthKit app with a
    // WRITE and demanded a key it does not need: a false under-declaration on the commonest shape, in the
    // fabrication direction this extension exists to fence. `toShareIsNil` carries the answer when the
    // syntactic engine can see it; a non-nil or invisible argument stays ambiguous and declares both.
    if member.hasPrefix("requestAuthorization") {
        return toShareIsNil == true ? ["read"] : ["read", "write"]
    }
    if member.hasPrefix("save") || member.hasPrefix("delete") || member.hasPrefix("remove")
        || member.hasPrefix("write") { return ["write"] }
    if member.hasPrefix("fetch") || member.hasPrefix("query") || member.hasPrefix("read") { return ["read"] }
    return []   // the verb does not say — no claim, and the effect keeps its old any-key semantics
}

/// EventKit's `EKEventStore` reaches BOTH calendars and reminders, chosen per call by an `EKEntityType`
/// argument — the same ambiguity shape as `AVCaptureDevice`'s media type, and resolved the same way: a
/// statically-visible `.event`/`.reminder` refines, and an ambiguous store over-discloses BOTH.
///
/// The over-disclosure is the deliberate trade-off this extension states: for a privacy manifest a MISSED
/// sensor is App-Store-rejection-shaped, so an ambiguous store declares both rather than silently miss one.
/// It does mean a calendar-only app is told it also needs a Reminders key — annoying, and the correct
/// direction to be wrong in. The precision fence still holds for a genuinely unknown receiver: that stays
/// pure and is never guessed.
public func privacyEventKitEffects(entityType: String?) -> [String] {
    switch entityType {
    case "event":    return ["Calendar"]
    case "reminder": return ["Reminders"]
    default:         return ["Calendar", "Reminders"]
    }
}

/// The EventKit types whose Calendar/Reminders split is refined by an entity-type argument.
public let PRIVACY_EVENTKIT_TYPES: Set<String> = ["EKEventStore"]

/// Classify a member call `root.member(...)` (root = the receiver chain's base identifier or the
/// receiver's inferred TYPE). Returns nil for the pure/unknown surface — never a guess.
public func kappaMember(root: String, member: String) -> String? {
    // §1 ⟨0.13⟩ model-SDK surface: ANY call into a curated model-provider client type is `Llm` (the
    // caller adds the companion `Net`). No method-name gating — the clients are single-purpose.
    if MODEL_SDK_TYPES.contains(root) { return "Llm" }
    // `privacy/1`: ANY call into a curated privacy-sensor type is that sensor effect (no method-name
    // gating — single-purpose types). A local same-named type shadows this via declaredTypes at the driver.
    // MEMBER-GATED FIRST. A member with its OWN key must beat its type's general one: CLLocationManager
    // is Location, but `requestTemporaryFullAccuracyAuthorization` additionally requires
    // NSLocationTemporaryUsageDescription — and with the type checked first, the type always won and the
    // temporary key could never be emitted. The general Location key is still charged by every other
    // call on the manager (its constructor included), so nothing is lost by the more specific match.
    if let priv = PRIVACY_MEMBER_TYPES[root]?[member] { return priv }
    if let priv = PRIVACY_SDK_TYPES[root] { return priv }
    // (member-gated map consulted above — the type is shared, only a specific member names the resource)
    // `HKObjectType.clinicalType(forIdentifier:)` needs its own key, but HKObjectType vends EVERY
    // HealthKit type — putting it in PRIVACY_SDK_TYPES would charge clinical-records access to every app
    // that touches a step count. Gate on the member, which is what actually names the resource.
    if let priv = PRIVACY_MEMBER_TYPES[root]?[member] { return priv }
    switch root {
    case "FileManager", "FileHandle": return FS_MEMBERS.contains(member) || member == "readToEnd"
        || member == "write" || member == "read" ? "Fs" : nil
    case "URLSession": return NET_MEMBERS.contains(member) ? "Net" : nil
    // JohnSundell's Files (third-party Fs wrapper). The pure builder/property surface (path/name/url/
    // subfolders/files/nameExcludingExtension) is not a verb → stays out. A LOCAL `File`/`Folder`/`Storage`
    // type shadows this in the driver (declaredTypes), so this only fires on the real package's types.
    case "File", "Folder", "Storage": return FILES_MEMBERS.contains(member) ? "Fs" : nil
    case "Process": return PROCESS_MEMBERS.contains(member) ? "Exec" : nil
    case "Logger", "OSLog": return LOG_MEMBERS.contains(member) ? "Log" : nil
    case "NSPasteboard", "UIPasteboard":
        // PURE capability/metadata queries read no clipboard data — exclude them (the whole-owner rule
        // fabricated Clipboard on these — the precision failure; sweep [33]). Unknown verbs stay Clipboard
        // (sound over-approx). `.types`/`.changeCount`/`.name` are PROPERTY reads handled elsewhere.
        return PASTEBOARD_PURE_QUERIES.contains(member) ? nil : "Clipboard"
    // UserDefaults: every listed verb reads/writes the plist-backed store → Fs (covered-module sweep,
    // 2026-07-09). `volatileDomain(forName:)`/`volatileDomainNames` are IN-MEMORY domains — not listed,
    // stay pure. `let d = UserDefaults.standard` carries the type (SINGLETON_ACCESSORS has "standard").
    case "UserDefaults": return USER_DEFAULTS_MEMBERS.contains(member) ? "Fs" : nil
    // Bundle resource lookups (`Bundle.main.url(forResource:withExtension:)`) stat/search the bundle on
    // disk → Fs. Metadata property reads (bundleIdentifier/infoDictionary) are in-memory — stay pure.
    case "Bundle": return BUNDLE_RESOURCE_MEMBERS.contains(member) ? "Fs" : nil
    case "Date": return member == "now" ? "Clock" : nil
    case "ContinuousClock", "SuspendingClock", "DispatchTime": return member == "now" ? "Clock" : nil
    case "NWBrowser", "NetService", "NetServiceBrowser":
        // BONJOUR / mDNS DISCOVERY, modelled nowhere until now: `NWBrowser(for: .bonjour(…))` produced no
        // effect whatever, so a service-discovery app read PURE. Found while adding the LocalNetwork
        // privacy key; the missing `Net` is the more serious half and is a soundness fix on its own.
        return NW_PURE_VERBS.contains(member) ? nil : "Net"
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
        || name == "File" || name == "Folder"                                        // Files: path arg
    case "Exec": return name == "posix_spawn" || name == "execv" || name == "execvp"  // path arg (Process() ctor
        // takes NO command — set via .executableURL/.arguments — so the ctor is not establishing)
        || name == "shellOut"   // ShellOut's `shellOut(to:)` takes the command as its arg → establishing;
        // a MASKED (runtime) command must mark Exec incomplete (fail-closed) like posix_spawn, else
        // `shellOut(to: runtimeVar)` evades an `allow Exec` allowlist (gate-masking sweep, 2026-06-18).
    case "Db":   return name.hasPrefix(DB_FREE_PREFIX)                                // sqlite3_exec/prepare take SQL
    default:     return false
    }
}

/// Classify a free-function or constructor call by name.
public func kappaFree(name: String, argCount: Int) -> String? {
    // §1 ⟨0.13⟩ model-SDK surface: constructing a curated model-provider client (`OpenAI(apiToken:)`,
    // `LanguageModelSession()`) is the model dispatch entry → `Llm` (caller adds `Net`). A local type of
    // the same name shadows this at the call site (localTypes/localFreeFns), like `Pipe`/`Process`.
    if MODEL_SDK_TYPES.contains(name) { return "Llm" }
    // `privacy/1`: constructing a curated privacy-sensor type (`CLLocationManager()`, `AVAudioRecorder(...)`,
    // `CNContactStore()`) is the sensor-access entry → that sensor effect. A local type of the same name
    // shadows this at the call site (localTypes/localFreeFns), like the model-SDK types (anti-fabrication).
    if let priv = PRIVACY_SDK_TYPES[name] { return priv }
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
    // JohnSundell's Files: `File(path:)` / `Folder(path:)` RESOLVE the path against the live filesystem
    // (the throwing init fails when it does not exist) — a real stat → Fs. The 0-arg form does not exist
    // (path is required), so any call is the resolving ctor. A LOCAL `struct File`/`Folder` shadows this
    // (localFreeFns / declaredTypes guard at the call site), so a project's own File() never fabricates.
    case "File", "Folder": return argCount > 0 ? "Fs" : nil
    // JohnSundell's ShellOut: `shellOut(to:)` runs a subprocess via /bin/bash → Exec. A distinctive,
    // collision-unlikely name; a local `func shellOut` (localFreeFns) still shadows it (never fabricate).
    case "shellOut": return "Exec"
    // Core Audio process taps — the C entry points for system-audio capture (NSAudioCaptureUsageDescription).
    case "AudioHardwareCreateProcessTap": return "AudioCapture"
    case "NWConnection", "NWListener": return "Net"
    case "NWBrowser", "NetService", "NetServiceBrowser": return "Net"   // bonjour/mDNS discovery
    case "SystemRandomNumberGenerator": return "Rand"
    case "arc4random", "arc4random_uniform", "getentropy": return "Rand"
    case "getenv", "setenv", "unsetenv": return "Env"
    // The Keychain C surface (`import Security` — a PLATFORM module, so unmodeled calls read silent-pure,
    // the covered-module cardinal-sin shape). The four CRUD entry points → Fs (system secure store; NOT
    // Db — the family reserves Db for query-capable datastores). Distinctive PascalCase C names; a local
    // `func SecItemAdd` still shadows via the call site's localFreeFns guard (never fabricate).
    case "SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete": return "Fs"
    // DNS resolution is Net (rust/java/ts all classify it; swift floored it silently — sweep [20]). These
    // are POSIX/Darwin/Glibc free calls; the call site already shadow-guards a local fn of the same name.
    case "getaddrinfo", "getnameinfo", "gethostbyname", "gethostbyname2", "gethostbyaddr",
         "gethostbyname_r", "gethostbyaddr_r", "getaddrinfo_a": return "Net"
    case "NSXPCConnection": return "Ipc"
    case "os_log": return "Log"
    case "posix_spawn", "execv", "execvp": return "Exec"
    case "fopen": return "Fs"
    // POSIX SOCKET WIRE verbs → Net, GATED ON THE EXACT ARITY of the C signature (and still shadow-guarded
    // by the call site's localFreeFns, so a project's own same-named fn never fabricates). This closes a
    // real under-report — a raw `import Glibc; connect(fd, &addr, len)` client did Net at runtime yet read
    // silent-pure — for the DISTINCTIVE, establishing verbs only. `connect` is THE network-establishing act
    // and a 3-arg free `connect` is unmistakably POSIX; sendto/recvfrom (6-arg) and sendmsg/recvmsg (3-arg)
    // are collision-unlikely as free calls at that arity. See the NOTE below for what stays absent and why.
    case "connect":  return argCount == 3 ? "Net" : nil   // connect(fd, sockaddr*, socklen_t)
    case "sendmsg", "recvmsg": return argCount == 3 ? "Net" : nil // (fd, msghdr*, flags)
    case "sendto", "recvfrom": return argCount == 6 ? "Net" : nil // (fd, buf, len, flags, sockaddr*, socklen)
    // NOTE deliberately ABSENT: the collision-prone bare POSIX names — SETUP verbs (bind/socket/listen: not
    // the wire act, and `bind` collides with SQL binding — the first real-repo sweep caught GRDB's local
    // `bind(...)` fabricating Net onto 214 fns), the ULTRA-common words (send/recv/read/write/open — free
    // functions of these arities exist all over), and process/fs names (fork/system/mkdir/rename/unlink).
    // For these, under-report the rare direct-syscall program beats a wrong label on a common one; idiomatic
    // Swift reaches the network via URLSession/Network.framework (both modelled → Net) anyway.
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
    // FileManager property-form FS reads (`currentDirectoryPath`, `temporaryDirectory`,
    // `homeDirectoryForCurrentUser`): these are PROPERTIES, not calls, so they never reach the
    // method-call FS classifier — they live in FS_MEMBERS but were dead in the property-read path
    // (a real-world dogfood vein: `FileManager.default.currentDirectoryPath` read silent-pure).
    if root == "FileManager", let m = path.last, FS_MEMBERS.contains(m) { return "Fs" }
    // `privacy/1` finding 4 — AVAudioEngine's mic-specific member. A bare AVAudioEngine is a general
    // audio-graph type (playback/synthesis/mixing); only its `.inputNode` (and taps installed on it —
    // `engine.inputNode.installTap(...)`, where `engine.inputNode` is the receiver chain here) touches the
    // microphone. Member-gate on `inputNode` so a playback-only engine is NOT fabricated as Mic; the bare
    // type is deliberately absent from PRIVACY_SDK_TYPES (under-disclose via the coverage ledger rather
    // than fabricate). `engine.inputNode.installTap(...)` reaches here as the `.inputNode` property read
    // (its parent is the `.installTap` member-access, not a call), so both forms classify Mic.
    if root == "AVAudioEngine" && path.contains("inputNode") { return "Mic" }
    return nil
}

/// `privacy/1` finding 5 — the effect(s) of an AVFoundation CAPTURE call, discriminated by the media-type
/// argument. `mediaType` is the statically-visible leading-dot member name of the `for:` argument on
/// `AVCaptureDevice.default(for:)` / `.devices(for:)` (`"audio"`/`"video"`), or nil when the argument is
/// NOT statically visible (a computed value, or a bare `AVCaptureSession` with no media-type arg at all).
///
/// - `.video` → `["Camera"]`; `.audio` → `["Mic"]` (the arg IS visible, so classify precisely).
/// - nil (ambiguous) → `["Camera", "Mic"]` — OVER-DISCLOSE both. This is the safe direction for a privacy
///   manifest: a capture that could be either must declare both, never silently miss a real microphone
///   capture (an under-declared sensor is the App-Store-rejection-shaped error). This is the OPPOSITE
///   trade-off from the Llm/Net host case (an unknown host stays bare Net, never fabricated to Llm),
///   because for privacy CAPTURE a missed sensor is the costly failure, not a spurious extra one.
///
/// Applied only when the receiver is a CONFIRMED capture type (AVCaptureDevice/AVCaptureSession), so the
/// no-fabrication-on-unknown-receiver rule still holds — the over-disclosure is bounded to a real capture.
/// AVAudioSession / AVAudioApplication → `Mic`, gated on the CATEGORY, on exactly the AVCaptureDevice
/// pattern above.
///
/// FOUND BY A RECALL BATTERY, not by review: `AVAudioSession.sharedInstance().setCategory(.record)` —
/// the canonical spelling in every voice-recording app — emitted NOTHING. Mic is a MODELLED sensor, so
/// this was not a vocabulary gap; it was a covered sensor with its most common entry point missing, and
/// a clean `privacy-manifest --verify` over an app that records audio is an App Store rejection.
///
/// The type cannot simply join `PRIVACY_SDK_TYPES`: configuring an audio session is what PLAYBACK apps
/// do too, and charging every one of them Mic is the fabrication mirror. So it is discriminated by the
/// category argument, and an argument this engine cannot read OVER-DISCLOSES — the same ruling, for the
/// same reason, as an ambiguous capture: on a privacy manifest a false prompt costs a confused user, a
/// false silence costs a rejection.
public func privacyAudioSessionEffects(category: String?) -> [String] {
    switch category {
    case "record", "playAndRecord": return ["Mic"]
    // Categories that CANNOT reach the microphone. A denylist would be wrong here and an allowlist is
    // right, unusually — because the safe default is to CHARGE, so what must be enumerated is the set
    // that is provably safe, and these are the whole of it in AVFoundation.
    // PROVABLY mic-free only. `.multiRoute` was here and does not belong: Apple documents it as usable
    // "for input, output, or both" — it is how an app records USB input while monitoring on headphones.
    // An allowlist is right here (the safe default is to CHARGE), which makes a wrong entry a MISS, and a
    // miss on this key is an App Store rejection.
    case "playback", "ambient", "soloAmbient": return []
    default: return ["Mic"]   // unreadable/absent category → over-disclose (never under-declare)
    }
}

/// The AVAudioSession/AVAudioApplication members that mean the microphone REGARDLESS of category.
public let PRIVACY_MIC_PERMISSION_MEMBERS: Set<String> = [
    "requestRecordPermission", "recordPermission", "requestRecordPermissionWithCompletionHandler",
]

public func privacyCaptureEffects(mediaType: String?) -> [String] {
    switch mediaType {
    case "video": return ["Camera"]
    case "audio": return ["Mic"]
    default:      return ["Camera", "Mic"]  // ambiguous capture → over-disclose both (privacy: never under-declare)
    }
}

/// The AVFoundation capture types whose Camera/Mic split is refined by the media-type argument (finding 5).
/// The types whose calls DECIDE a capture's medium. `AVCaptureSession` is NOT one of them.
///
/// A session is a COORDINATOR: it captures nothing until an `AVCaptureDeviceInput` built from an
/// `AVCaptureDevice` is added, and that device call carries the media type that says Camera or Mic. So
/// the session contributes no information the device call does not, and treating it as an ambiguous
/// capture over-disclosed BOTH on every function that merely touches one.
///
/// Measured on Bitwarden, a QR scanner with no microphone key: `stopCameraSession()` — whose body is
/// `outputs.forEach { removeOutput($0) }` and `stopRunning()` — reported Mic, and so did a SwiftUI
/// preview. A member denylist did not hold, because `.forEach` on `session.outputs` is a member call
/// like any other; the fragility was the signal that the type was the wrong place to ask.
///
/// The recall this gives up is a session fed by a device from a source the scan cannot resolve — which
/// is exactly what the Unknown machinery and the coverage ledger exist to disclose, rather than
/// something to guess a microphone from.
public let PRIVACY_CAPTURE_TYPES: Set<String> = ["AVCaptureDevice"]

/// Members of a capture type that TEAR DOWN or configure rather than capture.
///
/// A DENYLIST, not an allowlist, deliberately: an allowlist of "capturing" members would silently miss
/// the one I forgot, which is the cardinal sin, while a denylist that is too short only leaves an
/// over-disclosure standing. Every name here is carved out because it provably cannot capture.
///
/// Measured on Bitwarden: `stopCameraSession()` — whose whole body is `stopRunning()` and
/// `removeOutput()` on a stored property — was the evidence that a shipping QR scanner "reaches Mic".
/// Stopping a session is not using a microphone.
public let PRIVACY_CAPTURE_TEARDOWN_MEMBERS: Set<String> = [
    "stopRunning", "removeOutput", "removeInput", "removeConnection",
    "beginConfiguration", "commitConfiguration",
]
/// The audio-session types whose CATEGORY decides whether the microphone is reached — see
/// `privacyAudioSessionEffects`. Kept separate from PRIVACY_CAPTURE_TYPES because the discriminating
/// argument is different (a category, not a media type) and the safe default differs in shape.
public let PRIVACY_AUDIO_SESSION_TYPES: Set<String> = ["AVAudioSession", "AVAudioApplication"]

/// Fluent (Vapor's ORM) persistence verbs → Db. A project entity `final class X: Model` INHERITS these
/// from FluentKit's `Model` protocol extension; called on the project type (`x.save(on:)`,
/// `X.query(on:)`, `X.find(_:on:)`) the owner resolves to X with no body, so without modeling they read
/// silent (the inherited-into-project vein, conforms-to-external-protocol shape — found corpus-testing
/// the Vapor template). Modeled like CoreData's NSManagedObjectContext. The query-builder chain
/// (`X.query(on:).filter(..).all()`) hits the DB at the terminal, but the chain ROOT `X.query` is the
/// modeled entry on the project type, so classifying it catches the operation; the lazy builder verbs
/// (filter/sort/with/limit) are on the external QueryBuilder, not the Model type, so they're not here.
public let FLUENT_MODEL_PROTOCOLS: Set<String> = ["Model"]
public func fluentModelEffect(_ member: String) -> String? {
    ["save", "create", "update", "delete", "restore", "query", "find",
     "all", "first", "count", "exists", "paginate", "aggregate"].contains(member) ? "Db" : nil
}

/// Std protocols whose synthesized/value requirements are PURE. When a project type conforms to an
/// EXTERNAL supertype and an inherited method doesn't resolve to a project body, the engine discloses
/// Unknown (the inherited-into-project vein) — but a SYNTHESIZED requirement of these protocols
/// (`x.encode(to:)`, `x.hash(into:)`) is pure, so disclosing Unknown there would be false over-disclosure
/// across the many types conforming to them. A HAND-WRITTEN requirement has a project body → resolves
/// normally; only the synthesized (bodyless) case reaches the fallback, and for these it stays pure.
public let STD_PURE_PROTOCOLS: Set<String> = [
    "Codable", "Encodable", "Decodable", "Equatable", "Hashable", "Sendable", "Comparable",
    "Identifiable", "CaseIterable", "RawRepresentable", "CustomStringConvertible",
    "CustomDebugStringConvertible", "Error", "Strideable", "OptionSet", "AdditiveArithmetic",
    // Iteration protocols: their default requirement (`makeIterator`) is pure; an EFFECTFUL `next()` is a
    // project body captured by the dedicated iterator-forcing path, so the external-super fallback must
    // not disclose Unknown for them (it false-flagged a pure custom Sequence — the S1 smoke case).
    "Sequence", "IteratorProtocol", "Collection", "BidirectionalCollection", "RandomAccessCollection",
    "MutableCollection", "RangeReplaceableCollection", "AsyncSequence", "AsyncIteratorProtocol",
]

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
public let PLATFORM_MODULES: Set<String> = ["Swift", "Foundation", "FoundationEssentials", "FoundationNetworking", "FoundationXML",
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
    // A QUALIFIED/NESTED type path `Outer.Inner` (MemberTypeSyntax): produce the dotted spelling so a
    // receiver typed `Outer.Inner` matches the nested type's unit key `Outer.Inner.method` (DeclCollector
    // keys an `extension Outer.Inner` under that same trimmed dotted name). A module-qualified stdlib type
    // (`Foundation.Date`) also yields a dotted name the κ table doesn't know → under-report, never a guess.
    if let mem = t.as(MemberTypeSyntax.self) {
        let head = typeName(mem.baseType).name
        return (head.map { "\($0).\(mem.name.text)" } ?? mem.name.text, false)
    }
    if let tup = t.as(TupleTypeSyntax.self), tup.elements.count == 1, let only = tup.elements.first {
        return typeName(only.type)
    }
    if let some = t.as(SomeOrAnyTypeSyntax.self) { return typeName(some.constraint) } // `some P` / `any P`
    return (nil, false)
}

/// The PLAIN NOMINAL spelling of a return type, or nil — the ⟨0.23⟩ `typeSurface.returns` producer
/// predicate (SPEC §2, `DEP-RECEIVER-TYPING-DESIGN.md`).
///
/// DELIBERATELY STRICTER THAN `typeName`, and the difference is the whole rule. `typeName` peels
/// `Optional`/`some`/`any`/attributes and DROPS a generic argument clause, because for naming the type a
/// receiver was declared with, `Conn?` and `Conn` are the same thing. For publishing what a BINDING
/// HOLDS they are not: `let c = connect()` where `connect() -> Conn?` holds an Optional, and keying
/// `c.map { … }` against `Conn` charges effects nobody runs. candor-rust shipped exactly that and
/// reverted it. So: an identifier with NO generic argument clause, or a dotted `Outer.Inner` of those,
/// and nothing else — no optional, array, dictionary, tuple, function type, `some`/`any`, `Result<_,_>`
/// or `Array<_>`. Refusing is the safe direction: what it refuses costs precision only, because a miss
/// falls back to half 1's disclosure rather than to silence.
public func plainNominalTypeName(_ t: TypeSyntax) -> String? {
    if let id = t.as(IdentifierTypeSyntax.self) {
        return id.genericArgumentClause == nil ? id.name.text : nil
    }
    if let mem = t.as(MemberTypeSyntax.self) {
        guard mem.genericArgumentClause == nil, let head = plainNominalTypeName(mem.baseType) else { return nil }
        return "\(head).\(mem.name.text)"
    }
    return nil
}

/// Is this parameter type spelled `some P` (an OPAQUE type) rather than `any P` (an existential)?
///
/// `typeName` deliberately collapses the two — for naming a type they are the same. For class-hierarchy
/// analysis they are opposites. `any P` is erased: the value could be any conformer, so the conformers
/// visible here really are its candidate witnesses. `some P` is monomorphized BY THE CALLER: exactly one
/// concrete type is chosen at each call site, so unioning every conformer's effects onto the callee
/// charges it with effects it cannot perform. (`<T: P>` is the same thing under another spelling. In
/// PARAMETER position it is inert here because the param's type name is `T`, which resolves to nothing —
/// but `[T]`, a `T`-typed FIELD and `where Element: P` all DO resolve to the bound, so those forms carry
/// their opacity through `opaqueArrayParams`/`opaqueFields`/`selfElementType` instead of through this
/// predicate. The gate is the same one; only the spelling that reaches it differs.)
///
/// Found via candor-rust, which hit the identical trap from the other side: gating its imported-trait CHA
/// on PROVENANCE alone put 32 spurious Unknowns on serde_json, and erasure was the discriminator that
/// fixed it. Peels the wrappers `typeName` peels, so `some P?` and `@escaping some P` are caught too.
public func isOpaqueParam(_ t: TypeSyntax) -> Bool {
    if let opt = t.as(OptionalTypeSyntax.self) { return isOpaqueParam(opt.wrappedType) }
    if let att = t.as(AttributedTypeSyntax.self) { return isOpaqueParam(att.baseType) }
    if let tup = t.as(TupleTypeSyntax.self), tup.elements.count == 1, let only = tup.elements.first {
        return isOpaqueParam(only.type)
    }
    if let some = t.as(SomeOrAnyTypeSyntax.self) { return some.someOrAnySpecifier.text == "some" }
    return false
}

/// The ELEMENT type name of a collection type: `[T]`/`Set<T>`/`Array<T>`/`ContiguousArray<T>` → `T`
/// (peeling Optional/`some`/`any` wrappers). Used to type a `for x in coll`/`coll.forEach { x in … }`
/// iteration variable so its member calls classify — without it, a loop/closure over a typed
/// collection dropped its receiver to pure (a §4 under-report on a very common Swift shape).
public func arrayElementName(_ t: TypeSyntax) -> String? {
    arrayElementType(t).flatMap { typeName($0).name }
}

/// The ELEMENT type SYNTAX of a collection type — `arrayElementName` without the name projection, so a
/// caller that needs to inspect the element's SPELLING (is it `some P`? — `isOpaqueParam`) can, rather
/// than re-deriving the same peeling and drifting from it.
public func arrayElementType(_ t: TypeSyntax) -> TypeSyntax? {
    if let arr = t.as(ArrayTypeSyntax.self) { return arr.element }
    if let opt = t.as(OptionalTypeSyntax.self) { return arrayElementType(opt.wrappedType) }
    if let att = t.as(AttributedTypeSyntax.self) { return arrayElementType(att.baseType) }
    if let some = t.as(SomeOrAnyTypeSyntax.self) { return arrayElementType(some.constraint) }
    if let gen = t.as(IdentifierTypeSyntax.self), let args = gen.genericArgumentClause,
       // The async-sequence/task-group element is also the FIRST generic argument: `for await x in s`
       // over an `AsyncStream<E>`/`AsyncThrowingStream<E, _>`/`TaskGroup<E>`/`ThrowingTaskGroup<E, _>`
       // yields an `E` — without these the loop var was untyped and `x.member()` read silent-pure (a
       // structured-concurrency consumer hole found by a Swift-concurrency sweep).
       ["Array", "Set", "ContiguousArray", "ArraySlice",
        "AsyncStream", "AsyncThrowingStream", "TaskGroup", "ThrowingTaskGroup"].contains(gen.name.text),
       let first = args.arguments.first, let at = first.argument.as(TypeSyntax.self) {
        return at
    }
    return nil
}

/// Protocol/erased-type spellings whose VALUES are iterable but whose CONCRETE iterator type is hidden:
/// `some Sequence` / `any IteratorProtocol` (the constraint, peeled by typeName to the bare protocol name)
/// and the type-erasing wrappers `AnySequence` / `AnyIterator` / `AnyCollection` / `AnyAsyncSequence`. A
/// `for x in <value of this type>` runs a `next()` that candor cannot pin to a concrete local unit — so
/// forcing it must read Unknown, never silent-pure (Finding 1: opaque/erased effectful Sequence builders).
public let ITERABLE_PROTOCOLS: Set<String> =
    ["Sequence", "IteratorProtocol", "Collection", "BidirectionalCollection", "RandomAccessCollection",
     "MutableCollection", "RangeReplaceableCollection", "AsyncSequence", "AsyncIteratorProtocol",
     "LazySequenceProtocol", "LazyCollectionProtocol"]
public let ERASED_ITERABLES: Set<String> =
    ["AnySequence", "AnyIterator", "AnyCollection", "AnyBidirectionalCollection", "AnyAsyncSequence"]

/// Is `t` an OPAQUE (`some Sequence`) or ERASED (`AnySequence`) iterable whose concrete element-iterator
/// type is hidden? Returns the constraint/wrapper name when so, else nil. Used to decide whether iterating
/// a value of this type can be pinned to a concrete local `next`/`makeIterator` unit (precise) or must be
/// honest Unknown. Peels Optional/Attributed wrappers so `(some Sequence)?` still classifies.
public func opaqueIterableName(_ t: TypeSyntax) -> String? {
    if let opt = t.as(OptionalTypeSyntax.self) { return opaqueIterableName(opt.wrappedType) }
    if let att = t.as(AttributedTypeSyntax.self) { return opaqueIterableName(att.baseType) }
    if let some = t.as(SomeOrAnyTypeSyntax.self) {
        // `some P` / `any P` — opaque/existential. The hidden iterator is unknowable from the signature.
        if let n = typeName(some.constraint).name, ITERABLE_PROTOCOLS.contains(n) { return n }
        return nil
    }
    // a bare `AnySequence<E>` / `AnyIterator<E>` identifier (the erasing wrapper, generic args ignored)
    if let id = t.as(IdentifierTypeSyntax.self), ERASED_ITERABLES.contains(id.name.text) { return id.name.text }
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
