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
    /// `.plugin(…)` — a BUILD-TOOL or COMMAND plugin. Carried because a plugin is **not an importable
    /// module**: app code cannot `import` it, and its sources live under `Plugins/<name>`, which this
    /// engine's discovery excludes outright — so a plugin target can never legitimately account for an
    /// analyzed file. A consumer deciding module IDENTITY must skip it; a consumer resolving a scan
    /// SCOPE never reaches one (plugins do not appear in `dependencies:`), which is why the distinction
    /// did not exist until identity became a second caller.
    public let isPlugin: Bool
    /// A `dependencies:` argument was present but not a literal array, so this target's dependency list
    /// is UNKNOWN rather than empty. Resolving a closure through it would silently scan a subset.
    public let dependenciesUnreadable: Bool
    /// `.product(name:package:)` NAMES in this target's dependency list. The SPM `--target` closure
    /// still excludes them (they may be remote, and remote stays κ-disclosed) — but the `.xcodeproj`
    /// scoping resolves the LOCAL ones across a repo's sibling packages, and it needs the names to do
    /// so. Recorded, not resolved, here.
    public let productDependencies: [String]
    /// A `.product(…)` entry whose `name:` is not a literal — the Xcode-path resolver must REFUSE
    /// rather than treat "could not read" as "not there".
    public let productDependenciesUnreadable: Bool

    public init(name: String, dependencies: [String], path: String?, isTest: Bool,
                isPlugin: Bool = false,
                dependenciesUnreadable: Bool = false,
                productDependencies: [String] = [], productDependenciesUnreadable: Bool = false) {
        self.name = name; self.dependencies = dependencies; self.path = path; self.isTest = isTest
        self.isPlugin = isPlugin
        self.dependenciesUnreadable = dependenciesUnreadable
        self.productDependencies = productDependencies
        self.productDependenciesUnreadable = productDependenciesUnreadable
    }
}

/// One `products:` declaration of a SwiftPM manifest: `.library(name:targets:)` / `.executable(…)`.
public struct PackageProduct: Equatable, Sendable {
    public let name: String
    /// The member target names — EMPTY plus `targetsUnreadable` when the list is not literal.
    public let targets: [String]
    public let targetsUnreadable: Bool

    public init(name: String, targets: [String], targetsUnreadable: Bool = false) {
        self.name = name; self.targets = targets; self.targetsUnreadable = targetsUnreadable
    }
}

/// Every product a SwiftPM manifest declares. Same structured parse as `parsePackageTargets`, same
/// reason: the product name is the join key the `.xcodeproj` scoping resolves a
/// `XCSwiftPackageProductDependency` against, and a regex over `name:` matches targets first.
/// The products a manifest DECLARES — only the elements of `Package(products: [...])`.
///
/// Same split, same reason, as `parsePackageTargetDeclarations`: `parsePackageProducts` collects
/// `.library(…)` calls anywhere in the file, which is right for resolving a scan SCOPE (a stray one
/// either names a real product or resolves to nothing) and wrong for deciding what a package EXPOSES,
/// where a name alone is the whole answer. A `.library(…)` sitting in a dead hoisted `let` — SwiftPM
/// never validates an unused one — would otherwise read as an exposure and let a package claim a module
/// it does not publish.
///
/// The lesson was already learned here for targets and not carried across; this is that gap closed
/// rather than rediscovered. Returns nil when `products:` is present but not a literal array, and when
/// any element is not a plain declaration call — "cannot be read", which claims nothing.
public func parsePackageProductDeclarations(manifestSource: String) -> [PackageProduct]? {
    let tree = Parser.parse(source: manifestSource)
    let finder = DeclaredProductFinder()
    finder.walk(tree)
    return finder.sawLiteral ? finder.products : nil
}

private final class DeclaredProductFinder: SyntaxVisitor {
    var products: [PackageProduct] = []
    var sawLiteral = false
    private static let kinds: Set<String> = ["library", "executable", "plugin"]

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard DeclaredTargetFinder.isPackageCall(node) else { return .visitChildren }
        for arg in node.arguments where arg.label?.text == "products" {
            guard let array = arg.expression.as(ArrayExprSyntax.self) else { continue }
            for el in array.elements {
                guard let call = el.expression.as(FunctionCallExprSyntax.self),
                      let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                      member.base == nil
                        || member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Product",
                      Self.kinds.contains(member.declName.baseName.text)
                else { return .visitChildren }   // unreadable ⇒ sawLiteral stays false ⇒ nil
                let sub = ProductFinder()
                sub.walk(call)
                products += sub.products
            }
            sawLiteral = true
        }
        return .visitChildren
    }
}

public func parsePackageProducts(manifestSource: String) -> [PackageProduct] {
    let tree = Parser.parse(source: manifestSource)
    let finder = ProductFinder()
    finder.walk(tree)
    return finder.products
}

