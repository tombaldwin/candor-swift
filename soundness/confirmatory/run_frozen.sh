#!/usr/bin/env bash
# FROZEN confirmatory run — Swift syscall arm (see FROZEN.md). Linux + strace (the swift CI linux job).
# Reuses the CI-green soundness/realworld mechanism on a held-out, version-pinned, pre-registered corpus.
#
# ############################################################################################################
# # SOUNDNESS INVARIANT — READ BEFORE EDITING.                                                              #
# # The H-VIOLATION check runs on observed_raw (the FULL kernel-observed class set), NEVER on the           #
# # baseline-subtracted observed_crate. Baseline subtraction (harness-artifact removal) is INFORMATIONAL    #
# # ONLY: it sharpens the *reported coverage quality* so the story reflects the package's own effects, not  #
# # the XCTest runner's. Subtracting the baseline from the CHECKED set could delete a class that is BOTH a  #
# # harness artifact AND a genuine package effect — hiding a real under-report = the cardinal sin (a false  #
# # all-clear). Over-observation is the SAFE direction: it can only make a class easier to cover, never     #
# # hide a real miss. So the violation computation below reads observed_raw and observed_raw alone.         #
# ############################################################################################################
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
case "$(uname -s)" in Linux) : ;; *) echo "swift confirmatory: needs Linux + strace — skipping."; exit 0 ;; esac
command -v strace >/dev/null 2>&1 || { echo "strace not installed — skipping."; exit 0; }

echo "building candor-swift…"; ( cd "$ROOT" && swift build -q ) || { echo "FAIL: candor-swift build"; exit 1; }
SW="$ROOT/.build/debug/candor-swift"; [ -x "$SW" ] || { echo "FAIL: no candor-swift"; exit 1; }

WORK="${CORPUS_WORK:-${TMPDIR:-/tmp}/candor-swift-corpus}"; mkdir -p "$WORK" "$HERE/results"
SUM="$HERE/results/FROZEN-SUMMARY.tsv"
# Columns (see FROZEN.md):
#   observed_raw  = every effect class the kernel emitted under strace (THE CHECKED SET).
#   observed_crate= observed_raw MINUS the measured harness baseline — INFORMATIONAL only (see invariant).
#   named         = observed_raw classes some package function's inferred set LITERALLY contains (strong).
#   unknown_only  = observed_raw classes covered ONLY by a disclosed Unknown (honest but weak/near-vacuous).
#   violations    = observed_raw classes NO function names AND NO function discloses Unknown (cardinal sin).
#   level         = per-function (strace -k stacks reconstructed) or program (fallback).
printf 'package\ttag\tobserved_raw\tobserved_crate\tnamed\tunknown_only\tviolations\tlevel\tverdict\n' > "$SUM"

# swift-demangle is shipped in the swift toolchain image; used to turn $s-mangled frames into readable paths.
DEMANGLE="$(command -v swift-demangle || true)"

# ---------------------------------------------------------------------------------------------------------
# HARNESS BASELINE (informational). Build a throwaway SwiftPM package whose only test is an empty XCTest and
# strace its test bundle through the SAME pipeline. Whatever effect classes appear are produced by XCTest +
# the Swift runtime + the loader ITSELF (dlopen of the test bundle + runtime dylibs -> Fs; the runtime may
# open a control socket -> Net), not by any package under test. Subtracted from observed_raw only.
# THIS NEVER GATES — see the soundness invariant banner above.
# ---------------------------------------------------------------------------------------------------------
BASELINE="-"
strace_bundle() { # $1=bundle $2=outfile ; also try -k into $2.k
  strace -f -e trace=openat,openat2,open,connect,socket,execve,unlink -o "$2" "$1" >/dev/null 2>&1 || true
  strace -f -k -e trace=openat,openat2,open,connect,socket,execve,unlink -o "$2.k" "$1" >/dev/null 2>&1 || true
}
classes_of() { # $1=trace -> comma-list of effect classes
  python3 - "$1" <<'PY'
import sys,re
CLS={'openat':'Fs','openat2':'Fs','open':'Fs','unlink':'Fs','connect':'Net','socket':'Net','execve':'Exec'}
RX=re.compile(r'(?:^|\s)(openat2|openat|open|connect|socket|execve|unlink)\(')
obs=set()
for line in open(sys.argv[1],errors='replace'):
    m=RX.search(line)
    if m and m.group(1) in CLS: obs.add(CLS[m.group(1)])
print(",".join(sorted(obs)) or "-")
PY
}
measure_baseline() {
  local bd="$WORK/__baseline__"
  rm -rf "$bd"; mkdir -p "$bd/Sources/Base" "$bd/Tests/BaseTests"
  cat > "$bd/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name:"Base",
  targets:[.target(name:"Base"), .testTarget(name:"BaseTests", dependencies:["Base"])])
