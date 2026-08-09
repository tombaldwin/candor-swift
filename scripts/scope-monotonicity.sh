#!/usr/bin/env bash
# SCOPE MONOTONICITY — a SELF-differential property: one engine against itself, scoped vs unscoped.
#
#   For a LEAF function in a file that a `Package.swift` owns, present in both runs:
#       scoped `invisible`(fn)  ⊇  unscoped `invisible`(fn)
#
#   Scoping may only ever DISCLOSE MORE about such a function, never less.
#
# WHY THOSE TWO RESTRICTIONS ARE NOT HEDGING. The naive property — "a scoped scan is never more silent
# than an unscoped one" — is FALSE, and it was written, run, and refuted before this version existed.
# On NetNewsWire it reported 991 violations across 7 of 8 targets. Both restrictions remove a class of
# them for a reason, and what is left is 0.
#
#   OWNED FILES ONLY (991 → 90). Scoping does not only narrow — it ADDS evidence. An app-level file has
#   no owning `Package.swift`, so the unscoped scan knows nothing about what it may import and claims
#   nothing; the scoped scan knows which Xcode target compiles it and what that target links. The scoped
#   run is entitled to claim more there, so the two runs are not comparable. A file under a package is
#   answered from its manifest either way, and the manifest does not change with the scope — only the
#   set of ANALYZED targets does, and that set shrinks under scoping, so the claim can only shrink too.
#
#   LEAF FUNCTIONS ONLY (90 → 0). `invisible` PROPAGATES along the callgraph, so a function in a package
#   accumulates the hedges of everything it reaches — including app-level code, which reintroduces the
#   case above through the back door. A leaf function's hedge is exactly its own file's, with no
#   propagation, which is the quantity the argument above is about.
#
# So the property holds where it is argued to hold, and nowhere else. That distinction is the whole
# value: a green run of the naive version would have been meaningless, and a red run of it — which is
# what happened — says nothing about the engine.
#
# WHY BOTHER, given fixtures exist. No fixture finds a defect its author did not already suspect. This
# asks a real tree, has no expected-value table, and cannot drift from the engine, because the two runs
# are each other's oracle. It is aimed at one defect class in particular: the rung this checks was
# opened by an app target's `import Lottie` going SILENT under `--target` while the unscoped scan of the
# same tree disclosed it.
#
# A VIOLATION IS NOT ALWAYS A SCOPING DEFECT, and the first one this found was not. On
# home-assistant/iOS it flagged `Promise.asyncValue` losing its `Shared` hedge under 12 targets. The
# cause is two DIFFERENT units merging under one key: a `public extension Promise { func asyncValue() }`
# in module HANetworking, and a `private extension Promise { var asyncValue }` in the App module, whose
# file imports `Shared`. The unscoped run holds both and unions their hedges; a scoped run that contains
# only one does not. Extension members on the same type from two modules are two units — so the finding
# is real, it is a unit-identity defect rather than a scoping one, and it fabricates (a caller of either
# gets the other's effects) rather than silencing. Read a violation as "these two runs disagree", then
# ask which of them is wrong.
#
# Usage:  scripts/scope-monotonicity.sh <repo-dir> [candor-swift-binary]
# Exit:   0 property holds · 1 violated (details on stdout) · 2 could not run
set -uo pipefail

