// ════════════════════════════════════════════════════════════════════════════════════════════════
// THE κ REGISTRY — which ENTITY each curated entry describes, and whether it is an authority or a floor
// ════════════════════════════════════════════════════════════════════════════════════════════════
//
// `kappaMember` and `kappaFree` (Classifier.swift) answer "what effect does this name perform"; they never said
// WHOSE name it is. Some κ names describe the platform (POSIX `connect`, Foundation's `FileManager`) and some
// describe a named THIRD-PARTY package (ShellOut's `shellOut`, Files' `File`, AsyncHTTPClient's `HTTPClient`).
// That fact was re-derived separately by three hand-kept module lists (`KAPPA_MODULES`,
// `KAPPA_DEPENDENCY_MODULES`, `KAPPA_DEPENDENCY_ROOTS`) and by R649's `depShadows`, which is how the free-name,
// ctor and module-qualified routes came to apply three different precedences (curated-routing design §1–§2,
// SOUNDNESS R1867 / R1870 / R1871).
//
// Stage S0 (this file) records the fact ONCE. It is a refactor: the three module lists are now DERIVED from it
// and must equal what they were, so no report byte moves. Later stages read `describes` to decide whether a
// chained declaration is the SAME entity as a κ entry (union) or a different one (name resolution, R649).
//
// THE FIELDS ARE CLAIMS AND CAN BE WRONG IN BOTH DIRECTIONS (Fable review §1 C):
//   • a package's name marked `.platform` → a chained declaration of it shadows κ → row-wins → R1867 re-created;
//   • a platform name marked `.package` → κ unions onto a different entity → R649's fabrication returns.
// `KappaRegistryTests` pins both directions against a census of κ names that real dependencies DECLARE, and
// requires every κ name in `kappaMember`/`kappaFree` to have an entry here (adding one forces a decision).
//
// `authority` follows SPEC §2 ⟨0.43⟩ ("a curated entry claims the call performs E, not that it performs nothing
// else"): a THIRD-PARTY entry is a `floor` — a body exists that a report could read. Only an all-platform entry
// may be `complete`. S0 records it; nothing reads it yet (the Q1 floor `invisible` is a later stage).

/// How today's coverage ledger treats a package κ knows. This is the CURRENT behaviour, recorded so the module
/// lists can be derived byte-identically — it is not a claim about what the posture should be (see `authority`).
public enum KappaLedger: Hashable, Sendable {
    /// Counted covered by κ: in `KAPPA_MODULES`, so `blindModules()` never names it in `invisible`; R1866 hedges
    /// the members κ does not model.
    case curatedCovered
    /// An ordinary blind module: the per-function `invisible` ledger names it like any uncovered dependency; κ
    /// answers only the spellings it curates.
    case ledgerNamed
}

/// A third-party package κ curates part of.
public struct KappaPackage: Hashable, Sendable {
    /// The package's own name (SwiftPM identity as its manifest spells it).
    public let name: String
    /// The modules through which κ recognises this package — NOT necessarily every module the package vends
    /// (swift-nio vends more than NIOCore/NIOPosix/NIOHTTP1; only these are counted). A chained report whose
    /// module set contains one of these counts as this package (Fable review §2 Q2). `nil` = the module name
    /// was never verified; no identity may be formed through it until it is.
    public let modules: Set<String>?
    public let ledger: KappaLedger
}

/// The entity a κ entry describes.
public enum KappaEntity: Hashable, Sendable {
    /// The platform frontier (OS, SDK, C library, stdlib): no dependency report can describe it, so ANY chained
    /// declaration of the same name is a different entity (R649). `module` is recorded where it is known and
    /// read (the covered OS frameworks); `nil` means not recorded, never "no module". `Darwin` stands for the
    /// target's C library module (Darwin / Glibc / Musl / WinSDK).
    case platform(module: String?)
    /// A third-party package. `declaredIn` = the package modules that declare (or re-export) this name; empty
    /// when the κ name is not a declaration at all (the `AsyncHTTPClient` root is the module's own name used as
    /// a receiver base).
    case package(KappaPackage, declaredIn: Set<String>)
}

public enum KappaAuthority: Hashable, Sendable {
    /// κ's verb table is the whole answer for this entity.
    case complete
    /// κ's charge is a lower bound: the entity has a body κ never read.
    case floor
}

