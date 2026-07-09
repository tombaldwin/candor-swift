#!/usr/bin/env bash
# candor-swift smoke: the conformance oracle + gate + ledger, end to end.
set -uo pipefail
cd "$(dirname "$0")"
# Capture build diagnostics instead of discarding them (2>/dev/null hid the actual compiler error on a
# failing CI run — the log said only "FAIL: build"); dump them on failure, stay quiet on success.
BUILD_LOG=$(mktemp)
swift build > "$BUILD_LOG" 2>&1 || { echo "FAIL: build — diagnostics:"; cat "$BUILD_LOG"; rm -f "$BUILD_LOG"; exit 1; }
rm -f "$BUILD_LOG"
BIN=.build/debug/candor-swift
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }

"$BIN" conformance/Cases.swift --out "$W/r" 2>/dev/null
RPT=$(ls "$W"/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
EXPECTED="${CANDOR_SPEC:-../candor-spec}/conformance/expected.json"
if [ -f "$EXPECTED" ]; then
  N=$(python3 - "$EXPECTED" "$RPT" <<'PY'
import json, sys
exp = {k: set(v) for k, v in json.load(open(sys.argv[1])).items() if not k.startswith("_")}
got = {e["fn"].split(".")[-1]: set(e.get("inferred", [])) for e in json.load(open(sys.argv[2]))["functions"]}
print(sum(1 for c, e in exp.items() if got.get(c, set()) == e), "/", len(exp), sep="")
PY
)
  # All cases must match; don't hardcode the count (the shared oracle grows — was 22, now 24, …).
  [ -n "$N" ] && [ "${N%/*}" = "${N#*/}" ] && ok "conformance oracle $N" || bad "conformance oracle $N"
else
  echo "  skip conformance oracle (clone candor-spec as a sibling or set CANDOR_SPEC)"
fi

# Data/String(contentsOf: URL) reads file OR network — exactly one, scheme-dependent. A provably-file
# URL is Fs, a literal http(s) URL is Net, but an INDETERMINATE url is honest Unknown — NEVER both
# (asserting Fs+Net fabricates one; this caught candor fabricating Net on SwiftFormat's file config reads).
cat > "$W/dt.swift" <<'SW'
import Foundation
func dt_file() { _ = try? Data(contentsOf: URL(fileURLWithPath: "/x")) }
func dt_http() { _ = try? Data(contentsOf: URL(string: "https://h")!) }
func dt_var(_ u: URL) { _ = try? Data(contentsOf: u) }
SW
"$BIN" "$W/dt.swift" --out "$W/dt" 2>/dev/null
DRPT=$(ls "$W"/dt.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
dchk() { python3 -c "import json,sys; d=json.load(open('$DRPT')); print(next((','.join(sorted(f['inferred'])) for f in d['functions'] if f['fn'].endswith('.'+sys.argv[1]) or f['fn']==sys.argv[1]), 'absent'))" "$1"; }
[ "$(dchk dt_file)" = "Fs" ]      && ok "contentsOf: file URL -> Fs"                        || bad "contentsOf: file URL -> Fs (got $(dchk dt_file))"
[ "$(dchk dt_http)" = "Net" ]     && ok "contentsOf: http URL -> Net"                       || bad "contentsOf: http URL -> Net (got $(dchk dt_http))"
[ "$(dchk dt_var)" = "Unknown" ]  && ok "contentsOf: indeterminate URL -> Unknown (no Fs+Net fabrication)" || bad "contentsOf: indeterminate -> Unknown (got $(dchk dt_var))"
# NESTED-TYPE SYMBOL KEYING: two same-named nested types (`MemoryStorage.Backend`, `DiskStorage.Backend`)
# must be DISTINCT symbols. Keyed by the immediate enclosing type alone they collapse to one `Backend.store`
# whose effect is the UNION of both bodies — fabricating DiskStorage's Fs onto MemoryStorage's pure store
# (the Kingfisher sweep). Full nested-path quals keep them apart; the pure one stays pure, the Fs one fires.
cat > "$W/ns.swift" <<'SW'
import Foundation
final class MemoryStorage { final class Backend {
    func storeNoThrow() { let _ = 1 + 1 }
    func store() { storeNoThrow() }                                   // PURE
} }
final class DiskStorage { final class Backend {
    func store() { let _ = try? Data(contentsOf: URL(fileURLWithPath: "/x")) }  // Fs
} }
SW
"$BIN" "$W/ns.swift" --out "$W/ns" 2>/dev/null
NRPT=$(ls "$W"/ns.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
nchk() { python3 -c "import json,sys; d=json.load(open('$NRPT')); print(next((','.join(sorted(f['inferred'])) for f in d['functions'] if f['fn']==sys.argv[1]), 'absent'))" "$1"; }
[ "$(nchk DiskStorage.Backend.store)" = "Fs" ]   && ok "nested-type keying: DiskStorage.Backend.store -> Fs (control fires)" || bad "nested keying control: got $(nchk DiskStorage.Backend.store)"
[ "$(nchk MemoryStorage.Backend.store)" = "absent" ] && ok "nested-type keying: MemoryStorage.Backend.store stays pure (no same-name Fs collapse)" || bad "nested keying fabrication: MemoryStorage.Backend.store got $(nchk MemoryStorage.Backend.store)"
# sqlite3_* PREFIX rule: real query ops are Db, but the pure C INTROSPECTION getters (sqlite3_sql /
# _column_name / _changes / _db_filename / _errmsg) read resident handle state and touch no database —
# the prefix rule fabricated Db on them (SQLite.swift sweep: Statement.description, Connection.changes…).
# The sqlite3_* symbols come from `import SQLite3` (a C module) — they are NOT locally declared. Do NOT
# add local `func sqlite3_*` stubs here: candor parses (it does not type-check), so the calls resolve
# without them, and a local decl would (correctly) SHADOW the platform free-call table — the same
# project-owns-the-name guard the trapLocal* fuzzer forms pin (a local `func NSLog`/`Pipe` must not
# fabricate). With stubs this would be the WRONG test — a pure local fn classified Db is a fabrication.
cat > "$W/sq.swift" <<'SW'
func sqlText(_ s: OpaquePointer) { let _ = sqlite3_sql(s) }              // PURE introspection
func changes(_ d: OpaquePointer) { let _ = sqlite3_changes(d) }         // PURE
func runStep(_ s: OpaquePointer) { let _ = sqlite3_step(s) }            // Db (real query)
func openDb(_ d: inout OpaquePointer?) { let _ = sqlite3_open("/x", &d) } // Db
SW
"$BIN" "$W/sq.swift" --out "$W/sq" 2>/dev/null
SRPT=$(ls "$W"/sq.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
schk() { python3 -c "import json,sys; d=json.load(open('$SRPT')); print(next((','.join(sorted(f['inferred'])) for f in d['functions'] if f['fn']==sys.argv[1]), 'absent'))" "$1"; }
[ "$(schk runStep)" = "Db" ] && ok "sqlite3_step -> Db (control fires)" || bad "sqlite3 control: runStep got $(schk runStep)"
[ "$(schk openDb)" = "Db" ] && ok "sqlite3_open -> Db (control fires)" || bad "sqlite3 control: openDb got $(schk openDb)"
[ "$(schk sqlText)" = "absent" ] && ok "sqlite3_sql introspection stays pure (no fabricated Db)" || bad "sqlite3 fabrication: sqlText got $(schk sqlText)"
[ "$(schk changes)" = "absent" ] && ok "sqlite3_changes introspection stays pure (no fabricated Db)" || bad "sqlite3 fabrication: changes got $(schk changes)"
# PARAM-TYPE OVERLOAD RESOLUTION: same-name overloads must NOT merge their effects. (a) different ARITY —
# a clock-reading 1-arg overload must not contaminate callers of a pure 2-arg overload. (b) SAME arity,
# different param TYPE — a call routes to the overload its arg type matches (the SwiftDate compare bug:
# `compare(_:DateComparisonType)` read the clock while `compare(toDate:granularity:)`/`compare(_:Date)`
# were pure). A labeled call that omits defaulted params must still resolve (no false type-exclusion).
cat > "$W/ov.swift" <<'SW'
import Foundation
struct A {}
struct B {}
struct Box {
    func use(_ x: A) -> Int { return 0 }                              // PURE
    func use(_ x: B) -> Int { let _ = Date(); return 1 }             // Clock (same arity, diff param type)
    func viaA(_ a: A) -> Int { return use(a) }                       // PURE — must pick use(A)
    func viaB(_ b: B) -> Int { return use(b) }                       // Clock — must pick use(B)
    func cmp(toDate o: A, granularity g: Int) -> Int { return g }    // PURE (arity 2)
    func cmp(_ k: String) -> Int { let _ = Date(); return 0 }        // Clock (arity 1)
    func before(_ o: A) -> Bool { return cmp(toDate: o, granularity: 1) > 0 }  // PURE — arity-2 overload
    func kind() -> Int { return cmp("x") }                           // Clock — arity-1 overload
    func make(id: Int = 0, name: String) -> Int { let _ = Date(); return id }  // Clock (BODY); id defaulted
    func make(_ raw: A) -> Int { return 0 }                         // pure 1-arg overload
    func build() -> Int { return make(name: "n") }                  // Clock — labeled call omits defaulted id
}
struct Forwarder {
    var sink: ExternalSink?                                          // ExternalSink not local → unresolved receiver
    func cb(_ x: A) { let _ = Date() }                              // Clock — a real sibling overload
    func cb(_ x: B) { }                                             // pure sibling overload
    func forward(_ x: B) { sink?.cb(x) }                           // calls cb on the EXTERNAL sink — must NOT
}                                                                   // resolve to self's `cb` overload cluster
SW
"$BIN" "$W/ov.swift" --out "$W/ov" 2>/dev/null
ORPT=$(ls "$W"/ov.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
ochk() { python3 -c "import json,sys; d=json.load(open('$ORPT')); print(next((','.join(sorted(f['inferred'])) for f in d['functions'] if f['fn']==sys.argv[1]), 'absent'))" "$1"; }
[ "$(ochk Box.viaA)" = "absent" ] && ok "overload param-type: viaA(A) picks pure use(A) (no Clock)" || bad "overload param-type: viaA got $(ochk Box.viaA)"
[ "$(ochk Box.viaB)" = "Clock" ]  && ok "overload param-type: viaB(B) picks use(B) -> Clock (control)" || bad "overload param-type: viaB got $(ochk Box.viaB)"
[ "$(ochk Box.before)" = "absent" ] && ok "overload arity: before() picks pure 2-arg cmp (no Clock)" || bad "overload arity: before got $(ochk Box.before)"
[ "$(ochk Box.kind)" = "Clock" ]  && ok "overload arity: kind() picks 1-arg cmp -> Clock (control)" || bad "overload arity: kind got $(ochk Box.kind)"
[ "$(ochk Box.build)" = "Clock" ] && ok "overload defaults: labeled call omitting defaults still resolves (Clock kept)" || bad "overload defaults: build got $(ochk Box.build)"
[ "$(ochk Forwarder.forward)" = "absent" ] && ok "member call on an unresolved receiver does NOT resolve to a self-sibling overload (Get fab)" || bad "unresolved-receiver member resolved to sibling: forward got $(ochk Forwarder.forward)"
[ "$(ochk Forwarder.cb)" = "Clock" ] || [ "$(ochk 'Forwarder.cb(A)')" = "Clock" ] && ok "the real sibling overload Forwarder.cb(A) keeps its Clock" || bad "Forwarder.cb(A) lost Clock"
printf 'deny Net hop\n' > "$W/pol"
"$BIN" conformance/Cases.swift --out "$W/r" --policy "$W/pol" >"$W/gate.out" 2>&1
grep -q 'AS-EFF-006.*hop_a.*Net' "$W/gate.out" && ok "deny gate flags the transitive caller" || bad "deny gate"
mkdir -p "$W/led" && printf 'import Alamofire\nfunc go() { _ = FileManager.default.contents(atPath: "/x") }\nimport Foundation\n' > "$W/led/m.swift"
"$BIN" "$W/led" --out "$W/led/r" 2>"$W/led.err"
grep -q "κ doesn't know.*Alamofire" "$W/led.err" && ok "κ ledger names the unlisted import" || bad "κ ledger"
HASH=$(python3 -c "import json; print(json.load(open('$RPT'))['functions'][0].get('hash',''))")
case "$HASH" in *"#"*) ok "hash join keys emitted (0.4 MUST)";; *) bad "hash emission";; esac
# spec 0.5 draft: an accessor unit carries unitKind
mkdir -p "$W/uk" && printf 'import Foundation\nstruct C { var v: Int { _ = FileManager.default.contents(atPath: "/x"); return 1 } }\nfunc plain() { _ = Date() }\n' > "$W/uk/m.swift"
"$BIN" "$W/uk" --out "$W/uk/r" >/dev/null 2>&1
UK=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/uk/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:e for e in r['functions']}
print(by.get('C.v',{}).get('unitKind',''), by.get('plain',{}).get('unitKind','-none-'))")
[ "$UK" = "accessor -none-" ] && ok "accessor unit carries unitKind; plain fn omits it" || bad "unitKind: got '$UK'"

# a let-bound singleton accessor (FileManager.default / URLSession.shared) carries the base type, so
# its member calls classify — the inline chain already did, the let-bound dropped to pure before.
mkdir -p "$W/sg" && cat > "$W/sg/m.swift" <<'SW'
import Foundation
func letBound() { let fm = FileManager.default; try? fm.removeItem(atPath: "/x") }
func inlineChain() { try? FileManager.default.removeItem(atPath: "/y") }
func nonEffect() { let q = DispatchQueue.main; q.sync { } }
SW
"$BIN" "$W/sg" --out "$W/sg/r" >/dev/null 2>&1
SG=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/sg/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
print('lb' if by.get('letBound')=={'Fs'} else 'X', 'in' if by.get('inlineChain')=={'Fs'} else 'X', 'ne' if 'nonEffect' not in by else 'X')")
[ "$SG" = "lb in ne" ] && ok "let-bound singleton accessor classifies (no fabrication for non-effect types)" || bad "singleton accessor: got '$SG'"

# iterating a typed collection types the loop/closure variable, so the element's effectful member
# calls classify (for-in AND forEach/map closures, explicit param AND $0) — was dropped to pure.
mkdir -p "$W/it" && cat > "$W/it/m.swift" <<'SW'
import Foundation
final class Client { func send() { _ = URLSession.shared.dataTask(with: URL(string: "https://x")!) } }
func forIn(cs: [Client]) { for c in cs { c.send() } }
func forEachP(cs: [Client]) { cs.forEach { c in c.send() } }
func shorthand(cs: [Client]) { cs.forEach { $0.send() } }
func intLoop(ns: [Int]) { ns.forEach { n in _ = n + 1 } }
SW
"$BIN" "$W/it" --out "$W/it/r" >/dev/null 2>&1
IT=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/it/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = by.get('forIn')=={'Net'} and by.get('forEachP')=={'Net'} and by.get('shorthand')=={'Net'} and 'intLoop' not in by
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$IT" = "PASS" ] && ok "iteration-variable typing resolves the element's effects (for-in + forEach + \$0; no fabrication on [Int])" || bad "iteration typing: $IT"

# collection typing completeness: array FIELDS, dict (k,v) iteration, enumerated(), transform reuse
mkdir -p "$W/ct2" && cat > "$W/ct2/m.swift" <<'SW'
import Foundation
final class Client { func send() { _ = URLSession.shared.dataTask(with: URL(string: "https://x")!) } }
struct Pool { let clients: [Client] = []; func run() { for c in clients { c.send() } } }
func dictV(d: [String: Client]) { for (_, c) in d { c.send() } }
func enumer(cs: [Client]) { for (_, c) in cs.enumerated() { c.send() } }
func reuse(cs: [Client]) { let a = cs.filter { _ in true }; for c in a { c.send() } }
func dictInt(d: [String: Int]) { for (_, n) in d { _ = n + 1 } }
SW
"$BIN" "$W/ct2" --out "$W/ct2/r" >/dev/null 2>&1
CT=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/ct2/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = (by.get('Pool.run')=={'Net'} and by.get('dictV')=={'Net'} and by.get('enumer')=={'Net'}
      and by.get('reuse')=={'Net'} and 'dictInt' not in by)
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$CT" = "PASS" ] && ok "collection typing: array fields, dict (k,v), enumerated(), filter-reuse (no fabrication on [String:Int])" || bad "collection typing: $CT"

# receiver EXPRESSION typing: subscript, as!/as? cast, ternary (inline + let-bound) — all dropped to pure.
mkdir -p "$W/rx" && cat > "$W/rx/m.swift" <<'SW'
import Foundation
final class Client { func send() { _ = URLSession.shared.dataTask(with: URL(string: "https://x")!) } }
func sub(cs: [Client]) { cs[0].send() }
func cast(x: Any) { (x as! Client).send() }
func tern(a: Client, b: Client, f: Bool) { (f ? a : b).send() }
func castLet(x: Any) { let c = x as! Client; c.send() }
func castInt(x: Any) { _ = (x as! Int) + 1 }
SW
"$BIN" "$W/rx" --out "$W/rx/r" >/dev/null 2>&1
RX=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/rx/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = (by.get('sub')=={'Net'} and by.get('cast')=={'Net'} and by.get('tern')=={'Net'}
      and by.get('castLet')=={'Net'} and 'castInt' not in by)
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$RX" = "PASS" ] && ok "receiver-expression typing: subscript, as! cast, ternary (no fabrication on as! Int)" || bad "receiver-expr typing: $RX"

# FIELD-CHAIN: `self.field.method()` / `outer.inner.method()` resolve the method on the FIELD's type,
# not the enclosing/first type (explicit self.field and field-of-field chains dropped to pure before).
mkdir -p "$W/fc" && cat > "$W/fc/m.swift" <<'SW'
import Foundation
final class Client { func send() { _ = URLSession.shared.dataTask(with: URL(string: "https://x")!) } }
struct Inner { let c = Client() }
final class Svc { let client = Client(); func go() { self.client.send() } }   // explicit self.field
struct Outer { let inner = Inner(); func use() { inner.c.send() } }             // field-of-field
SW
"$BIN" "$W/fc" --out "$W/fc/r" >/dev/null 2>&1
FC=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/fc/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
print('PASS' if by.get('Svc.go')=={'Net'} and by.get('Outer.use')=={'Net'} else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$FC" = "PASS" ] && ok "field-chain typing: self.field.method() + field-of-field resolve the field's type" || bad "field-chain typing: $FC"

# enum associated-value binding: `case .active(let c): c.send()` (switch + if-case) types c from the
# case's payload type; ambiguous case names and non-effect payloads stay pure (never guess/fabricate).
mkdir -p "$W/en" && cat > "$W/en/m.swift" <<'SW'
import Foundation
final class Client { func send() { _ = URLSession.shared.dataTask(with: URL(string: "https://x")!) } }
enum St { case idle, active(Client) }
func sw(s: St) { switch s { case .active(let c): c.send(); default: break } }
func ic(s: St) { if case .active(let c) = s { c.send() } }
enum N { case n(Int) }
func intCase(x: N) { switch x { case .n(let v): _ = v + 1 } }
SW
"$BIN" "$W/en" --out "$W/en/r" >/dev/null 2>&1
EN=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/en/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
print('PASS' if by.get('sw')=={'Net'} and by.get('ic')=={'Net'} and 'intCase' not in by else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$EN" = "PASS" ] && ok "enum case binding: switch/if-case .active(let c) types c (no fabrication on Int payload)" || bad "enum case binding: $EN"

# generic protocol-bound param + guard/if-let factory binding
mkdir -p "$W/gp" && cat > "$W/gp/m.swift" <<'SW'
import Foundation
final class Client { func send() { _ = URLSession.shared.dataTask(with: URL(string: "https://x")!) } }
protocol Sender { func send() }
struct Disk: Sender { func send() { try? FileManager.default.removeItem(atPath: "/x") } }
func generic<T: Sender>(x: T) { x.send() }
func makeC() -> Client? { Client() }
func guardF() { guard let c = makeC() else { return }; c.send() }
func ifLetF() { if let c = makeC() { c.send() } }
SW
"$BIN" "$W/gp" --out "$W/gp/r" >/dev/null 2>&1
GP=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/gp/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
print('PASS' if by.get('generic')=={'Fs'} and by.get('guardF')=={'Net'} and by.get('ifLetF')=={'Net'} else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$GP" = "PASS" ] && ok "generic <T: P> param dispatches like P; guard/if-let factory binding types the value" || bad "generic/optional-binding: $GP"

# tuple typing: positional `p.0`, named `p.c`, and destructure `let (a,_) = (...)` — receiver resolves.
mkdir -p "$W/tu" && cat > "$W/tu/m.swift" <<'SW'
import Foundation
final class Client { func send() { _ = URLSession.shared.dataTask(with: URL(string: "https://x")!) } }
func pos(p: (Client, Int)) { p.0.send() }
func named(p: (c: Client, n: Int)) { p.c.send() }
func destr() { let (a, b) = (Client(), 1); a.send(); _ = b }
func intTup(p: (Int, Int)) { _ = p.0 + p.1 }
SW
"$BIN" "$W/tu" --out "$W/tu/r" >/dev/null 2>&1
TU=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/tu/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
print('PASS' if by.get('pos')=={'Net'} and by.get('named')=={'Net'} and by.get('destr')=={'Net'} and 'intTup' not in by else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$TU" = "PASS" ] && ok "tuple typing: p.0 / p.c / let (a,_) destructure (no fabrication on (Int,Int))" || bad "tuple typing: $TU"

# NESTED-RECEIVER composition: each indirection works alone; rootOf must thread the type through
# several at once — field+subscript, cast+field, loop+field+subscript, deep field.field[0].field chains.
mkdir -p "$W/ne" && cat > "$W/ne/m.swift" <<'SW'
import Foundation
final class Client { func send() { _ = URLSession.shared.dataTask(with: URL(string: "https://x")!) } }
struct Pool { let clients: [Client] = [] }
func fieldSub(p: Pool) { p.clients[0].send() }
func castField(x: Any) { (x as! Pool).clients[0].send() }
func loopFieldSub(ps: [Pool]) { for p in ps { p.clients[0].send() } }
struct Wrap { let inner: [Pool] = [] }
func deep(w: Wrap) { w.inner[0].clients[0].send() }
SW
"$BIN" "$W/ne" --out "$W/ne/r" >/dev/null 2>&1
NE=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/ne/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = all(by.get(f)=={'Net'} for f in ['fieldSub','castField','loopFieldSub','deep'])
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$NE" = "PASS" ] && ok "nested-receiver composition: field+subscript, cast+field, loop+field+sub, deep chain" || bad "nested composition: $NE"

# REGRESSION F1: a closure passed to a NON-iterator method (onComplete/sink/custom HOF) must CLEAR
# its param so a prior same-named binding (loop var `request: URLSession`) can't leak in and fabricate.
# The element closure of a whitelisted iterator stays TYPED; an explicit param annotation types precisely.
mkdir -p "$W/f1" && cat > "$W/f1/m.swift" <<'SW'
import Foundation
struct API { func onComplete2(_ f: (URLRequest) -> Void) {}; func onEach(_ f: (URLSession) -> Void) {} }
func leakRepro(api: API, sessions: [URLSession]) {
    for request in sessions { _ = request.configuration }   // request: URLSession
    api.onComplete2 { request in _ = request.httpMethod }    // param CLEARED — must NOT fabricate Net
}
func annotCtrl(api: API) { api.onEach { (s: URLSession) in _ = s.dataTask(with: URL(string:"https://x")!) } } // Net via annotation
func iterCtrl(sessions: [URLSession]) { sessions.forEach { s in _ = s.dataTask(with: URL(string:"https://x")!) } } // Net via iterator element
SW
"$BIN" "$W/f1" --out "$W/f1/r" >/dev/null 2>&1
F1=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/f1/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = 'leakRepro' not in by and by.get('annotCtrl')=={'Net'} and by.get('iterCtrl')=={'Net'}
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$F1" = "PASS" ] && ok "F1: non-iterator closure param cleared (no leak-fabrication; annotation + iterator element still type)" || bad "F1 closure-param leak: $F1"

# REGRESSION F2: an enum-case binding only types when the case is unambiguous AND the pattern's
# ARITY matches the single-associated-value form. Two enums sharing a case name where only one is
# single-payload — a multi-payload pattern must NOT bind the wrong enum's single-assoc type.
mkdir -p "$W/f2" && cat > "$W/f2/m.swift" <<'SW'
import Foundation
enum AA { case live(URLSession) }
enum BB { case live(Plain, Int) }
struct Plain { func dataTask(with: URL) {} }
func useBB(b: BB) { switch b { case .live(let c, _): c.dataTask(with: URL(string:"http://x")!) } }  // arity 2 — CLEAR, no fabrication
func useAA(a: AA) { switch a { case .live(let c): _ = c.dataTask(with: URL(string:"http://x")!) } }   // arity 1 single-assoc — Net
SW
"$BIN" "$W/f2" --out "$W/f2/r" >/dev/null 2>&1
F2=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/f2/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = 'useBB' not in by and by.get('useAA')=={'Net'}
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$F2" = "PASS" ] && ok "F2: enum-case arity guard (multi-payload cleared; single-assoc still types)" || bad "F2 enum arity: $F2"

# REGRESSION F3: a singleton vended by a free FACTORY (`static let shared = build()`) must carry the
# factory's VENDED type, not the static's own type. The vended type's effects resolve; the static's
# own-type effects must NOT fabricate onto the value.
mkdir -p "$W/f3" && cat > "$W/f3/m.swift" <<'SW'
import Foundation
struct Registry { static let shared = build(); func run() { FileManager.default.removeItem(atPath: "/tmp/x") } }
struct Plain3 { func run() {} }
func build() -> Plain3 { Plain3() }
func usesShared() { let r = Registry.shared; r.run() }            // r: Plain3 — pure, must NOT fabricate Fs
struct Doer { func go() { FileManager.default.removeItem(atPath: "/tmp/y") } }
func makeDoer() -> Doer { Doer() }
struct Reg2 { static let shared = makeDoer() }
func usesDoer() { let d = Reg2.shared; d.go() }                  // d: Doer — Fs CONTROL still resolves
SW
"$BIN" "$W/f3" --out "$W/f3/r" >/dev/null 2>&1
F3=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/f3/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = 'usesShared' not in by and by.get('usesDoer')=={'Fs'}
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$F3" = "PASS" ] && ok "F3: free-factory singleton vends real type (no base-type fabrication; effectful vended type resolves)" || bad "F3 factory singleton: $F3"

# REGRESSION F4: a NESTED func (or closure-bound let) SHADOWS a same-named module-level/sibling free
# fn. Swift resolves a bare `helper()` to the innermost (local) decl — whose body attributes lexically.
# Edging it ALSO to the module-level free fn would FABRICATE that fn's effects onto a pure caller
# (the call-graph-key-collision class; the local unit is never registered, so freeFnByName has a single
# WRONG candidate). The pure callers must NOT inherit Fs; a real caller of the free fn still must.
mkdir -p "$W/f4" && cat > "$W/f4/m.swift" <<'SW'
import Foundation
func helper() { try? FileManager.default.removeItem(atPath: "/tmp/x") }      // module-level Fs
func writer() { try? FileManager.default.removeItem(atPath: "/tmp/y") }      // module-level Fs
func pureLocalFunc() { func helper() { let _ = 1 + 1 }; helper() }           // local shadow — pure
func pureLocalLet()  { let writer = { let _ = 1 + 1 }; writer() }            // closure-let shadow — pure
func realFreeCall()  { helper() }                                            // genuine reach — Fs
func effectfulLocal() { func doWrite() { try? FileManager.default.removeItem(atPath: "/tmp/z") }; doWrite() } // lexical — Fs
SW
"$BIN" "$W/f4" --out "$W/f4/r" >/dev/null 2>&1
F4=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/f4/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = ('pureLocalFunc' not in by and 'pureLocalLet' not in by
      and by.get('realFreeCall')=={'Fs'} and by.get('effectfulLocal')=={'Fs'})
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$F4" = "PASS" ] && ok "F4: local func / closure-let shadow no fabrication (key-collision class; genuine reach + lexical effect still resolve)" || bad "F4 shadow collision: $F4"

# REGRESSION U1: String/Data(contentsOfFile:) takes a FILE PATH (no scheme) — UNCONDITIONALLY Fs.
# The contentsOf: scheme-resolution guard keyed on `contentsOf` only, dropping contentsOfFile: to pure.
mkdir -p "$W/u1" && cat > "$W/u1/m.swift" <<'SW'
import Foundation
func readFile(p: String) { _ = try? String(contentsOfFile: p, encoding: .utf8) }     // Fs
func readData(p: String) { _ = try? Data(contentsOf: URL(fileURLWithPath: p)) }       // Fs CONTROL (contentsOf path still works)
SW
"$BIN" "$W/u1" --out "$W/u1/r" >/dev/null 2>&1
U1=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/u1/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = by.get('readFile')=={'Fs'} and by.get('readData')=={'Fs'}
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$U1" = "PASS" ] && ok "U1: String(contentsOfFile:) -> Fs (unconditional file read; contentsOf: still resolves)" || bad "U1 contentsOfFile: $U1"

# REGRESSION N1: a method on a NESTED type (`extension Outer.Inner { func wipe() }`), called from
# OUTSIDE via a `Outer.Inner`-typed PARAM or a `Outer.Inner()` CTOR binding, must resolve to the nested
# unit `Outer.Inner.wipe` (Fs) — the qualified-nested receiver couldn't bind before and read silent-pure.
# Controls: a same-named TOP-LEVEL `Inner` with a PURE method must NOT inherit the nested Fs (no fabrication).
mkdir -p "$W/n1" && cat > "$W/n1/m.swift" <<'SW'
import Foundation
struct Outer { struct Inner {} }
extension Outer.Inner { func wipe() { try? FileManager.default.removeItem(atPath:"/tmp/x") } }
func s_param(i: Outer.Inner) { i.wipe() }                 // Fs via nested-type param
func s_ctor() { let i = Outer.Inner(); i.wipe() }         // Fs via nested-type ctor
struct Inner { func wipe() {} }                            // a DISTINCT top-level Inner — PURE
func topCtrl() { let i = Inner(); i.wipe() }              // must stay pure (no nested Fs fabrication)
SW
"$BIN" "$W/n1" --out "$W/n1/r" >/dev/null 2>&1
N1=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/n1/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = by.get('s_param')=={'Fs'} and by.get('s_ctor')=={'Fs'} and 'topCtrl' not in by
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$N1" = "PASS" ] && ok "N1: nested-type method resolves via param + ctor (Outer.Inner.wipe Fs; distinct top-level Inner stays pure)" || bad "N1 nested-type: $N1"

# REGRESSION N2: a typealiased receiver/type must resolve THROUGH the alias before the κ classifier
# (`typealias Proc = Process` → Exec; `typealias FM = FileManager` → Fs) — the κ table keys on the literal
# spelling, so an alias evaded it and hid Exec/Fs. Control: an alias to a LOCAL type with a PURE method
# must NOT fabricate, and a same-named LOCAL type shadows an alias (never overridden).
mkdir -p "$W/n2" && cat > "$W/n2/m.swift" <<'SW'
import Foundation
typealias Proc = Process
func aliasExec() { let p = Proc(); p.launchPath="/bin/ls"; try? p.run() }   // Exec through the alias
typealias FM = FileManager
func aliasFs() { try? FM.default.removeItem(atPath:"/tmp/z") }              // Fs through the alias
struct Widget { func run() {} }
typealias W2 = Widget
func aliasLocalCtrl() { let w = W2(); w.run() }                            // alias to a PURE local — stays pure
SW
"$BIN" "$W/n2" --out "$W/n2/r" >/dev/null 2>&1
N2=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/n2/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = by.get('aliasExec')=={'Exec'} and by.get('aliasFs')=={'Fs'} and 'aliasLocalCtrl' not in by
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$N2" = "PASS" ] && ok "N2: typealiased receiver resolves through alias (Proc->Exec, FM->Fs; alias-to-pure-local stays pure)" || bad "N2 typealias: $N2"

# REGRESSION N3: an INFERRED-type fn-value local bound to a NAMED local fn (`let g = eff`) invoked
# `g()` must edge to `eff` (the real unit — better than Unknown), honoring the README §4 contract that a
# function-typed value invoked is NEVER silent pure. The explicit-annotation form (`let g: ()->Void = eff`)
# already disclosed Unknown — keep it. Control: a let bound to an ordinary VALUE (not a fn) must NOT edge.
mkdir -p "$W/n3" && cat > "$W/n3/m.swift" <<'SW'
import Foundation
func eff() { try? FileManager.default.removeItem(atPath:"/tmp/x") }
func varTyped() { let g: () -> Void = eff; g() }    // Unknown (annotated, opaque) — contract held
func varInfer() { let g = eff; g() }                // Fs — resolves to eff's real edge (was silent-pure)
func plainVal() { let x = 41; _ = x + 1 }           // a value copy, NOT a fn — must stay pure (no fabrication)
SW
"$BIN" "$W/n3" --out "$W/n3/r" >/dev/null 2>&1
N3=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/n3/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = by.get('varTyped')=={'Unknown'} and by.get('varInfer')=={'Fs'} and 'plainVal' not in by
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$N3" = "PASS" ] && ok "N3: inferred-type fn-value 'let g = eff; g()' resolves to eff (Fs); annotated stays Unknown; value copy pure" || bad "N3 fn-value infer: $N3"

# REGRESSION N4: a STRING-LITERAL receiver `.write(toFile:)`/`.write(to:)` is a String file write -> Fs
# (the `isFileWrite` gate keyed only on a String-TYPED identifier). Control: the pure `write(to:&stream)`
# TextOutputStream overload must NOT be classified Fs (the inout guard still excludes it — no fabrication).
mkdir -p "$W/n4" && cat > "$W/n4/m.swift" <<'SW'
import Foundation
func litWrite() { try? "data".write(toFile:"/tmp/z", atomically:true, encoding:.utf8) }   // Fs (literal receiver)
func litUrl() { try? "data".write(to: URL(fileURLWithPath:"/tmp/z"), atomically:true, encoding:.utf8) } // Fs (to: file)
func litStream(s: inout String) { "data".write(to: &s) }                                   // PURE TextOutputStream sink
SW
"$BIN" "$W/n4" --out "$W/n4/r" >/dev/null 2>&1
N4=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/n4/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = by.get('litWrite')=={'Fs'} and by.get('litUrl')=={'Fs'} and 'litStream' not in by
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$N4" = "PASS" ] && ok "N4: string-literal receiver write(toFile:)/write(to:file) -> Fs; inout TextOutputStream sink stays pure" || bad "N4 literal write: $N4"

# REGRESSION N4b (cross-engine write!/fmt::Write writer-side sweep, 2026-06-18): an EFFECTFUL custom
# TextOutputStream reached via `print(x, to: &s)` or `value.write(to: &s)` must charge the stream's
# `write` — it was silent-pure (the same shared blind spot the rust deep+scan engines had). A std String
# sink stays pure (no fabrication).
mkdir -p "$W/n4b" && cat > "$W/n4b/m.swift" <<'SW'
import Foundation
struct LoudStream: TextOutputStream { mutating func write(_ s: String) { _ = FileManager.default.contents(atPath: "/tmp/x") } }
func viaPrintTo() { var s = LoudStream(); print("hi", to: &s) }      // Fs (print drives LoudStream.write)
func viaWriteTo() { var s = LoudStream(); "hello".write(to: &s) }    // Fs (String.write(to:) drives s.write)
func viaStdString() { var out = ""; print("hi", to: &out) }         // PURE (std String sink)
SW
"$BIN" "$W/n4b" --out "$W/n4b/r" >/dev/null 2>&1
N4B=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/n4b/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = 'Fs' in by.get('viaPrintTo',set()) and 'Fs' in by.get('viaWriteTo',set()) and 'viaStdString' not in by
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$N4B" = "PASS" ] && ok "N4b: effectful TextOutputStream via print(to:)/write(to:) -> Fs; std String sink stays pure" || bad "N4b writer side: $N4B"

# REGRESSION S1 (FINDING 1): an effectful custom Sequence/IteratorProtocol returned behind an OPAQUE
# (`some Sequence`) or ERASED (`AnySequence`) type must NOT read silent-pure at the CONSUMER that iterates
# it. When the builder body returns a CONCRETE LOCAL iterable the iteration edges to its `next` (precise Fs);
# when the concrete type is genuinely unresolvable it reads honest Unknown. Controls: a PURE opaque sequence
# forced stays pure (no fabrication); the concrete-return form still classifies Fs.
mkdir -p "$W/s1" && cat > "$W/s1/m.swift" <<'SW'
import Foundation
struct FileEater: Sequence, IteratorProtocol {
    mutating func next() -> Bool? { try? FileManager.default.removeItem(atPath:"/t"); return nil }
}
struct Builder {
    func build(_ xs:[Int]) -> some Sequence<Bool> { FileEater() }
    func buildAny(_ xs:[Int]) -> AnySequence<Bool> { AnySequence(FileEater()) }
    func buildConcrete(_ xs:[Int]) -> FileEater { FileEater() }
}
struct Runner {
    func run(_ b: Builder) { for _ in b.build([1]) {} }            // Fs (precise via FileEater.next)
    func runAny(_ b: Builder) { for _ in b.buildAny([1]) {} }      // Fs (precise, eraser peeled)
    func runConcrete(_ b: Builder) { for _ in b.buildConcrete([1]) {} }  // Fs (concrete return)
}
func makeExternalSeq() -> some Sequence<Int> { stride(from:0,to:3,by:1) }   // returns a non-local stdlib seq
struct Honest { func run() { for _ in makeExternalSeq() {} } }              // Unknown (honest, unresolvable)
struct PureEater: Sequence, IteratorProtocol { mutating func next() -> Int? { return nil } }
struct PureBuilder { func build() -> some Sequence<Int> { PureEater() } }
struct PureRunner { func run(_ b: PureBuilder) { for _ in b.build() {} } }   // PURE (no fabrication)
SW
"$BIN" "$W/s1" --out "$W/s1/r" >/dev/null 2>&1
S1=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/s1/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = (by.get('Runner.run')=={'Fs'} and by.get('Runner.runAny')=={'Fs'} and by.get('Runner.runConcrete')=={'Fs'}
      and by.get('Honest.run')=={'Unknown'} and 'PureRunner.run' not in by and 'PureBuilder.build' not in by)
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items() if k.split('.')[0] in ('Runner','Honest','PureRunner','PureBuilder')}))")
[ "$S1" = "PASS" ] && ok "S1: opaque/erased effectful Sequence forced -> Fs (precise) or Unknown (honest); pure opaque seq stays pure" || bad "S1 opaque-sequence: $S1"

# REGRESSION S2 (FINDING 2): invoking a stored effectful CLOSURE PROPERTY must reach the closure's effects —
# whether INVOKED directly (`f(0)`), via the implicit-self bare form, via an explicit receiver (`obj.f()`),
# or passed as a fn-ref to a HOF that invokes it (`map(transform)`). Property-scoped: a PURE closure property
# contributes nothing (no flood, no fabrication). A method-reference (`map(zap)`) still resolves (control).
mkdir -p "$W/s2" && cat > "$W/s2/m.swift" <<'SW'
import Foundation
struct Holder {
    let transform: (Int)->Void = { _ in try? FileManager.default.removeItem(atPath:"/t") }
    func build(_ xs:[Int]) { _ = xs.lazy.map(transform) }    // Fs (closure prop passed to map)
}
struct Direct {
    let f: (Int)->Void = { _ in try? FileManager.default.removeItem(atPath:"/t") }
    func call() { f(0) }                                     // Fs (bare invoke)
}
struct ViaRecv {
    let g: (Int)->Void = { _ in try? FileManager.default.removeItem(atPath:"/t") }
    func call(_ o: ViaRecv) { o.g(0) }                       // Fs (explicit receiver invoke)
}
struct MethodRef {
    func zap(_ x:Int) { try? FileManager.default.removeItem(atPath:"/t") }
    func build(_ xs:[Int]) { _ = xs.map(zap) }               // Fs (method-ref control)
}
struct PureHolder {
    let transform: (Int)->Void = { _ in print($0) }
    func build(_ xs:[Int]) { _ = xs.lazy.map(transform) }    // PURE (no fabrication)
}
struct PureDirect {
    let f: (Int)->Void = { _ in _ = $0 }
    func call() { f(0) }                                     // PURE (no fabrication)
}
SW
"$BIN" "$W/s2" --out "$W/s2/r" >/dev/null 2>&1
S2=$(python3 -c "
import json,glob
r=json.load(open([p for p in glob.glob('$W/s2/r.*.json') if 'callgraph' not in p and 'hierarchy' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = (by.get('Holder.build')=={'Fs'} and by.get('Direct.call')=={'Fs'} and by.get('ViaRecv.call')=={'Fs'}
      and by.get('MethodRef.build')=={'Fs'} and 'PureHolder.build' not in by and 'PureDirect.call' not in by)
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items() if k.split('.')[0] in ('Holder','Direct','ViaRecv','MethodRef','PureHolder','PureDirect')}))")
[ "$S2" = "PASS" ] && ok "S2: invoked stored closure property reaches Fs (bare/receiver/map-ref); method-ref control Fs; pure closure prop stays pure" || bad "S2 closure-property: $S2"

# --agents: the self-describing engine (the contract is embedded as a Swift constant). The drift
# gate diffs the ACTUAL served contract (minus the version-header line) against AGENTS.md — testing
# end to end, and catching a stale AgentsDoc.swift (regenerate: python3 gen-agents-doc.py).
HERE_DIR="$(cd "$(dirname "$0")" && pwd)"
"$BIN" --agents > "$W/agents.out" 2>&1
grep -q '<!-- candor-swift' "$W/agents.out" && ok "--agents prints the version header" || bad "--agents header"
grep -q 'Using candor-swift' "$W/agents.out" && ok "--agents prints the installed contract" || bad "--agents contract"
tail -n +2 "$W/agents.out" > "$W/agents.body"
cmp -s "$HERE_DIR/AGENTS.md" "$W/agents.body" \
  && ok "served --agents contract matches AGENTS.md (drift gate)" \
  || bad "embedded contract drifted from AGENTS.md — regenerate: python3 gen-agents-doc.py"
# SPEC-STRING drift: every `spec <X>` claim in AGENTS.md must match the spec the BINARY declares. The
# embedded==file gate above can't catch a COHERENT stale pair (an 0.8 binary shipped an AGENTS.md still
# claiming spec 0.7 — v0.8.3). Case-sensitive: the uppercase `SPEC §…` section refs are not versions.
BSPEC=$("$BIN" --version 2>/dev/null | sed -nE 's/.*\(spec ([0-9.]+)\).*/\1/p' | head -1)
STALE=$(grep -oE 'spec[^0-9A-Za-z]{1,4}[0-9]+\.[0-9]+' "$HERE_DIR/AGENTS.md" | grep -v "$BSPEC" || true)
{ [ -n "$BSPEC" ] && [ -z "$STALE" ]; } \
  && ok "AGENTS.md spec strings all match the binary's declared spec ($BSPEC)" \
  || bad "AGENTS.md spec drift (binary declares spec ${BSPEC:-???}): ${STALE:-no spec string found}"
# README's headline spec claim must match the binary too (it said 0.5 while the engine spoke 0.8).
grep -qF "candor-spec) $BSPEC" "$HERE_DIR/README.md" \
  && ok "README's candor-spec version matches the binary ($BSPEC)" \
  || bad "README spec drift: expected 'candor-spec) $BSPEC' in README.md"

# Write-failure is GRACEFUL, not a crash. A report write that can't happen (unwritable --out path)
# used to `try!`-TRAP after the whole scan finished (SIGILL, no message). It must now exit 1 with a
# named diagnostic instead — so a sandbox/CI write failure is a readable error, not a crash signal.
cat > "$W/wf.swift" <<'SW'
import Foundation
func wf() { _ = FileManager.default }
SW
WF_ERR=$("$BIN" "$W/wf.swift" --out /proc/cannot/r 2>&1 >/dev/null); WF_CODE=$?
{ [ "$WF_CODE" -eq 1 ] && echo "$WF_ERR" | grep -q "could not write report"; } \
  && ok "unwritable --out path -> exit 1 + diagnostic (no try! trap)" \
  || bad "unwritable --out should fail gracefully (code=$WF_CODE, err=$WF_ERR)"

# MASKING gate-evasion (AS-EFF-008): a fn with one captured BENIGN host AND one structurally-invisible
# Net reach (URLSession to a runtime URL) must NOT certify under `allow Net <benign>` — the benign literal
# would otherwise MASK the invisible forbidden endpoint. A clean fn with only the benign host DOES certify.
mkdir -p "$W/mask" && cat > "$W/mask/m.swift" <<'SW'
import Foundation
import Network
func mask(_ url: URL) {
    let c = NWConnection(host: "benign.internal", port: 443, using: .tls)
    c.start(queue: .main)
    _ = URLSession.shared.dataTask(with: url)   // Net, host INVISIBLE — masks under the allowlist
}
func clean() {
    let c = NWConnection(host: "benign.internal", port: 443, using: .tls)
    c.start(queue: .main)
}
SW
printf 'allow Net benign.internal\n' > "$W/mask/pol"
"$BIN" "$W/mask" --out "$W/mask/r" --policy "$W/mask/pol" > "$W/mask/gate.out" 2>&1
{ grep -q 'AS-EFF-008.*`mask`' "$W/mask/gate.out" \
  && ! grep -q '`clean`' "$W/mask/gate.out"; } \
  && ok "masking guard: invisible-host Net fails closed under an allowlist; the clean host certifies" \
  || bad "masking guard: $(cat "$W/mask/gate.out")"

# Masking is NOT Net-only (sweep [14]/[15]): an Fs path-establishing call with a runtime (invisible) path
# masked by a benign allowlisted literal must ALSO fail closed. `cleanFs` (benign literal only) certifies.
mkdir -p "$W/maskfs" && cat > "$W/maskfs/m.swift" <<'SW'
import Foundation
func maskFs(_ p: String) {
    try? FileManager.default.removeItem(atPath: "/var/app/ok.txt")   // benign literal path (captured)
    try? FileManager.default.removeItem(atPath: p)                    // runtime path — structurally INVISIBLE
}
func cleanFs() { try? FileManager.default.removeItem(atPath: "/var/app/ok.txt") }
SW
printf 'allow Fs /var/app\n' > "$W/maskfs/pol"
"$BIN" "$W/maskfs" --out "$W/maskfs/r" --policy "$W/maskfs/pol" > "$W/maskfs/gate.out" 2>&1
{ grep -q 'AS-EFF-008.*`maskFs`' "$W/maskfs/gate.out" \
  && ! grep -q '`cleanFs`' "$W/maskfs/gate.out"; } \
  && ok "masking guard generalizes to Fs: invisible-path Fs fails closed; the clean path certifies" \
  || bad "Fs masking guard: $(cat "$W/maskfs/gate.out")"

# Masking generalizes to Exec via ShellOut (gate-masking cross-engine sweep, 2026-06-18): shellOut(to:)
# takes the command as its ARG → establishing, so a MASKED (runtime) command beside a benign literal must
# FAIL closed under `allow Exec <benign>` — else `shellOut(to: runtimeVar)` evades the allowlist (shellOut
# was classified Exec but was MISSING from the Exec establishing set). `cleanSh` (literal only) certifies.
mkdir -p "$W/masksh" && cat > "$W/masksh/m.swift" <<'SW'
import Foundation
import ShellOut
func maskSh(_ c: String) {
    let _ = try? shellOut(to: "ls")   // benign literal command (captured)
    let _ = try? shellOut(to: c)      // runtime command — structurally INVISIBLE
}
func cleanSh() { let _ = try? shellOut(to: "ls") }
SW
printf 'allow Exec ls\n' > "$W/masksh/pol"
"$BIN" "$W/masksh" --out "$W/masksh/r" --policy "$W/masksh/pol" > "$W/masksh/gate.out" 2>&1
{ grep -q 'AS-EFF-008.*`maskSh`' "$W/masksh/gate.out" \
  && ! grep -q '`cleanSh`' "$W/masksh/gate.out"; } \
  && ok "masking guard generalizes to Exec/shellOut: masked command fails closed; the clean command certifies" \
  || bad "Exec/shellOut masking guard: $(cat "$W/masksh/gate.out")"

# Two-path Fs masking (HIGH gate-evasion): a multi-locator op (copyItem/createSymbolicLink/…) captures
# only the FIRST path as the surface, so a literal SOURCE masks a runtime DESTINATION. The gate must
# inspect EVERY locator: incomplete unless ALL are literals. `exfilCopy`/`clobberLink` (masked dst/src)
# must FAIL closed; `legitCopy` (BOTH literals, both under the allowlist) must still certify (no false
# positive). Single-path `removeItem` is unchanged (literal certifies / masked fails — covered above).
mkdir -p "$W/tpfs" && cat > "$W/tpfs/m.swift" <<'SW'
import Foundation
func exfilCopy(_ dst: String) { try? FileManager.default.copyItem(atPath: "/tmp/ok/src", toPath: dst) }   // masked dst
func clobberLink(_ dst: String) { try? FileManager.default.createSymbolicLink(atPath: dst, withDestinationPath: "/tmp/ok/x") }
func legitCopy() { try? FileManager.default.copyItem(atPath: "/tmp/ok/a", toPath: "/tmp/ok/b") }            // BOTH literal + allowed
SW
printf 'allow Fs /tmp/ok\n' > "$W/tpfs/pol"
"$BIN" "$W/tpfs" --out "$W/tpfs/r" --policy "$W/tpfs/pol" > "$W/tpfs/gate.out" 2>&1
{ grep -q 'AS-EFF-008.*`exfilCopy`' "$W/tpfs/gate.out" \
  && grep -q 'AS-EFF-008.*`clobberLink`' "$W/tpfs/gate.out" \
  && ! grep -q '`legitCopy`' "$W/tpfs/gate.out"; } \
  && ok "two-path Fs masking: masked dst/src fails closed; a two-literal copy under the allowlist certifies" \
  || bad "two-path Fs masking guard: $(cat "$W/tpfs/gate.out")"

# Per-fn `invisible` disclosure: a pure-LOOKING fn that reaches a blind (κ-unknown) module via an
# unresolved external call carries `invisible:[module]` (so `inferred:[]` is never an unqualified pure
# claim); it propagates to a transitive caller; a purely-LOCAL pure fn in the same file is NOT tagged.
mkdir -p "$W/inv" && cat > "$W/inv/m.swift" <<'SW'
import Foundation
import SomeBlindNetLib
func fetch() { let c = BlindClient(); c.send("payload") }   // unresolved external reach → invisible
func caller() { fetch() }                                   // transitive → inherits invisible
func leaf() -> Int { return 1 }
func localOnly() -> Int { return leaf() + leaf() }          // only a resolved local sibling → NOT tagged
func adder(_ a: Int, _ b: Int) -> Int { return a + b }      // pure, no calls → omitted
func usesStdlib(_ s: String) -> String { return s.uppercased() }  // κ-known-pure MEMBER call → NOT tagged
func usesPlatform(_ p: NSPasteboard) -> Bool { return p.canReadObject(forClasses: [], options: nil) }  // ditto
SW
"$BIN" "$W/inv" --out "$W/inv/r" >/dev/null 2>&1
INVRPT=$(ls "$W"/inv/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
INV=$(python3 -c "
import json
d=json.load(open('$INVRPT'))
by={e['fn']: e for e in d['functions']}
fetch_ok = by.get('fetch',{}).get('invisible')==['SomeBlindNetLib'] and by['fetch']['inferred']==[]
caller_ok = by.get('caller',{}).get('invisible')==['SomeBlindNetLib']
# the over-disclosure guard (sweep [33]/[36]): a κ-known-pure MEMBER call is NOT a blind reach, even in a
# file importing a blind module — only an unqualified free/ctor reach is. localOnly/adder pure & omitted.
no_overdisclose = all(n not in by for n in ('localOnly','adder','usesStdlib','usesPlatform'))
print('PASS' if (fetch_ok and caller_ok and no_overdisclose) else 'FAIL '+repr({k:v.get('invisible') for k,v in by.items()}))")
[ "$INV" = "PASS" ] && ok "invisible disclosure: blind free/ctor reach tagged + propagated; κ-pure member calls NOT over-disclosed" || bad "invisible disclosure: $INV"

# DNS resolution classifies as Net (sweep [20]: was floored silently while rust/java/ts classify it).
mkdir -p "$W/dns" && cat > "$W/dns/m.swift" <<'SW'
import Foundation
func resolve(_ h: String) -> Int32 {
    var hints = addrinfo(); var res: UnsafeMutablePointer<addrinfo>? = nil
    let rc = getaddrinfo(h, "80", &hints, &res); freeaddrinfo(res); return rc
}
SW
"$BIN" "$W/dns" --out "$W/dns/r" >/dev/null 2>&1
DNSRPT=$(ls "$W"/dns/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
DNS=$(python3 -c "
import json
by={e['fn']:set(e.get('inferred',[])) for e in json.load(open('$DNSRPT'))['functions']}
print('PASS' if 'Net' in by.get('resolve',set()) else 'FAIL '+repr(by.get('resolve','absent')))")
[ "$DNS" = "PASS" ] && ok "DNS (getaddrinfo) classifies as Net" || bad "DNS classify: $DNS"

# Policy parser splits on bare \r (classic-Mac) line endings (sweep [16]/[17]): a multi-rule policy with
# bare-CR endings must NOT collapse to the first rule. `deny Exec hop` is rule 2, AFTER a bare \r.
mkdir -p "$W/cr" && printf 'import Foundation\nfunc hop() { _ = Process() }\n' > "$W/cr/m.swift"
printf 'deny Clock nope\rdeny Exec hop\rdeny Net nope2\r' > "$W/cr/pol"
"$BIN" "$W/cr" --out "$W/cr/r" --policy "$W/cr/pol" > "$W/cr/gate.out" 2>&1
grep -q 'AS-EFF-006.*`hop`.*Exec' "$W/cr/gate.out" \
  && ok "policy parser splits bare-CR line endings (rule after \\\\r is not dropped)" \
  || bad "bare-CR policy parse: $(cat "$W/cr/gate.out")"

# IMPLICIT-CONVERSION / COERCION edges: an effect reached through a protocol WITNESS (CustomStringConvertible
# `description`, ExpressibleBy*Literal `init`, Comparable `<`) is never spelled at the call site but RUNS — a
# fn reported pure while the witness does I/O is the cardinal sin. The witness is edged ONLY when the operand's
# TYPE resolves to a LOCAL type that declares it; a non-local (Int/String/external) operand stays pure; a PURE
# witness contributes nothing. Covers all 4 vectors + their no-fabrication controls.
mkdir -p "$W/ic" && cat > "$W/ic/m.swift" <<'SW'
import Foundation
// effectful description (the realistic format(w) shape from the brief)
struct W: CustomStringConvertible {
    var description: String { try? FileManager.default.removeItem(atPath: "/tmp/x"); return "w" }
    var debugDescription: String { try? FileManager.default.removeItem(atPath: "/tmp/d"); return "d" }
}
func fmtInterp(_ w: W) -> String { return "row=\(w)" }          // V1 interpolation -> description -> Fs
func fmtDescribing(_ w: W) { _ = String(describing: w) }        // V2 String(describing:) -> description -> Fs
func fmtReflecting(_ w: W) { _ = String(reflecting: w) }        // V2 String(reflecting:) -> debugDescription -> Fs
func fmtPrint(_ w: W) { print(w) }                              // V2 print -> description -> Fs
// effectful ExpressibleBy*Literal init
struct Lit: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { try? FileManager.default.removeItem(atPath: "/tmp/lit") }
}
func makeLit() { let _: Lit = "hi" }                            // V3 literal init -> Fs
// effectful Comparable < reached via sorted()
struct Item: Comparable {
    let n: Int
    static func < (a: Item, b: Item) -> Bool { try? FileManager.default.removeItem(atPath: "/tmp/c"); return a.n < b.n }
    static func == (a: Item, b: Item) -> Bool { return a.n == b.n }
}
func sortItems(_ xs: [Item]) -> [Item] { return xs.sorted() }   // V4 Comparable via sorted() -> Fs
// ── NO-FABRICATION CONTROLS ──
struct PW: CustomStringConvertible { var description: String { return "pure" } }
func fmtPureDesc(_ p: PW) -> String { return "x=\(p)" }         // pure description -> pure
struct PLit: ExpressibleByStringLiteral { init(stringLiteral value: String) { } }
func makePureLit() { let _: PLit = "hi" }                       // pure literal init -> pure
struct PItem: Comparable {
    let n: Int
    static func < (a: PItem, b: PItem) -> Bool { return a.n < b.n }
    static func == (a: PItem, b: PItem) -> Bool { return a.n == b.n }
}
func sortPureItems(_ xs: [PItem]) -> [PItem] { return xs.sorted() }  // pure < -> pure
func fmtInt(_ i: Int) -> String { return "n=\(i)" }             // interpolate Int (non-local witness) -> pure
func sortInts(_ xs: [Int]) -> [Int] { return xs.sorted() }      // sort [Int] (non-local <) -> pure
SW
"$BIN" "$W/ic" --out "$W/ic/r" >/dev/null 2>&1
ICRPT=$(ls "$W"/ic/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
IC=$(python3 -c "
import json
by={e['fn']:set(e.get('inferred',[])) for e in json.load(open('$ICRPT'))['functions']}
eff = ['fmtInterp','fmtDescribing','fmtReflecting','fmtPrint','makeLit','sortItems']
pure = ['fmtPureDesc','makePureLit','sortPureItems','fmtInt','sortInts']
ok = all(by.get(f)=={'Fs'} for f in eff) and all(f not in by for f in pure)
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$IC" = "PASS" ] && ok "implicit-conversion edges: description-via-interpolation/String(describing:)/print + literal-init + Comparable-via-sorted carry Fs; pure witnesses + Int/[Int] stay pure (no fabrication)" || bad "implicit-conversion: $IC"

# EXTENSION OF A PLATFORM EFFECTFUL TYPE: `extension Process { func go() { launch() } }` — an implicit/
# explicit-self call to a κ-platform member is a REAL effect, NOT a project method. `pushType` adds the
# extended type to localTypes (so sibling helpers resolve) but the shadow guard keyed on localTypes treated
# `self.launch()` as a local dispatch resolving to nothing → silent-pure (the ShellOut `launchBash` cardinal
# sin: its Process.launch()/Pipe-Exec was lost, the whole point of the library). Only a DECLARED type
# (declaredTypes) shadows κ; an extension-ONLY κ-platform type falls through to the κ table. Controls: a
# locally-DECLARED type extended with the SAME platform name still shadows (no fabrication on project code).
mkdir -p "$W/ex" && cat > "$W/ex/m.swift" <<'SW'
import Foundation
extension Process {
    func goSelf() { self.launch() }              // Exec (explicit self)
    func goImplicit() { launch() }               // Exec (implicit self)
}
extension URLSession {
    func fetchSelf() async throws { _ = try await self.data(from: URL(string: "https://h")!) }  // Net
}
extension FileManager {
    func nukeSelf() throws { try self.removeItem(atPath: "/tmp/x") }                              // Fs
}
SW
# A project's OWN type DECLARED locally must shadow the platform κ table even when extended with a
# platform-collision name — scanned SEPARATELY (a real project can't both declare `struct Process` AND
# extend the platform Process — they are the same symbol; merging the files into one scan is the conflated
# case where the local declaration legitimately wins for the WHOLE scan).
mkdir -p "$W/exs" && cat > "$W/exs/m.swift" <<'SW'
import Foundation
struct Process { func launch() {} }
extension Process { func goLocal() { self.launch() }      // PURE — declared locally, shadows κ
                    func goLocalImplicit() { launch() } }  // PURE
SW
"$BIN" "$W/ex" --out "$W/ex/r" >/dev/null 2>&1
"$BIN" "$W/exs" --out "$W/exs/r" >/dev/null 2>&1
EXRPT=$(ls "$W"/ex/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
EXSRPT=$(ls "$W"/exs/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
EX=$(python3 -c "
import json
by={e['fn']:set(e.get('inferred',[])) for e in json.load(open('$EXRPT'))['functions']}
sb={e['fn']:set(e.get('inferred',[])) for e in json.load(open('$EXSRPT'))['functions']}
want={'Process.goSelf':{'Exec'},'Process.goImplicit':{'Exec'},'URLSession.fetchSelf':{'Net'},'FileManager.nukeSelf':{'Fs'}}
shadow=['Process.goLocal','Process.goLocalImplicit']
ok = all(by.get(k)==v for k,v in want.items()) and all(k not in sb for k in shadow)
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()})+' shadow='+repr({k:sorted(v) for k,v in sb.items()}))")
[ "$EX" = "PASS" ] && ok "extension of platform type: self.launch()/data()/removeItem() in extension Process/URLSession/FileManager carry Exec/Net/Fs; a DECLARED-local same-name type still shadows (no fabrication)" || bad "extension-platform-self: $EX"

# THIRD-PARTY Fs/Exec PACKAGES (the differential): JohnSundell's `Files` (File/Folder/Storage do real Fs)
# and `ShellOut` (shellOut(to:) runs /bin/bash) read silent-pure as `invisible` third-party modules. Model
# the EFFECTFUL members (read/write/delete/createFile/ctors → Fs; shellOut → Exec); the pure surface
# (`.path` property, builders) stays pure. Controls: a project's OWN `struct File`/`func shellOut` shadows.
mkdir -p "$W/fl" && cat > "$W/fl/m.swift" <<'SW'
import Foundation
import Files
import ShellOut
func flRead(_ f: File) throws { _ = try f.read() }                    // Fs
func flWrite(_ f: File) throws { try f.write("hi") }                  // Fs
func flDelete(_ f: File) throws { try f.delete() }                    // Fs
func flCreate(_ d: Folder) throws { _ = try d.createFile(named: "x") } // Fs
func flOpenFile() throws { _ = try File(path: "/x") }                 // Fs (ctor resolves path)
func flOpenFolder() throws { _ = try Folder(path: "/x") }            // Fs (ctor)
func flPath(_ f: File) -> String { return f.path }                   // PURE (property read)
func flShell() throws { try shellOut(to: "ls") }                     // Exec
SW
# project's OWN File/Folder/shellOut shadow the package models — scanned SEPARATELY (a local declaration
# of File/Folder/shellOut is the project's own symbol for the WHOLE scan; the package types can't coexist).
mkdir -p "$W/fls" && cat > "$W/fls/m.swift" <<'SW'
import Foundation
struct File { func read() -> Int { 1 }; var path: String { "p" } }
struct Folder { func createFile(named: String) -> Int { 0 } }
func shellOut(to s: String) -> Int { 0 }
func locRead(_ f: File) -> Int { f.read() }                          // PURE
func locCreate(_ d: Folder) -> Int { d.createFile(named: "x") }     // PURE
func locShell() -> Int { shellOut(to: "x") }                        // PURE
SW
"$BIN" "$W/fl" --out "$W/fl/r" >/dev/null 2>&1
"$BIN" "$W/fls" --out "$W/fls/r" >/dev/null 2>&1
FLRPT=$(ls "$W"/fl/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
FLSRPT=$(ls "$W"/fls/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
FL=$(python3 -c "
import json
by={e['fn']:set(e.get('inferred',[])) for e in json.load(open('$FLRPT'))['functions']}
sb={e['fn']:set(e.get('inferred',[])) for e in json.load(open('$FLSRPT'))['functions']}
fs=['flRead','flWrite','flDelete','flCreate','flOpenFile','flOpenFolder']
ok = all(by.get(f)=={'Fs'} for f in fs) and by.get('flShell')=={'Exec'} \
     and 'flPath' not in by \
     and all(k not in sb for k in ['locRead','locCreate','locShell'])
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()})+' shadow='+repr({k:sorted(v) for k,v in sb.items()}))")
[ "$FL" = "PASS" ] && ok "third-party Fs/Exec packages: Files File/Folder read/write/delete/createFile/ctors -> Fs, ShellOut shellOut(to:) -> Exec; .path property + local File/Folder/shellOut stay pure (no fabrication)" || bad "Files/ShellOut coverage: $FL"

# EXTENSION-OF-PLATFORM-TYPE must NOT shadow the κ table (real-world dogfood vein: SwiftLint's
# `extension ProcessInfo {}` silently zeroed ALL Env detection project-wide; FileManager property reads
# were also dead). An extension ADDS members — the platform type's effectful members still exist — so
# the property-read κ-path gates shadowing on declaredTypes (real defs), not localTypes (incl. extensions).
cat > "$W/ext.swift" <<'SW'
import Foundation
extension ProcessInfo { var candorHelper: Int { 1 } }
extension FileManager { var candorHelper: Int { 1 } }
func extEnv() { _ = ProcessInfo.processInfo.environment["X"] }   // Env (survives the extension)
func extCwd() { _ = FileManager.default.currentDirectoryPath }   // Fs (property-form, survives)
SW
"$BIN" "$W/ext.swift" --out "$W/ext" 2>/dev/null
ERPT=$(ls "$W"/ext.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
echk() { python3 -c "import json,sys; d=json.load(open('$ERPT')); print(next((','.join(sorted(f['inferred'])) for f in d['functions'] if f['fn']==sys.argv[1]), 'absent'))" "$1"; }
[ "$(echk extEnv)" = "Env" ] && ok "extension ProcessInfo does NOT shadow its κ table — env read still Env (dogfood vein)" || bad "extension-shadow Env: got $(echk extEnv)"
[ "$(echk extCwd)" = "Fs" ]  && ok "extension FileManager + property-form currentDirectoryPath -> Fs (dogfood vein)"      || bad "extension-shadow/property Fs: got $(echk extCwd)"
# anti-fabrication control: a REAL local decl of the same name SHADOWS the platform table (stays pure).
cat > "$W/shd.swift" <<'SW'
struct ProcessInfo { let processInfo = Inner(); struct Inner { let environment = [String: String]() } }
func locEnv() { _ = ProcessInfo.processInfo.environment["X"] }   // PURE — a real local decl shadows κ
SW
"$BIN" "$W/shd.swift" --out "$W/shd" 2>/dev/null
SHRPT=$(ls "$W"/shd.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
shchk() { python3 -c "import json,sys; d=json.load(open('$SHRPT')); print(next((','.join(sorted(f['inferred'])) for f in d['functions'] if f['fn']==sys.argv[1]), 'absent'))" "$1"; }
[ "$(shchk locEnv)" = "absent" ] && ok "a REAL local ProcessInfo decl still shadows the κ table (no fabrication)" || bad "local-shadow control: locEnv got $(shchk locEnv)"

# `.write(to:)` Fs must survive (a) a Foundation Data-PRODUCER receiver (`encode(...)` / `.data(using:)`,
# inline / via let / via guard-let) and (b) a project `extension Data`. Real-world dogfood vein: SwiftLint's
# `extension Data` made `data.write(to:)` resolve to a phantom local Data.write (pure), and the encoder/
# data(using:) chains read silent-pure because rootOf typed them by the chain root, not the Data result.
cat > "$W/bw.swift" <<'SW'
import Foundation
extension Data { var candorX: Int { 1 } }   // an extension must NOT shadow Data's file-write κ effect
func bwInline() throws { try JSONEncoder().encode([1]).write(to: URL(fileURLWithPath: "/x")) }
func bwLocal(s: String) throws { let d = s.data(using: .utf8); try d?.write(to: URL(fileURLWithPath: "/x")) }
func bwGuard(s: String) throws { guard let d = s.data(using: .utf8) else { return }; try d.write(to: URL(fileURLWithPath: "/x")) }
func bwParam(data: Data) throws { try data.write(to: URL(fileURLWithPath: "/x")) }
SW
"$BIN" "$W/bw.swift" --out "$W/bw" 2>/dev/null
BWRPT=$(ls "$W"/bw.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
bwchk() { python3 -c "import json,sys; d=json.load(open('$BWRPT')); print(next((','.join(sorted(f['inferred'])) for f in d['functions'] if f['fn']==sys.argv[1]), 'absent'))" "$1"; }
for f in bwInline bwLocal bwGuard bwParam; do
  [ "$(bwchk $f)" = "Fs" ] && ok "write(to:) Fs survives Data-producer/extension: $f" || bad "write(to:) Fs: $f got $(bwchk $f)"
done

# INHERITED-INTO-PROJECT vein, conforms-to-EXTERNAL-protocol shape: a project entity `class X: Model`
# (FluentKit, external/unmodeled) inherits save/query/find from the Model extension — called on the project
# type the owner is X (no body), so it read SILENT (the Vapor-template dogfood vein). Fluent CRUD verbs →
# Db (modeled like CoreData); an UNMODELED external conformance → Unknown (general fix); a real project
# method + a synthesized std-protocol method (Codable.encode) stay pure (no fabrication / no false Unknown).
cat > "$W/fl.swift" <<'SW'
import Fluent
final class Todo: Model { func mine() -> Int { 1 } }
final class Other: SomeUnknownProto { func foo() -> Int { 2 } }
struct Pt: Codable, Hashable { var x: Int }
func fSave(t: Todo) async throws { try await t.save(on: 0) }
func fQuery() async throws { _ = try await Todo.query(on: 0).all() }
func fFind() async throws { _ = try await Todo.find(0, on: 0) }
func fMine(t: Todo) -> Int { t.mine() }
func fOther(o: Other) -> Int { o.bar() }
func fOtherFoo(o: Other) -> Int { o.foo() }
func fEnc(p: Pt, e: Encoder) throws { try p.encode(to: e) }
SW
"$BIN" "$W/fl.swift" --out "$W/fl" 2>/dev/null
FLRPT=$(ls "$W"/fl.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
flchk() { python3 -c "import json,sys; d=json.load(open('$FLRPT')); print(next((','.join(sorted(f['inferred'])) for f in d['functions'] if f['fn']==sys.argv[1]), 'pure'))" "$1"; }
for f in fSave fQuery fFind; do case "$(flchk $f)" in *Db*) ok "Fluent inherited $f -> Db (was silent — dogfood vein)";; *) bad "Fluent $f: $(flchk $f)";; esac; done
[ "$(flchk fMine)" = "pure" ]   && ok "a real project method on a Model type stays pure (no fabrication)"            || bad "Fluent mine: $(flchk fMine)"
[ "$(flchk fOther)" = "Unknown" ] && ok "inherited method from an UNMODELED external proto -> Unknown (general vein fix)" || bad "external-proto Unknown: $(flchk fOther)"
[ "$(flchk fOtherFoo)" = "pure" ] && ok "a real project method on an external-conforming type stays pure"              || bad "external-proto project method: $(flchk fOtherFoo)"
[ "$(flchk fEnc)" = "pure" ]    && ok "a synthesized std-protocol method (Codable.encode) stays pure (no false Unknown)" || bad "Codable encode: $(flchk fEnc)"

# COVERED-MODULE κ sweep (2026-07-09): UserDefaults / Keychain SecItem* / Bundle resource lookups live in
# PLATFORM_MODULES (Foundation/Security — no ledger naming, no Unknown), so unmodeled they read SILENT-PURE:
# the covered-module cardinal-sin shape (candor-java's Panache lesson). All → Fs (family decision:
# UserDefaults = file-backed store; SecItem* = system secure store, NOT Db — Db is reserved for
# query-capable datastores; Bundle url/path(forResource:) = on-disk stat). Pure surface stays pure.
mkdir -p "$W/ud" && cat > "$W/ud/m.swift" <<'SW'
import Foundation
import Security
func udWrite() { UserDefaults.standard.set(true, forKey: "seen") }                 // Fs (singleton chain)
func udRead(_ d: UserDefaults) -> String? { d.string(forKey: "name") }            // Fs (param receiver)
func udLet() { let d = UserDefaults.standard; d.removeObject(forKey: "k") }       // Fs (let-bound singleton)
func udVolatile(_ d: UserDefaults) -> [String] { d.volatileDomainNames }          // PURE (in-memory domain)
func kcAdd(_ q: CFDictionary) { _ = SecItemAdd(q, nil) }                          // Fs (Keychain CRUD)
func kcFind(_ q: CFDictionary) { _ = SecItemCopyMatching(q, nil) }                // Fs
func bunRes() -> URL? { Bundle.main.url(forResource: "cfg", withExtension: "json") } // Fs (disk lookup)
func bunPath(_ b: Bundle) -> String? { b.path(forResource: "cfg", ofType: "json") }  // Fs
func bunMeta(_ b: Bundle) -> String? { b.bundleIdentifier }                          // PURE (in-memory metadata)
SW
"$BIN" "$W/ud" --out "$W/ud/r" >/dev/null 2>&1
UDRPT=$(ls "$W"/ud/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
UD=$(python3 -c "
import json
by={e['fn']:set(e.get('inferred',[])) for e in json.load(open('$UDRPT'))['functions']}
fs=['udWrite','udRead','udLet','kcAdd','kcFind','bunRes','bunPath']
pure=['udVolatile','bunMeta']
ok = all(by.get(f)=={'Fs'} for f in fs) and all(f not in by for f in pure)
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$UD" = "PASS" ] && ok "covered-module sweep: UserDefaults/SecItem*/Bundle-resource -> Fs; volatile-domain + bundle metadata stay pure" || bad "UserDefaults/Keychain/Bundle sweep: $UD"

# anti-fabrication TWINS (scanned separately — a local decl owns the name for the whole scan): a project's
# OWN UserDefaults/Bundle type and a local func SecItemAdd must stay pure (the shadow discipline —
# declaredTypes for member calls, localFreeFns for free calls; the GRDB `bind` lesson applied to this batch).
mkdir -p "$W/uds" && cat > "$W/uds/m.swift" <<'SW'
struct UserDefaults { static let standard = UserDefaults(); func set(_ v: Bool, forKey k: String) {} }
struct Bundle { static let main = Bundle(); func url(forResource r: String, withExtension e: String) -> Int? { nil } }
func SecItemAdd(_ a: Int, _ b: Int) -> Int { 0 }
func twinUd() { UserDefaults.standard.set(true, forKey: "seen") }        // PURE — project type shadows κ
func twinBun() { _ = Bundle.main.url(forResource: "cfg", withExtension: "json") }  // PURE
func twinKc() { _ = SecItemAdd(1, 2) }                                   // PURE — local free fn shadows κ
SW
"$BIN" "$W/uds" --out "$W/uds/r" >/dev/null 2>&1
UDSRPT=$(ls "$W"/uds/r.*.Swift.json 2>/dev/null | grep -v callgraph | grep -v hierarchy | head -1)
UDS=$(python3 -c "
import json
by={e['fn']:set(e.get('inferred',[])) for e in json.load(open('$UDSRPT'))['functions']}
ok = all(f not in by for f in ['twinUd','twinBun','twinKc'])
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$UDS" = "PASS" ] && ok "covered-module sweep twins: local UserDefaults/Bundle/SecItemAdd shadow κ (no fabrication)" || bad "UserDefaults/Keychain/Bundle twins: $UDS"

echo; echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
