import Foundation
import Own20
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("U20.alias_generic") { _ = U20().alias_generic($0) }
cell("U20.alias_plain") { _ = U20().alias_plain($0) }
cell("U20.direct") { _ = U20().direct($0) }
cell("U20.alias_quiet") { _ = U20().alias_quiet($0) }
