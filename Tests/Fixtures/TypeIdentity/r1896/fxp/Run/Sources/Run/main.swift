import Foundation
import App
let base = CommandLine.arguments[1]
try? FileManager.default.removeItem(atPath: base); try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
func run(_ name: String, _ f: (String) -> Void) { let p = "\(base)/\(name)"; f(p); print(name, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
run("GBox2.c_genparam2") { GBox2<Int>().c_genparam2($0) }
let m = Msg4(); run("Msg4.c_platname") { m.c_platname($0) }; run("Msg4.c_ctrl") { m.c_ctrl($0) }
