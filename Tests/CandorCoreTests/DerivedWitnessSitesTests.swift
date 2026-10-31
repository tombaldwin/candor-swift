import Foundation
import XCTest

/// CALL-TARGET ROUND 2 — the witness SITE table (`STDLIB_WITNESS_SITES`, which platform member runs a user type's
/// `==` / `<` / `hash(into:)`) is DERIVED from the SDK by tools/gen-stdlib-conformances.py, and this test derives it
/// AGAIN, independently (its own parse, in Swift, sharing no code with the generator), against the toolchain on the
/// machine running the suite. The release recognised these sites from four hand lists and every member a list forgot
/// was a silent row (`a.sort()`, the free `max(a, b)` — executed, calltarget matrix H09/H11); a member the SDK adds
/// and the table lacks must FAIL here instead.
///
/// The test target cannot import the executable target, so the checked-in table is read as SOURCE TEXT from
/// `Sources/candor-swift/StdlibConformances.swift`. Skipped where no SDK interface exists (Linux CI).
final class DerivedWitnessSitesTests: XCTestCase {
    private func interface(_ module: String) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { throw XCTSkip("no xcrun") }
        p.waitUntilExit()
        let sdk = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = URL(fileURLWithPath: sdk).appendingPathComponent("usr/lib/swift/\(module).swiftmodule")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let f = files.filter({ $0.hasSuffix(".swiftinterface") && $0.contains("macos") }).sorted().first
        else { throw XCTSkip("no \(module).swiftinterface under \(dir.path)") }
        return try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    }

    /// The checked-in table, parsed from source: `"seq.sort": ["<"],` lines between the declaration and its `]`.
    private func checkedInTable() throws -> [String: Set<String>] {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/candor-swift/StdlibConformances.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        guard let start = text.range(of: "let STDLIB_WITNESS_SITES: [String: [String]] = [") else {
            XCTFail("STDLIB_WITNESS_SITES is missing from StdlibConformances.swift"); return [:]
        }
        var out: [String: Set<String>] = [:]
        let entry = try NSRegularExpression(pattern: #"^\s*"([a-z]+\.[A-Za-z]\w*)": \[(.*)\],$"#)
        for line in text[start.upperBound...].split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("]") { break }
            let ns = s as NSString
            guard let m = entry.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            out[ns.substring(with: m.range(at: 1))] = Set(ns.substring(with: m.range(at: 2))
                .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) })
        }
        return out
    }

    func testEveryPlatformWitnessSiteIsInTheTable() throws {
        let table = try checkedInTable()
        let seqFamily: Set<String> = ["Sequence", "Collection", "BidirectionalCollection", "MutableCollection",
                                      "RangeReplaceableCollection", "RandomAccessCollection", "Array", "ArraySlice",
                                      "ContiguousArray"]
        let protos: [(String, [String])] = [("Equatable", ["=="]), ("Comparable", ["<"]), ("Hashable", ["hash", "=="])]
        let closure = try NSRegularExpression(pattern: #"\([^()]*\)\s*(?:async\s+)?(?:throws(?:\([^)]*\))?\s+)?(?:rethrows\s+)?->"#)
        func hasClosure(_ s: String) -> Bool {
            closure.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        /// The balanced parameter clause after the declared name (generic clause skipped), so a RETURN arrow
        /// (`sorted() -> [Element]`) is never read as a closure parameter.
        func paramClause(_ rest: Substring) -> String {
            guard let open = rest.firstIndex(of: "(") else { return "" }
            var depth = 0, i = open
            while i < rest.endIndex {
                let c = rest[i]
                if c == "(" || c == "[" { depth += 1 }
                if c == ")" || c == "]" { depth -= 1; if depth == 0 { break } }
                i = rest.index(after: i)
            }
            return String(rest[rest.index(after: open)..<min(i, rest.endIndex)])
        }
        /// Module qualification is `Swift::Sequence` in a 27.x SDK's interface and `Swift.Sequence` in the older SDK on
        /// CI's macos-15 (where the `::`-only strip left every `extension Swift.X` unparsed: 3 sites, not ~100).
        func unqualify(_ s: String) -> String {
            s.replacingOccurrences(of: #"\b\w+::"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\b(?:Swift|_StringProcessing|_Concurrency)\."#, with: "", options: .regularExpression)
        }
        var expected: [String: Set<String>] = [:]
        for module in ["Swift", "_StringProcessing"] {
            var owner: String? = nil, whereClause = ""
            for raw in try interface(module).split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                if !line.hasPrefix(" "), !line.isEmpty {
                    owner = nil; whereClause = ""
                    // `extension Swift::Sequence where Self.Element : Swift::Equatable {` / `public struct Set<Element> … {`
                    let unq = unqualify(line)
                    if line.hasSuffix("{"), let r = unq.range(of: #"^(?:@\S+\s+)*extension (\w+)\b"#, options: .regularExpression) {
                        let name = String(unq[r].split(separator: " ").last!)
                        if !unq[r.upperBound...].hasPrefix(".") { owner = name; whereClause = String(unq[r.upperBound...]) }
                    } else if line.hasSuffix("{"), let r = unq.range(of: #"public struct (Set|Dictionary)<"#, options: .regularExpression) {
                        owner = unq[r].contains("Set") ? "Set" : "Dictionary"; whereClause = String(unq[r.upperBound...])
                    } else if let r = unq.range(of: #"public func [a-z]\w*<T>\("#, options: .regularExpression),
                              !hasClosure(paramClause(unq[unq.index(before: r.upperBound)...])),
                              paramClause(unq[unq.index(before: r.upperBound)...]).range(of: #":\s*T\b"#, options: .regularExpression) != nil {
                        let name = String(unq[r].dropFirst("public func ".count).prefix { $0 != "<" })
                        // `T` ITSELF bound (`where T : Comparable`, `T : Comparable & SignedNumeric`) — not a member of
                        // it (`pointwiseMax`'s `T.Scalar : Comparable` compares the vector's scalars, never `T`).
                        for (p, ws) in protos where unq.range(of: #"(?<![.\w])T\s*:\s*[^,{]*\b"# + p, options: .regularExpression) != nil {
                            expected["free.\(name)", default: []].formUnion(ws)
                        }
                    }
                    continue
                }
                guard let o = owner, line.hasPrefix("  "), !line.hasPrefix("   "), !line.contains("unavailable"),
                      let fr = line.range(of: #"\bpublic (?:\w+ )*func ([A-Za-z]\w*)"#, options: .regularExpression)
                else { continue }
                let name = String(line[fr].split(separator: " ").last!)
                let params = paramClause(line[fr.upperBound...])
                guard !hasClosure(params) else { continue }
                if seqFamily.contains(o) {
                    for (p, ws) in protos where whereClause.range(of: #"Element\s*:\s*"# + p + #"\b"#, options: .regularExpression) != nil {
                        expected["seq.\(name)", default: []].formUnion(ws)
                    }
                }
                let unqParams = unqualify(params)
                if o == "Set", unqParams.range(of: #":\s*(?:__owned\s+|consuming\s+)?(?:Element|Set<Element>|Self|S)\b"#, options: .regularExpression) != nil {
                    expected["set.\(name)", default: []].formUnion(["hash", "=="])
                }
                if o == "Dictionary", unqParams.range(of: #":\s*(?:__owned\s+)?Key\b"#, options: .regularExpression) != nil {
                    expected["dict.\(name)", default: []].formUnion(["hash", "=="])
                }
            }
        }
        XCTAssertGreaterThan(expected.count, 25, "the derivation found almost nothing — the parse, not the table, is broken")
        var missing: [String] = []
        for (k, ws) in expected where !(table[k].map { ws.isSubset(of: $0) } ?? false) {
            missing.append("\(k) \(ws.sorted())")
        }
        XCTAssertEqual(missing.sorted(), [], "platform witness sites the checked-in table lacks — regenerate it")
    }

    /// The release's four hand lists, kept HERE ONLY as a floor (the engine no longer has them): every member the
    /// release recognised is still a site, so the derivation can only widen what the engine charged.
    func testTheReleaseHandListsAreAFloor() throws {
        let table = try checkedInTable()
        let floor: [String: [String]] = [
            "<": ["seq.sorted", "seq.max", "seq.min"],
            "==": ["seq.contains", "seq.firstIndex", "seq.lastIndex", "seq.elementsEqual", "seq.starts", "seq.split"],
            "hash": ["set.insert", "set.contains", "set.remove", "set.update", "set.union", "set.formUnion",
                     "set.intersection", "set.formIntersection", "set.subtracting", "set.subtract",
                     "set.symmetricDifference", "set.formSymmetricDifference", "set.isSubset", "set.isSuperset",
                     "set.isDisjoint", "set.isStrictSubset", "set.isStrictSuperset",
                     "dict.updateValue", "dict.removeValue", "dict.index"],
        ]
        for (w, keys) in floor { for k in keys { XCTAssertTrue(table[k]?.contains(w) == true, "\(k) lost \(w)") } }
    }
}
