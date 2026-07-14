import XCTest
import SwiftParser
import SwiftSyntax
@testable import CandorCore

/// Native unit tests (XCTest) for CandorCore — the κ classifier, the §6.2 Exec-head refinement, the
/// SPEC §2 SQL-table extraction, and the SwiftSyntax type helpers. The smoke + fuzzer exercise these
/// only through a full scan; this pins their edge cases at the function boundary. Constructing a
/// `TypeSyntax` from a string needs SwiftParser, hence the dependency.
final class ClassifierTests: XCTestCase {

    func parseType(_ s: String) -> TypeSyntax {
        var parser = Parser(s)
        return TypeSyntax.parse(from: &parser)
    }

    // ── isHarnessPath ─────────────────────────────────────────────────────────────────────────────
    func testIsHarnessPath() {
        XCTAssertTrue(isHarnessPath("Package.swift"))
        XCTAssertTrue(isHarnessPath(".build/x/y.swift"))
        XCTAssertTrue(isHarnessPath("Tests/AppTests/FooTests.swift"))
        // a marker NESTED under Sources/ is production code, not harness (the under-report guard)
        XCTAssertFalse(isHarnessPath("Sources/App/Plugins/Render.swift"))
        XCTAssertFalse(isHarnessPath("Sources/App/Service.swift"))
    }

    // ── κ member / free / property classifiers (the cardinal-sin surface) ─────────────────────────
    func testKappaMember() {
        XCTAssertEqual(kappaMember(root: "FileManager", member: "removeItem"), "Fs")
        XCTAssertEqual(kappaMember(root: "URLSession", member: "dataTask"), "Net")
        XCTAssertEqual(kappaMember(root: "Process", member: "run"), "Exec")
        // covered-module precision: contentsEqual reads both files, attributesOfFileSystem statfs's the
        // volume — both real Fs I/O that read silent-pure before being modeled.
        XCTAssertEqual(kappaMember(root: "FileManager", member: "contentsEqual"), "Fs")
        XCTAssertEqual(kappaMember(root: "FileManager", member: "attributesOfFileSystem"), "Fs")
        XCTAssertEqual(kappaMember(root: "Logger", member: "info"), "Log")
        XCTAssertEqual(kappaMember(root: "Int", member: "random"), "Rand")
        XCTAssertNil(kappaMember(root: "FileManager", member: "path"))     // pure accessor, not in FS_MEMBERS
        XCTAssertNil(kappaMember(root: "SomeLocalType", member: "save"))   // unknown root → no guess
        // sweep [33]: pasteboard capability/metadata QUERIES are pure (no clipboard data touched) — the
        // whole-owner rule fabricated Clipboard on them; real verbs still classify.
        XCTAssertEqual(kappaMember(root: "NSPasteboard", member: "setString"), "Clipboard")
        XCTAssertEqual(kappaMember(root: "NSPasteboard", member: "clearContents"), "Clipboard")
        XCTAssertNil(kappaMember(root: "NSPasteboard", member: "canReadObject"))
        XCTAssertNil(kappaMember(root: "UIPasteboard", member: "availableType"))
        // sweep [34]: NWConnection cancel/batch perform no I/O; send/start still Net.
        XCTAssertEqual(kappaMember(root: "NWConnection", member: "send"), "Net")
        XCTAssertEqual(kappaMember(root: "NWConnection", member: "start"), "Net")
        XCTAssertNil(kappaMember(root: "NWConnection", member: "cancel"))
        XCTAssertNil(kappaMember(root: "NWConnection", member: "batch"))
        // §1 ⟨0.13⟩ `Llm` model-SDK surface: ANY call/ctor into a curated model client is Llm (the caller
        // adds the companion Net) — no method-name gating (single-purpose clients).
        XCTAssertEqual(kappaMember(root: "OpenAI", member: "chats"), "Llm")
        XCTAssertEqual(kappaMember(root: "AnthropicClient", member: "messages"), "Llm")
        XCTAssertEqual(kappaMember(root: "BedrockRuntimeClient", member: "converse"), "Llm")
        XCTAssertEqual(kappaMember(root: "LanguageModelSession", member: "respond"), "Llm")  // Apple FoundationModels
        XCTAssertEqual(kappaFree(name: "OpenAI", argCount: 1), "Llm")                        // OpenAI(apiToken:)
        XCTAssertEqual(kappaFree(name: "LanguageModelSession", argCount: 0), "Llm")
        XCTAssertNil(kappaMember(root: "URLSession", member: "chats"))                       // not a model client
    }

