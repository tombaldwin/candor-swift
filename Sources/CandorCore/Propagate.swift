// The effect/surface least-fixpoint, factored out of main.swift so it is unit-testable. Pure: it takes
// the per-fn seed sets and the caller→callees edge map and returns each fn's transitive union. Used for
// the inferred effect sets AND each literal surface (hosts/cmds/paths/tables) — the same propagation.

/// Propagate `seed` sets to the least fixpoint over `edges`: every caller's set unions in each callee's
/// set until nothing changes. Generic over the string sets, so effects and literal surfaces share it.
public func propagate(_ seed: [String: Set<String>], over edges: [String: Set<String>]) -> [String: Set<String>] {
    var acc = seed
    var changed = true
    while changed {
        changed = false
        for (caller, callees) in edges {
            for callee in callees {
                guard let add = acc[callee], !add.isEmpty else { continue }
                let before = acc[caller]?.count ?? 0
                acc[caller, default: []].formUnion(add)
                if (acc[caller]?.count ?? 0) != before { changed = true }
            }
        }
    }
    return acc
}
