#!/usr/bin/env python3
"""tools/gen-stdlib-conformances.py — DERIVE the platform's nominal-type -> protocol conformance table.

SOUNDNESS R1071 (residual). A dependency's (or this package's own) `extension Sequence { func stampAll() }`
called on a STANDARD-LIBRARY receiver (`a: [Int]`, `s: String`, `d: Data`) resolves to that extension only
if the receiver's type conforms to `Sequence` — a fact the PLATFORM declares, and no report carries. A
hand-listed table of "which stdlib types are Sequences" is an ALLOWLIST: every type it forgets is a silent
under-report. So the table is not written; it is READ from the compiler's own published module interfaces
(the `.swiftinterface` files in the SDK), which state every public conformance of every public type:

    @frozen public struct Array<Element> : Swift::_DestructorSafeContainer {
    extension Swift::Array : Swift::RandomAccessCollection, Swift::MutableCollection {
    public protocol Collection<Element> : Swift::Sequence {
    public typealias Codable = Swift::Decodable & Swift::Encodable

CONDITIONAL conformances (`extension Array : Equatable where Element : Equatable`) are INCLUDED: the table
answers "MAY this type conform", and a call that compiled against a member only a protocol extension
provides proves the conformance held at that site.

Run on macOS with Xcode selected; writes Sources/candor-swift/StdlibConformances.swift. `--check` exits 1
when the checked-in file differs from what this SDK derives (an SDK bump is then a regenerate + review).
"""
import os, re, subprocess, sys

MODULES = ["Swift", "_Concurrency", "_StringProcessing", "Foundation", "Dispatch"]
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "candor-swift", "StdlibConformances.swift")


def interface(sdk, mod):
    cands = [
        f"{sdk}/usr/lib/swift/{mod}.swiftmodule/arm64e-apple-macos.swiftinterface",
        f"{sdk}/System/Library/Frameworks/{mod}.framework/Versions/C/Modules/{mod}.swiftmodule/arm64e-apple-macos.swiftinterface",
        f"{sdk}/System/Library/Frameworks/{mod}.framework/Modules/{mod}.swiftmodule/arm64e-apple-macos.swiftinterface",
    ]
    for c in cands:
        if os.path.exists(c):
            return c
    sys.exit(f"gen-stdlib-conformances: no interface for {mod} under {sdk}")


QUAL = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*::")


def strip(s):
    return QUAL.sub("", s).strip()


def split_top(s, sep=","):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "<([":
            depth += 1
        elif ch in ">)]":
            depth -= 1
        if ch == sep and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def supers_of(clause):
    """`: A, @unchecked B, C & D where ...` (already cut at the brace) -> [A, B, C, D]"""
    clause = re.split(r"\bwhere\b", clause)[0]
    names = []
    for part in split_top(clause):
        for p in part.split("&"):
            p = re.sub(r"@[A-Za-z_]+(\([^)]*\))?", "", p).strip()
            if not p or p.startswith("~"):
                continue
            p = strip(p)
            p = re.sub(r"<.*", "", p).strip()          # `Sequence<Element>` primary associated types
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", p):
                names.append(p)
    return names


DECL = re.compile(r"^(?P<ind> *)(?:@[^\s(]+(?:\([^)]*\))?\s+)*(?:public|open)\s+(?:final\s+)?(?:indirect\s+)?"
                  r"(?P<kind>struct|enum|class|protocol|actor)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
                  r"(?:<[^{:]*?>)?(?P<rest>.*)$")
EXT = re.compile(r"^(?P<ind> *)(?:@[^\s(]+(?:\([^)]*\))?\s+)*extension\s+(?P<name>[A-Za-z_][A-Za-z0-9_:.]*)(?P<rest>.*)$")
ALIAS = re.compile(r"^(?:@[^\s(]+(?:\([^)]*\))?\s+)*public\s+typealias\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?P<rhs>.+)$")


FUNC = re.compile(r"\b(?:public|open)\s+(?:[a-z_]+\s+)*func\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^(]*>)?\s*\(")
PROP = re.compile(r"\b(?:public|open)\s+(?:[a-z_]+\s+)*var\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:")


def params_of(text, start):
    """The parenthesised parameter clause starting at text[start] == '(' -> external label specs."""
    depth, i = 0, start
    while i < len(text):
        if text[i] in "([<":
            depth += 1
        elif text[i] in ")]>" and not (text[i] == ">" and text[i - 1] == "-"):
            depth -= 1
            if depth == 0:
                break
        i += 1
    clause = text[start + 1:i]
    specs = []
    for prm in split_top(clause):
        prm = prm.strip()
        if not prm or ":" not in prm:
            continue
        head, rest = prm.split(":", 1)
        label = head.split()[0] if head.split() else "_"
        defaulted = "=" in "".join(split_top(rest, "="))[0:0] or len(split_top(rest, "=")) > 1
        variadic = rest.split("=")[0].strip().endswith("...")
        specs.append(label + ("=" if defaulted else "") + ("..." if variadic else ""))
    return specs


