import XCTest
import Foundation

/// THE SINGLETON FIELD — `private let session = URLSession.shared`.
///
/// A stored property's type came from its ANNOTATION, or from a ctor CALL in its initializer. The
/// dominant Apple-platform spelling is neither: `URLSession.shared` / `FileManager.default` /
/// `MyStore.shared` is a member ACCESS, so the field stayed untyped, every call on it missed κ and
/// resolved to no unit, and the enclosing function read SILENT-PURE — the cardinal sin, and one that no
/// amount of host or command extraction can reach, because the effect itself was never charged.
///
/// The same inference already existed for a LOCAL binding (`let d = UserDefaults.standard` — see
/// `SINGLETON_ACCESSORS`, whose comment says so); only the FIELD case was missing.
///
/// The inference is `Type.member : Type`, which is true for the canonical singleton accessors and NOT in
/// general — a `static let logger: Logger` on a local type would otherwise type the field as its OWNER and
/// resolve calls to the owner's methods, fabricating whatever those do. So the guard is an allowlist of
/// spellings, and the mirrors below are the half that keeps it honest.
final class SingletonFieldTypeProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: SingletonFieldTypeProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    // ── THE MIRRORS, FIRST ──────────────────────────────────────────────────────────────────────────

    /// A static member that is NOT a singleton accessor must not type the field as its owner. Here
    /// `Service.helper` is a `Helper`, and typing `h` as `Service` would resolve `h.go()` to
    /// `Service.go()` and charge this function with an `Fs` it never performs.
    func testFailClosedNonSingletonStaticDoesNotTypeTheField() throws {
        let by = try scan("""
        import Foundation
        final class Helper { func go() {} }
        final class Service {
            static let helper = Helper()
            func go() { _ = FileManager.default.contents(atPath: "/tmp/x") }
        }
        final class User {
            let h = Service.helper
            func run() { h.go() }
        }
        User().run()
        """)
        XCTAssertNil(ProcessHarness.inferred(by, "User.run"),
                     "`Service.helper` is a Helper — typing the field as Service would fabricate Service.go's Fs")
    }

    /// A NESTED static (`Type.Inner.value`) has the wrong root: the base must be a bare identifier.
    func testFailClosedNestedStaticDoesNotTypeTheField() throws {
        let by = try scan("""
        import Foundation
        final class Outer {
            enum Inner { static let shared = Outer() }
            func go() { _ = FileManager.default.contents(atPath: "/tmp/x") }
        }
        final class User {
            let o = Outer.Inner.shared
            func run() { o.go() }
        }
        User().run()
        """)
        XCTAssertNil(ProcessHarness.inferred(by, "User.run"),
                     "the root of `Outer.Inner.shared` is not `Outer` as far as this rule can prove")
    }

    /// A lowercase base is a VALUE, not a type — `config.shared` says nothing about a type name.
    func testFailClosedLowercaseBaseDoesNotTypeTheField() throws {
        let by = try scan("""
        import Foundation
        final class Registry { func go() { _ = FileManager.default.contents(atPath: "/tmp/x") } }
        let registry = Registry()
        final class User {
            let r = registry
            func run() { r.go() }
        }
        User().run()
        """)
        XCTAssertNil(ProcessHarness.inferred(by, "User.run"))
    }

    // ── THE GAINS ───────────────────────────────────────────────────────────────────────────────────

    /// THE DEFECT THAT MOTIVATED THIS. A stored `URLSession` performed network I/O and the whole function
    /// was absent from the report.
    func testSingletonURLSessionFieldReachesNet() throws {
        let by = try scan("""
        import Foundation
        final class Client {
            private let session = URLSession.shared
            func fetch() {
                let t = session.dataTask(with: URL(string: "https://api.segment.io/v1/track")!) { _, _, _ in }
                t.resume()
            }
        }
        Client().fetch()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Client.fetch"), ["Net"],
                       "a stored URLSession performs Net — it was reported as pure")
        XCTAssertEqual(by["Client.fetch"]?["hosts"] as? [String], ["api.segment.io"],
                       "and the locator mechanisms then reach it")
    }

    /// `FileManager.default` — the same shape on the filesystem surface.
    func testSingletonFileManagerFieldReachesFs() throws {
        let by = try scan("""
        import Foundation
        final class Cache {
            private let fm = FileManager.default
            func purge() { try? fm.removeItem(atPath: "/tmp/cache") }
        }
        Cache().purge()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Cache.purge"), ["Fs"])
    }

    /// A LOCAL singleton type: `MyStore.shared` resolves to the project's own unit and its real effects.
    /// This is the pollen shape — a SwiftUI view holding a store that persists to disk read pure.
    func testLocalSingletonFieldReachesItsUnitEffects() throws {
        let by = try scan("""
        import Foundation
        final class Store {
            static let shared = Store()
            func save() { try? Data().write(to: URL(fileURLWithPath: "/tmp/store.json")) }
        }
        struct Card {
            private var store = Store.shared
            func tap() { store.save() }
        }
        Card().tap()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Card.tap"), ["Fs"],
                       "the view reaches the store's disk write through the singleton field")
    }

    /// A locally-DECLARED type of the same name still shadows the platform one, as everywhere else.
    func testLocalTypeShadowsThePlatformSingleton() throws {
        let by = try scan("""
        import Foundation
        final class URLSession { static let shared = URLSession(); func dataTask(with s: String) {} }
        final class Client {
            private let session = URLSession.shared
            func fetch() { session.dataTask(with: "https://api.segment.io/v1/track") }
        }
        Client().fetch()
        """)
        XCTAssertNil(ProcessHarness.inferred(by, "Client.fetch"),
                     "the project's own URLSession has a pure dataTask — never the platform effect")
    }
}