    // ── isModelHost — the §1 ⟨0.13⟩ host-literal refinement (mirrors candor-java's Literals.isModelHost) ──
    func testIsModelHost() {
        // the verbatim MODEL_HOSTS table (both cohere spellings)
        for h in ["api.openai.com", "api.anthropic.com", "generativelanguage.googleapis.com",
                  "api.mistral.ai", "api.cohere.ai", "api.cohere.com", "api.groq.com",
                  "api.together.xyz", "api.perplexity.ai", "openrouter.ai"] {
            XCTAssertTrue(isModelHost(h), "\(h) is a known model host")
            XCTAssertTrue(isModelHost(h + ":443"), "port is stripped before the host match")
            XCTAssertTrue(isModelHost(h.uppercased()), "the match is case-insensitive")
        }
        // a SUBDOMAIN of a listed host counts
        XCTAssertTrue(isModelHost("eu.api.openai.com"))
        XCTAssertFalse(isModelHost("openai.com.evil.example"), "a suffix that is not `.`-anchored must NOT match")
        // Ollama: any host on port 11434 is the local model endpoint (host is irrelevant)
        XCTAssertTrue(isModelHost("localhost:11434"))
        XCTAssertTrue(isModelHost("127.0.0.1:11434"))
        XCTAssertFalse(isModelHost("localhost:8080"), "a non-11434 local port is not Ollama")
        // Bedrock: host CONTAINS "bedrock" AND ends .amazonaws.com
        XCTAssertTrue(isModelHost("bedrock-runtime.us-east-1.amazonaws.com"))
        XCTAssertFalse(isModelHost("s3.us-east-1.amazonaws.com"), "amazonaws without bedrock is not a model host")
        XCTAssertFalse(isModelHost("bedrock.example.com"), "bedrock without amazonaws is not a model host")
        // an unknown host stays bare Net
        XCTAssertFalse(isModelHost("api.stripe.com"))
        // covered-module sweep (2026-07-09): UserDefaults is the plist-backed store — every access verb
        // is Fs; the in-memory volatile-domain surface stays pure (verb-precision, never whole-owner).
        XCTAssertEqual(kappaMember(root: "UserDefaults", member: "set"), "Fs")
        XCTAssertEqual(kappaMember(root: "UserDefaults", member: "string"), "Fs")
        XCTAssertEqual(kappaMember(root: "UserDefaults", member: "object"), "Fs")
        XCTAssertEqual(kappaMember(root: "UserDefaults", member: "removeObject"), "Fs")
        XCTAssertEqual(kappaMember(root: "UserDefaults", member: "synchronize"), "Fs")
        XCTAssertEqual(kappaMember(root: "UserDefaults", member: "register"), "Fs")
        XCTAssertNil(kappaMember(root: "UserDefaults", member: "volatileDomain"))       // in-memory
        XCTAssertNil(kappaMember(root: "UserDefaults", member: "volatileDomainNames"))  // in-memory
        // Bundle resource lookups stat the bundle on disk → Fs; metadata reads are in-memory (pure).
        XCTAssertEqual(kappaMember(root: "Bundle", member: "url"), "Fs")
        XCTAssertEqual(kappaMember(root: "Bundle", member: "path"), "Fs")
        XCTAssertEqual(kappaMember(root: "Bundle", member: "urls"), "Fs")
        XCTAssertEqual(kappaMember(root: "Bundle", member: "paths"), "Fs")
        XCTAssertNil(kappaMember(root: "Bundle", member: "bundleIdentifier"))
        XCTAssertNil(kappaMember(root: "Bundle", member: "object"))  // object(forInfoDictionaryKey:) — in-memory
    }