SWIFT
  printf 'public func base() {}\n' > "$bd/Sources/Base/Base.swift"
  printf 'import XCTest\nfinal class BaseTests: XCTestCase { func testNoop() {} }\n' > "$bd/Tests/BaseTests/BaseTests.swift"
  ( cd "$bd" && swift build --build-tests -q ) >"$bd/build.log" 2>&1 || { echo "  baseline build failed — baseline empty"; return; }
  local bb; bb=$(find "$bd/.build/debug" -name '*PackageTests.xctest' 2>/dev/null | head -1)
  [ -x "$bb" ] || bb=$(find "$bd/.build" -name '*.xctest' -type f 2>/dev/null | head -1)
  [ -n "$bb" ] || { echo "  no baseline test bundle — baseline empty"; return; }
  strace_bundle "$bb" "$bd/trace.log"
  BASELINE="$(classes_of "$bd/trace.log")"
}
echo "measuring harness baseline (empty XCTest package under the same strace pipeline)…"
measure_baseline
echo "harness baseline effect classes (informational, subtracted from observed_crate only): [$BASELINE]"

grep -vE '^\s*#|^\s*$' "$HERE/manifest.tsv" | while IFS=$'\t' read -r name url tag effects why; do
  echo; echo "################## $name ($tag) ##################"
  d="$WORK/$name"
  [ -d "$d/.git" ] || { rm -rf "$d"; git clone --quiet --depth 1 --branch "$tag" "$url" "$d" 2>/dev/null \
      || { echo "  clone-failed"; printf '%s\t%s\t-\t-\t-\t-\t-\t-\tclone-failed\n' "$name" "$tag" >>"$SUM"; continue; }; }
  rm -rf "$d/.candor"; "$SW" "$d" >/dev/null 2>&1
  rep=$(ls "$d"/.candor/report.*.Swift.json 2>/dev/null | grep -vE 'callgraph|hierarchy' | head -1)
  [ -n "$rep" ] || { echo "  scan-failed"; printf '%s\t%s\t-\t-\t-\t-\t-\t-\tscan-failed\n' "$name" "$tag" >>"$SUM"; continue; }
  if ! ( cd "$d" && swift build --build-tests -q ) >"$d/build.log" 2>&1; then
    echo "  build-failed (see $d/build.log)"; printf '%s\t%s\t-\t-\t-\t-\t-\t-\tbuild-failed\n' "$name" "$tag" >>"$SUM"; continue
  fi
  bin=$(find "$d/.build/debug" -name '*PackageTests.xctest' 2>/dev/null | head -1)
  [ -x "$bin" ] || bin=$(find "$d/.build" -name '*.xctest' -type f 2>/dev/null | head -1)
  [ -n "$bin" ] || { echo "  no test bundle"; printf '%s\t%s\t-\t-\t-\t-\t-\t-\tno-test-bin\n' "$name" "$tag" >>"$SUM"; continue; }
  # program-level trace (observed_raw) + a SEPARATE -k trace (per-function upgrade). Keeping them separate
  # means observed_raw is never affected by whether -k stacks reconstruct.
  strace_bundle "$bin" "$d/trace.log"

  # ---- PROGRAM-LEVEL analysis on observed_raw (THE CHECKED SET) + informational columns. --------------
  observed=$(BASELINE="$BASELINE" python3 - "$d/trace.log" "$rep" <<'PY'
import json,sys,re,os
trace,rep=sys.argv[1],sys.argv[2]
CLS={'openat':'Fs','openat2':'Fs','open':'Fs','unlink':'Fs','connect':'Net','socket':'Net','execve':'Exec'}
# observed_raw = EVERY effect class the kernel emitted. This is the set the H-violation check runs on.
RX=re.compile(r'(?:^|\s)(openat2|openat|open|connect|socket|execve|unlink)\(')
raw=set()
for line in open(trace,errors='replace'):
    m=RX.search(line)
    if m and m.group(1) in CLS: raw.add(CLS[m.group(1)])
d=json.load(open(rep)); named=set(); unknown=False
for f in d.get('functions',[]):
    inf=set(f.get('inferred') or []); named|=(inf-{'Unknown'})
    if 'Unknown' in inf or f.get('invisible') or f.get('unresolved') or f.get('incomplete'): unknown=True
# harness baseline (informational only) -> observed_crate. NEVER used for the violation check below.
base=set(x for x in (os.environ.get('BASELINE','') or '').split(',') if x and x!='-')
crate=raw-base
# named-vs-Unknown breakdown + the VIOLATION check — all on observed_raw (raw), never on crate.
named_cov=set(); unknown_only=set(); viol=set()
for c in raw:                                  # <-- SOUNDNESS: iterate observed_raw, not observed_crate.
    if c in named: named_cov.add(c)            # strong: a function literally names this class.
    elif unknown:  unknown_only.add(c)         # weak: covered only by a disclosed Unknown (near-vacuous).
    else:          viol.add(c)                 # cardinal sin: undisclosed observed effect class.
j=lambda s: ",".join(sorted(s)) or "-"
print("%s|%s|%s|%s|%s"%(j(raw),j(crate),j(named_cov),j(unknown_only),j(viol)))
PY
)
  IFS='|' read -r obs_raw obs_crate named unk_only vio <<<"$observed"

  # ---- PER-FUNCTION upgrade via -k stacks (best-effort; honest fallback to program-level). -------------
  # Reconstruct the package functions on the kernel stack at each effect syscall and check per-function H:
  # every ON-STACK package function must NAME the effect class or disclose Unknown. Falls back to program-
  # level (level=program) whenever no -k stack yields a demangled package frame we can attribute. Swift
  # frames are $s-mangled; we prefer `swift-demangle` (in the toolchain image) and fall back to a leaf
  # heuristic if it is absent.
  pf=$(DEMANGLE="$DEMANGLE" python3 - "$d/trace.log.k" "$rep" <<'PY'
import json,sys,re,os,subprocess
ktrace,rep=sys.argv[1],sys.argv[2]
SYS2CLS={'openat':'Fs','openat2':'Fs','open':'Fs','unlink':'Fs','connect':'Net','socket':'Net','execve':'Exec'}
SYSLINE=re.compile(r'(?:^|\s)(openat2|openat|open|connect|socket|execve|unlink)\(')
FRAME=re.compile(r'^\s*>\s')
SYM=re.compile(r'\(([^)+]+)')
if not os.path.exists(ktrace):
    print("program|-"); sys.exit()

# Collect raw symbols per effect event first, then batch-demangle Swift symbols in one swift-demangle call.
events=[]; cur=None
for line in open(ktrace,errors='replace'):
    if FRAME.match(line):
        if cur is not None:
            m=SYM.search(line)
            if m: cur[1].append(m.group(1))
        continue
    m=SYSLINE.search(line)
    if m:
        cls=SYS2CLS.get(m.group(1))
        if cur is not None: events.append(cur)
        cur=[cls,[]] if cls else None
    else:
        if cur is not None: events.append(cur); cur=None
if cur is not None: events.append(cur)

allsyms=sorted({s for _,ls in events for s in ls})
demangled={}
dm=os.environ.get('DEMANGLE') or ''
swift_syms=[s for s in allsyms if s.startswith('$s') or s.startswith('_$s') or s.startswith('$S')]
if dm and swift_syms:
    try:
        out=subprocess.run([dm,'-compact']+swift_syms,capture_output=True,text=True,timeout=60).stdout.splitlines()
        for s,o in zip(swift_syms,out): demangled[s]=o
    except Exception:
        pass
def leaf(sym):
    full=demangled.get(sym,sym)
    # demangled Swift looks like 'Module.Type.method(args) -> R' or 'Module.func(...)'. Take the identifier
    # just before the first '(' (the call site), then its last dotted component = the method/func name.
    full=re.sub(r'<[^<>]*>','',full)
    head=full.split('(')[0].strip()
    if not head: return sym
    return head.split('.')[-1].strip()

# candor per-function table, keyed by leaf name (report 'fn' is like 'Type.method' / 'Module.func' / bare).
d=json.load(open(rep)); fns={}
for f in d.get('functions',[]):
    inf=set(f.get('inferred') or [])
    disclosed=('Unknown' in inf) or any(f.get(k) for k in ('unresolved','invisible','blind','incomplete'))
    fn=(f.get('fn') or '')
    lf=re.split(r'[.:]',fn)[-1] if fn else ''
    if lf: fns[lf]=(inf,disclosed)

checked=0; bad=set()
for cls,syms in events:
    onstack=[leaf(s) for s in syms]
    onstack=[l for l in onstack if l in fns]
    if not onstack: continue
    checked+=1
    for l in onstack:
        inf,disclosed=fns[l]
        if cls in inf or disclosed: continue
        bad.add("%s@%s{%s}"%(l,cls,",".join(sorted(inf)) or "-"))
if checked==0:
    print("program|-")            # honest fallback: no attributable package frame -> program-level only.
else:
    print("perfn|%s"%(";".join(sorted(bad)) or "-"))
PY
)
  IFS='|' read -r level pf_bad <<<"$pf"
  [ "$level" = "perfn" ] || level="program"

  # VERDICT from the observed_raw violation set (the program-level cardinal-sin gate); the per-function
  # pass is an additional stricter datapoint surfaced alongside — the primary H gate stays observed_raw.
  if [ "$vio" != "-" ]; then verdict="VIOLATION[$vio]"
  elif [ "$level" = "perfn" ] && [ "$pf_bad" != "-" ]; then verdict="PF-VIOLATION[$pf_bad]"
  else verdict="H-holds"; fi
  echo "  observed_raw=[$obs_raw] observed_crate=[$obs_crate] named=[$named] unknown_only=[$unk_only] level=$level -> $verdict"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$tag" "$obs_raw" "$obs_crate" "$named" "$unk_only" "$vio" "$level" "$verdict" >>"$SUM"
done
echo; echo "===================== SWIFT CONFIRMATORY (program-level H on observed_raw) ====================="
echo "harness baseline (informational, subtracted only in observed_crate): [$BASELINE]"
column -t -s "$(printf '\t')" "$SUM" 2>/dev/null || cat "$SUM"
nviol=$(awk -F'\t' 'NR>1 && $9 ~ /^VIOLATION/' "$SUM" | wc -l | tr -d ' ')
npf=$(awk -F'\t' 'NR>1 && $9 ~ /^PF-VIOLATION/' "$SUM" | wc -l | tr -d ' ')
echo; echo "packages with an undisclosed observed effect class (program-level false all-clear, on observed_raw): $nviol"
echo "packages with a per-function under-report (stricter -k check, program-level still H-holds): $npf"
