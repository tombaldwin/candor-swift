import Foundation
import Feat25
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("UB25.ext_twin") { UB25().ext_twin($0) }
cell("UB25.ext_twin_quiet") { _ = UB25().ext_twin_quiet($0) }
cell("UB25.field") { UB25().field($0) }
cell("L25.live") { L25().live($0) }
