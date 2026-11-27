import Foundation
import App
import Guess
let base = CommandLine.arguments[1]
try? FileManager.default.removeItem(atPath: base); try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
func run(_ name: String, _ f: (String) -> Void) { let p = "\(base)/\(name)"; f(p); print(name, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
let m = Msg()
run("Msg.c_coll") { m.c_coll($0) }; run("Msg.c_coll_self") { m.c_coll_self($0) }; run("Msg.c_own") { _ = m.c_own($0) }
run("Msg.c_cv") { m.c_cv($0) }; run("Msg.c_mk") { m.c_mk($0) }; run("Msg.c_ta") { m.c_ta($0) }; run("Msg.c_bare") { m.c_bare($0) }
run("Msg.c_static") { m.c_static($0) }; run("Msg.c_static_self") { m.c_static_self($0) }
run("Msg.c_ext_noimport") { m.c_ext_noimport($0) }; run("Msg.c_ext_coll") { m.c_ext_coll($0) }
let m2 = Msg2()
run("Msg2.c_tcoll") { m2.c_tcoll($0) }; run("Msg2.c_tcoll_self") { m2.c_tcoll_self($0) }; run("Msg2.c_acoll") { m2.c_acoll($0) }
run("Msg2.c_ann_bare") { m2.c_ann_bare($0) }; run("Msg2.c_local_mk") { m2.c_local_mk($0) }
run("Msg2.c_ann_noimport") { m2.c_ann_noimport($0) }; run("Msg2.c_tcoll_noimport") { m2.c_tcoll_noimport($0) }
let m3 = Msg3()
run("Msg3.c_reexport") { m3.c_reexport($0) }; run("Msg3.c_reexport_ext") { m3.c_reexport_ext($0) }
run("Msg3.c_aliascoll") { m3.c_aliascoll($0) }; run("Msg3.c_genalias") { m3.c_genalias($0) }
run("Msg3.c_scoped_import") { m3.c_scoped_import($0) }; run("GBox.c_genparam") { GBox<Int>().c_genparam($0) }
