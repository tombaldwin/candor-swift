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
  [ "$N" = "21/21" ] && ok "conformance oracle $N" || bad "conformance oracle $N"
else
  echo "  skip conformance oracle (clone candor-spec as a sibling or set CANDOR_SPEC)"
fi
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
echo; echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