    func testKappaFree() {
        XCTAssertEqual(kappaFree(name: "Date", argCount: 0), "Clock")      // Date() reads the clock
        XCTAssertNil(kappaFree(name: "Date", argCount: 1))                 // Date(timeInterval:) is arithmetic
        XCTAssertEqual(kappaFree(name: "Process", argCount: 0), "Exec")
        XCTAssertEqual(kappaFree(name: "getenv", argCount: 1), "Env")
        XCTAssertEqual(kappaFree(name: "sqlite3_exec", argCount: 3), "Db") // sqlite3_ prefix → Db
        XCTAssertNil(kappaFree(name: "sqlite3_changes", argCount: 1))      // resident-state read → never Db
        XCTAssertEqual(kappaFree(name: "NSDate", argCount: 0), "Clock")    // legacy Date() twin
        XCTAssertEqual(kappaFree(name: "CACurrentMediaTime", argCount: 0), "Clock")
        XCTAssertEqual(kappaFree(name: "NSLog", argCount: 1), "Log")
        XCTAssertEqual(kappaFree(name: "Pipe", argCount: 0), "Ipc")
        XCTAssertNil(kappaFree(name: "myLocalHelper", argCount: 0))
        // sweep [20]: DNS resolution is Net (rust/java/ts classify it; swift floored it silently)
        XCTAssertEqual(kappaFree(name: "getaddrinfo", argCount: 4), "Net")
        XCTAssertEqual(kappaFree(name: "getnameinfo", argCount: 7), "Net")
        XCTAssertEqual(kappaFree(name: "gethostbyname", argCount: 1), "Net")
        // property-read clock surface: ContinuousClock/SuspendingClock `.now`
        XCTAssertEqual(kappaPropertyRead(root: "ContinuousClock", path: ["now"]), "Clock")
        XCTAssertEqual(kappaPropertyRead(root: "SuspendingClock", path: ["now"]), "Clock")
        // covered-module sweep (2026-07-09): the Keychain CRUD free fns (import Security — a PLATFORM
        // module, so unmodeled they read silent-pure) → Fs (system secure store; NOT Db by family decision).
        XCTAssertEqual(kappaFree(name: "SecItemAdd", argCount: 2), "Fs")
        XCTAssertEqual(kappaFree(name: "SecItemCopyMatching", argCount: 2), "Fs")
        XCTAssertEqual(kappaFree(name: "SecItemUpdate", argCount: 2), "Fs")
        XCTAssertEqual(kappaFree(name: "SecItemDelete", argCount: 1), "Fs")
        // adjacent Security surface deliberately unmodeled: key algebra is in-memory (no store access).
        XCTAssertNil(kappaFree(name: "SecKeyCreateRandomKey", argCount: 2))
    }

    // ── κ member VERB TABLES, table-driven (TESTING.md §2.3: where the rule is a member/verb table,
    // walk the WHOLE list so a typo un-classifies loudly — the CoreData/NIO rows were validated once
    // by a corpus sweep and then pinned by nothing). Each family: every modeled verb on every owner
    // root → the effect, plus a builder/algebra member that must stay out (the builder discipline).
    func testKappaMemberTableCoreData() {
        // NSManagedObjectContext: the store-touching verbs → Db.
        for verb in ["save", "fetch", "execute", "count", "performFetch", "executeFetchRequest"] {
            XCTAssertEqual(kappaMember(root: "NSManagedObjectContext", member: verb), "Db",
                           "NSManagedObjectContext.\(verb) must classify Db")
        }
        // builder/algebra surface stays pure (NSFetchRequest construction, object reads).
        XCTAssertNil(kappaMember(root: "NSManagedObjectContext", member: "object"))
        XCTAssertNil(kappaMember(root: "NSManagedObjectContext", member: "registeredObjects"))
        // container/coordinator store verbs → Db; the pure viewContext accessor stays out.
        for root in ["NSPersistentContainer", "NSPersistentStoreCoordinator"] {
            for verb in ["loadPersistentStores", "execute", "addPersistentStore", "performBackgroundTask"] {
                XCTAssertEqual(kappaMember(root: root, member: verb), "Db", "\(root).\(verb) must classify Db")
            }
            XCTAssertNil(kappaMember(root: root, member: "viewContext"), "\(root).viewContext is a pure accessor")
        }
    }

    func testKappaMemberTableNIO() {
        // bootstrap wiring verbs → Net across all four bootstrap owners.
        for root in ["ClientBootstrap", "ServerBootstrap", "DatagramBootstrap", "NIOTSConnectionBootstrap"] {
            for verb in ["connect", "bind", "withConnectedSocket"] {
                XCTAssertEqual(kappaMember(root: root, member: verb), "Net", "\(root).\(verb) must classify Net")
            }
            XCTAssertNil(kappaMember(root: root, member: "channelOption"), "\(root) option-builder stays pure")
        }
        // channel socket verbs → Net; the pure EventLoop/future algebra stays out.
        for root in ["Channel", "ChannelHandlerContext"] {
            for verb in ["write", "writeAndFlush", "read", "connect", "bind", "close", "flush"] {
                XCTAssertEqual(kappaMember(root: root, member: verb), "Net", "\(root).\(verb) must classify Net")
            }
            XCTAssertNil(kappaMember(root: root, member: "eventLoop"), "\(root).eventLoop is pure algebra")
        }
    }

