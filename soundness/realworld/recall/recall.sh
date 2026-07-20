#!/usr/bin/env bash
# Non-syscall RECALL oracle for candor-swift — Ipc/Log/Rand/Env/Clock. strace can't distinguish these from
# ordinary fd/register ops, so (like rust's soundness/realworld/recall) the ground truth is the DOCUMENTED
# API semantics in expected.json, checked against candor-swift's static prediction. candor-swift is syntactic,
# so this needs NO strace, NO Linux, NO builds of the drivers — it runs anywhere. Red only on an under-report
# (an expected effect that candor neither predicts nor discloses as Unknown).
#
#   bash soundness/realworld/recall/recall.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

( cd "$ROOT" && swift build -q ) || { echo "FAIL: candor-swift build"; exit 1; }
SW="$ROOT/.build/debug/candor-swift"
[ -x "$SW" ] || { echo "FAIL: no candor-swift binary at $SW"; exit 1; }

rm -rf "$HERE/.candor" 2>/dev/null
"$SW" "$HERE" >/dev/null 2>&1
REP=$(ls "$HERE"/.candor/report.*.Swift.json 2>/dev/null | grep -vE 'callgraph|hierarchy' | head -1)
[ -n "$REP" ] || { echo "FAIL: no candor-swift report"; exit 1; }

echo "swift recall oracle (Ipc/Log/Rand/Env/Clock — known-semantics):"
python3 - "$REP" "$HERE/expected.json" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1])); expected = json.load(open(sys.argv[2]))
inf = {}
for f in rep.get("functions", []):
    s = set(f.get("inferred", []))
    disc = ("Unknown" in s) or f.get("unresolved") or f.get("invisible") or f.get("blind") or f.get("incomplete")
    inf[f.get("fn")] = (s, disc)
ok = under = 0; bad = []
for fn, eff in expected.items():
    s, disc = inf.get(fn, (set(), False))
    if eff in s:
        ok += 1; print(f"  {fn}: expected {eff}  candor={sorted(s)}  ok")
    elif disc:
        ok += 1; print(f"  {fn}: expected {eff}  candor={sorted(s)}  ok(disclosed Unknown)")
    else:
        under += 1; bad.append(fn); print(f"  {fn}: expected {eff}  candor={sorted(s) or '-'}  ✗ UNDER-REPORT")
print(f"\nswift recall oracle: {ok} recalled, {under} under-report(s)")
sys.exit(1 if under else 0)
PY
rc=$?
rm -rf "$HERE/.candor" 2>/dev/null
exit $rc
