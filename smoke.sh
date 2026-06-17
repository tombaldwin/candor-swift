#!/usr/bin/env bash
# candor-swift smoke: the conformance oracle + gate + ledger, end to end.
set -uo pipefail
cd "$(dirname "$0")"
swift build 2>/dev/null || { echo "FAIL: build"; exit 1; }
BIN=.build/debug/candor-swift
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }

"$BIN" conformance/Cases.swift --out "$W/r" 2>/dev/null
RPT=$(ls "$W"/r.*.Swift.json 2>/dev/null | grep -v callgraph | head -1)
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
DRPT=$(ls "$W"/dt.*.Swift.json 2>/dev/null | grep -v callgraph | head -1)
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
NRPT=$(ls "$W"/ns.*.Swift.json 2>/dev/null | grep -v callgraph | head -1)
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
SRPT=$(ls "$W"/sq.*.Swift.json 2>/dev/null | grep -v callgraph | head -1)
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
ORPT=$(ls "$W"/ov.*.Swift.json 2>/dev/null | grep -v callgraph | head -1)
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
r=json.load(open([p for p in glob.glob('$W/uk/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/sg/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/it/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/ct2/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/rx/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/fc/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/en/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/gp/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/tu/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/ne/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/f1/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/f2/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/f3/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/f4/r.*.json') if 'callgraph' not in p][0]))
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
r=json.load(open([p for p in glob.glob('$W/u1/r.*.json') if 'callgraph' not in p][0]))
by={e['fn']:set(e.get('inferred',[])) for e in r['functions']}
ok = by.get('readFile')=={'Fs'} and by.get('readData')=={'Fs'}
print('PASS' if ok else 'FAIL '+repr({k:sorted(v) for k,v in by.items()}))")
[ "$U1" = "PASS" ] && ok "U1: String(contentsOfFile:) -> Fs (unconditional file read; contentsOf: still resolves)" || bad "U1 contentsOfFile: $U1"

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
"$BIN" "$W/mask" --out "$W/mask/r" --policy "$W/mask/pol" > "$W/mask/gate.out" 2>/dev/null
{ grep -q 'AS-EFF-008.*`mask`.*cannot be certified' "$W/mask/gate.out" \
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
"$BIN" "$W/maskfs" --out "$W/maskfs/r" --policy "$W/maskfs/pol" > "$W/maskfs/gate.out" 2>/dev/null
{ grep -q 'AS-EFF-008.*`maskFs`.*cannot be certified' "$W/maskfs/gate.out" \
  && ! grep -q '`cleanFs`' "$W/maskfs/gate.out"; } \
  && ok "masking guard generalizes to Fs: invisible-path Fs fails closed; the clean path certifies" \
  || bad "Fs masking guard: $(cat "$W/maskfs/gate.out")"

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
INVRPT=$(ls "$W"/inv/r.*.Swift.json 2>/dev/null | grep -v callgraph | head -1)
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
DNSRPT=$(ls "$W"/dns/r.*.Swift.json 2>/dev/null | grep -v callgraph | head -1)
DNS=$(python3 -c "
import json
by={e['fn']:set(e.get('inferred',[])) for e in json.load(open('$DNSRPT'))['functions']}
print('PASS' if 'Net' in by.get('resolve',set()) else 'FAIL '+repr(by.get('resolve','absent')))")
[ "$DNS" = "PASS" ] && ok "DNS (getaddrinfo) classifies as Net" || bad "DNS classify: $DNS"

# Policy parser splits on bare \r (classic-Mac) line endings (sweep [16]/[17]): a multi-rule policy with
# bare-CR endings must NOT collapse to the first rule. `deny Exec hop` is rule 2, AFTER a bare \r.
mkdir -p "$W/cr" && printf 'import Foundation\nfunc hop() { _ = Process() }\n' > "$W/cr/m.swift"
printf 'deny Clock nope\rdeny Exec hop\rdeny Net nope2\r' > "$W/cr/pol"
"$BIN" "$W/cr" --out "$W/cr/r" --policy "$W/cr/pol" > "$W/cr/gate.out" 2>/dev/null
grep -q 'AS-EFF-006.*`hop`.*Exec' "$W/cr/gate.out" \
  && ok "policy parser splits bare-CR line endings (rule after \\\\r is not dropped)" \
  || bad "bare-CR policy parse: $(cat "$W/cr/gate.out")"

echo; echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
