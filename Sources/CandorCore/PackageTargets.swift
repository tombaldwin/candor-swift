import Foundation
import SwiftParser
import SwiftSyntax

// PER-TARGET SCAN SCOPING — resolve one target of a multi-target package to the source dirs that
// actually compile into it.
//
// WHY, from a real finding. candor-swift scans a DIRECTORY: every `.swift` file under it. For a package
// with several shipped binaries sharing a core, that charges each binary with every OTHER binary's
// effects. Measured on a real app (see candor/docs/case-study-privacy-manifest.md): scanning the repo
// whole and verifying against the macOS `Info.plist` reported
//
//     ✗ code reaches Mic (via iOSBlowMonitor.…) but Info.plist declares no NSMicrophoneUsageDescription
//
// and `iOSBlowMonitor` lives in a target the macOS app does not compile. The ANALYSIS was right — the
// reach is real inside the scanned unit — but the unit was not a shipped binary, so the verdict was about
// nothing that ships. The documented remedy was to hand-build a separate `Package.swift` per binary,
// which is a workaround wearing methodology's clothes.
//
// THE SOUNDNESS DIRECTION THAT MATTERS. This feature makes a scan see LESS, and under ⟨0.21⟩ absence from
// `functions` is a positive purity claim — so every way of resolving too little is the cardinal sin, and
// every failure here REFUSES rather than falls back:
//
//   · an unknown target name          -> error listing the targets that exist (never "scan everything")
//   · a target whose source dir is absent -> error naming what was tried (never a silent skip)
//   · a dependency this file cannot classify -> kept as in-package if a target by that name exists
//
// EXTERNAL dependencies (`.product(name:package:)`) are deliberately NOT in the closure: they are not
// sources in this tree. They are already handled — and DISCLOSED — by the κ coverage ledger and the
// `--workspace` chain, so excluding them here changes nothing about what the report claims.

public struct PackageTarget: Equatable, Sendable {
    public let name: String
    /// In-package target names only. `.product(…)` entries are external and excluded by design.
    public let dependencies: [String]
    /// The `path:` argument if the manifest declared one, else nil (convention applies).
    public let path: String?
    public let isTest: Bool

    public init(name: String, dependencies: [String], path: String?, isTest: Bool) {
        self.name = name; self.dependencies = dependencies; self.path = path; self.isTest = isTest
    }
}

public enum TargetScopeError: Error, CustomStringConvertible, Equatable {
    case noManifest(dir: String)
    case noTargets(manifest: String)
    case unknownTarget(name: String, available: [String])
    case missingSourceDir(target: String, tried: [String])

    public var description: String {
        switch self {
        case .noManifest(let dir):
            return "--target needs a Package.swift to resolve against; none at \(dir)"
        case .noTargets(let m):
            return "no targets found in \(m) — --target cannot be resolved (is this a SwiftPM manifest?)"
        case .unknownTarget(let name, let available):
            return "no target named `\(name)`. This package declares: \(available.joined(separator: ", "))"
        case .missingSourceDir(let target, let tried):
            // REFUSES rather than scanning less: a target in the closure whose sources cannot be found
            // would silently drop real code from the scan, and absence from `functions` is a purity claim.
            return "target `\(target)` is in the dependency closure but its sources were not found "
                 + "(tried: \(tried.joined(separator: ", "))). Refusing to scan a partial closure — "
                 + "declare the target's `path:` in Package.swift, or scan without --target."
        }
    }
}

/// Every target a SwiftPM manifest declares. Parsed with SwiftSyntax rather than by regex: the manifest is
/// Swift, and the regex forms already in this repo (`manifestPackageName`) are documented as fragile for
/// exactly the reason a structured parse avoids — a `name:` belonging to something else, matched first.
public func parsePackageTargets(manifestSource: String) -> [PackageTarget] {
    let tree = Parser.parse(source: manifestSource)
    let finder = TargetFinder()
    finder.walk(tree)
    return finder.targets
}

