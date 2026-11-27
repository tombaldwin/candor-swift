#!/usr/bin/env bash
# tools/identity-exec.sh — EXECUTE every type-identity fixture under swiftc and write or check its ground truth.
#
#   tools/identity-exec.sh --write [--scratch DIR] [fixture ...]   run each Run package, write exec-ground-truth.txt
#   tools/identity-exec.sh --check [--scratch DIR] [fixture ...]   run each, diff against the checked-in file (exit 1 on a diff)
#
# A fixture is a name from the list below (or none: all). Each Run package takes the directory to write its marker files into
# as argv[1] and prints `<cell> WRITES|pure|LOGS`; those lines ARE the executed truth the process tests assert their tables
# against (Tests/CandorCoreTests/TypeIdentity*Tests.swift). The packages are built into a private scratch dir, never into the
# fixture tree. One build at a time (RAM): the loop is serial.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fx="$here/Tests/Fixtures/TypeIdentity"
mode=""; scratch="${TMPDIR:-/tmp}/candor-identity-exec"; want=()
while [ $# -gt 0 ]; do case "$1" in
  --write) mode=write;; --check) mode=check;; --scratch) scratch="$2"; shift;;
  *) want+=("$1");; esac; shift; done
[ -n "$mode" ] || { echo "usage: $0 --write|--check [--scratch DIR] [fixture ...]" >&2; exit 2; }
# <fixture-name>  <ground-truth file relative to $fx>  <Run package relative to $fx>
table='
fx3        fx3/exec-ground-truth.txt              fx3/Run3
fx4        fx4/exec-ground-truth.txt              fx4/Run4
fx5        fx5/exec-ground-truth.txt              fx5/Run5
fx5nw      fx5nw/exec-ground-truth.txt            fx5nw/Run5nw
fx6        fx6/exec-ground-truth.txt              fx6/Run6
fx6c       fx6/exec-ground-truth-c.txt            fx6/Run6c
fx7        fx7/exec-ground-truth.txt              fx7/Run7
fx8        fx8/exec-ground-truth.txt              fx8/Run8
F1         r1931/fx/exec-ground-truth.txt         r1931/fx/Run
F2         r1931/fx2/exec-ground-truth.txt        r1931/fx2/Run2
R          r1896/fx/exec-ground-truth.txt         r1896/fx/Run
Rp         r1896/fxp/exec-ground-truth.txt        r1896/fxp/Run
RL         r1896/fx3/exec-ground-truth.txt        r1896/fx3/Run
Rlog2      r1896/fxlog2/exec-ground-truth.txt     r1896/fxlog2/Run
fx9        fx9/exec-ground-truth.txt              fx9/Run9
fx9r       fx9r/exec-ground-truth.txt             fx9r/Run9r
fx10       fx10/exec-ground-truth.txt             fx10/Run10
fx11       fx11/exec-ground-truth.txt             fx11/Run11
fx12       fx12/exec-ground-truth.txt             fx12/Run12
fx13       fx13/exec-ground-truth.txt             fx13/Run13
fx15       fx15/exec-ground-truth.txt             fx15/Run15
fx16       fx16/exec-ground-truth.txt             fx16/Run16
fx19       fx19/exec-ground-truth.txt             fx19/Run19
fx20       fx20/exec-ground-truth.txt             fx20/Run20
fx22       fx22/exec-ground-truth.txt             fx22/Run22
fx23       fx23/exec-ground-truth.txt             fx23/Run23
fx24       fx24/exec-ground-truth.txt             fx24/Run24
fx25       fx25/exec-ground-truth.txt             fx25/Run25
'
fail=0
while read -r name gt run; do
  [ -n "$name" ] || continue
  if [ ${#want[@]} -gt 0 ]; then case " ${want[*]} " in *" $name "*) ;; *) continue;; esac; fi
  [ -d "$fx/$run" ] || { echo "$name: no Run package at $run" >&2; fail=1; continue; }
  out="$scratch/out-$name"; build="$scratch/build-$name"
  rm -rf "${out:?}"; mkdir -p "$out"
  if ! got="$(swift run -j 2 --package-path "$fx/$run" --scratch-path "$build" "$(basename "$run")" "$out" 2>"$scratch/$name.log")"; then
    echo "$name: EXECUTION FAILED (see $scratch/$name.log)" >&2; tail -5 "$scratch/$name.log" >&2; fail=1; continue
  fi
  if [ "$mode" = write ]; then printf '%s\n' "$got" > "$fx/$gt"; echo "$name: wrote $gt ($(printf '%s\n' "$got" | wc -l | tr -d ' ') cells)"
  else
    if diff <(printf '%s\n' "$got") "$fx/$gt" >/dev/null; then echo "$name: OK ($(printf '%s\n' "$got" | wc -l | tr -d ' ') cells)"
    else echo "$name: DIFFERS from $gt" >&2; diff <(printf '%s\n' "$got") "$fx/$gt" >&2 || true; fail=1; fi
  fi
done <<< "$table"
exit $fail
