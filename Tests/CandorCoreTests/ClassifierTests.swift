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
        // Ollama: port 11434 on a LOOPBACK host. The comment here used to read "any host on port 11434 …
        // (host is irrelevant)", which is what the code did before the max-review r3 parity fix and has
        // not been true since — a stale comment sitting directly above the assertions that would have
        // caught it, describing the defect as if it were the contract. See the negative arm below.
        XCTAssertTrue(isModelHost("localhost:11434"))
        XCTAssertTrue(isModelHost("127.0.0.1:11434"))
        XCTAssertFalse(isModelHost("localhost:8080"), "a non-11434 local port is not Ollama")
        // Bedrock: the FIRST LABEL is the model-inference service. Not "contains bedrock" (which the
        // comment here used to claim, and which caught the S3 bucket below), and not the control plane.
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

    /// THE TWO OVER-CHARGE CONTROLS `isModelHost` CARRIES, neither of which had a test.
    ///
    /// Both branches below are NARROWINGS that a review round added after measuring a fabrication, and
    /// both are documented in `Classifier.swift` by naming the exact host that broke them. Neither could
    /// be told from its absence: GUARD-DELETION MEASURED 2026-08-30 — making the `:11434` arm
    /// `return true` (any host on that port) left all 958 tests GREEN, and so did widening the Bedrock
    /// first-label test to `first.contains("bedrock")`. A fabricated `Llm` is the direction that puts a
    /// model-provider claim on code that makes none, and `Llm` rides §6.1's boundary-effect footing, so
    /// `deny Llm` turns it into a red gate on an ordinary internal service.
    func testIsModelHostDoesNotFabricateOnLookalikes() {
        // ── the Ollama port. The signal is a LOCAL inference endpoint, not the number 11434.
        XCTAssertFalse(isModelHost("internal-svc.corp:11434"),
                       "a corporate service that happens to listen on 11434 is not Ollama — this is the "
                       + "max-review r3 fabrication, and the ONLY thing standing against it is the "
                       + "loopback test")
        XCTAssertFalse(isModelHost("10.0.0.7:11434"), "a LAN address is not loopback")
        XCTAssertTrue(isModelHost("[::1]:11434"),
                      "the IPv6 loopback counts — and it must be written bracketed, because `hostPart` "
                      + "returns a BARE multi-colon literal whole (there is no port to strip), so a bare "
                      + "`::1:11434` is a different host string entirely")
        // ── Bedrock. `bedrock-runtime` / `bedrock-agent-runtime` are the inference services; the
        // control plane and anything merely NAMED after bedrock are not.
        XCTAssertTrue(isModelHost("bedrock-agent-runtime.eu-west-1.amazonaws.com"))
        XCTAssertFalse(isModelHost("bedrock-backups.s3.us-east-1.amazonaws.com"),
                       "the S3 bucket the substring test caught — a first-label CONTAINS check fabricates "
                       + "Llm on ordinary object storage")
        XCTAssertFalse(isModelHost("bedrock.us-east-1.amazonaws.com"),
                       "the CONTROL PLANE (CreateModelCustomizationJob etc.) dispatches no inference")
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
        // POSIX socket WIRE verbs → Net (raw `import Glibc; connect(fd,&addr,len)` did Net at runtime but
        // read silent-pure — the swift dynamic oracle surfaced the gap). GATED ON EXACT ARITY + shadow-guarded.
        XCTAssertEqual(kappaFree(name: "connect", argCount: 3), "Net")      // connect(fd, sockaddr*, socklen)
        XCTAssertEqual(kappaFree(name: "sendto", argCount: 6), "Net")
        XCTAssertEqual(kappaFree(name: "recvfrom", argCount: 6), "Net")
        XCTAssertEqual(kappaFree(name: "sendmsg", argCount: 3), "Net")
        XCTAssertEqual(kappaFree(name: "recvmsg", argCount: 3), "Net")
        // Anti-fabrication: the arity gate rejects a same-named non-POSIX call, and the collision-prone
        // SETUP/common verbs stay ABSENT (bind is the GRDB Statement.bind case — must never fabricate Net).
        XCTAssertNil(kappaFree(name: "connect", argCount: 2))              // not the POSIX 3-arg signature
        XCTAssertNil(kappaFree(name: "connect", argCount: 1))
        XCTAssertNil(kappaFree(name: "bind", argCount: 3))                 // GRDB Statement.bind → NEVER Net
        XCTAssertNil(kappaFree(name: "socket", argCount: 3))              // fd creation, not the wire act
        XCTAssertNil(kappaFree(name: "send", argCount: 4))                // too-common a word to model bare
        XCTAssertNil(kappaFree(name: "listen", argCount: 2))
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

    /// SOUNDNESS R385 — A LOCATOR THE DESTINATION SURFACE CANNOT EXPRESS.
    ///
    /// The Keychain half. `SecItem*` classify `Fs` (the system secure store) and `isEstablishingFree`
    /// for Fs was two names, so a benign path literal certified a Keychain write with a runtime query:
    /// `"x".write(toFile: "/tmp/benign.txt")` beside `SecItemAdd(runtimeQuery, nil)` reported
    /// `paths:['/tmp/benign.txt'] incomplete:NONE` and `allow Fs /tmp/benign.txt` exited 0. Calibrated
    /// first — `deny Fs` exits 1 on the same fixture.
    ///
    /// **THE FIX IS NOT "ADD THE NAMES", and that is the whole row.** A `SecItem` query is a
    /// CFDictionary and a bonjour `type:` is a service type; neither is a path or a host. Adding them to
    /// the establishing predicates while the literal picker scans the argument list would CAPTURE one as
    /// a destination — which is exactly how R381's first cut put `"443"` into `hosts`. So the posture is
    /// ⟨0.29⟩'s bind/listen rule, already in this codebase as the dotless-model-host break: mark
    /// establishing so a missing locator fails closed, and capture NOTHING.
    ///
    /// THE BONJOUR HALF IS STILL OPEN and is deliberately asserted as open below rather than left
    /// unmentioned: `NWBrowser` classifies through `kappaMember` on `start()`, and the engine
    /// deliberately does not mask at a USE-site because the locator was fixed at construction
    /// (`isNetEstablishingMember`'s own doc). The predicate here is correct and simply is not reached
    /// for that shape yet.
    func testR385OpaqueLocatorFormsEstablishWithoutCapturing() {
        // The Keychain family — the locator is a CFDictionary, invisible to any surface.
        for n in ["SecItemAdd", "SecItemUpdate", "SecItemDelete", "SecItemCopyMatching"] {
            XCTAssertTrue(isOpaqueLocatorFree(n), "\(n)'s locator is a CFDictionary — R385")
            XCTAssertTrue(isEstablishingFree(effect: "Fs", name: n),
                          "\(n) must ESTABLISH so a runtime query fails closed — R385")
        }
        // Bonjour — the predicate is right; reaching it is the open half.
        for n in ["NWBrowser", "NetService", "NetServiceBrowser"] {
            XCTAssertTrue(isOpaqueLocatorFree(n), "\(n)'s locator is a SERVICE TYPE, not a host — R385")
        }
        // The pre-existing Fs establishing names must survive.
        XCTAssertTrue(isEstablishingFree(effect: "Fs", name: "fopen"))
        XCTAssertTrue(isEstablishingFree(effect: "Fs", name: "FileHandle"))
        // CONTROLS — an ordinary host-bearing Net form is NOT opaque: its locator IS a host and must
        // still be captured, or this fix would withhold every real destination in the engine.
        for n in ["NWConnection", "NWListener", "getaddrinfo", "connect", "fopen"] {
            XCTAssertFalse(isOpaqueLocatorFree(n),
                           "\(n) names a real host or path — withholding its literal would destroy "
                           + "the surface this engine exists to publish")
        }
    }

    /// SOUNDNESS R381 — R379's GATE BYPASS, CARRIED TO THIS ENGINE. The κ tables classify eight POSIX
    /// resolver verbs and `NSURLConnection` as `Net`; the masking tables that decide certifiability knew
    /// only `NWConnection`/`NWListener`. Two tables, one question, never connected.
    ///
    /// Measured before the fix, with the instrument calibrated first: a `URLSession` request to a literal
    /// `api.stripe.com` beside `getaddrinfo(callerHost, "443", …)` reported
    /// `hosts:['api.stripe.com'] incomplete:NONE`; `deny Net` exited 1 (so the gate was live) and
    /// **`allow Net api.stripe.com` exited 0** over a DNS resolution of a caller-supplied name.
    ///
    /// The whole family is asserted, not the two spellings that were measured — R346.
    func testR381ResolverVerbsAreEstablishing() {
        for n in ["getaddrinfo", "getnameinfo", "gethostbyname", "gethostbyname2", "gethostbyaddr",
                  "gethostbyname_r", "gethostbyaddr_r", "getaddrinfo_a"] {
            XCTAssertTrue(isNetEstablishingFree(name: n),
                          "\(n) resolves a caller-supplied host — R381. Absent, `allow Net <benign literal>` "
                          + "exits 0 over a DNS lookup of a runtime name.")
            XCTAssertTrue(isEstablishingFree(effect: "Net", name: n), "\(n) must reach the generalized guard too")
            XCTAssertTrue(isNetResolverFree(n), "\(n) belongs to the family the LOCATOR POSITION rule keys on")
        }
        // `NSURLConnection`'s request object carries the URL, so these forms establish.
        for m in ["sendSynchronousRequest", "sendAsynchronousRequest", "start", "init"] {
            XCTAssertTrue(isNetEstablishingMember(root: "NSURLConnection", member: m), "R381: \(m)")
        }
        // The pre-existing entries must survive, and USE-verbs must stay out — this is an ALLOWLIST and
        // R379 measured why inverting it is not automatically right.
        XCTAssertTrue(isNetEstablishingFree(name: "NWConnection"))
        XCTAssertFalse(isNetEstablishingFree(name: "send"))
        XCTAssertFalse(isNetResolverFree("NWConnection"), "only the libc resolver family keys the locator rule")
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