    func testKappaMemberTableAsyncHTTPClient() {
        for root in ["HTTPClient", "AsyncHTTPClient"] {
            for verb in ["execute", "get", "post", "put", "patch", "delete", "shutdown"] {
                XCTAssertEqual(kappaMember(root: root, member: verb), "Net", "\(root).\(verb) must classify Net")
            }
            XCTAssertNil(kappaMember(root: root, member: "eventLoopGroup"), "\(root).eventLoopGroup stays pure")
        }
    }

    // ── isNetEstablishingFree / the establishing rows the masking guard keys on (never executed
    // in-repo before: the NWConnection/NWListener ctor is the free form whose host is a ctor arg) ──
    func testNetEstablishingFreeAndMemberRows() {
        XCTAssertTrue(isNetEstablishingFree(name: "NWConnection"))
        XCTAssertTrue(isNetEstablishingFree(name: "NWListener"))
        XCTAssertFalse(isNetEstablishingFree(name: "URLSession"), "not a ctor-carries-host form")
        XCTAssertFalse(isNetEstablishingFree(name: "MyLocalType"))
        // member rows: bootstrap connect/bind + HTTPClient verbs ESTABLISH; Channel use-verbs and
        // HTTPClient.shutdown (teardown) do not — a missing literal there is the legitimate
        // split-construct/use shape, never the masking signal.
        for root in ["ClientBootstrap", "ServerBootstrap", "DatagramBootstrap", "NIOTSConnectionBootstrap"] {
            XCTAssertTrue(isNetEstablishingMember(root: root, member: "connect"), "\(root).connect establishes")
            XCTAssertTrue(isNetEstablishingMember(root: root, member: "bind"), "\(root).bind establishes")
        }
        for verb in ["execute", "get", "post", "put", "patch", "delete"] {
            XCTAssertTrue(isNetEstablishingMember(root: "HTTPClient", member: verb), "HTTPClient.\(verb) establishes")
        }
        XCTAssertFalse(isNetEstablishingMember(root: "HTTPClient", member: "shutdown"), "teardown never establishes")
        XCTAssertFalse(isNetEstablishingMember(root: "Channel", member: "writeAndFlush"), "USE-verb, not establishing")
    }

    // ── establishing-call predicates (the AS-EFF-008 masking guard, generalized to all 4 effects) ──
    func testEstablishingPredicates() {
        // Net (member): URLSession verbs + bootstrap connect/bind establish; Channel use-verbs do not.
        XCTAssertTrue(isEstablishingMember(effect: "Net", root: "URLSession", member: "data"))
        XCTAssertFalse(isEstablishingMember(effect: "Net", root: "Channel", member: "write"))
        // Fs (member): FileManager path ops establish; FileHandle read/write are USE (path at ctor).
        XCTAssertTrue(isEstablishingMember(effect: "Fs", root: "FileManager", member: "removeItem"))
        XCTAssertFalse(isEstablishingMember(effect: "Fs", root: "FileHandle", member: "write"))
        // Free: Fs FileHandle/fopen, Exec posix_spawn/execv*, Db sqlite3_* establish; Process() ctor does not.
        XCTAssertTrue(isEstablishingFree(effect: "Fs", name: "fopen"))
        XCTAssertTrue(isEstablishingFree(effect: "Exec", name: "execvp"))
        XCTAssertTrue(isEstablishingFree(effect: "Db", name: "sqlite3_prepare_v2"))
        XCTAssertFalse(isEstablishingFree(effect: "Exec", name: "Process"))
    }

    func testKappaPropertyRead() {
        XCTAssertEqual(kappaPropertyRead(root: "ProcessInfo", path: ["processInfo", "environment"]), "Env")
        XCTAssertEqual(kappaPropertyRead(root: "Date", path: ["now"]), "Clock")
        XCTAssertNil(kappaPropertyRead(root: "Foo", path: ["bar"]))
        // FileManager PROPERTY-form FS reads were dead in the property path (real-world dogfood vein:
        // `FileManager.default.currentDirectoryPath` read silent-pure). They're in FS_MEMBERS but were
        // only reachable via the method-call classifier — the property path had no FileManager case.
        XCTAssertEqual(kappaPropertyRead(root: "FileManager", path: ["default", "currentDirectoryPath"]), "Fs")
        XCTAssertEqual(kappaPropertyRead(root: "FileManager", path: ["default", "temporaryDirectory"]), "Fs")
        XCTAssertEqual(kappaPropertyRead(root: "FileManager", path: ["default", "homeDirectoryForCurrentUser"]), "Fs")
        XCTAssertNil(kappaPropertyRead(root: "FileManager", path: ["default", "delegate"]))  // not an FS member → pure
    }

