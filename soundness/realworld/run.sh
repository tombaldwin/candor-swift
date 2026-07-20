#!/usr/bin/env bash
# Real-world DYNAMIC oracle for candor-swift — kernel ground truth on candor's STATIC prediction.
#
# The mechanism-INDEPENDENT third soundness check (static analysis → cross-engine conformance → THIS).
# candor-swift is the only engine that lacked it: rust has soundness/realworld (strace), java a bytecode
# agent, candor-ts verify-core — this closes the RQ3 gap (conformance is the WEAKEST check because shared
# blind spots hide from agreement; a runtime trace shares no code/spec/author-intuition with the analyzer).
#
# For each driver (a small Swift program exercising ONE real effectful API with a distinctive marker):
# compile it, RUN it under strace, and confirm the effect actually executed (its marker appears in the
# trace). If it did, assert candor-swift's STATIC prediction contains that effect — OR discloses uncertainty
# (Unknown/unresolved/invisible/blind/incomplete), which is honest. An effect that demonstrably RAN which
# candor predicts NOWHERE and discloses NOWHERE (silent-pure) is a real under-report — the cardinal sin.
# A pure control that runs no syscall and is predicted pure guards the fabrication mirror.
#
#   bash soundness/realworld/run.sh
# Linux + strace only (the swift CI linux job; locally via a swift:6.1 Docker container + strace).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

case "$(uname -s)" in Linux) : ;; *) echo "swift realworld oracle: needs Linux + strace (got $(uname -s)) — skipping."; exit 0 ;; esac
command -v strace >/dev/null 2>&1 || { echo "swift realworld oracle: strace not installed — skipping."; exit 0; }
command -v swiftc >/dev/null 2>&1 || { echo "swift realworld oracle: swiftc not found — skipping."; exit 0; }

echo "swift realworld oracle: building candor-swift…"
( cd "$ROOT" && swift build -q ) || { echo "FAIL: candor-swift build"; exit 1; }
SW="$ROOT/.build/debug/candor-swift"
[ -x "$SW" ] || { echo "FAIL: no candor-swift binary at $SW"; exit 1; }

# KNOWN, TRIAGED under-reports — tracked so the oracle is a clean gate (green on known gaps, red only on
# NEW findings). Empty now; a real find gets a fix + a row here (never a silent ignore).
KNOWN_UNDER=()

# driver | effect ("" = pure control) | marker (must appear in the strace iff the effect ran)
# The marker is chosen to be a DIRECTLY-traced syscall argument: an openat path for Fs; for Exec, the CHILD
# process opens a marker path (the openat proves the subprocess ran — robust vs matching argv inside the
# parent's posix_spawn); for Net, the connect() carries the literal TEST-NET address. A driver whose effect
# does not execute under strace this run is SKIPped (logged), never a failure — the gate only reds on a
# genuine under-report (effect ran, candor silent-pure).
CASES=(
  "fs_read|Fs|/tmp/candor-oracle-swift-fs-read"
  "fs_write|Fs|/tmp/candor-oracle-swift-fs-write"
  "fs_filehandle|Fs|/tmp/candor-oracle-swift-fh"
  "fs_manager|Fs|/tmp/candor-oracle-swift-fm"
  "exec_proc|Exec|/tmp/candor-oracle-swift-exec-ran"
  "net_url|Net|192.0.2.1"
  "net_raw|Net|192.0.2.5"
  "pure_ctrl||__no_marker__"
)

