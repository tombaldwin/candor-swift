#!/usr/bin/env python3
"""candor-swift soundness fuzzer (candor-spec §7.13).

GENERATES Swift packages that thread a KNOWN effect from a sink up through a chain of call forms —
the forms that could hide an edge in Swift: direct calls, local closures, method dispatch via typed
receivers, initializers, nested functions (lexical attribution), scheduled closures
(DispatchQueue.async — the scheduler-attribution rule), protocol dispatch (bounded CHA), a
function-typed parameter invoked (which MUST read Unknown), and a function-typed FIELD invoked
(likewise). Every chain function transitively reaches the effect, so each must be reported with the
effect OR Unknown — a chain function reported pure (or omitted) is a SILENT UNDER-REPORT, the bug
class this exists to catch. The precision twin: a pure bystander must stay OUT of the report.

Teeth (verify per MECHANISM, the §7.13 rule): disabling a resolution mechanism in main.swift —
the closure walk, the protocol CHA, the ctor binding — must make this harness fail.

Run: python3 fuzz.py [N]   (default 25 seeds; deterministic per seed)
"""
import json, os, random, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, ".build", "debug", "candor-swift")

SINKS = {
    "fs":    ('_ = FileManager.default.contents(atPath: "/tmp/x")', "Fs"),
    "net":   ('_ = URLSession.shared.dataTask(with: URL(string: "http://h")!)', "Net"),
    "exec":  ("_ = Process()", "Exec"),
    "env":   ('_ = ProcessInfo.processInfo.environment["P"]', "Env"),
    "clock": ("_ = Date()", "Clock"),
}

# Edge forms: how fn i reaches fn i+1 (or the sink). `unknown` forms must read Unknown in the
# RECEIVING function instead of (or in addition to) the effect.
FORMS = ["direct", "closure", "method", "init_wired", "nested_fn", "sched", "proto", "callback_recv", "fn_field", "computed_prop", "opaque_local", "iter", "for_each", "field_iter", "dict_iter", "subscript_recv", "cast_recv", "field_chain", "enum_bind", "generic_proto", "guard_let", "tuple_recv", "field_subscript", "cast_field", "loop_field_subscript", "deep_nest", "overload_subtype",
         # implicit-call / uncollected-decl holes (the silent-pure soundness fix). NB `deinit_io` is
         # NOT here: a deinit runs at scope-exit with no caller site, so it does not PROPAGATE up the
         # chain (correct — candor can't model dealloc timing). It is appended off-chain every seed and
         # checked via extra_effectful instead.
         "custom_seq", "subscript_access", "static_init", "global_init", "proto_prop", "call_as_function", "operator_overload",
         "default_arg", "dynamic_member", "property_wrapper", "sorted_closure", "predicate_closure"]


def build_deep_nest(rng, i, me, callee):
    """A RANDOM-DEPTH nested receiver: stack 2–4 struct wrappers (plain field or [E] array-field), then
    navigate `v.inner.inner[0]….go()` down to the innermost struct whose go() reaches callee. Each
    wrapper alone is covered by a single form; this checks rootOf threads a type through an arbitrary
    chain of field/subscript indirections at once (the nested-receiver composition class)."""
    depth = rng.randint(2, 4)
    decls = [f"struct E{i}_0 {{ func go() {{ {callee}() }} }}"]
    access, cur = "", f"E{i}_0"
    for d in range(1, depth + 1):
        t = f"E{i}_{d}"
        if rng.random() < 0.5:
            decls.append(f"struct {t} {{ let inner = {cur}() }}")
            access = ".inner" + access
        else:
            decls.append(f"struct {t} {{ let inner: [{cur}] = [{cur}()] }}")
            access = ".inner[0]" + access
        cur = t
    return "\n".join(decls) + f"\nfunc {me}() {{ let v = {cur}(); v{access}.go() }}"


