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
FORMS = ["direct", "closure", "method", "init_wired", "nested_fn", "sched", "proto", "callback_recv", "fn_field"]


def gen(seed):
    rng = random.Random(seed)
    n = rng.randint(2, 6)
    sink_stmt, sink_eff = SINKS[rng.choice(list(SINKS))]
    fn = lambda i: f"f{i:02d}" if i < n else "sink"
    bodies = [None] * (n + 1)
    forms = []
    expect_unknown = set()
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
        elif form == "fn_field":
            bodies[i] = (f"struct D{i} {{ let f: () -> Void }}\n"
                         f"func hold{i}(_ d: D{i}) {{ d.f() }}\n"
                         f"func {me}() {{ hold{i}(D{i}(f: {{ {callee}() }})) }}")
            expect_unknown.add(f"hold{i}")
    bystander = "func zzBystander(_ n: Int) -> Int { n * 2 }"
    src = "import Foundation\n\n" + "\n".join(bodies) + "\n" + bystander + "\n"
    chain = [fn(i) for i in range(n + 1)]
    return src, chain, sink_eff, expect_unknown, forms


def run_seed(seed):
    src, chain, eff, expect_unknown, forms = gen(seed)
    d = tempfile.mkdtemp(prefix="candor-swift-fuzz-")
    try:
        with open(os.path.join(d, "m.swift"), "w") as f:
            f.write(src)
        out = os.path.join(d, "r")
        subprocess.run([BIN, d, "--out", out], capture_output=True)
        rep = json.load(open(out + ".json"))
        got = {e["fn"].split(".")[-1]: set(e["inferred"]) for e in rep["functions"]}
        fails = []
        for c in chain:
            s = got.get(c, set())
            if eff not in s and "Unknown" not in s:
                fails.append(f"{c}: SILENT under-report (expected {eff} or Unknown, got {sorted(s)})")
        for u in expect_unknown:
            if "Unknown" not in got.get(u, set()):
                fails.append(f"{u}: callback/field invocation must read Unknown, got {sorted(got.get(u, set()))}")
        if "zzBystander" in got:
            fails.append(f"zzBystander: precision twin leaked into the report: {sorted(got['zzBystander'])}")
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
