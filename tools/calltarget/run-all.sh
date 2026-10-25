#!/bin/bash
# tools/calltarget/run-all.sh BIN OUTDIR [--write-baseline] [--env K=V]...
#
# The exhaustive call-target instrument (call-target round 1, SOUNDNESS R1415/R1416). Generates the two cell
# batches into OUTDIR, COMPILES AND EXECUTES every cell (ground truth: an `EFF:` line inside the gated
# function's BEGIN/END), scans each with BIN (chained cells: the library scanned `--out` and handed to the
# app through CANDOR_DEPS), gates every gated function with `deny E fn` and `deny E Unknown fn`, then runs
# the R764-shape controls and compares the classification of every measurement against baseline.tsv.
# Exit 0 = every measurement matches the baseline; 1 = something moved (printed); 2 = usage.
#
# NOT wired into per-commit CI (it compiles ~1,240 Swift programs, ~10 minutes at --jobs 2). On the shared
# machine it must hold the A/B lock. --env is applied to every SCAN, e.g. --env CANDOR_R1415_OFF=1.
set -u
[ $# -ge 2 ] || { echo "usage: $0 BIN OUTDIR [--write-baseline] [--env K=V]..." >&2; exit 2; }
BIN=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); OUT=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
WRITE=0; ENVS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --write-baseline) WRITE=1; shift ;;
    --env) ENVS+=(--env "$2"); shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"
python3 "$HERE/gen.py" "$OUT/cells" || exit 2
python3 "$HERE/gen2.py" "$OUT/cells2" || exit 2
for b in cells cells2; do
  rm -f "$OUT/$b.results.jsonl"
  python3 "$HERE/run.py" "$OUT/$b" "$BIN" --jobs 2 --out "$OUT/$b.results.jsonl" ${ENVS[@]+"${ENVS[@]}"} > "$OUT/$b.log" 2>&1 || exit 2
done
python3 "$HERE/analyze.py" "$OUT/cells.results.jsonl" > "$OUT/analysis1.txt"
python3 "$HERE/analyze.py" "$OUT/cells2.results.jsonl" > "$OUT/analysis2.txt"
python3 "$HERE/causes.py" "$OUT/cells.results.jsonl.classified.json" "$OUT/cells2.results.jsonl.classified.json" > "$OUT/causes.txt"
( for e in ${ENVS[@]+"${ENVS[@]}"}; do [ "$e" = --env ] || export "$e"; done; python3 "$HERE/controls.py" "$OUT/controls" "$BIN" ) > "$OUT/controls.txt"
cat "$OUT/causes.txt" "$OUT/controls.txt"
if [ $WRITE = 1 ]; then
  python3 "$HERE/baseline.py" write "$HERE/baseline.tsv" "$OUT/cells.results.jsonl" "$OUT/cells2.results.jsonl"
  cp "$OUT/controls/controls.json" "$HERE/controls-baseline.json"
  exit 0
fi
python3 "$HERE/baseline.py" check "$HERE/baseline.tsv" "$OUT/cells.results.jsonl" "$OUT/cells2.results.jsonl"; rc=$?
python3 - "$HERE/controls-baseline.json" "$OUT/controls/controls.json" <<'PY' || rc=1
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
bad = [k for k in sorted(set(a) | set(b)) if a.get(k, {}).get("verdict") != b.get(k, {}).get("verdict")]
for k in bad: print("controls:", k, a.get(k, {}).get("verdict"), "->", b.get(k, {}).get("verdict"))
sys.exit(1 if bad else 0)
PY
exit $rc
