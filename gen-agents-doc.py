#!/usr/bin/env python3
"""Regenerate Sources/candor-swift/AgentsDoc.swift from AGENTS.md (the canonical doc).

The agent contract is EMBEDDED as a Swift string constant — not a bundle resource — so
`candor-swift --agents` works for a binary copied out of .build (the documented install flow),
where Bundle.module would fatalError. smoke.sh gates drift by diffing --agents output against
AGENTS.md. Run this after editing AGENTS.md.
"""
import pathlib

HERE = pathlib.Path(__file__).parent
doc = (HERE / "AGENTS.md").read_text()
# Raw Swift string with a 5-hash delimiter: markdown never contains the sequence `"""#####`.
delim = "#####"
assert f'"""{delim}' not in doc and f'{delim}"""' not in doc, "delimiter collision — add hashes"
out = (
    "// GENERATED from AGENTS.md by gen-agents-doc.py — do not edit.\n"
    "// The agent contract, embedded so `--agents` needs no resource bundle (a copied binary has none).\n"
    f'let AGENTS_MD = {delim}"""\n{doc}"""{delim}\n'
)
(HERE / "Sources" / "candor-swift" / "AgentsDoc.swift").write_text(out)
print(f"AgentsDoc.swift regenerated ({len(doc)} chars)")