    // ── classifyCommandHead (§4 Exec refinement — UNAMBIGUOUS tools only) ─────────────────────────
    func testClassifyCommandHead() {
        XCTAssertEqual(classifyCommandHead("curl"), ["Net"])
        XCTAssertEqual(classifyCommandHead("/usr/bin/psql"), ["Db"])   // matched by basename
        XCTAssertEqual(classifyCommandHead("candor-scan"), ["Env", "Fs"])
        XCTAssertEqual(classifyCommandHead("git"), [])                 // multi-modal → no fabrication
    }

    // ── tablesInSql (SPEC §2, token-for-token across engines) ─────────────────────────────────────
    func testTablesInSql() {
        XCTAssertEqual(tablesInSql("SELECT id FROM users WHERE x = 1"), ["users"])
        XCTAssertEqual(tablesInSql("INSERT INTO audit_log (a) VALUES (1)"), ["audit_log"])
        XCTAssertEqual(tablesInSql("SELECT a FROM t1, t2 WHERE x = 1"), ["t1", "t2"]) // comma chain
        XCTAssertEqual(tablesInSql("SELECT a FROM t1 a1, t2"), ["t1"])               // an alias breaks the chain
        XCTAssertEqual(tablesInSql("hello world from nowhere"), [])                  // not SQL → nothing
    }

    // ── SwiftSyntax type helpers ──────────────────────────────────────────────────────────────────
    func testTypeName() {
        XCTAssertEqual(typeName(parseType("Foo")).name, "Foo")
        XCTAssertEqual(typeName(parseType("Foo?")).name, "Foo")        // Optional peeled
        XCTAssertEqual(typeName(parseType("any P")).name, "P")         // existential peeled
        XCTAssertTrue(typeName(parseType("(Int) -> Void")).isFunction) // function-typed
    }

    func testArrayElementName() {
        XCTAssertEqual(arrayElementName(parseType("[Client]")), "Client")
        XCTAssertEqual(arrayElementName(parseType("Set<Worker>")), "Worker")
        XCTAssertEqual(arrayElementName(parseType("Array<Foo>?")), "Foo")
        XCTAssertNil(arrayElementName(parseType("Int")))              // not a collection
    }

    func testTupleElements() {
        let t = tupleElements(parseType("(c: Client, n: Int)"))
        XCTAssertEqual(t["0"], "Client")
        XCTAssertEqual(t["c"], "Client")   // keyed by both position and label
        XCTAssertEqual(t["1"], "Int")
        XCTAssertEqual(t["n"], "Int")
        XCTAssertTrue(tupleElements(parseType("Int")).isEmpty)
    }

    func testDictValueName() {
        XCTAssertEqual(dictValueName(parseType("[String: Client]")), "Client")
        XCTAssertEqual(dictValueName(parseType("Dictionary<String, Worker>")), "Worker")
        XCTAssertNil(dictValueName(parseType("[Client]")))           // an array, not a dict
    }

    // ── propagate (the effect/surface least-fixpoint) ─────────────────────────────────────────────
    func testPropagateTransitive() {
        let r = propagate(["c": ["Fs"]], over: ["a": ["b"], "b": ["c"]])
        XCTAssertEqual(r["a"], ["Fs"])  // a -> b -> c
        XCTAssertEqual(r["b"], ["Fs"])
        XCTAssertEqual(r["c"], ["Fs"])
    }

    func testPropagateUnionsMultipleCallees() {
        let r = propagate(["x": ["Net"], "y": ["Db"]], over: ["caller": ["x", "y"]])
        XCTAssertEqual(r["caller"], ["Db", "Net"])
    }

    func testPropagateTerminatesOnCycle() {
        let r = propagate(["a": ["Fs"]], over: ["a": ["b"], "b": ["a"]]) // a <-> b
        XCTAssertEqual(r["a"], ["Fs"])
        XCTAssertEqual(r["b"], ["Fs"])  // the cycle does not loop forever
    }

    func testPropagateWorksForLiteralSurfaces() {
        // the same fixpoint carries literal surfaces (hosts/paths/…), not just effects
        let r = propagate(["leaf": ["api.example.com"]], over: ["root": ["leaf"]])
        XCTAssertEqual(r["root"], ["api.example.com"])
    }

    func testPropagatePureLeafStaysEmpty() {
        let r = propagate([:], over: ["a": ["b"]])
        XCTAssertNil(r["a"])  // nothing reachable carries a value
    }
}