/// The transitive in-package dependency closure of `name`, including `name` itself.
public func targetClosure(_ name: String, in targets: [PackageTarget]) throws -> [PackageTarget] {
    guard !targets.isEmpty else { throw TargetScopeError.noTargets(manifest: "Package.swift") }
    let byName = Dictionary(targets.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    guard byName[name] != nil else {
        throw TargetScopeError.unknownTarget(name: name, available: targets.map(\.name).sorted())
    }
    var seen = Set<String>()
    var out: [PackageTarget] = []
    var stack = [name]
    while let n = stack.popLast() {
        guard seen.insert(n).inserted, let t = byName[n] else { continue }
        out.append(t)
        // A dependency naming something this package does not declare is an EXTERNAL product referred to
        // by its bare name. Dropping it here is correct — it has no sources in this tree — and it stays
        // disclosed by the coverage ledger rather than becoming a silent purity claim.
        stack.append(contentsOf: t.dependencies.filter { byName[$0] != nil })
    }
    return out.sorted { $0.name < $1.name }
}

/// The source directories for a resolved closure, relative to `packageRoot`.
/// `exists` is injected so this is unit-testable without a filesystem.
public func targetSourceDirs(_ closure: [PackageTarget], packageRoot: String,
                            exists: (String) -> Bool) throws -> [String] {
    var dirs: [String] = []
    for t in closure {
        if let p = t.path {
            let abs = (packageRoot as NSString).appendingPathComponent(p)
            guard exists(abs) else { throw TargetScopeError.missingSourceDir(target: t.name, tried: [abs]) }
            dirs.append(abs); continue
        }
        // SwiftPM's conventional layout when no `path:` is declared: `Sources/<name>` (`Tests/<name>` for
        // a test target), falling back to a bare `<name>/` at the package root, which SwiftPM also accepts.
        let base = t.isTest ? "Tests" : "Sources"
        let candidates = [(packageRoot as NSString).appendingPathComponent("\(base)/\(t.name)"),
                          (packageRoot as NSString).appendingPathComponent(t.name)]
        guard let hit = candidates.first(where: exists) else {
            throw TargetScopeError.missingSourceDir(target: t.name, tried: candidates)
        }
        dirs.append(hit)
    }
    return dirs
}

// MARK: - the syntax walk

private final class TargetFinder: SyntaxVisitor {
    var targets: [PackageTarget] = []
    private static let kinds: Set<String> = ["target", "executableTarget", "testTarget", "macro", "plugin"]

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.base == nil,                                   // `.target(…)`, not `Foo.target(…)`
              Self.kinds.contains(member.declName.baseName.text) else { return .visitChildren }
        let isTest = member.declName.baseName.text == "testTarget"
        var name: String?, path: String?, deps: [String] = []
        for arg in node.arguments {
            switch arg.label?.text {
            case "name": name = Self.literal(arg.expression)
            case "path": path = Self.literal(arg.expression)
            case "dependencies":
                guard let arr = arg.expression.as(ArrayExprSyntax.self) else { break }
                for el in arr.elements {
                    if let s = Self.literal(el.expression) { deps.append(s); continue }
                    // `.target(name: "X")` and `.byName(name: "X")` are in-package references;
                    // `.product(name:package:)` is external and is deliberately not collected.
                    guard let call = el.expression.as(FunctionCallExprSyntax.self),
                          let m = call.calledExpression.as(MemberAccessExprSyntax.self),
                          ["target", "byName"].contains(m.declName.baseName.text) else { continue }
                    if let n = call.arguments.first(where: { $0.label?.text == "name" })
                        .flatMap({ Self.literal($0.expression) }) { deps.append(n) }
                }
            default: break
            }
        }
        if let n = name { targets.append(PackageTarget(name: n, dependencies: deps, path: path, isTest: isTest)) }
        // DO NOT DESCEND. `.target(name: "Core")` is also the in-package form of a DEPENDENCY reference
        // (`.testTarget(name: "CoreTests", dependencies: [.target(name: "Core")])`), and visiting children
        // parsed that inner call as a second DECLARATION of Core — one carrying no dependencies. Two
        // entries then race in the by-name dictionary, and when the phantom wins the closure walk stops at
        // Core instead of continuing through its own dependencies: sources silently dropped from the scan,
        // which under ⟨0.21⟩ is a purity claim over every function in them. Caught by the first run of
        // `testParsesEveryTargetKindAndItsShape`, which is the whole reason to assert on the full list
        // rather than on membership.
        return .skipChildren
    }

    /// A simple string literal's contents, or nil for anything interpolated or computed — which is
    /// treated as "not a name I can read", never guessed at.
    static func literal(_ expr: ExprSyntax) -> String? {
        guard let lit = expr.as(StringLiteralExprSyntax.self), lit.segments.count == 1,
              let seg = lit.segments.first?.as(StringSegmentSyntax.self) else { return nil }
        return seg.content.text
    }
}