/// Which κ function answers the name.
public enum KappaSurface: Hashable, Sendable {
    case member   // a `kappaMember` root (a receiver base or type)
    case free     // a `kappaFree` free function or constructor name
    case freePrefix // a `kappaFree` name PREFIX (`DB_FREE_PREFIX`)
}

public struct KappaEntry: Hashable, Sendable {
    public let name: String
    public let surfaces: Set<KappaSurface>
    /// Usually one entity. More than one when ONE κ spelling covers two entities that share a name
    /// (`Logger`: os's and swift-log's).
    public let describes: [KappaEntity]
    public let authority: KappaAuthority
}

// ── the packages ────────────────────────────────────────────────────────────────────────────────

public let KAPPA_PKG_NIO = KappaPackage(name: "swift-nio", modules: ["NIOCore", "NIOPosix", "NIOHTTP1"], ledger: .curatedCovered)
public let KAPPA_PKG_NIO_HTTP2 = KappaPackage(name: "swift-nio-http2", modules: ["NIOHTTP2"], ledger: .curatedCovered)
public let KAPPA_PKG_NIO_SSL = KappaPackage(name: "swift-nio-ssl", modules: ["NIOSSL"], ledger: .curatedCovered)
public let KAPPA_PKG_NIO_TS = KappaPackage(name: "swift-nio-transport-services", modules: ["NIOTransportServices"],
                                           ledger: .curatedCovered)
public let KAPPA_PKG_AHC = KappaPackage(name: "async-http-client", modules: ["AsyncHTTPClient"], ledger: .curatedCovered)
public let KAPPA_PKG_FILES = KappaPackage(name: "Files", modules: ["Files"], ledger: .ledgerNamed)
public let KAPPA_PKG_SHELLOUT = KappaPackage(name: "ShellOut", modules: ["ShellOut"], ledger: .ledgerNamed)
public let KAPPA_PKG_SWIFT_LOG = KappaPackage(name: "swift-log", modules: ["Logging"], ledger: .ledgerNamed)
// The model-provider SDKs (`MODEL_SDK_TYPES`). Only MacPaw/OpenAI's module is stated in the source this was taken
// from; the others were never verified, so their modules are `nil` (no identity may be formed through them).
public let KAPPA_PKG_OPENAI = KappaPackage(name: "OpenAI", modules: ["OpenAI"], ledger: .ledgerNamed)
public let KAPPA_PKG_ANTHROPIC = KappaPackage(name: "swift-anthropic / AnthropicSwiftSDK", modules: nil, ledger: .ledgerNamed)
public let KAPPA_PKG_AWS_BEDROCK = KappaPackage(name: "aws-sdk-swift (Bedrock runtime)", modules: nil, ledger: .ledgerNamed)
public let KAPPA_PKG_LANGCHAIN = KappaPackage(name: "langchain-swift", modules: nil, ledger: .ledgerNamed)

/// Every package κ knows, including those that carry no κ entry of their own (NIOHTTP2/NIOSSL are counted
/// covered as part of the NIO tier — the vapor probe's pointer).
public let KAPPA_PACKAGES: [KappaPackage] = [
    KAPPA_PKG_NIO, KAPPA_PKG_NIO_HTTP2, KAPPA_PKG_NIO_SSL, KAPPA_PKG_NIO_TS, KAPPA_PKG_AHC,
    KAPPA_PKG_FILES, KAPPA_PKG_SHELLOUT, KAPPA_PKG_SWIFT_LOG,
    KAPPA_PKG_OPENAI, KAPPA_PKG_ANTHROPIC, KAPPA_PKG_AWS_BEDROCK, KAPPA_PKG_LANGCHAIN,
]

/// OS frameworks outside `PLATFORM_MODULES` that κ counts as covered (they have no dependency factory that could
/// untype a receiver, which is why R1866 does not disclose into them). Each must be the module of at least one
/// `.platform` entry below (pinned by the tests).
public let KAPPA_PLATFORM_FRAMEWORKS: Set<String> = ["Network", "SQLite3", "CoreData"]

// ── the entries ─────────────────────────────────────────────────────────────────────────────────

