#!/usr/bin/env bash
# candor-swift self-gate (SPEC §7.12): candor-swift analyzes ITSELF and holds its own declared
# boundary. An effect-gate vendor whose own gate is red has no business gating anyone else.
#
# TWO HALVES, because a policy file cannot say "deny Exec everywhere except main.swift":
#   (1) the WHOLE engine under .candor/policy — `deny Net Db`, no file excluded;
#   (2) the Exec/Ipc-performing units are EXACTLY the declared self-invocation list below.
#
# WHY THIS REPLACED THE PREVIOUS ARRANGEMENT. The old half (1) proved the analysis CORE clean by
# COPYING Sources to a temp dir and DELETING main.swift — carving out the Exec/Ipc surface a whole
# FILE at a time. That left 2158 lines in which a new subprocess was caught by nothing: half (2) only
# asked about Net/Db. Declaring the four UNITS instead keeps every line of the engine inside the gate,
# so this is strictly stronger — it now also fails on an Exec added anywhere in main.swift itself.
# candor-ts's ci/self-gate.sh is the same shape, for the same reason.
#
# Half (2) is a CARVE-OUT OF PROVEN-SAFE UNITS, not an allowlist of exempt files: Exec or Ipc
# appearing anywhere else fails, and so does a DECLARED entry that STOPS performing them — a stale
# exemption is a gate that has quietly stopped asserting anything.
#
# EVERY WRITE GOES TO A TEMP DIR — nothing under the working tree is touched (candor-rust's self-gate
# learned this the hard way: it deleted eight tracked report files and got caught in a `git add -A`).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${CANDOR_SWIFT_BIN:-$ROOT/.build/debug/candor-swift}"
[ -x "$BIN" ] || { echo "self-gate: no candor-swift binary at $BIN (run \`swift build\` first)"; exit 2; }
WS="$(mktemp -d "${TMPDIR:-/tmp}/candor-swift-self-gate.XXXXXX")"
trap 'rm -rf "$WS"' EXIT

# The subprocess sites, by unit. All four are in main.swift and all are "run a tool again": the
# `--workspace` chain spawns candor-swift itself on each dependency and reads the report back through
# a Pipe (Exec + Ipc), and Xcode-scope resolution shells out via /usr/bin/env to resolve a target.
# `<main>` is the top-level entry, which inherits both transitively — the same file, not a fifth site.
DECLARED_SPAWN="<main>
makeXcodeScopeFS
runRounds
scopeToXcodeTarget"

"$BIN" "$ROOT/Sources" --out "$WS/self" --policy "$ROOT/.candor/policy" > "$WS/scan.log" 2>&1
gate_rc=$?
# Trim the per-function Unknown advisory — it buries the verdict in CI. The COUNT stays on the summary
# line, so the advisory is still visible as a number; violations are never filtered.
grep -v '^    `' "$WS/scan.log"
RPT="$(ls "$WS"/self*.Swift.json 2>/dev/null | grep -vE 'callgraph|hierarchy|locs' | head -1)"
[ -n "$RPT" ] && [ -s "$RPT" ] || { echo "self-gate: candor-swift produced no report"; exit 2; }

DECLARED="$DECLARED_SPAWN" python3 - "$RPT" <<'PY'
import json, os, sys
declared = {l.strip() for l in os.environ["DECLARED"].splitlines() if l.strip()}
fns = json.load(open(sys.argv[1])).get("functions", [])
found = {e["fn"] for e in fns if {"Exec", "Ipc"} & set(e.get("inferred", []))}
new, stale = sorted(found - declared), sorted(declared - found)
for f in new:
    print(f"  AS-EFF-006  {f} performs Exec/Ipc — not a declared subprocess site.")
    print( "              candor-swift spawns a process in main.swift only, and says so in .candor/policy.")
    print( "              If this one is legitimate, add it there AND to ci/self-gate.sh's list.")
for f in stale:
    print(f"  STALE       {f} is declared Exec/Ipc-exempt but no longer performs either — drop it.")
    print( "              An exemption nothing exercises is a gate that has stopped asserting.")
sys.exit(1 if (new or stale) else 0)
PY
spawn_rc=$?

if [ "$gate_rc" -eq 0 ] && [ "$spawn_rc" -eq 0 ]; then
  echo "self-gate: OK — candor-swift reaches no Net/Db, and spawns a process only where it declares it does"
  exit 0
fi
[ "$gate_rc" -ne 0 ] && echo "self-gate: FAILED — the declared boundary in .candor/policy is red (exit $gate_rc)"
[ "$spawn_rc" -ne 0 ] && echo "self-gate: FAILED — the Exec/Ipc set does not match the declared subprocess list"
exit 1
