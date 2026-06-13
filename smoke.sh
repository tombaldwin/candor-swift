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
