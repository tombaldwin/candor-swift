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
# asked about Net/Db. Declaring the UNITS instead keeps every line inside the gate for anything that
# BINDS a unit; bare top-level statements fold into `<main>` and are covered by the source ratchet
# at the end of this script, not by the unit check.
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
# `<main>` IS declared, and the reason is a limit worth stating rather than papering over. The engine
# folds every bare top-level statement in main.swift into that one synthetic unit — ~1.8k of its 2159
# lines — so declaring it exempts all of them, and NOT declaring it fails on a clean tree (`<main>`
# carries Exec/Ipc even in `direct`, because file-scope declarations fold in too). Measured both ways.
# A unit-level check therefore cannot see a subprocess spawned by unbound top-level code, and the
# earlier claim that this gate "fails on an Exec added anywhere in main.swift" was FALSE: the
# demonstration behind it used a named `func`, which binds its own unit and IS caught.
#
# The SOURCE RATCHET below is what covers that gap. It is cruder than the unit check — it counts call
# sites rather than reasoning about reachability — but it is the only thing here that can see a
# `Process()` inside a bare `if` at file scope.
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
    # An overload turns a bare unit name into arity-qualified keys (`runRounds` -> `runRounds()`,
    # `runRounds(Int)`), which surfaces as this entry going stale AND new ones appearing. Saying "drop
    # it" there is exactly backwards, so name the likelier cause when the shape matches.
    kin = sorted(k for k in found if k.startswith(f + "("))
    if kin:
        print(f"  RENAMED     {f} is now arity-qualified as {kin} — the engine did that, not you.")
        print( "              UPDATE the declared name; do NOT drop it, or the exemption silently widens.")
    else:
        print(f"  STALE       {f} is declared Exec/Ipc-exempt but no longer performs either — drop it.")
        print( "              An exemption nothing exercises is a gate that has stopped asserting.")
sys.exit(1 if (new or stale) else 0)
PY
spawn_rc=$?

# ── the SOURCE RATCHET — the half the unit check is blind to ────────────────────────────────────────
# Every subprocess CONSTRUCTION in the engine, by file, comments excluded. The unit check cannot see a
# spawn in bare top-level code (it folds into `<main>`, which is declared), so this counts the call
# sites directly. A new `Process()` anywhere — including inside a top-level `if` — moves a count and
# fails, and so does one REMOVED, because a ratchet that only tightens stops describing the code.
# Deliberately crude: it does not know reachability. It knows how many places can start a process.
EXPECTED_SPAWN_SITES="Sources/candor-swift/main.swift:2"
# Comment TAILS, not just comment lines: `case "Exec": … // path arg (Process() ctor` in Classifier.swift
# is a documentation reference on a code line, and a leading-`//` filter counted it as a spawn site.
actual_sites="$(grep -rn 'Process()' "$ROOT/Sources" 2>/dev/null \
  | sed 's|//.*||' | grep 'Process()' | sed "s|^$ROOT/||" | cut -d: -f1 | sort | uniq -c \
  | awk '{printf "%s:%s\n", $2, $1}' | sort)"
src_rc=0
if [ "$actual_sites" != "$(printf '%s' "$EXPECTED_SPAWN_SITES" | sort)" ]; then
  src_rc=1
  echo "  AS-EFF-006  the subprocess call-site inventory moved."
  echo "              expected: $(printf '%s' "$EXPECTED_SPAWN_SITES" | tr '\n' ' ')"
  echo "              actual:   $(printf '%s' "$actual_sites" | tr '\n' ' ')"
  echo "              A spawn in BARE TOP-LEVEL code folds into <main> and no unit check here can see"
  echo "              it — this inventory is the only thing that can. Justify it, then update the list."
fi

if [ "$gate_rc" -eq 0 ] && [ "$spawn_rc" -eq 0 ] && [ "$src_rc" -eq 0 ]; then
  echo "self-gate: OK — candor-swift reaches no Net/Db, and spawns a process only where it declares it does"
  exit 0
fi
# Exit 2 is NOT a violation — it is the ⟨0.21⟩ fail-closed "could not evaluate" verdict (unanalyzable sources),
# and this project treats that distinction as load-bearing everywhere else. Reporting it as "the
# boundary is red" sends the reader hunting for a subprocess that does not exist, and collapsing it to
# exit 1 tells CI a violation was ESTABLISHED. Preserved as 2. (Found by review in the java arm first;
# all three self-gates were written with the same collapse.)
if [ "$gate_rc" -eq 2 ]; then
  echo "self-gate: COULD NOT EVALUATE — candor-swift exited 2 over its own sources (the boundary was never"
  echo "  judged, so this is not a clean result and not a violation). Fix the input, then re-run."
  exit 2
fi
[ "$gate_rc" -ne 0 ] && echo "self-gate: FAILED — the declared boundary in .candor/policy is red (exit $gate_rc)"
[ "$spawn_rc" -ne 0 ] && echo "self-gate: FAILED — the Exec/Ipc set does not match the declared subprocess list"
[ "$src_rc" -ne 0 ] && echo "self-gate: FAILED — the subprocess call-site inventory moved"
exit 1