pass=0; under=0; known=0; skip=0; fab=0; blame=0; failed=""
for row in "${CASES[@]}"; do
  IFS='|' read -r d eff marker <<<"$row"
  src="$HERE/$d/main.swift"
  bin="$HERE/$d/$d.bin"
  [ -f "$src" ] || { echo "  $d: no source — SKIP"; skip=$((skip+1)); continue; }
  # Compile the driver (Foundation/FoundationNetworking auto-linked on Linux). A build failure = SKIP,
  # not a finding — an oracle can only judge a program that runs.
  swiftc "$src" -o "$bin" >/dev/null 2>&1 || { echo "  $d: swiftc failed — SKIP"; skip=$((skip+1)); continue; }

  strace -f -e trace=connect,socket,openat,open,execve -o "$HERE/$d/trace.log" "$bin" >/dev/null 2>&1 || true
  ran=0; grep -qF "$marker" "$HERE/$d/trace.log" 2>/dev/null && ran=1

  rm -rf "$HERE/$d/.candor" 2>/dev/null
  "$SW" "$HERE/$d" >/dev/null 2>&1   # writes .candor/report.<d>.Swift.json (+ callgraph/hierarchy)
  rep=$(ls "$HERE/$d"/.candor/report.*.Swift.json 2>/dev/null | grep -vE 'callgraph|hierarchy' | head -1)
  # Pass the report FILE as argv (NOT a stdin pipe): `candor --json | python - <<'PY'` is broken because
  # the heredoc overrides stdin, so json.load(sys.stdin) would read the SCRIPT text, not the report.
  # Extract candor's PRECISE claim (the inferred effects EXCEPT Unknown — Unknown is disclosure, not a
  # precise effect), whether it disclosed any uncertainty, and the unknownWhy REASONS (the blame data).
  read -r pred uncertain whys <<<"$(python3 - "${rep:-/dev/null}" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1])); funcs = d.get("functions", [])
except Exception:
    funcs = []
precise = set(); unc = False; whys = set()
for f in funcs:
    s = set(f.get("inferred", []))
    precise |= (s - {"Unknown"})
    if "Unknown" in s or f.get("unresolved") or f.get("invisible") or f.get("blind") or f.get("incomplete"):
        unc = True
    for w in (f.get("unknownWhy") or []): whys.add(w)
print((",".join(sorted(precise)) or "-"), ("uncertain" if unc else "certain"), (";".join(sorted(whys)) or "-"))
PY
)"

  echo "  $d: ran=$ran  effect=${eff:-none}  candor=[$pred] $uncertain"
  if [ -z "$eff" ]; then  # pure control: nothing should run, nothing should be predicted
    { [ "$ran" = "0" ] && [ "$pred" = "-" ]; } && pass=$((pass+1)) || { echo "    ⚠ control: ran=$ran pred=$pred (expected none/none)"; fab=$((fab+1)); }
    continue
  fi
  if [ "$ran" = "0" ]; then echo "    SKIP ($eff did not execute under strace this run)"; skip=$((skip+1)); continue; fi
  # Three-way honesty verdict (mirrors candor-ts verify-core):
  #  (1) PRECISE   — the effect is in candor's precise (non-Unknown) claim: held tightly.
  #  (2) HELD BY DISCLOSURE — not precise, but Unknown was disclosed → honest, and BLAME-TRACKED: the
  #      unknownWhy reason names the exact unresolved edge to fix for a precise answer (backlog P3).
  #  (3) VIOLATION — neither: a silent-pure that demonstrably ran = the cardinal sin.
  if echo ",$pred," | grep -q ",$eff,"; then
    pass=$((pass+1))
  elif [ "$uncertain" = "uncertain" ]; then
    echo "    ⓘ $eff held by DISCLOSURE (Unknown), not a precise claim — blame: [$whys]  (resolve this edge → precise $eff)"
    blame=$((blame+1)); pass=$((pass+1))
  elif printf '%s\n' "${KNOWN_UNDER[@]}" | grep -qx "$d"; then
    echo "    ⚠ KNOWN under-report (tracked, awaiting fix): ran $eff but candor predicts [$pred] — see KNOWN_UNDER"
    known=$((known+1))
  else
    echo "    ✗ NEW UNDER-REPORT: ran $eff (marker '$marker' in trace) but candor predicts [$pred] with no uncertainty"
    under=$((under+1)); failed="$failed $d"
  fi
done

echo
echo "swift realworld oracle: $pass honest ($blame held by disclosure+blamed), $known KNOWN under-report(s), $under NEW under-report(s), $fab fabrication(s), $skip skipped"
[ -n "$failed" ] && { echo "swift realworld oracle: NEW under-reporting drivers:$failed"; exit 1; }
[ "$fab" -gt 0 ] && { echo "swift realworld oracle: fabrication on the pure control"; exit 1; }
exit 0