REPO="${1:-}"
BIN="${2:-$(cd "$(dirname "$0")/.." && pwd)/.build/release/candor-swift}"
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "usage: $0 <repo-dir> [binary]" >&2; exit 2; }
[ -x "$BIN" ] || { echo "no candor-swift binary at $BIN (swift build -c release)" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "scope-monotonicity: $REPO"

# The unscoped baseline. A refusal here is a scan that never happened, not a property violation.
if ! "$BIN" "$REPO" --json > "$WORK/unscoped.json" 2> "$WORK/unscoped.err"; then
    echo "  unscoped scan did not succeed — nothing to compare against:"
    sed 's/^/    /' "$WORK/unscoped.err" | head -3
    exit 2
fi

# Target names come from the engine's own refusal listing, so this needs no second pbxproj reader.
"$BIN" "$REPO" --target "__no_such_target__$$" > /dev/null 2> "$WORK/targets.err"
TARGETS="$(sed -n 's/^    \(.*\)  ([^)]*)$/\1/p' "$WORK/targets.err" || true)"
if [ -z "$TARGETS" ]; then
    echo "  no Xcode targets declared here — the property is about scoping, so there is nothing to check"
    exit 0
fi

VIOLATIONS=0; CHECKED=0; CELLS=0
while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ! "$BIN" "$REPO" --target "$t" --json > "$WORK/scoped.json" 2> "$WORK/scoped.err"; then
        # A REFUSAL IS NOT A VIOLATION. Exit 2 is the engine declining to answer, which is the outcome
        # it is designed for; counting it here would pressure the next person to weaken a refusal to
        # make a property go green.
        echo "  [refused] $t — not a violation"
        continue
    fi
    CHECKED=$((CHECKED + 1))
    n=$(python3 - "$WORK/unscoped.json" "$WORK/scoped.json" "$t" "$REPO" <<'PY'
import json, os, sys
un, sc, target, root = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4]
U = {f["fn"]: f for f in un.get("functions", [])}
S = {f["fn"]: f for f in sc.get("functions", [])}

_owned_cache = {}
def owned(loc):
    """Does a DECLARED TARGET of some package own this file?

    Not "is there a Package.swift above it" — that was the first spelling and it is a different
    question. stripe-ios has a root manifest and an `Example/` tree that no declared target covers;
    those files fall to the Xcode arm exactly like an app-level file, so the property does not apply to
    them, and including them produced 12 violations that were all the excluded case. It also must not be
    "is there a NESTED manifest", which was the spelling before that: it excluded every root-only repo,
    and two of three held-out repos came back with ZERO live cells.

    So: the nearest `Package.swift` at or above the file, AND the file under that package's `Sources/`
    or `Tests/` — SwiftPM's conventional layout, which is what a declared target's source root is unless
    the manifest says `path:`. A `path:`-relocated target is missed, which costs cells and never
    invents them; the printed cell count is how you see that happening."""
    if not loc:
        return False
    d = os.path.dirname(os.path.join(root, loc.split(":")[0]))
    if d in _owned_cache:
        return _owned_cache[d]
    probe, hit = d, False
    while len(probe) >= len(root):
        if os.path.exists(os.path.join(probe, "Package.swift")):
            rest = d[len(probe):].lstrip("/")
            # `== "Sources"` as well as `startswith("Sources/")`. A target with `path: "Sources"` puts
            # its files DIRECTLY there with no per-target subdirectory, and requiring the trailing slash
            # excluded them — which silently dropped the one real violation this checker had found. That
            # is the failure mode a property is most vulnerable to: a filter tightened until the red goes
            # away. The finding was re-confirmed by hand before this line was written.
            first = rest.split("/", 1)[0]
            hit = first in ("Sources", "Tests")
            break
        if probe == root:
            break
        probe = os.path.dirname(probe)
    _owned_cache[d] = hit
    return hit

cells, bad = 0, []
for fn, u in U.items():
    s = S.get(fn)
    if s is None or u.get("calls") or s.get("calls") or not owned(u.get("loc")):
        continue
    cells += 1
    lost = set(u.get("invisible", [])) - set(s.get("invisible", []))
    if lost:
        bad.append((fn, u.get("loc"), sorted(lost)))

if bad:
    print(f"  [VIOLATION] --target {target}: the scoped scan claims what the unscoped scan disclosed",
          file=sys.stderr)
    for fn, loc, lost in bad[:8]:
        print(f"      {fn}  ({loc}) lost hedge {lost}", file=sys.stderr)
    if len(bad) > 8:
        print(f"      … and {len(bad) - 8} more", file=sys.stderr)
    print(f"CELLS {cells} BAD {len(bad)}")
    sys.exit(1)
print(f"CELLS {cells} BAD 0")
PY
)
    rc=$?
    CELLS=$((CELLS + $(echo "$n" | sed -n 's/^CELLS \([0-9]*\).*/\1/p')))
    [ $rc -eq 0 ] || VIOLATIONS=$((VIOLATIONS + 1))
done <<< "$TARGETS"

# CELL COUNT IS PART OF THE RESULT. A property with no live cells is green for the wrong reason, and a
# repo whose every function is filtered out by the two restrictions has told you nothing.
echo "  checked $CHECKED target(s), $CELLS live cell(s), $VIOLATIONS violation(s)"
[ "$CELLS" -gt 0 ] || { echo "  WARNING: no live cells — this run is vacuous, not passing"; exit 0; }
[ "$VIOLATIONS" -eq 0 ] || exit 1