def gen(seed):
    rng = random.Random(seed)
    n = rng.randint(2, 6)
    sink_stmt, sink_eff = SINKS[rng.choice(list(SINKS))]
    fn = lambda i: f"f{i:02d}" if i < n else "sink"
    bodies = [None] * (n + 1)
    forms = []
    expect_unknown = set()
    extra_effectful = set()   # non-chain UNITS (deinit/static/global init) that must carry the effect
    bodies[n] = f"func sink() {{ {sink_stmt} }}"
    for i in range(n - 1, -1, -1):
        me, callee = fn(i), fn(i + 1)
        form = rng.choice(FORMS)
        forms.append(form)
        if form == "direct":
            bodies[i] = f"func {me}() {{ {callee}() }}"
        elif form == "closure":
            bodies[i] = f"func {me}() {{ let c = {{ {callee}() }}; c() }}"
        elif form == "method":
            bodies[i] = (f"struct K{i} {{ func run() {{ {callee}() }} }}\n"
                         f"func {me}() {{ K{i}().run() }}")
        elif form == "init_wired":
            bodies[i] = (f"struct C{i} {{ init() {{ {callee}() }} }}\n"
                         f"func {me}() {{ _ = C{i}() }}")
        elif form == "nested_fn":
            # lexical attribution: the nested fn's body charges the enclosing unit
            bodies[i] = f"func {me}() {{ func inner() {{ {callee}() }}; inner() }}"
        elif form == "sched":
            bodies[i] = f"func {me}() {{ DispatchQueue.global().async {{ {callee}() }} }}"
        elif form == "proto":
            bodies[i] = (f"protocol P{i} {{ func go() }}\n"
                         f"struct I{i}: P{i} {{ func go() {{ {callee}() }} }}\n"
                         f"func via{i}(_ x: P{i}) {{ x.go() }}\n"
                         f"func {me}() {{ via{i}(I{i}()) }}")
        elif form == "callback_recv":
            # the effect reaches `recv` ONLY through a callback param it invokes -> Unknown required
            bodies[i] = (f"func recv{i}(_ cb: () -> Void) {{ cb() }}\n"
                         f"func {me}() {{ recv{i}({{ {callee}() }}) }}")
            expect_unknown.add(f"recv{i}")
        elif form == "computed_prop":
            # the accessor hole: a computed GETTER's body must be a unit, and reading the
            # property must edge to it
            bodies[i] = (f"struct G{i} {{ var v: Int {{ {callee}(); return 1 }} }}\n"
                         f"func {me}() {{ _ = G{i}().v }}")
        elif form == "property_wrapper":
            # the @propertyWrapper desugar hole: reading `s.p` runs `_p.wrappedValue`, whose body
            # reaches the callee. Pre-fix the wrapped-property read was silently pure (the access is
            # neither a call nor a computed-property unit ON the wrapped type — the edge must go to the
            # WRAPPER's wrappedValue accessor).
            bodies[i] = (f"@propertyWrapper struct W{i} {{ let s: Int; init(wrappedValue: Int) {{ s = wrappedValue }}\n"
                         f"  var wrappedValue: Int {{ {callee}(); return s }} }}\n"
                         f"struct PW{i} {{ @W{i} var p: Int = 0 }}\n"
                         f"func {me}() {{ _ = PW{i}().p }}")
        elif form == "fn_field":
            bodies[i] = (f"struct D{i} {{ let f: () -> Void }}\n"
                         f"func hold{i}(_ d: D{i}) {{ d.f() }}\n"
                         f"func {me}() {{ hold{i}(D{i}(f: {{ {callee}() }})) }}")
            expect_unknown.add(f"hold{i}")
        elif form == "iter":
            # the effect reaches `callee` only through a `for x in xs` over a typed [E] collection —
            # the loop variable must carry the element type or its `x.go()` drops to pure.
            bodies[i] = (f"struct E{i} {{ func go() {{ {callee}() }} }}\n"
                         f"func {me}() {{ let xs: [E{i}] = [E{i}()]; for x in xs {{ x.go() }} }}")
        elif form == "sorted_closure":
            # a NON-whitelisted element-closure HOF: `xs.sorted { $0.go2() < $1.go2() }`. The closure's
            # params are BOTH the receiver element; pre-fix only the 8-method whitelist typed `$0`, so a
            # `sorted`/`min`/`max` (pair) or `drop`/`firstIndex` (single) closure left `$0`/`$1` untyped and
            # the effectful member call went silent-pure. `go2` returns Int so it composes in the predicate.
            bodies[i] = (f"struct So{i} {{ func go2() -> Int {{ {callee}(); return 0 }} }}\n"
                         f"func {me}() {{ let xs: [So{i}] = [So{i}(), So{i}()]; _ = xs.sorted {{ $0.go2() < $1.go2() }} }}")
        elif form == "predicate_closure":
            # single-element predicate HOF (`drop(while:)`/`firstIndex(where:)`): `$0` is the element.
            bodies[i] = (f"struct Pr{i} {{ func ok() -> Bool {{ {callee}(); return true }} }}\n"
                         f"func {me}() {{ let xs: [Pr{i}] = [Pr{i}()]; _ = xs.firstIndex {{ $0.ok() }} }}")
        elif form == "for_each":
            # same, through a `xs.forEach {{ x in x.go() }}` closure (the element-param typing path)
            bodies[i] = (f"struct F{i} {{ func go() {{ {callee}() }} }}\n"
                         f"func {me}() {{ let xs: [F{i}] = [F{i}()]; xs.forEach {{ x in x.go() }} }}")
        elif form == "field_iter":
            # iterate a STORED [E] field — `for x in self.items` types x from the field's element type
            bodies[i] = (f"struct E{i} {{ func go() {{ {callee}() }} }}\n"
                         f"struct H{i} {{ let xs: [E{i}] = [E{i}()]; func run() {{ for x in xs {{ x.go() }} }} }}\n"
                         f"func {me}() {{ H{i}().run() }}")
        elif form == "dict_iter":
            # iterate a [K: V] — `for (k, v) in m` types v from the dictionary's value type
            bodies[i] = (f"struct V{i} {{ func go() {{ {callee}() }} }}\n"
                         f"func {me}() {{ let m: [String: V{i}] = [:]; for (_, v) in m {{ v.go() }} }}")
        elif form == "subscript_recv":
            # `xs[0].go()` — an array subscript yields the element type as the receiver
            bodies[i] = (f"struct S{i} {{ func go() {{ {callee}() }} }}\n"
                         f"func {me}() {{ let xs: [S{i}] = [S{i}()]; xs[0].go() }}")
        elif form == "cast_recv":
            # `(x as! T).go()` — the cast names the receiver type
            bodies[i] = (f"struct A{i} {{ func go() {{ {callee}() }} }}\n"
                         f"func {me}() {{ let x: Any = A{i}(); (x as! A{i}).go() }}")
        elif form == "field_chain":
            # `self.field.go()` — resolve the method on the FIELD's type, not the enclosing type
            bodies[i] = (f"struct E{i} {{ func go() {{ {callee}() }} }}\n"
                         f"struct W{i} {{ let e = E{i}(); func run() {{ self.e.go() }} }}\n"
                         f"func {me}() {{ W{i}().run() }}")
        elif form == "generic_proto":
            # `func via<T: P>(x: T) { x.go() }` — a protocol-bounded generic dispatches like a P param
            bodies[i] = (f"protocol P{i} {{ func go() }}\n"
                         f"struct I{i}: P{i} {{ func go() {{ {callee}() }} }}\n"
                         f"func via{i}<T: P{i}>(_ x: T) {{ x.go() }}\n"
                         f"func {me}() {{ via{i}(I{i}()) }}")
        elif form == "tuple_recv":
            # `p.0.go()` — a tuple element is typed by position; the receiver resolves
            bodies[i] = (f"struct T{i} {{ func go() {{ {callee}() }} }}\n"
                         f"func {me}() {{ let p: (T{i}, Int) = (T{i}(), 1); p.0.go(); _ = p.1 }}")
        elif form == "guard_let":
            # `guard let y = factory() else {…}; y.go()` — type the unwrapped binding from the factory
            bodies[i] = (f"struct G{i} {{ func go() {{ {callee}() }} }}\n"
                         f"func make{i}() -> G{i}? {{ G{i}() }}\n"
                         f"func {me}() {{ guard let y = make{i}() else {{ return }}; y.go() }}")
        elif form == "enum_bind":
            # `case .cN(let x): x.go()` — type the binding from the enum case's associated value type.
            # The case name is unique per instance (a name reused across enums is ambiguous → unbound).
            bodies[i] = (f"struct P{i} {{ func go() {{ {callee}() }} }}\n"
                         f"enum N{i} {{ case c{i}(P{i}) }}\n"
                         f"func {me}() {{ let n = N{i}.c{i}(P{i}()); switch n {{ case .c{i}(let x): x.go() }} }}")
        elif form == "deep_nest":
            bodies[i] = build_deep_nest(rng, i, me, callee)
        elif form == "overload_subtype":
            # SUBTYPE-BLIND OVERLOAD hole (the silent-pure cardinal violation): two same-name overloads
            # on `Snk{i}` — `handle(_: An{i})` (a protocol param) reaches the effect, and a PURE sibling
            # `handle(_: Int)`. The call passes a CONCRETE conformer (`Dg{i}: An{i}`), so its static arg
            # type is `Dg{i}`, a strict subtype of the param `An{i}`. A raw `"Dg{i}" != "An{i}"` string
            # mismatch excludes the effectful overload and, with no sibling matching, DROPS the edge → the
            # caller comes back SILENTLY PURE. Subtype-aware matching must keep the effectful overload, so
            # `me` reads the effect (or Unknown). Randomly pick base-class vs protocol conformer to also
            # cover the class-inheritance arm of the subtype index.
            if rng.random() < 0.5:
                supertype = (f"protocol An{i} {{ func speak() }}\n"
                             f"struct Dg{i}: An{i} {{ func speak() {{}} }}")
            else:
                supertype = (f"class An{i} {{ func speak() {{}} }}\n"
                             f"class Dg{i}: An{i} {{ override func speak() {{}} }}")
            bodies[i] = (f"{supertype}\n"
                         f"struct Snk{i} {{\n"
                         f"    func handle(_ a: An{i}) {{ {callee}() }}\n"
                         f"    func handle(_ n: Int) {{ _ = n }}\n"
                         f"}}\n"
                         f"func {me}() {{ let d = Dg{i}(); Snk{i}().handle(d) }}")
        elif form == "field_subscript":
            # NESTED receiver: `h.xs[0].go()` — a [E] FIELD of a typed local, then a subscript. Each
            # indirection works alone; this checks rootOf threads the type through both at once.
            bodies[i] = (f"struct E{i} {{ func go() {{ {callee}() }} }}\n"
                         f"struct H{i} {{ let xs: [E{i}] = [E{i}()] }}\n"
                         f"func {me}() {{ let h = H{i}(); h.xs[0].go() }}")
        elif form == "cast_field":
            # NESTED: `(x as! H).e.go()` — a cast, then a field-chain through the cast result.
            bodies[i] = (f"struct E{i} {{ func go() {{ {callee}() }} }}\n"
                         f"struct H{i} {{ let e = E{i}() }}\n"
                         f"func {me}() {{ let x: Any = H{i}(); (x as! H{i}).e.go() }}")
        elif form == "loop_field_subscript":
            # NESTED: `for h in hs {{ h.xs[0].go() }}` — loop var typed, then its [E] field, then subscript.
            bodies[i] = (f"struct E{i} {{ func go() {{ {callee}() }} }}\n"
                         f"struct H{i} {{ let xs: [E{i}] = [E{i}()] }}\n"
                         f"func {me}() {{ let hs: [H{i}] = [H{i}()]; for h in hs {{ h.xs[0].go() }} }}")
        elif form == "opaque_local":
            # `me` reaches the sink ONLY by invoking a closure pulled from an opaque global slot —
            # no lexical closure in `me`, no edge. A fn-typed LOCAL whose origin is indeterminate is
            # §4 Unknown (distinct from callback_recv's fn-typed PARAM). The wiring closure is
            # charged to setup{i}, off-chain. Regression guard for the dropped-Unknown soundness hole.
            bodies[i] = (f"var slot{i}: (() -> Void)? = nil\n"
                         f"func setup{i}() {{ slot{i} = {{ {callee}() }} }}\n"
                         f"func {me}() {{ let cb: () -> Void = slot{i}!; cb() }}")
            expect_unknown.add(me)
        elif form == "custom_seq":
            # HOLE 1 (HIGH): a custom Sequence/IteratorProtocol — `for _ in s` desugars to
            # makeIterator()/next(), an IMPLICIT call. The effect lives in next(); iterating it must
            # reach the effect (else silently pure). UNPINNED receiver: the sequence is a branch-MERGE
            # of two distinct conforming types so candor can't pin a single concrete type from a `new`.
            bodies[i] = (f"struct Sq{i}: Sequence, IteratorProtocol {{\n"
                         f"    func makeIterator() -> Sq{i} {{ self }}\n"
                         f"    mutating func next() -> Int? {{ {callee}(); return nil }}\n"
                         f"}}\n"
                         f"struct Sr{i}: Sequence, IteratorProtocol {{\n"
                         f"    func makeIterator() -> Sr{i} {{ self }}\n"
                         f"    mutating func next() -> Int? {{ {callee}(); return nil }}\n"
                         f"}}\n"
                         f"func pick{i}(_ b: Bool) -> Sq{i} {{ Sq{i}() }}\n"
                         f"func {me}() {{ let s = pick{i}(true); for _ in s {{ }} }}")
        elif form == "subscript_access":
            # HOLE 2: `obj[i]` runs the subscript getter body — an implicit accessor call.
            bodies[i] = (f"struct Sb{i} {{ subscript(i: Int) -> Int {{ {callee}(); return i }} }}\n"
                         f"func mk{i}(_ b: Bool) -> Sb{i} {{ Sb{i}() }}\n"
                         f"func {me}() {{ let o = mk{i}(true); _ = o[3] }}")
        elif form == "static_init":
            # HOLE 3: a `static let` initializer runs at first ACCESS; touching it charges the toucher.
            bodies[i] = (f"struct St{i} {{ static let v: Int = {{ {callee}(); return 1 }}() }}\n"
                         f"func {me}() {{ _ = St{i}.v }}")
            extra_effectful.add(f"St{i}.v")
        elif form == "global_init":
            # HOLE 3 (globals): a top-level `let g = …` initializer runs lazily at first bare-name read.
            bodies[i] = (f"let gl{i}: Int = {{ {callee}(); return 1 }}()\n"
                         f"func {me}() {{ _ = gl{i} }}")
            extra_effectful.add(f"gl{i}")
        elif form == "proto_prop":
            # HOLE 4: a protocol PROPERTY requirement read `p.payload` dispatches to the conformer's
            # accessor. UNPINNED via a branch-MERGE of two conformers passed to a protocol-typed param.
            bodies[i] = (f"protocol Pp{i} {{ var payload: Int {{ get }} }}\n"
                         f"struct Pa{i}: Pp{i} {{ var payload: Int {{ {callee}(); return 1 }} }}\n"
                         f"struct Pb{i}: Pp{i} {{ var payload: Int {{ {callee}(); return 2 }} }}\n"
                         f"func use{i}(_ p: Pp{i}) {{ _ = p.payload }}\n"
                         f"func {me}() {{ let p: Pp{i} = Bool.random() ? Pa{i}() : Pb{i}(); use{i}(p) }}")
        elif form == "call_as_function":
            # HOLE 6: `f()` on a callAsFunction instance desugars to f.callAsFunction().
            bodies[i] = (f"struct Cf{i} {{ func callAsFunction() {{ {callee}() }} }}\n"
                         f"func {me}() {{ let f = Cf{i}(); f() }}")
        elif form == "operator_overload":
            # HOLE 7: `a + b` resolves to a `+` operator func — not a syntactic call.
            bodies[i] = (f"struct Op{i} {{ static func + (a: Op{i}, b: Op{i}) -> Op{i} {{ {callee}(); return a }} }}\n"
                         f"func {me}() {{ let a = Op{i}(); let b = Op{i}(); _ = a + b }}")
        elif form == "default_arg":
            # HOLE 9: omitting a defaulted arg runs the default EXPRESSION, which reaches `callee`. The
            # callee-attribution makes `wd{i}` (and thus the omitting `me`) carry the effect.
            bodies[i] = (f"func da{i}() -> Int {{ {callee}(); return 1 }}\n"
                         f"func wd{i}(_ x: Int = da{i}()) {{ _ = x }}\n"
                         f"func {me}() {{ wd{i}() }}")
        elif form == "dynamic_member":
            # HOLE 8: `@dynamicMemberLookup` — `p.x` desugars to the dynamic subscript whose runtime
            # member can't be pinned, so the consumer must read Unknown (precise resolution intractable).
            bodies[i] = (f"@dynamicMemberLookup struct Dm{i} {{\n"
                         f"    subscript(dynamicMember m: String) -> Int {{ {callee}(); return 1 }}\n"
                         f"}}\n"
                         f"func {me}() {{ let d = Dm{i}(); _ = d.anything }}")
            expect_unknown.add(me)
    bystander = "func zzBystander(_ n: Int) -> Int { n * 2 }"
    # HOLE 5 (off-chain): a `deinit` body had no visitor. It runs at scope-exit with no caller site, so
    # its effect attributes to the deinit UNIT itself — checked via extra_effectful (it does not, and
    # must not, propagate to the allocating function: candor can't model dealloc timing).
    dei = f"final class DeinitProbe {{ deinit {{ {sink_stmt} }} }}"
    extra_effectful.add("DeinitProbe.deinit")
    src = ("import Foundation\n\n" + "\n".join(bodies) + "\n" + bystander + "\n"
           + dei + "\n" + PRECISION_TRAPS + "\n" + FILE_WRITE_POSITIVE + "\n")
    chain = [fn(i) for i in range(n + 1)]
    return src, chain, sink_eff, expect_unknown, extra_effectful, forms


