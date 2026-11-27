import Foundation
import Own28
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
for (n, f) in [("U28.trailing_pure", U28().trailing_pure), ("U28.trailing_loud", U28().trailing_loud), ("U28.unlabeled_pure", U28().unlabeled_pure), ("U28.unlabeled_loud", U28().unlabeled_loud), ("U28.defaulted", U28().defaulted), ("U28.variadic", U28().variadic), ("U28.failable", U28().failable), ("U28.generic", U28().generic), ("U28.two_labels", U28().two_labels)] as [(String, (String) -> Void)] { cell(n, f) }