private func plat(_ module: String?, _ surfaces: Set<KappaSurface>, _ names: [String]) -> [KappaEntry] {
    names.map { KappaEntry(name: $0, surfaces: surfaces, describes: [.platform(module: module)], authority: .complete) }
}
private func pkg(_ p: KappaPackage, _ declaredIn: Set<String>, _ surfaces: Set<KappaSurface>, _ names: [String]) -> [KappaEntry] {
    names.map { KappaEntry(name: $0, surfaces: surfaces, describes: [.package(p, declaredIn: declaredIn)], authority: .floor) }
}

/// The hand-classified entries: every `case` label of `kappaMember` and `kappaFree`, and every
/// `MODEL_SDK_TYPES` name (that table mixes Apple's FoundationModels with third-party SDKs).
private let KAPPA_EXPLICIT_ENTRIES: [KappaEntry] =
    // Foundation
    plat("Foundation", [.member], ["FileManager", "URLSession", "URL", "NSURLConnection", "UserDefaults", "Bundle"])
    + plat("Foundation", [.member, .free], ["FileHandle", "Process", "NSXPCConnection", "NetService",
                                            "NetServiceBrowser", "Date"])
    + plat("Foundation", [.free], ["NSLog", "Pipe", "UUID"])
    // the stdlib and Dispatch clocks / entropy
    + plat("Swift", [.member], ["ContinuousClock", "SuspendingClock"])
    + plat("Dispatch", [.member], ["DispatchTime"])
    + plat("Swift", [.free], ["SystemRandomNumberGenerator"])
    // unified logging (the `Logger` root is shared with swift-log: see below)
    + plat("OSLog", [.member], ["OSLog"])
    + plat("os", [.free], ["os_log"])
    // pasteboards
    + plat("AppKit", [.member], ["NSPasteboard"])
    + plat("UIKit", [.member], ["UIPasteboard"])
    // Network.framework (a covered OS framework)
    + plat("Network", [.member, .free], ["NWConnection", "NWListener", "NWBrowser"])
    // CoreData (a covered OS framework)
    + plat("CoreData", [.member], ["NSManagedObjectContext", "NSPersistentContainer", "NSPersistentStoreCoordinator"])
    // SQLite3's C surface by prefix (a covered OS framework)
    + plat("SQLite3", [.freePrefix], [DB_FREE_PREFIX])
    // Security / CoreAudio / CoreServices C entry points
    + plat("Security", [.free], ["SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete"])
    + plat("CoreAudio", [.free], ["AudioHardwareCreateProcessTap"])
    + plat("CoreServices", [.free], ["AESendMessage"])
    // the C library (R649's names: a dependency's own `connect` is a DIFFERENT entity)
    + plat("Darwin", [.free], ["arc4random", "arc4random_uniform", "getentropy",
                               "getaddrinfo", "getnameinfo", "gethostbyname", "gethostbyname2", "gethostbyaddr",
                               "gethostbyname_r", "gethostbyaddr_r", "getaddrinfo_a",
                               "posix_spawn", "posix_spawnp", "execv", "execvp", "execve", "execvP", "fexecve",
                               "fopen", "connect", "sendmsg", "recvmsg", "sendto", "recvfrom"])
    // Apple FoundationModels (MODEL_SDK_TYPES' platform half)
    + plat("FoundationModels", [.member, .free], ["LanguageModelSession", "SystemLanguageModel"])
    // ── third-party ──
    + pkg(KAPPA_PKG_NIO, ["NIOPosix"], [.member], ["ClientBootstrap", "ServerBootstrap", "DatagramBootstrap"])
    + pkg(KAPPA_PKG_NIO_TS, ["NIOTransportServices"], [.member], ["NIOTSConnectionBootstrap"])
    + pkg(KAPPA_PKG_NIO, ["NIOCore", "NIOPosix"], [.member], ["Channel", "ChannelHandlerContext"])
    + pkg(KAPPA_PKG_AHC, ["AsyncHTTPClient"], [.member], ["HTTPClient"])
    + pkg(KAPPA_PKG_AHC, [], [.member], ["AsyncHTTPClient"])   // the module's own name as a receiver base
    + pkg(KAPPA_PKG_FILES, ["Files"], [.member, .free], ["File", "Folder"])
    + pkg(KAPPA_PKG_FILES, ["Files"], [.member], ["Storage"])
    + pkg(KAPPA_PKG_SHELLOUT, ["ShellOut"], [.free], ["shellOut"])
    + pkg(KAPPA_PKG_OPENAI, ["OpenAI"], [.member, .free], ["OpenAI"])
    + pkg(KAPPA_PKG_ANTHROPIC, [], [.member, .free], ["AnthropicClient", "AnthropicSwiftClient", "SwiftAnthropic"])
    + pkg(KAPPA_PKG_AWS_BEDROCK, [], [.member, .free], ["BedrockRuntimeClient", "BedrockRuntime"])
    + pkg(KAPPA_PKG_LANGCHAIN, [], [.member, .free], ["LLM", "LangChain"])
    // ONE κ root, TWO entities: `Logger` is os's (OSLog) and swift-log's (Logging). A floor, because one of them
    // is a package with a body.
    + [KappaEntry(name: "Logger", surfaces: [.member],
                  describes: [.platform(module: "OSLog"), .package(KAPPA_PKG_SWIFT_LOG, declaredIn: ["Logging"])],
                  authority: .floor)]

