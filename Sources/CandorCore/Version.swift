// Version comparison for `--check-update`. Pure + side-effect-free, so it lives in CandorCore and is
// unit-testable; the executable does the (opt-in) network GET and feeds the two versions through here.

import Foundation

/// `true` iff release semver `a` is strictly greater than `b` by a NUMERIC tuple compare: split on '.',
/// parse each component as an integer (a non-numeric or missing component reads 0), compare left-to-right.
/// Mirrors the family's `version_gt` (candor-scan/ts/java) so `--check-update` agrees across engines:
/// `0.5.1 > 0.5.0`, `0.6.0 > 0.5.9`, equal → false, `0.5.0` vs `0.5` → false (trailing zeros).
public func versionGreater(_ a: String, _ b: String) -> Bool {
    func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
    let pa = parts(a), pb = parts(b)
    let n = max(pa.count, pb.count)
    for i in 0..<n {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}
