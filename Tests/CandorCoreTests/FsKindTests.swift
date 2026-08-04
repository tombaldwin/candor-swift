import XCTest
@testable import CandorCore

/// SPEC §2 `fs` — the read/write refinement of a PROVED `Fs`.
///
/// The field's whole discipline is the empty case: *"when `Fs` is reached but its kind is unknown … the
/// field MUST be omitted rather than guessed. An empty or partial `fs` would be read as a positive claim
/// ('reads but never writes'), which is the §4 trust contract's forbidden direction."* So most of what
/// these assert is what the classifier REFUSES to say.
final class FsKindTests: XCTestCase {

    func testWriteVerbs() {
        for m in ["createFile", "removeItem", "createDirectory", "createSymbolicLink", "write",
                  "writeToFile", "trashItem"] {
            XCTAssertEqual(fsKind(root: "FileManager", member: m), ["write"], "\(m) mutates the disk")
        }
    }

    func testReadVerbs() {
        for m in ["contents", "contentsOfDirectory", "attributesOfItem", "fileExists",
                  "destinationOfSymbolicLink", "contentsEqual", "readToEnd"] {
            XCTAssertEqual(fsKind(root: "FileManager", member: m), ["read"], "\(m) observes without mutating")
        }
    }

    /// A two-locator copy reads the source AND writes the destination — one call, both kinds. Matches
    /// candor-java's `Files.copy` arm.
    func testTwoLocatorVerbsAreBoth() {
        for m in ["copyItem", "moveItem", "replaceItem", "replaceItemAt", "linkItem"] {
            XCTAssertEqual(fsKind(root: "FileManager", member: m).sorted(), ["read", "write"])
        }
    }

    /// THE LOAD-BEARING CASE. A verb that does not reveal direction must contribute NOTHING — not a
    /// default, not a guess. Anything here returning a kind would let a function claim "reads but never
    /// writes" on the strength of a verb that said neither.
    func testUnrevealingVerbsMakeNoClaim() {
        for m in ["temporaryDirectory", "urls", "url", "homeDirectoryForCurrentUser",
                  "currentDirectoryPath", "enumerator", "someUnknownFutureVerb"] {
            let k = fsKind(root: "FileManager", member: m)
            XCTAssertTrue(k.isEmpty || k == ["read"],
                          "\(m) must not claim a WRITE it did not reveal (got \(k))")
        }
        XCTAssertEqual(fsKind(root: "FileManager", member: "someUnknownFutureVerb"), [],
                       "an unrecognised verb must say nothing at all")
    }

    /// A FileHandle opened for one direction reveals it in the initializer label; a bare one does not.
    func testFileHandleInitializerLabels() {
        XCTAssertEqual(fsKind(root: "FileHandle", member: "forReadingAtPath"), ["read"])
        XCTAssertEqual(fsKind(root: "FileHandle", member: "forWritingAtPath"), ["write"])
        XCTAssertEqual(fsKind(root: "FileHandle", member: "forUpdatingAtPath"), ["write"])
        XCTAssertEqual(fsKind(root: "FileHandle", member: "<init>"), [],
                       "a bare FileHandle(...) reveals no direction — no claim")
    }
}