# PRECISION TRAPS — pure functions that LOOK like they should trigger a receiver-typing heuristic but
# must stay PURE. The fuzzer threads effects UP a chain (propagation); these guard the other direction —
# that the heuristics never FABRICATE an effect (the worst bug, candor's cardinal sin). Each trap is a
# real fabrication the adversarial review found (singleton accessor that vends a different type; a stored
# field named like a κ property; a `vars`-leak across same-named loop bindings). Appended to every seed
# (so they're checked under every form combination); the harness asserts NONE of TRAP_FNS is in the report.
PRECISION_TRAPS = """
final class PV { func go() {} }
final class TrapCache { static let current: PV = PV(); func go() { _ = FileManager.default.contents(atPath: "/x") } }
func trapSingleton() { let v = TrapCache.current; v.go() }                 // .current vends PV, not TrapCache → pure
final class TrapTimer { let now: Date = Date(); func trapRead() { _ = self.now } }   // field named `now` → pure
struct TrapBox { func data() {}; func write() {} }                          // methods named like κ members
func trapBoxes() -> [TrapBox] { [] }
func trapLeak() { let ss: [URLSession] = []; for s in ss { _ = s }; for s in trapBoxes() { s.data(); s.write() } }
func trapDollar() { let ss: [URLSession] = []; ss.forEach { _ = $0 }; trapBoxes().map { $0.data() } }
// String's PURE write overloads — `write(to: &TextOutputStream)` (in-memory sink) and `write(_:)`
// (TextOutputStream append) are NOT file I/O. The Data/String file-write classifier must exclude them
// (the inout/label guard) — else it fabricates Fs.
func trapWriteStream(_ s: String) { var o = ""; s.write(to: &o); _ = o }
func trapWriteAppend() { var t = ""; t.write("x"); _ = t }
"""
TRAP_FNS = ["trapSingleton", "trapRead", "trapLeak", "trapDollar", "trapWriteStream", "trapWriteAppend"]

