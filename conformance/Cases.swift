// Cross-impl conformance fixtures (Swift) — mirrors candor-spec's rust/java/ts Cases with the SAME
// intended effects; the Part-1 oracle (expected.json) is the pass/fail target, like every engine.
import Foundation

// --- direct vocabulary ------------------------------------------------------------------------------
func fs_read() { _ = FileManager.default.contents(atPath: "/tmp/x") }
func net_connect() { _ = URLSession.shared.dataTask(with: URL(string: "http://example.com")!) }
func exec_spawn() { _ = Process() }
func env_read() { _ = ProcessInfo.processInfo.environment["PATH"] }
func clock_now() { _ = Date() }
func pure_fn() -> Int { 1 + 2 }

// --- the trust contract: an unanalysable call is Unknown --------------------------------------------
struct Dyn { let f: () -> Void }
func unknown_dyn(_ d: Dyn) { d.f() }

// --- composition: union + transitive propagation ----------------------------------------------------
func combined() { _ = FileManager.default.contents(atPath: "/tmp/x"); _ = URLSession.shared.dataTask(with: URL(string: "http://h")!) }
func transitive_leaf() { _ = FileManager.default.contents(atPath: "/tmp/x") }
func transitive_caller() { transitive_leaf() }

// --- effect inside a locally-invoked closure flows to the enclosing fn -------------------------------
func closure_effect() {
    let f = { _ = FileManager.default.contents(atPath: "/tmp/x") }
    f()
}

// --- Unknown propagates across a call like any other effect -----------------------------------------
func unknown_propagates(_ d: Dyn) { unknown_dyn(d) }
func mixed_unknown(_ d: Dyn) { _ = FileManager.default.contents(atPath: "/tmp/x"); d.f() }

// --- multi-hop propagation ---------------------------------------------------------------------------
func hop_c() { _ = URLSession.shared.dataTask(with: URL(string: "http://h")!) }
func hop_b() { hop_c() }
func hop_a() { hop_b() }

// --- union of two callees ----------------------------------------------------------------------------
func union_b() { _ = FileManager.default.contents(atPath: "/tmp/x") }
func union_c() { _ = URLSession.shared.dataTask(with: URL(string: "http://h")!) }
func union_a() { union_b(); union_c() }

// --- recursion: the fixpoint terminates and keeps the effect -----------------------------------------
func recurse(_ n: Int) {
    _ = ProcessInfo.processInfo.environment["HOME"]
    if n > 0 { recurse(n - 1) }
}

// --- conditional: branch effects over-approximate ----------------------------------------------------
func conditional(_ b: Bool) { if b { _ = Process() } }

// --- transitive purity (negative case) ---------------------------------------------------------------
func pure_b() -> Int { 21 }
func pure_a() -> Int { pure_b() * 2 }

// --- method dispatch via a typed receiver ------------------------------------------------------------
struct Svc {
    func act() { _ = FileManager.default.contents(atPath: "/tmp/x") }
}
func method_call(_ s: Svc) { s.act() }

// --- scheduler attribution: an effect inside a scheduled closure attributes to the SCHEDULER ---------
func sched() {
    DispatchQueue.global().async { _ = FileManager.default.contents(atPath: "/tmp/x") }
}
