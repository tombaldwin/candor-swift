import Foundation
import Own19
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("Parsed19.resp_init") { _ = Parsed19().resp_init($0) }
cell("Parsed19.resp_make") { _ = Parsed19().resp_make($0) }
cell("Parsed19.resp_plain") { _ = Parsed19().resp_plain($0) }
cell("Parsed19.resp_quiet") { _ = Parsed19().resp_quiet($0) }