def parse(path, conforms, protocols, nominals, members, props, mutating):
    stack = []            # (indent, qualified type name) of the enclosing type / extension bodies
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("//") or line.lstrip().startswith("#"):
            continue
        ind = len(line) - len(line.lstrip(" "))
        while stack and stack[-1][0] >= ind:
            stack.pop()
        if stack and stack[-1][1]:   # a member of a platform type / protocol / extension
            fm = FUNC.search(line)
            if fm:
                members.setdefault(fm.group("name"), set()).add(",".join(params_of(line, fm.end() - 1)))
                if re.search(r"\bmutating\s+(?:[a-z_]+\s+)*func\b", line):
                    mutating.add(fm.group("name"))
            pm = PROP.search(line)
            if pm:
                props.add(pm.group("name"))
        m = ALIAS.match(line)
        if m and ind == 0 and "&" in m.group("rhs"):
            parts = [strip(x) for x in m.group("rhs").split("&")]
            if all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", p) for p in parts):
                protocols.add(m.group("name"))
                conforms.setdefault(m.group("name"), set()).update(parts)
            continue
        m = EXT.match(line)
        if m:
            name = strip(m.group("name"))
            rest = m.group("rest").split("{")[0]
            if rest.lstrip().startswith(":"):
                conforms.setdefault(name, set()).update(supers_of(rest.lstrip()[1:]))
            if line.rstrip().endswith("{"):
                stack.append((ind, name))
            continue
        m = DECL.match(line)
        if m:
            outer = stack[-1][1] if stack else None
            if stack and not outer:
                continue
            name = f"{outer}.{m.group('name')}" if outer else m.group("name")
            rest = m.group("rest").split("{")[0].strip()
            if m.group("kind") == "protocol":
                protocols.add(name)
            else:
                nominals.add(name)
            conforms.setdefault(name, set())
            if rest.startswith(":"):
                conforms[name].update(supers_of(rest[1:]))
            if line.rstrip().endswith("{"):
                stack.append((ind, name))
            continue
        if line.rstrip().endswith("{"):
            stack.append((ind, None))   # a function / accessor body: nothing nested in it is a type here


def main():
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    sdkver = subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip()
    conforms, protocols, nominals, members, props, mutating = {}, set(), set(), {}, set(), set()
    for mod in MODULES:
        parse(interface(sdk, mod), conforms, protocols, nominals, members, props, mutating)
    # Only public names: underscored types and protocols are implementation detail no source spells, and
    # an underscored SUPER is kept only where it is a protocol we also know (its own refinements matter).
    keep = lambda n: not n.split(".")[-1].startswith("_")
    lines = [
        "// GENERATED by tools/gen-stdlib-conformances.py from the macOS SDK " + sdkver + " module interfaces",
        "// (" + ", ".join(MODULES) + ") — do not edit; regenerate. SOUNDNESS R1071: the conformance table is",
        "// DERIVED from what the platform declares, never hand-listed (an omission would be a silent under-report).",
        "",
        "/// Every public protocol the platform modules declare (including `Codable`-style composition aliases).",
        "let STDLIB_PROTOCOLS: Set<String> = [",
    ]
    for p in sorted(x for x in protocols if keep(x)):
        lines.append(f'    "{p}",')
    lines += ["]", "", "/// Every public nominal (struct / enum / class / actor) type the platform modules declare.",
              "let STDLIB_NOMINALS: Set<String> = ["]
    for n in sorted(x for x in nominals if keep(x)):
        lines.append(f'    "{n}",')
    lines += ["]", "",
              "/// Each platform type or protocol -> the protocols it DIRECTLY conforms to / refines, unioned over its",
              "/// declaration and every extension (conditional conformances included: \"may conform\").",
              "let STDLIB_DIRECT_CONFORMANCES: [String: [String]] = ["]
    for n in sorted(conforms):
        if not keep(n) and n not in protocols:
            continue
        sups = sorted(s for s in conforms[n] if s != n)
        if not sups:
            continue
        body = ", ".join(f'"{s}"' for s in sups)
        lines.append(f'    "{n}": [{body}],')
    lines += ["]", "",
              "/// Every public METHOD the platform types and protocols declare -> each declaration's external labels,",
              "/// comma-joined (`_` = unlabelled; `=` suffix = defaulted; `...` = variadic). A member call whose labels one",
              "/// of these admits may be the platform's own member rather than an extension's same-named one.",
              "let STDLIB_MEMBER_LABELS: [String: [String]] = ["]
    for n in sorted(members):
        body = ", ".join(f'"{x}"' for x in sorted(members[n]))
        lines.append(f'    "{n}": [{body}],')
    lines += ["]", "", "/// Every public PROPERTY name the platform types and protocols declare.",
              "let STDLIB_PROPERTY_NAMES: Set<String> = ["]
    for n in sorted(props):
        lines.append(f'    "{n}",')
    lines += ["]", "",
              "/// SOUNDNESS R1105 — every METHOD name some platform type or protocol declares `mutating`. A call of one of",
              "/// these through a property chain may write the property back (running its setter and observers); a",
              "/// platform method NOT in this set never does.",
              "let STDLIB_MUTATING_MEMBERS: Set<String> = ["]
    for n in sorted(mutating):
        lines.append(f'    "{n}",')
    lines += ["]", ""]
    text = "\n".join(lines)
    if "--check" in sys.argv:
        cur = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        strip_hdr = lambda t: "\n".join(t.split("\n")[1:])
        if strip_hdr(cur) != strip_hdr(text):
            print("gen-stdlib-conformances: the checked-in table differs from this SDK's interfaces — regenerate and review")
            sys.exit(1)
        print("gen-stdlib-conformances: OK")
        return
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"wrote {OUT}: {len(protocols)} protocols, {len(nominals)} nominals, {len(conforms)} conformance rows")


if __name__ == "__main__":
    main()
