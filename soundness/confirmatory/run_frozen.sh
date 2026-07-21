#!/usr/bin/env bash
# FROZEN confirmatory run — Swift syscall arm (see FROZEN.md). Linux + strace (the swift CI linux job).
# Reuses the CI-green soundness/realworld mechanism on a held-out, version-pinned, pre-registered corpus.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
case "$(uname -s)" in Linux) : ;; *) echo "swift confirmatory: needs Linux + strace — skipping."; exit 0 ;; esac
command -v strace >/dev/null 2>&1 || { echo "strace not installed — skipping."; exit 0; }

echo "building candor-swift…"; ( cd "$ROOT" && swift build -q ) || { echo "FAIL: candor-swift build"; exit 1; }
SW="$ROOT/.build/debug/candor-swift"; [ -x "$SW" ] || { echo "FAIL: no candor-swift"; exit 1; }

WORK="${CORPUS_WORK:-${TMPDIR:-/tmp}/candor-swift-corpus}"; mkdir -p "$WORK" "$HERE/results"
SUM="$HERE/results/FROZEN-SUMMARY.tsv"; printf 'package\ttag\tobserved\tcovered\tviolations\tverdict\n' > "$SUM"

grep -vE '^\s*#|^\s*$' "$HERE/manifest.tsv" | while IFS=$'\t' read -r name url tag effects why; do
  echo; echo "################## $name ($tag) ##################"
  d="$WORK/$name"
  [ -d "$d/.git" ] || { rm -rf "$d"; git clone --quiet --depth 1 --branch "$tag" "$url" "$d" 2>/dev/null \
      || { echo "  clone-failed"; printf '%s\t%s\t-\t-\t-\tclone-failed\n' "$name" "$tag" >>"$SUM"; continue; }; }
  rm -rf "$d/.candor"; "$SW" "$d" >/dev/null 2>&1
  rep=$(ls "$d"/.candor/report.*.Swift.json 2>/dev/null | grep -vE 'callgraph|hierarchy' | head -1)
  [ -n "$rep" ] || { echo "  scan-failed"; printf '%s\t%s\t-\t-\t-\tscan-failed\n' "$name" "$tag" >>"$SUM"; continue; }
  if ! ( cd "$d" && swift build --build-tests -q ) >"$d/build.log" 2>&1; then
    echo "  build-failed (see $d/build.log)"; printf '%s\t%s\t-\t-\t-\tbuild-failed\n' "$name" "$tag" >>"$SUM"; continue
  fi
  bin=$(find "$d/.build/debug" -name '*PackageTests.xctest' 2>/dev/null | head -1)
  [ -x "$bin" ] || bin=$(find "$d/.build" -name '*.xctest' -type f 2>/dev/null | head -1)
  [ -n "$bin" ] || { echo "  no test bundle"; printf '%s\t%s\t-\t-\t-\tno-test-bin\n' "$name" "$tag" >>"$SUM"; continue; }
  strace -f -e trace=openat,open,connect,execve,unlink -o "$d/trace.log" "$bin" >/dev/null 2>&1 || true
  observed=$(python3 - "$d/trace.log" "$rep" <<'PY'
import json,sys,re
trace,rep=sys.argv[1],sys.argv[2]
CLS={'openat':'Fs','openat2':'Fs','open':'Fs','unlink':'Fs','connect':'Net','socket':'Net','execve':'Exec'}
obs=set()
# strace -f prefixes "PID  syscall(...)"; match the syscall name wherever it sits (not anchored at start).
RX=re.compile(r'(?:^|\s)(openat2|openat|open|connect|socket|execve|unlink)\(')
for line in open(trace,errors='replace'):
    m=RX.search(line)
    if m and m.group(1) in CLS: obs.add(CLS[m.group(1)])
d=json.load(open(rep)); named=set(); unknown=False
for f in d.get('functions',[]):
    inf=set(f.get('inferred') or []); named|=(inf-{'Unknown'})
    if 'Unknown' in inf or f.get('invisible') or f.get('unresolved') or f.get('incomplete'): unknown=True
cov=set(); vio=set()
for c in obs:
    (cov if (c in named or unknown) else vio).add(c)
print("%s|%s|%s"%(",".join(sorted(obs)) or "-",",".join(sorted(cov)) or "-",",".join(sorted(vio)) or "-"))
PY
)
  IFS='|' read -r obs cov vio <<<"$observed"
  verdict=$([ "$vio" = "-" ] && echo "H-holds" || echo "VIOLATION[$vio]")
  echo "  observed=[$obs] covered=[$cov] -> $verdict"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$tag" "$obs" "$cov" "$vio" "$verdict" >>"$SUM"
done
echo; echo "===================== SWIFT CONFIRMATORY (program-level H) ====================="
column -t -s "$(printf '\t')" "$SUM" 2>/dev/null || cat "$SUM"
echo; echo "packages with an undisclosed observed effect class: $(awk -F'\t' 'NR>1 && $6 ~ /VIOLATION/' "$SUM" | wc -l | tr -d ' ')"