# POSITIVE classifier fixture appended every seed: the Foundation file-write idiom `Data/String.write(to:
# url)` persists to a FILE → Fs. Was unclassified (silent pure). Guarded by the trapWrite* twins above.
FILE_WRITE_POSITIVE = """
func fwData(_ d: Data, _ u: URL) { try? d.write(to: u) }
func fwStr(_ s: String, _ u: URL) { try? s.write(to: u, atomically: true, encoding: .utf8) }
"""
FILE_WRITE_FNS = ["fwData", "fwStr"]  # must each carry Fs


def run_seed(seed):
    src, chain, eff, expect_unknown, extra_effectful, forms = gen(seed)
    d = tempfile.mkdtemp(prefix="candor-swift-fuzz-")
    try:
        with open(os.path.join(d, "m.swift"), "w") as f:
            f.write(src)
        out = os.path.join(d, "r")
        subprocess.run([BIN, d, "--out", out], capture_output=True)
        import glob as _g
        rep = json.load(open(next(p for p in _g.glob(out + ".*.Swift.json") if "callgraph" not in p)))
        got = {e["fn"].split(".")[-1]: set(e["inferred"]) for e in rep["functions"]}
        gotFull = {e["fn"]: set(e["inferred"]) for e in rep["functions"]}
        fails = []
        for c in chain:
            s = got.get(c, set())
            if eff not in s and "Unknown" not in s:
                fails.append(f"{c}: SILENT under-report (expected {eff} or Unknown, got {sorted(s)})")
        # non-chain UNITS (deinit / static / global initializers) — the effect attributes to the unit
        # itself, not to a chain caller; assert each carries the effect-or-Unknown (never silent-pure).
        for u in extra_effectful:
            s = gotFull.get(u, set())
            if eff not in s and "Unknown" not in s:
                fails.append(f"{u}: SILENT under-report on uncollected unit (expected {eff} or Unknown, got {sorted(s)})")
        for u in expect_unknown:
            if "Unknown" not in got.get(u, set()):
                fails.append(f"{u}: callback/field invocation must read Unknown, got {sorted(got.get(u, set()))}")
        if "zzBystander" in got:
            fails.append(f"zzBystander: precision twin leaked into the report: {sorted(got['zzBystander'])}")
        for t in TRAP_FNS:
            if t in got:
                fails.append(f"{t}: PRECISION TRAP — a pure fn FABRICATED an effect {sorted(got[t])} via a receiver-typing heuristic")
        for t in FILE_WRITE_FNS:
            if "Fs" not in got.get(t, set()):
                fails.append(f"{t}: SILENT under-report — Data/String.write(to: url) must classify Fs, got {sorted(got.get(t, set()))}")
        return fails, forms
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 25
    bad = 0
    for seed in range(n):
        fails, forms = run_seed(seed)
        if fails:
            bad += 1
            print(f"seed {seed} ({'+'.join(forms)}): FAIL")
            for f in fails:
                print(f"    {f}")
    print(f"fuzz: {n - bad} seeds passed, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