/// Are the `Package(products:targets:)` LISTS themselves fully readable — i.e. literal arrays whose
/// every element is a call the walkers above collect?
///
/// WHY THIS EXISTS. The walkers find `.library(…)`/`.target(…)` calls ANYWHERE in the file, so a
/// helper like WordPress's `XcodeSupport.products` still yields its literal members. But
/// `products: makeProducts()` — or an array holding a VARIABLE — hides entries entirely, and a
/// consumer that treats "not found among the parsed products" as "must be a remote product" turns a
/// hidden LOCAL product into a silently-narrowed scan. This is the checkable difference between
/// "absent from a complete list" (a sound negative) and "absent from a list I could not fully read"
/// (no answer at all). A missing argument counts as complete: an empty list is a real answer.
public func packageManifestListsAreComplete(manifestSource: String) -> (products: Bool, targets: Bool) {
    let tree = Parser.parse(source: manifestSource)
    let finder = PackageCallFinder()
    finder.walk(tree)
    return (finder.productsComplete, finder.targetsComplete)
}

private final class PackageCallFinder: SyntaxVisitor {
    var productsComplete = true
    var targetsComplete = true

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
              callee.baseName.text == "Package" else { return .visitChildren }
        for arg in node.arguments {
            let complete = Self.isLiteralCallArray(arg.expression)
            switch arg.label?.text {
            case "products": productsComplete = complete
            case "targets": targetsComplete = complete
            default: break
            }
        }
        return .visitChildren
    }

    /// A literal array whose elements are all direct calls (`.library(…)`, `.target(…)`) — anything
    /// else (a concatenation, a function call, an identifier element) can hide entries.
    static func isLiteralCallArray(_ expr: ExprSyntax) -> Bool {
        guard let arr = expr.as(ArrayExprSyntax.self) else { return false }
        return arr.elements.allSatisfy { $0.expression.as(FunctionCallExprSyntax.self) != nil }
    }
}

public enum TargetScopeError: Error, CustomStringConvertible, Equatable {
    case noManifest(dir: String)
    case noTargets(manifest: String)
    case unknownTarget(name: String, available: [String])
    case missingSourceDir(target: String, tried: [String])
    case unreadableDependencies(target: String)