/// Table-backed κ names whose table is platform BY DEFINITION, so they are classified per table rather than per
/// name: the Apple privacy-sensor types (`privacy/1`, Apple frameworks only), the stdlib `random` roots, and the
/// capability free calls (C library / Foundation). A third-party name may not be added to these tables; the
/// tests require these names to stay disjoint from every package entry.
private let KAPPA_TABLE_ENTRIES: [KappaEntry] =
    plat(nil, [.member, .free], PRIVACY_SDK_TYPES.keys.sorted())
    + plat(nil, [.member], PRIVACY_MEMBER_TYPES.keys.sorted())
    + plat("Swift", [.member], RAND_ROOTS.sorted())
    + plat(nil, [.free], CAPABILITY_FREE_EFFECT.keys.sorted())

/// Built once; a name listed twice MERGES its surfaces when it describes the same entities, and is recorded in
/// `KAPPA_REGISTRY_CONFLICTS` (asserted empty by the tests) when it does not — never silently last-wins.
private let KAPPA_REGISTRY_BUILT: (registry: [String: KappaEntry], conflicts: [String]) = {
    var out: [String: KappaEntry] = [:]
    var conflicts: [String] = []
    for e in KAPPA_EXPLICIT_ENTRIES + KAPPA_TABLE_ENTRIES {
        guard let prior = out[e.name] else { out[e.name] = e; continue }
        // A table entry with `module: nil` agrees with an explicit platform entry of a known module.
        let samePosture = prior.authority == e.authority
            && Set(prior.describes.map(kappaEntityClass)) == Set(e.describes.map(kappaEntityClass))
        if !samePosture { conflicts.append(e.name); continue }
        out[e.name] = KappaEntry(name: e.name, surfaces: prior.surfaces.union(e.surfaces),
                                 describes: prior.describes, authority: prior.authority)
    }
    return (out, conflicts.sorted())
}()

private func kappaEntityClass(_ e: KappaEntity) -> String {
    switch e {
    case .platform: return "platform"
    case .package(let p, _): return "package:" + p.name
    }
}

/// The registry: κ name (a root, a free name, or a free-name prefix) → what it describes.
public let KAPPA_REGISTRY: [String: KappaEntry] = KAPPA_REGISTRY_BUILT.registry
/// Names listed twice with different postures. Must be empty.
public let KAPPA_REGISTRY_CONFLICTS: [String] = KAPPA_REGISTRY_BUILT.conflicts

/// Does a declaration of `name` in module `module` (a chained report's module, or a readable dependency's)
/// denote the SAME entity this κ entry describes? `nil` when `name` is no κ name. A `.platform` entry is never the
/// same entity as a dependency's declaration (R649); a `.package` entry is the same entity exactly when `module`
/// is one of the package's recognised modules — package identity, never the bare spelling (Fable review §2 Q2:
/// a vendored `ShellKit.shellOut` is a different entity). Nothing in the scan path reads this yet (stage S1 will);
/// it is what `KappaRegistryTests` pins.
public func kappaDescribesDeclaration(name: String, module: String) -> Bool? {
    guard let e = KAPPA_REGISTRY[name] else { return nil }
    return e.describes.contains {
        if case .package(let p, _) = $0, let mods = p.modules { return mods.contains(module) }
        return false
    }
}

