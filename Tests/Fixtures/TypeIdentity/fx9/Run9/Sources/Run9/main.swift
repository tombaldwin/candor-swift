import Foundation
import Use9
let dir = CommandLine.arguments[1]
// WRITES: the cell created its marker file. TOUCHES: the cell returned true (it reached the platform's stat and saw it throw). pure: neither.
func cell(_ n: String, _ f: (String) throws -> Bool = { _ in false }) {
    let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p)
    let touched = (try? f(p)) ?? false
    print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : (touched ? "TOUCHES" : "pure"))
}
let u = U9(), uf = UF9()
cell("U9.s1s12_ann") { try u.s1s12_ann($0); return false }
cell("U9.s1s12_ctor") { try u.s1s12_ctor($0); return false }
cell("U9.s1s12_inline") { try u.s1s12_inline($0); return false }
cell("U9.s12_url_ann") { u.s12_url_ann($0) }
cell("U9.s12_url_ctor") { u.s12_url_ctor($0) }
cell("U9.s12_result_get") { _ in _ = u.s12_result_get(); return false }
cell("UF9.s12_file_ann") { try uf.s12_file_ann($0); return false }
cell("UF9.s12_file_ctor") { try uf.s12_file_ctor($0); return false }
cell("UF9.live") { uf.live($0); return false }
