import Foundation
import ToolA
import ToolB
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("TA.a_data_ann") { try TA().a_data_ann($0) }
cell("TA.a_data_ctor") { try TA().a_data_ctor($0) }
cell("TB.b_data_ann") { try TB().b_data_ann($0) }
cell("TB.b_data_ctor") { try TB().b_data_ctor($0) }
cell("TB.b_own_nested") { TB().b_own_nested($0) }
