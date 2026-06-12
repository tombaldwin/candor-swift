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
EXPECTED="${CANDOR_SPEC:-../candor-spec}/conformance/expected.json"
if [ -f "$EXPECTED" ]; then
  N=$(python3 - "$EXPECTED" "$W/r.json" <<'PY'
import json, sys
exp = {k: set(v) for k, v in json.load(open(sys.argv[1])).items() if not k.startswith("_")}
got = {e["fn"].split(".")[-1]: set(e.get("inferred", [])) for e in json.load(open(sys.argv[2]))["functions"]}
print(sum(1 for c, e in exp.items() if got.get(c, set()) == e), "/", len(exp), sep="")
PY
)
  [ "$N" = "20/20" ] && ok "conformance oracle $N" || bad "conformance oracle $N"
else
  echo "  skip conformance oracle (clone candor-spec as a sibling or set CANDOR_SPEC)"
fi
printf 'deny Net hop\n' > "$W/pol"
"$BIN" conformance/Cases.swift --out "$W/r" --policy "$W/pol" >"$W/gate.out" 2>&1
grep -q 'AS-EFF-006.*hop_a.*Net' "$W/gate.out" && ok "deny gate flags the transitive caller" || bad "deny gate"
mkdir -p "$W/led" && printf 'import Alamofire\nfunc go() { _ = FileManager.default.contents(atPath: "/x") }\nimport Foundation\n' > "$W/led/m.swift"
"$BIN" "$W/led" --out "$W/led/r" 2>"$W/led.err"
grep -q "κ doesn't know.*Alamofire" "$W/led.err" && ok "κ ledger names the unlisted import" || bad "κ ledger"
HASH=$(python3 -c "import json; print(json.load(open('$W/r.json'))['functions'][0].get('hash',''))")
case "$HASH" in *"#"*) ok "hash join keys emitted (0.4 MUST)";; *) bad "hash emission";; esac
echo; echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
