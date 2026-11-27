import Foundation
import App
import Guess
let base = CommandLine.arguments[1]
try? FileManager.default.removeItem(atPath: base); try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
func run(_ name: String, _ f: (String) -> Void) { let p = "\(base)/\(name)"; f(p); print(name, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
let m = Msg()
run("Msg.s_bare") { m.s_bare($0) }; run("Msg.s_self") { m.s_self($0) }; run("Msg.s_let") { m.s_let($0) }
run("Msg.s_pure") { _ = m.s_pure($0) }; run("Msg.s_own") { m.s_own($0) }; run("Msg.s_ownpure") { _ = m.s_ownpure($0) }
run("Msg.s_nest") { m.s_nest($0) }; run("Msg.s_init") { m.s_init($0) }; run("Msg.s_gen") { m.s_gen($0) }
run("Msg.s_opt") { m.s_opt($0) }; run("Msg.s_comp") { m.s_comp($0) }; run("Msg.s_fac") { m.s_fac($0) }; run("Msg.s_kind") { m.s_kind($0) }
run("Msg.s_shadow_local") { _ = m.s_shadow_local($0) }; run("Msg.s_shadow_param") { _ = m.s_shadow_param(Guess.DepPure(), $0) }
run("Msg.s_closure") { m.s_closure($0) }; run("Msg.s_ext") { m.s_ext($0) }
run("Derived.s_inherit") { Derived().s_inherit($0) }; run("DerivedDep.s_inheritdep") { DerivedDep().s_inheritdep($0) }
run("GenOwner.s_genowner") { GenOwner<Int>().s_genowner($0) }
run("Msg.s_dkind") { m.s_dkind($0) }; run("Msg.s_mk") { m.s_mk($0) }
run("ODerived.s_oinh") { ODerived().s_oinh($0) }; run("ODerived.s_ainh") { ODerived().s_ainh($0) }; run("ODerived.s_qinh") { ODerived().s_qinh($0) }; run("ODerived.s_qinh_self") { ODerived().s_qinh_self($0) }
run("Msg.s_iuo") { m.s_iuo($0) }; run("Msg.s_iuo_self") { m.s_iuo_self($0) }; run("Msg.s_iuo_pure") { _ = m.s_iuo_pure($0) }
run("Msg.s_b1") { m.s_b1($0) }; run("Msg.s_b2") { m.s_b2($0) }; run("Msg.s_b3") { m.s_b3($0) }; run("Msg.s_b3_tc") { m.s_b3_tc($0) }
