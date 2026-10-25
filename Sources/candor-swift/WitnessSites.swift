import Foundation

// CALL-TARGET ROUND 2 — ONE ENTRY POINT FOR "WHICH PLATFORM MEMBER RUNS A USER WITNESS HERE".
//
// The release recognised these sites from four hand lists in CallCollector (`COMPARABLE_ORDERERS` = sorted/max/min,
// `EQUATABLE_ELEMENT_MEMBERS` = 6 names, `SET_HASHING_MEMBERS` = 17, `DICT_KEY_MEMBERS` = 3), and a member a list
// forgot produced no edge and no `Unknown`: `a.sort()` (the in-place twin of `sorted()`) and the free `max(a, b)` read
// pure while the program ran the element's `<` (calltarget matrix H09/H11, SOUNDNESS R1249 — executed). The lists are
// gone; the sites come from `STDLIB_WITNESS_SITES`, DERIVED from the SDK's `.swiftinterface` by
// tools/gen-stdlib-conformances.py and re-derived independently by `DerivedWitnessSitesTests`. A site matches the
// SPELLED call's argument labels against the declaration (`a.index(of: x)` runs `==`, `a.index(after: i)` does not),
// so a name alone never decides.

/// Does a call spelled with `call` argument labels (nil = unlabelled) and `trailing` trailing closures admit a
/// declaration whose external labels are `decl` (`STDLIB_MEMBER_LABELS` spelling: `_` unlabelled, `=` suffix
/// defaulted, `...` variadic)? The one implementation; Driver's R1071 platform-member check calls it too.
func declLabelsAdmit(_ call: [String?], _ trailing: Int, _ decl: [String]) -> Bool {
    var i = 0, trail = trailing
    for spec in decl {
        var label = spec
        let variadic = label.hasSuffix("..."); if variadic { label.removeLast(3) }
        let defaulted = label.hasSuffix("="); if defaulted { label.removeLast() }
        if i < call.count, (call[i] ?? "_") == label {
            i += 1
            if variadic { while i < call.count, call[i] == nil { i += 1 } }
        } else if defaulted || variadic {
            continue
        } else if i >= call.count, trail > 0 {
            trail -= 1
        } else {
            return false
        }
    }
    return i == call.count
}

/// Kill switch: every derived witness site inert (the four call sites below recognise NOTHING — not the release's
/// lists; the published binary is the before-arm). Diagnosis only.
let ct2SitesOff = ProcessInfo.processInfo.environment["CANDOR_CT2_SITES_OFF"] != nil

/// The witnesses (`==`, `<`, `hash`) the platform member `<kind>.<name>` runs at a call spelled with `labels`
/// (no closure arguments: the caller has already excluded a closure form), or `[]` when the table names none.
/// `kind`: `seq` (an array/collection receiver), `set`, `dict`, `free`.
func stdlibWitnessSite(_ kind: String, _ name: String, labels: [String?]) -> [String] {
    if ct2SitesOff { return [] }
    let key = "\(kind).\(name)"
    guard let ws = STDLIB_WITNESS_SITES[key], let specs = STDLIB_WITNESS_SITE_LABELS[key] else { return [] }
    for spec in specs where declLabelsAdmit(labels, 0, spec.isEmpty ? [] : spec.split(separator: ",").map(String.init)) {
        return ws
    }
    return []
}
