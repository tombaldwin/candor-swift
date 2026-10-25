# tools/calltarget — the exhaustive call-target matrix

One command: `bash tools/calltarget/run-all.sh <candor-swift binary> <outdir>` (hold the shared A/B lock on
the coordinator's machine; ~10 minutes at `--jobs 2`). Exit 0 means every executed measurement classifies
exactly as `baseline.tsv` says and every R764-shape control (`controls.py`) matches `controls-baseline.json`.
`--write-baseline` moves the baseline with an intended change; `--env K=V` reaches every scan (kill switches).

Axes, ground truth and classes: `gen.py` docstring, `classify.py`. Built by the call-target analysis lane
(2026-10-24) and committed in call-target round 1 (SOUNDNESS R1415/R1416). Not wired into per-commit CI.

Round 2 (2026-10-25) added controls to `controls.py`, all executed: K12–K18 (the re-key leg, N-hop stored property,
the R1436 sibling-subtree shape and its subtree/ancestor/held-value twins, `wx_unrelated_override`,
`wx_exact_producer`, indirect consumer subclass), R1437a–d (the four R1416 residuals), N1–N4 (non-invoking
look-alikes) and S1/S2 (chained report with its sidecars deleted vs present). K14 and K14h are the pair that shows
why R1436 cannot be scoped consumer-side: byte-identical producer rows, opposite ground truth.
