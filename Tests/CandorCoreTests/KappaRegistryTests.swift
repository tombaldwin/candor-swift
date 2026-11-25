import XCTest
import Foundation
@testable import CandorCore

/// The κ registry's DRIFT GUARD (curated-routing stage S0; Fable review §1 C, §4.1).
///
/// The registry records which ENTITY each κ entry describes. That is a new fact and it can be entered wrong in
/// two directions, each of which re-creates a measured defect once a later stage reads it:
///   (a) a package's name marked `.platform` → a chained declaration shadows κ → row-wins → R1867 re-created;
///   (b) a platform name marked `.package` → κ unions onto a different entity → R649's fabrication returns.
/// `testCollisionCensus` pins both directions against κ names that real dependencies DECLARE. The completeness
/// tests make a NEW κ name impossible to add without classifying it, so the census is not the only line.
final class KappaRegistryTests: XCTestCase {

    private static let classifierSource: String = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("Sources/CandorCore/Classifier.swift"),
                            encoding: .utf8)) ?? ""
    }()

    /// The string literals in the `case` LABELS (up to the label's colon, never the arm body) of one function.
    private static func caseLabels(of signature: String) -> [String] {
        let src = classifierSource
        guard let start = src.range(of: signature),
              let end = src.range(of: "\n}\n", range: start.upperBound..<src.endIndex) else { return [] }
        let body = String(src[start.lowerBound..<end.lowerBound])
        var names: [String] = []
        // Scan character by character from each `case ` at a line start to the first colon outside quotes.
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            let atLineStart = i == 0 || chars[i - 1] == "\n"
            if atLineStart {
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                if j + 5 <= chars.count, String(chars[j..<j + 5]) == "case " {
                    var k = j + 5, inQuote = false, cur = "", label: [String] = []
                    while k < chars.count {
                        let c = chars[k]
                        if c == "\"" {
                            if inQuote { label.append(cur); cur = "" }
                            inQuote.toggle()
                        } else if inQuote {
                            cur.append(c)
                        } else if c == ":" {
                            break
                        }
                        k += 1
                    }
                    names += label
                    i = k
                    continue
                }
            }
            i += 1
        }
        return names
    }

    private static var memberLabels: [String] { caseLabels(of: "public func kappaMember(") }
    private static var freeLabels: [String] { caseLabels(of: "public func kappaFree(") }

    /// Every name `kappaMember` can answer for.
    private static var memberNames: Set<String> {
        Set(memberLabels).union(MODEL_SDK_TYPES).union(PRIVACY_SDK_TYPES.keys).union(PRIVACY_MEMBER_TYPES.keys)
            .union(RAND_ROOTS)
    }
    /// Every name `kappaFree` can answer for (the `DB_FREE_PREFIX` prefix arm is a `.freePrefix` entry).
    private static var freeNames: Set<String> {
        Set(freeLabels).union(MODEL_SDK_TYPES).union(PRIVACY_SDK_TYPES.keys).union(CAPABILITY_FREE_EFFECT.keys)
    }

    // ── completeness: a κ name cannot be added without a decision here ──

    func testEveryKappaNameHasAnEntry() {
        // VACUITY FLOOR: the parse must find the switches it asserts about.
        XCTAssertGreaterThanOrEqual(Self.memberLabels.count, 30, "parsed too few kappaMember case labels")
        XCTAssertGreaterThanOrEqual(Self.freeLabels.count, 40, "parsed too few kappaFree case labels")
        XCTAssertTrue(Self.memberLabels.contains("HTTPClient") && Self.freeLabels.contains("shellOut"),
                      "the parse missed a label it must see")
        for n in Self.memberNames.sorted() {
            XCTAssertTrue(KAPPA_REGISTRY[n]?.surfaces.contains(.member) == true,
                          "κ member root `\(n)` has no registry entry: classify it (platform or package) in KappaRegistry.swift")
        }
        for n in Self.freeNames.sorted() {
            XCTAssertTrue(KAPPA_REGISTRY[n]?.surfaces.contains(.free) == true,
                          "κ free name `\(n)` has no registry entry: classify it (platform or package) in KappaRegistry.swift")
        }
        XCTAssertEqual(KAPPA_REGISTRY[DB_FREE_PREFIX]?.surfaces, [.freePrefix])
    }

    /// The reverse: an entry for a name κ does not answer is stale, and a stale `.package` entry is a claim about
    /// an entity nothing curates.
    func testEveryEntryIsAKappaName() {
        for (n, e) in KAPPA_REGISTRY {
            if e.surfaces.contains(.member) {
                XCTAssertTrue(Self.memberNames.contains(n), "registry says `\(n)` is a κ member root; kappaMember has no such root")
            }
            if e.surfaces.contains(.free) {
                XCTAssertTrue(Self.freeNames.contains(n), "registry says `\(n)` is a κ free name; kappaFree has no such name")
                XCTAssertTrue((0...6).contains { kappaFree(name: n, argCount: $0) != nil },
                              "`\(n)`: kappaFree answers nil at every arity 0...6")
            }
            if e.surfaces.contains(.freePrefix) { XCTAssertEqual(n, DB_FREE_PREFIX) }
        }
    }

    func testNoConflictingEntries() {
        XCTAssertEqual(KAPPA_REGISTRY_CONFLICTS, [], "a name is listed twice with different entities or authority")
    }

    // ── authority (SPEC §2 ⟨0.43⟩: a third-party entry is a floor) ──

    func testOnlyPlatformEntriesAreComplete() {
        for (n, e) in KAPPA_REGISTRY {
            let hasPackage = e.describes.contains { if case .package = $0 { return true }; return false }
            XCTAssertFalse(e.describes.isEmpty, "`\(n)` describes nothing")
            if hasPackage {
                XCTAssertEqual(e.authority, .floor, "`\(n)` describes a third-party package, so κ is a floor for it")
            }
        }
    }

    // ── the collision census: both error directions ──

    /// κ names a real dependency DECLARES, and whether that declaration is the entity κ describes. Seeded from the
    /// curated-routing design's reach census over Publish's and vapor's resolved dependencies
    /// (`_kfree_declared_by_corpus`), plus the R649 POSIX case and the κ-dependency roots the chained join hits.
    /// `true` = same entity (a later stage UNIONS κ with the row); `false` = a different entity (the declaration
    /// shadows, R649). Getting a `true` row wrong re-creates R1867; getting a `false` row wrong re-creates R649.
    private static let census: [(name: String, module: String, same: Bool)] = [
        ("shellOut", "ShellOut", true),          // R1867: ShellOut's own shellOut
        ("shellOut", "ShellKit", false),         // a vendored copy under another module (Fable N5)
        ("File", "Files", true),                 // R1870: Files' File
        ("Folder", "Files", true),
        ("File", "Vapor", false),                // Vapor's own File type
        ("Process", "Vapor", false),             // Vapor declares a Process; κ's is Foundation's
        ("FileHandle", "NIOFS", false),          // NIO's FileHandle; κ's is Foundation's
        ("FileHandle", "_NIOFileSystem", false),
        ("connect", "Chan", false),              // R649: a dependency's own `connect` is not POSIX's
        ("HTTPClient", "AsyncHTTPClient", true),
        ("Channel", "NIOCore", true),
        ("Logger", "Logging", true),             // swift-log's Logger (κ's root covers it and os's)
        ("Logger", "MyLogKit", false),
    ]

    func testCollisionCensus() {
        for c in Self.census {
            XCTAssertEqual(kappaDescribesDeclaration(name: c.name, module: c.module), c.same,
                           "REGISTRY DRIFT: `\(c.name)` declared in module \(c.module) should be "
                           + (c.same ? "the SAME entity κ describes (else row-wins: R1867)"
                                     : "a DIFFERENT entity (else κ unions onto it: R649)"))
        }
        XCTAssertNil(kappaDescribesDeclaration(name: "notAKappaName", module: "Files"))
    }

    // ── the derived module lists ──

    /// `KAPPA_MODULES` decides which imports `blindModules()` never names in `invisible`, so changing it moves
    /// reports: it is a behaviour change, not a registry edit, and this pin makes it a deliberate one. (Replaces
    /// R1866's hand partition: the partition now holds by construction.)
    func testDerivedModuleListsArePinned() {
        XCTAssertEqual(KAPPA_MODULES, ["Network", "SQLite3", "CoreData", "NIOCore", "NIOPosix", "NIOHTTP1", "NIOHTTP2",
                                       "NIOSSL", "NIOTransportServices", "AsyncHTTPClient"])
        XCTAssertEqual(KAPPA_DEPENDENCY_MODULES, ["NIOCore", "NIOPosix", "NIOHTTP1", "NIOHTTP2", "NIOSSL",
                                                  "NIOTransportServices", "AsyncHTTPClient"])
        XCTAssertEqual(KAPPA_DEPENDENCY_ROOTS, [
            "HTTPClient": ["AsyncHTTPClient"],
            "ClientBootstrap": ["NIOPosix"], "ServerBootstrap": ["NIOPosix"], "DatagramBootstrap": ["NIOPosix"],
            "NIOTSConnectionBootstrap": ["NIOTransportServices"],
            "Channel": ["NIOCore", "NIOPosix"], "ChannelHandlerContext": ["NIOCore", "NIOPosix"],
        ])
    }

    func testCoveredPlatformFrameworksAreDescribed() {
        XCTAssertTrue(KAPPA_PLATFORM_FRAMEWORKS.isDisjoint(with: PLATFORM_MODULES))
        XCTAssertTrue(KAPPA_DEPENDENCY_MODULES.isDisjoint(with: PLATFORM_MODULES))
        let described = Set(KAPPA_REGISTRY.values.flatMap { $0.describes }.compactMap { e -> String? in
            if case .platform(let m) = e { return m }; return nil
        })
        for f in KAPPA_PLATFORM_FRAMEWORKS {
            XCTAssertTrue(described.contains(f), "covered OS framework \(f) has no κ entry describing it")
        }
        // A package the ledger counts covered derives module lists, so its modules must be verified (non-nil).
        for p in KAPPA_PACKAGES where p.ledger == .curatedCovered {
            XCTAssertNotNil(p.modules, "\(p.name) is counted covered but its modules were never verified")
        }
    }
}
