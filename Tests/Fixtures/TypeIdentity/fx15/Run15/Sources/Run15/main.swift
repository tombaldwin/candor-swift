import Foundation
import Own15
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("Outer15.a_pure") { Outer15().a_pure($0) }
cell("Outer15.a_loud") { Outer15().a_loud($0) }
cell("Plain15.p_data") { try Plain15().p_data($0) }
