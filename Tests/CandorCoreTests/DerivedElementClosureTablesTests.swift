import Foundation
import XCTest
@testable import CandorCore

/// SOUNDNESS R791 — the element-closure tables are DERIVED from the stdlib, and this is the derivation, re-run
/// against the toolchain on the machine running the suite. An inclusion list for a TYPING fact fails SILENT for
/// every method it forgets (`count(where:)` was the measured one), so a method the stdlib adds and the tables do
/// not cover must FAIL here rather than be rediscovered as a silent row.
///
/// The parse is deliberately the same coarse one the tables were built from: every `public func NAME(…)` line
/// whose parameter list holds a closure type taking `Element`/`Self.Element` (or a dictionary's `Value`) at some
/// position. Underscored (SPI) names are skipped. Skipped outright when no SDK interface is present (Linux CI).
final class DerivedElementClosureTablesTests: XCTestCase {
    private func interfaceText() throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { throw XCTSkip("no xcrun") }
        p.waitUntilExit()
        let sdk = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = URL(fileURLWithPath: sdk).appendingPathComponent("usr/lib/swift/Swift.swiftmodule")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let f = files.filter({ $0.hasSuffix(".swiftinterface") && $0.contains("macos") }).sorted().first
        else { throw XCTSkip("no Swift.swiftinterface under \(dir.path)") }
        return try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    }

    func testEveryStdlibElementClosureIsCovered() throws {
        let text = try interfaceText()
        let fnRe = try NSRegularExpression(pattern: #"\bfunc ([A-Za-z]\w*)\s*(?:<[^>]*>)?\s*\((.*)"#)
        let closureRe = try NSRegularExpression(
            pattern: #"\(([^()]*)\)\s*(?:async\s+)?(?:throws(?:\([^)]*\))?\s+)?(?:rethrows\s+)?->"#)
        var missing: [String] = []
        var seen = 0
        for line in text.split(separator: "\n") {
            let s = String(line); let ns = s as NSString
            guard let m = fnRe.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            let name = ns.substring(with: m.range(at: 1)), params = ns.substring(with: m.range(at: 2))
            let pns = params as NSString
            for cm in closureRe.matches(in: params, range: NSRange(location: 0, length: pns.length)) {
                let inner = pns.substring(with: cm.range(at: 1)).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: #"^(?:_\s+\w+\s*:\s*|inout\s+)"#, with: "", options: .regularExpression)
                }
                for (i, t) in inner.enumerated() {
                    let isElem = ["Element", "Self.Element", "Self.Iterator.Element"].contains(t)
                    let isValue = t == "Value"
                    guard isElem || isValue else { continue }
                    seen += 1
                    let covered: Bool
                    if isValue {
                        covered = STDLIB_DICT_VALUE_CLOSURE[name]?.contains(i) == true
                            || (i == 0 && ["map", "filter", "first", "forEach", "flatMap"].contains(name))
                    } else {
                        covered = STDLIB_ELEMENT_CLOSURE_PAIR.contains(name)
                            || STDLIB_ELEMENT_CLOSURE_INDEX[name] == i
                            || (i == 0 && STDLIB_ELEMENT_CLOSURE_FIRST.contains(name))
                    }
                    if !covered { missing.append("\(name)#\(i)\(isValue ? "(Value)" : "")") }
                }
            }
        }
        XCTAssertGreaterThan(seen, 30, "the derivation found almost nothing — the parse, not the tables, is broken")
        XCTAssertEqual(Set(missing).sorted(), [],
                       "stdlib methods whose closure takes the element at a position the tables do not cover")
    }
}