// ── the module lists, DERIVED (they were three hand-kept lists; R1866's partition test pinned them by hand) ──

/// SOUNDNESS R1866 — the κ modules that are DEPENDENCY PACKAGES (SwiftPM, not an OS framework). κ's coverage of
/// them is a curated verb table keyed on a TYPED receiver, so a value whose type this engine could not form (a
/// dependency factory's result, `let r = makeClient()`) is answered by nothing: the module is not blind (no
/// `invisible`), the classifier cannot key the call, and no report is chained. The Driver discloses that call.
/// Derived: the modules of every package the ledger counts covered.
public let KAPPA_DEPENDENCY_MODULES: Set<String> =
    Set(KAPPA_PACKAGES.filter { $0.ledger == .curatedCovered }.flatMap { $0.modules ?? [] })

/// The modules κ counts as covered — the OS frameworks it curates plus the covered dependency packages. Every
/// other imported module is either a `PLATFORM_MODULES` member or NAMED by the ledger.
public let KAPPA_MODULES: Set<String> = KAPPA_PLATFORM_FRAMEWORKS.union(KAPPA_DEPENDENCY_MODULES)

/// SOUNDNESS R1866 (typed) — the types `kappaMember` models that a κ DEPENDENCY module declares, with the modules
/// that declare (or re-export) them. κ answers only its VERBS on these types; any other member is a body no scan
/// read, and with the module counted as covered nothing else says so. Derived: every `.member` entry describing a
/// covered package through a non-empty set of declaring modules.
public let KAPPA_DEPENDENCY_ROOTS: [String: Set<String>] = {
    var out: [String: Set<String>] = [:]
    for (name, e) in KAPPA_REGISTRY where e.surfaces.contains(.member) {
        for case .package(let p, let declaredIn) in e.describes where p.ledger == .curatedCovered && !declaredIn.isEmpty {
            out[name, default: []].formUnion(declaredIn)
        }
    }
    return out
}()

// ── stage S1: the identity question the free-name, ctor and module-qualified routes ask ──────────────────────

/// How a declaration of a κ name in one module relates to the entity the κ entry describes.
public enum KappaRelation: Hashable, Sendable {
    /// The module is one of the package's recognised modules: the declaration IS the entity κ describes, so a
    /// chained row and κ's charge answer the same call and are UNIONED (SPEC §2 ⟨0.43⟩).
    case same
    /// A different entity of the same name: a platform entry (any dependency declaration is another entity,
    /// R649) or a package entry whose recognised modules do not include this module (a vendored copy).
    case different
    /// The entry names a package whose modules were never verified (`modules == nil`): no identity may be
    /// formed through it, so a caller keeps whatever it did before the registry existed.
    case unknown
}

/// Stage S1's reading of the registry (curated-routing design §4, Fable review §2 Q2). `nil` when `name` is no
/// κ name. A `Logger`-shaped entry (platform AND package) is `.same` for the package's module and `.different`
/// for every other module.
public func kappaRelation(name: String, module: String) -> KappaRelation? {
    guard let e = KAPPA_REGISTRY[name] else { return nil }
    var unknown = false
    for d in e.describes {
        guard case .package(let p, _) = d else { continue }
        guard let mods = p.modules else { unknown = true; continue }
        if mods.contains(module) { return .same }
    }
    return unknown ? .unknown : .different
}

/// Does the κ entry for `name` describe a THIRD-PARTY package (with verified modules) at all? The routes that
/// withdraw κ on a different entity (the vendored-copy half of R1871) act only on such entries; a platform entry
/// keeps R649's own rule.
public func kappaDescribesKnownPackage(_ name: String) -> Bool {
    guard let e = KAPPA_REGISTRY[name] else { return false }
    return e.describes.contains {
        if case .package(let p, _) = $0 { return p.modules != nil }
        return false
    }
}

/// Is the κ entry for `name` a platform entry only (no package)? R1876's signature check applies to these.
public func kappaIsPlatformOnly(_ name: String) -> Bool {
    guard let e = KAPPA_REGISTRY[name] else { return false }
    return !e.describes.isEmpty && e.describes.allSatisfy {
        if case .platform = $0 { return true }
        return false
    }
}