    public var description: String {
        switch self {
        case .noManifest(let dir):
            return "--target needs a Package.swift to resolve against; none at \(dir)"
        case .noTargets(let m):
            return "no targets found in \(m) — --target cannot be resolved (is this a SwiftPM manifest?)"
        case .unknownTarget(let name, let available):
            return "no target named `\(name)`. This package declares: \(available.joined(separator: ", "))"
        case .unreadableDependencies(let target):
            return "target `\(target)`'s `dependencies:` is not a literal array (a hoisted variable, a "
                 + "concatenation, or a helper call), so its in-package dependencies cannot be read. "
                 + "Refusing to scan a closure that would silently omit them — inline the list, or scan "
                 + "without --target."
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
/// The LOCAL path dependencies a manifest declares: the `path:` of every `.package(path: …)` in
/// `Package(dependencies: [...])`, relative to the manifest's own directory.
///
/// A fourth hand-written manifest reader existed for this — a line regex in `main.swift`'s `--workspace`
/// path requiring `.package(` and `path:` on the SAME line, "the common monorepo form". The day this was
/// written, that assumption class had just cost ten silent under-reports elsewhere in the same file, so
/// it goes through the parser like everything else: multi-line declarations, comments, and string
/// literals are the parser's problem, not a convention's.
///
/// Returns nil when `dependencies:` is present but not a literal array — the same "cannot be read" that
/// `parsePackageTargetDeclarations` returns, and for the same reason: a caller must be able to tell it
/// apart from "declares none", because treating unreadable as empty is how a claim gets made on no
/// evidence.
public func parsePackageLocalDependencies(manifestSource: String) -> [String]? {
    let tree = Parser.parse(source: manifestSource)
    let finder = LocalDependencyFinder()
    finder.walk(tree)
    return finder.unreadable ? nil : finder.paths
}

private final class LocalDependencyFinder: SyntaxVisitor {
    var paths: [String] = []
    var unreadable = false

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard DeclaredTargetFinder.isPackageCall(node) else { return .visitChildren }
        for arg in node.arguments where arg.label?.text == "dependencies" {
            guard let array = arg.expression.as(ArrayExprSyntax.self) else { unreadable = true; continue }
            for el in array.elements {
                guard let call = el.expression.as(FunctionCallExprSyntax.self),
                      let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                      member.declName.baseName.text == "package"
                else { continue }   // `.package(url:)` and friends are not local; not unreadable
                for a in call.arguments where a.label?.text == "path" {
                    if let lit = TargetFinder.literal(a.expression) { paths.append(lit) }
                    else { unreadable = true }   // a computed path is not "no local dep"
                }
            }
        }
        return .visitChildren
    }
}

/// The targets a manifest DECLARES — only the elements of `Package(targets: [...])`.
///
/// Distinct from `parsePackageTargets`, and the distinction is load-bearing. That function collects
/// `.target(…)` calls ANYWHERE in the file, which is right for resolving a scan SCOPE: a stray one
/// either names a target that also appears properly (dedups harmlessly) or names nothing (resolves to
/// no sources). It is wrong for deciding module IDENTITY, where a name alone is the whole answer.
///
/// The input that forced this apart, measured on the built engine: a leftover
/// `let legacyDeps: [Target.Dependency] = [.target(name: "Analytics")]` that NOTHING references — SwiftPM
/// never validates an unused `let`, so the manifest builds — beside a stale `Sources/Analytics/`. The
/// dead reference read as a declaration, the stale directory gave it a source root, and a function
/// calling into the real remote Analytics SDK vanished from `functions` with no ledger entry and no
/// `invisible` hedge. One dead line, both disclosure channels off.
///
/// Returns nil when the `targets:` argument is not a literal array (a hoisted or computed list), so a
/// caller can tell "declares nothing" from "cannot be read here" — the second is what
/// `packageManifestListsAreComplete` exists to route to SwiftPM itself.
public func parsePackageTargetDeclarations(manifestSource: String) -> [PackageTarget]? {
    let tree = Parser.parse(source: manifestSource)
    let finder = DeclaredTargetFinder()
    finder.walk(tree)
    return finder.sawLiteralTargets ? finder.targets : nil
}

private final class DeclaredTargetFinder: SyntaxVisitor {
    var targets: [PackageTarget] = []
    var sawLiteralTargets = false

    init() { super.init(viewMode: .sourceAccurate) }

    /// `Package(…)` or `PackageDescription.Package(…)` — both are ordinary spellings, and matching only
    /// the bare one made a qualified manifest read as declaring nothing, so its own analyzed modules were
    /// named third-party blind spots.
    static func isPackageCall(_ node: FunctionCallExprSyntax) -> Bool {
        if let d = node.calledExpression.as(DeclReferenceExprSyntax.self) { return d.baseName.text == "Package" }
        if let m = node.calledExpression.as(MemberAccessExprSyntax.self) {
            return m.declName.baseName.text == "Package"
                && m.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "PackageDescription"
        }
        return false
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard Self.isPackageCall(node) else { return .visitChildren }
        for arg in node.arguments where arg.label?.text == "targets" {
            guard let array = arg.expression.as(ArrayExprSyntax.self) else { continue }
            // EVERY ELEMENT MUST *BE* A DECLARATION CALL. Sub-walking each element found `.target(…)`
            // anywhere inside it, so a ternary — `useMock ? .target(name: "Stripe") : .executableTarget(
            // name: "App")` — read BOTH branches as declarations, and the dead one claimed a module whose
            // stale directory then silenced a real SDK. An element that is not a plain declaration call
            // means the list cannot be read, which is exactly what `packageManifestListsAreComplete`
            // (sixty lines above) already says about the same array — the two now agree.
            for el in array.elements {
                guard let call = el.expression.as(FunctionCallExprSyntax.self),
                      let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                      // `.target(…)` and the qualified `Target.target(…)`, which is a real spelling.
                      member.base == nil
                        || member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Target",
                      TargetFinder.kinds.contains(member.declName.baseName.text)
                else { return .visitChildren }   // unreadable ⇒ sawLiteralTargets stays false ⇒ nil
                let sub = TargetFinder()
                sub.walk(call)
                targets += sub.targets
            }
            sawLiteralTargets = true
        }
        return .visitChildren
    }
}

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
        if t.dependenciesUnreadable { throw TargetScopeError.unreadableDependencies(target: t.name) }
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
        // `Source/` (singular) is one of SwiftPM's predefined source directories and a real layout
        // (Alamofire ships it). Omitting it made an ANALYZED local module read as a third-party blind
        // spot — a false disclosure — and for `--target` it would have meant refusing a package this
        // resolver can in fact resolve.
        var candidates = [(packageRoot as NSString).appendingPathComponent("\(base)/\(t.name)")]
        if !t.isTest { candidates.append((packageRoot as NSString).appendingPathComponent("Source/\(t.name)")) }
        candidates.append((packageRoot as NSString).appendingPathComponent(t.name))
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
    static let kinds: Set<String> = ["target", "executableTarget", "testTarget", "macro", "plugin"]

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              // `.target(…)` — and the QUALIFIED `Target.target(…)`, which is an ordinary spelling that
              // this guard used to reject. The rejection was safe for scope resolution (a package
              // written that way simply resolved nothing) and showed up as a FALSE DISCLOSURE in module
              // identity: the package's own analyzed modules were named third-party blind spots. Any
              // OTHER base is still refused — `Foo.target(…)` is not a target declaration.
              member.base == nil
                || member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Target",
              Self.kinds.contains(member.declName.baseName.text) else { return .visitChildren }
        let isTest = member.declName.baseName.text == "testTarget"
        let isPlugin = member.declName.baseName.text == "plugin"
        var name: String?, path: String?, deps: [String] = []
        var unreadableDeps = false
        var productDeps: [String] = []
        var unreadableProductDeps = false
        for arg in node.arguments {
            switch arg.label?.text {
            case "name": name = Self.literal(arg.expression)
            case "path": path = Self.literal(arg.expression)
            case "dependencies":
                // A `dependencies:` argument that EXISTS but is not a literal array must REFUSE, not
                // resolve to none. Two ordinary manifest idioms defeated the literal-only read —
                //     let coreDeps: [Target.Dependency] = ["Core"]
                //     .executableTarget(name: "App", dependencies: coreDeps)
                //     .executableTarget(name: "App", dependencies: ["Core"] + extra)
                // — and each produced `deps: []`, so `--target App` scanned App ALONE and reported it as
                // performing nothing while the truth was that it reaches Fs through Core. An empty
                // report is a purity claim over every function in the dropped targets, and the header's
                // promise that an excluded dep "stays disclosed by the coverage ledger" is false here:
                // a target that was never scanned leaves no ledger entry at all.
                guard let arr = arg.expression.as(ArrayExprSyntax.self) else {
                    unreadableDeps = true
                    break
                }
                for el in arr.elements {
                    if let s = Self.literal(el.expression) { deps.append(s); continue }
                    // `.target(name: "X")` and `.byName(name: "X")` are in-package references;
                    // `.product(name:package:)` is external to THIS package — excluded from the
                    // in-package closure as ever, but its NAME is recorded so the `.xcodeproj` scoping
                    // can resolve it against the repo's sibling local packages.
                    guard let call = el.expression.as(FunctionCallExprSyntax.self),
                          let m = call.calledExpression.as(MemberAccessExprSyntax.self) else { continue }
                    let kind = m.declName.baseName.text
                    if kind == "product" {
                        if let n = call.arguments.first(where: { $0.label?.text == "name" })
                            .flatMap({ Self.literal($0.expression) }) { productDeps.append(n) }
                        else { unreadableProductDeps = true }   // a product we cannot NAME cannot be
                                                                // proved absent from the local set
                        continue
                    }
                    guard ["target", "byName"].contains(kind) else { continue }
                    if let n = call.arguments.first(where: { $0.label?.text == "name" })
                        .flatMap({ Self.literal($0.expression) }) { deps.append(n) }
                }
            default: break
            }
        }
        if let n = name {
            targets.append(PackageTarget(name: n, dependencies: deps, path: path, isTest: isTest,
                                         isPlugin: isPlugin,
                                         dependenciesUnreadable: unreadableDeps,
                                         productDependencies: productDeps,
                                         productDependenciesUnreadable: unreadableProductDeps))
        }
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

/// The `products:` walk. `.library(name:targets:)` / `.executable(name:targets:)` /
/// `.plugin(name:targets:)`. A product whose `targets:` is not a literal array is kept with
/// `targetsUnreadable` — the consumer must refuse to resolve THROUGH it, but its NAME still proves the
/// product is local, which is the difference between a refusal and a silent remote-misclassification.
final class ProductFinder: SyntaxVisitor {
    var products: [PackageProduct] = []
    private static let kinds: Set<String> = ["library", "executable", "plugin"]

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.base == nil,
              Self.kinds.contains(member.declName.baseName.text) else { return .visitChildren }
        var name: String?
        var targets: [String] = []
        var sawTargets = false, unreadable = false
        for arg in node.arguments {
            switch arg.label?.text {
            case "name": name = TargetFinder.literal(arg.expression)
            case "targets":
                sawTargets = true
                guard let arr = arg.expression.as(ArrayExprSyntax.self) else { unreadable = true; break }
                for el in arr.elements {
                    if let s = TargetFinder.literal(el.expression) { targets.append(s) }
                    else { unreadable = true }
                }
            default: break
            }
        }
        if let n = name {
            products.append(PackageProduct(name: n, targets: targets,
                                           targetsUnreadable: unreadable || !sawTargets))
        }
        // `.library(…)` does not nest another product declaration; and NOT descending keeps a
        // `targets:` list's own strings from ever being re-read as anything else — the same
        // phantom-declaration hazard TargetFinder documents.
        return .skipChildren
    }
}
