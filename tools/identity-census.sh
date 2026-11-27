#!/usr/bin/env bash
# tools/identity-census.sh — run the type-identity probe and the analysers.
#
#   tools/identity-census.sh --fixtures BIN OUTDIR        the six seed fixtures (fx3 fx4 fx5 fx5nw Pkg6 Pkg6c): census + kappa shadow
#   tools/identity-census.sh --pool BIN POOLDIR OUTDIR    every entry of a pool, --jobs 2: census + kappa shadow + module identity
#
# BIN is a candor-swift built WITH the probe (it is in every build from the R1938 lane on; it is OFF unless CANDOR_IDENT_PROBE is set,
# which this script sets). Each entry's probe trace lands in OUTDIR/<entry>.probe. The analysers read them:
#   ident_census.py   binder sites where the engine's binding and Swift's differ (X1/X2/X3), and the use-site census
#   kappa_shadow.py   which platform names a scan type shadows
#   ident_modules.py  moduleOf vs swiftModuleOf, the attribution gap, the visible-set cross-check
# The analysers live beside this script because they read the ENGINE's probe format; the umbrella's bin/ is for tools that need nothing
# engine-side.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:?--fixtures|--pool}"; bin="${2:?BIN}"
[ -x "$bin" ] || { echo "no such binary: $bin" >&2; exit 2; }
if [ "$mode" = "--fixtures" ]; then
  out="${3:?OUTDIR}"; fx="$here/../Tests/Fixtures/TypeIdentity"
  rm -rf "${out:?}"; mkdir -p "$out/pool"
  for pair in fx3/App3 fx4/App4 fx5/App5 fx5nw/App5nw fx6/Pkg6 fx6/Pkg6c; do
    n="$(basename "$pair")"
    # an ABSOLUTE staged copy so the relative `.package(path:)` in the manifests resolves
    mkdir -p "$out/stage"; [ -e "$out/stage/fx" ] || cp -R "$fx/." "$out/stage/"
    ln -sfn "$out/stage/$pair" "$out/pool/$n"
    env -u CANDOR_DEPS CANDOR_IDENT_PROBE=1 "$bin" "$out/stage/$pair" --out "$out/rep.$n" > /dev/null 2> "$out/$n.probe"
    rm -f "$out/rep.$n".*
  done
  pool="$out/pool"
else
  pool="${3:?POOLDIR}"; out="${4:?OUTDIR}"; rm -rf "${out:?}"; mkdir -p "$out"
  export bin out pool
  # --jobs 2: RAM is shared (24 GB). Each entry is one scan.
  ls "$pool" | xargs -P 2 -I{} bash -c 'env -u CANDOR_DEPS CANDOR_IDENT_PROBE=1 "$bin" "$pool/{}" --out "$out/rep.{}" > /dev/null 2> "$out/{}.probe"; rm -f "$out/rep.{}".*'
fi
if [ "$mode" = "--fixtures" ]; then
  # the SEEDS: each instrument must fire on the fixture it was written for and stay quiet on its control. A census that cannot
  # fail proves nothing, so this table is the first thing to read. Binder-site X1/X2/X3 per entry, then the use-site answers.
  echo "== seeds (design: ident census fx3 4 / fx4 20 / fx5 0 / fx5nw 0 / Pkg6 5 / Pkg6c 0; use-site fx3 4 / fx4 14 / fx5 3 / fx5nw 3 / Pkg6 3 / Pkg6c 0)"
  printf '%-8s %-14s %s\n' entry "binder X1+X2+X3" "use-site X1 answers"
  for n in App3 App4 App5 App5nw Pkg6 Pkg6c; do
    o="$(python3 "$here/ident_census.py" "$out" "$pool" --entry-filter="$n")"
    b="$(printf '%s\n' "$o" | python3 -c "import sys,re; t=sys.stdin.read(); m=re.search(r\"^  \\w+\\s+\\{'X1': (\\d+), 'X2': (\\d+), 'X3': (\\d+)\\}\", t, re.M); print(sum(map(int,m.groups())) if m else 0)")"
    u="$(printf '%s\n' "$o" | python3 -c "import sys,re; t=sys.stdin.read(); m=re.search(r'^use-site: (\\{.*\\})', t, re.M); d=eval(m.group(1)) if m else {}; print(sum(v for k,v in d.items() if k.startswith('U.X1')))")"
    printf '%-8s %-14s %s\n' "$n" "$b" "$u"
  done
fi
echo "== ident_census.py"; python3 "$here/ident_census.py" "$out" "$pool"
echo "== kappa_shadow.py"; python3 "$here/kappa_shadow.py" "$out"
echo "== ident_modules.py"; python3 "$here/ident_modules.py" "$out" "$pool"
