import Foundation
import SwiftSyntax
import SwiftParser

// SOUNDNESS R1938 (type-identity lane L1) — module identity: which MODULE a file belongs to, and which modules it can SEE.
//
// This is infrastructure for the type-identity design (swift-type-identity-design/DESIGN.md §2.2, §2.4, §3). NOTHING in the engine's
// report-producing path calls it: the Driver feeds it only to the env-gated identity probe (`CANDOR_IDENT_PROBE`), whose output is
// stderr. It exists so the later lanes (a resolver that answers "which type does this spelling name from THIS file") can be built
// on a module answer that was measured against the engine's existing one (`swiftModuleOf`, the path segment after `Sources/`) over
// the pool BEFORE anything depends on it.
//
// WHY NOT `swiftModuleOf`. It is a path heuristic. A target with `path:` is mis-named (Kingfisher's single target becomes
// `Image`/`General`/`Utility`/`Views`), and `owningTarget` — the manifest answer — is nil for every file of GRDB, swift-format,
// Nimble and Quick. `moduleOf` here is the MANIFEST (or Xcode) target and says nil rather than guessing; the caller counts the nils.

/// The `MemberImportVisibility` upcoming feature (SE-0444), per target. With it ON a member (notably an EXTENSION member) is visible in
/// a file only if THAT FILE imports the module declaring it; with it OFF (the Swift 5 and 6 language modes' default) an extension
/// member is visible in every file of a module once SOME file of the module imports the declaring module.
public enum MemberImportVisibilitySetting: String, Equatable, Sendable {
    case enabled
    case disabled
    /// The manifest's `swiftSettings:` is not a literal the parser can read (a helper call, an unresolved name), or the target is
    /// not a SwiftPM one (an Xcode target's build settings are not read here). "Could not read" is not "off".
    case unreadable
}

/// What each target's `swiftSettings:` says about MemberImportVisibility, by target name. A target with no `swiftSettings:` is
/// `.disabled`. `.enableUpcomingFeature("MemberImportVisibility")`, `.enableExperimentalFeature(…)` and a `.unsafeFlags` list that
/// spells it all count as `.enabled`; a `swiftSettings:` naming a top-level `let` of the manifest is followed (to a bounded depth).
public func parsePackageMemberImportVisibility(manifestSource: String) -> [String: MemberImportVisibilitySetting] {
    let tree = Parser.parse(source: manifestSource)
    // top-level `let name = <expr>` / `var name: T = <expr>` bindings the manifest may spell `swiftSettings:` through
    var bindings: [String: ExprSyntax] = [:]
    for item in tree.statements {
        guard let v = item.item.as(VariableDeclSyntax.self) else { continue }
        for b in v.bindings {
            if let id = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text, let iv = b.initializer?.value { bindings[id] = iv }
        }
    }
    final class Finder: SyntaxVisitor {
        var out: [String: MemberImportVisibilitySetting] = [:]
        let bindings: [String: ExprSyntax]
        static let kinds: Set<String> = ["target", "executableTarget", "testTarget", "macro", "plugin"]
        init(_ b: [String: ExprSyntax]) { bindings = b; super.init(viewMode: .sourceAccurate) }
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                  member.base == nil || member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Target",
                  Self.kinds.contains(member.declName.baseName.text) else { return .visitChildren }
            var name: String? = nil
            var setting: MemberImportVisibilitySetting = .disabled
            for arg in node.arguments {
                switch arg.label?.text {
                case "name":
                    if let lit = arg.expression.as(StringLiteralExprSyntax.self), lit.segments.count == 1,
                       let seg = lit.segments.first?.as(StringSegmentSyntax.self) { name = seg.content.text }
                case "swiftSettings":
                    var found = false, unreadable = false
                    collect(Syntax(arg.expression), 0, &found, &unreadable)
                    setting = found ? .enabled : (unreadable ? .unreadable : .disabled)
                default: break
                }
            }
            if let n = name { out[n] = setting }
            return .skipChildren
        }
        /// Walk a settings expression: a string literal spelling the feature is a hit; a member-access's `declName` is a setting
        /// constructor (`.define`, `.enableUpcomingFeature`) and is NOT a name to resolve; an unqualified identifier is a reference
        /// to a manifest binding, followed if the manifest has one, `unreadable` otherwise; `#if` conditions are not expressions.
        func collect(_ n: Syntax, _ depth: Int, _ found: inout Bool, _ unreadable: inout Bool) {
            if let lit = n.as(StringLiteralExprSyntax.self) {
                for seg in lit.segments {
                    if let s = seg.as(StringSegmentSyntax.self), s.content.text == "MemberImportVisibility" { found = true }
                }
                return
            }
            if let m = n.as(MemberAccessExprSyntax.self) { if let b = m.base { collect(Syntax(b), depth, &found, &unreadable) }; return }
            if let d = n.as(DeclReferenceExprSyntax.self) {
                let id = d.baseName.text
                if let b = bindings[id], depth < 4 { collect(Syntax(b), depth + 1, &found, &unreadable) } else { unreadable = true }
                return
            }
            if let c = n.as(IfConfigClauseSyntax.self) { if let e = c.elements { collect(Syntax(e), depth, &found, &unreadable) }; return }
            for ch in n.children(viewMode: .sourceAccurate) { collect(ch, depth, &found, &unreadable) }
        }
    }
    let f = Finder(bindings)
    f.walk(tree)
    return f.out
}

/// The modules a parsed Swift file RE-EXPORTS (`@_exported import M`), every `#if` arm included. The text-taking
/// `reexportedModules(source:)` is this over a fresh parse.
public func reexportedModules(in tree: SourceFileSyntax) -> Set<String> {
    final class V: SyntaxVisitor {
        var out: Set<String> = []
        init() { super.init(viewMode: .sourceAccurate) }
        override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
            let exported = node.attributes.contains {
                $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "_exported"
            }
            if exported, let m = node.path.first?.name.text { out.insert(m) }
            return .skipChildren
        }
    }
    let v = V()
    v.walk(tree)
    return v.out
}

/// The answers, computed once from the facts a scan already holds. Immutable; every query is a lookup.
public struct ModuleIdentityIndex: Sendable {
    /// rel file -> its manifest (or unique Xcode) target. A file absent here is UNATTRIBUTED, and the index says so rather than guess.
    public let moduleOfFile: [String: String]
    /// rel file -> the modules it imports (an import's first path segment).
    public let importsByFile: [String: [String]]
    /// rel file -> the modules it `@_exported import`s.
    public let exportedByFile: [String: Set<String>]
    /// A DEPENDENCY module -> the modules its sources `@_exported import` (the engine's `deps.moduleReexports`).
    public let dependencyReexports: [String: Set<String>]
    /// own target -> its MemberImportVisibility setting.
    public let memberImportVisibility: [String: MemberImportVisibilitySetting]

    private let filesByModule: [String: [String]]
    private let directExports: [String: Set<String>]

    public init(moduleOfFile: [String: String], importsByFile: [String: [String]], exportedByFile: [String: Set<String>],
                dependencyReexports: [String: Set<String>] = [:], memberImportVisibility: [String: MemberImportVisibilitySetting] = [:]) {
        self.moduleOfFile = moduleOfFile; self.importsByFile = importsByFile; self.exportedByFile = exportedByFile
        self.dependencyReexports = dependencyReexports; self.memberImportVisibility = memberImportVisibility
        var byModule: [String: [String]] = [:]
        for (f, m) in moduleOfFile { byModule[m, default: []].append(f) }
        for k in byModule.keys { byModule[k]?.sort() }
        filesByModule = byModule
        var direct: [String: Set<String>] = [:]
        for (m, fs) in byModule { for f in fs { direct[m, default: []].formUnion(exportedByFile[f] ?? []) } }
        directExports = direct
    }

    /// Every module of the scan (a manifest or Xcode target that owns a file).
    public var ownModules: Set<String> { Set(filesByModule.keys) }
    public func files(ofModule m: String) -> [String] { filesByModule[m] ?? [] }

    /// The file's module, or nil when no manifest or Xcode target claims it (the attribution gap).
    public func moduleOf(_ file: String) -> String? { moduleOfFile[file] }

    /// `seed` and every module reachable from it through `@_exported import`, following own targets by THEIR files and dependency
    /// modules by `dependencyReexports`. Terminates on a cycle.
    private func reexportClosure(_ seed: Set<String>) -> Set<String> {
        var out: Set<String> = [], queue = Array(seed)
        while let x = queue.popLast() {
            guard out.insert(x).inserted else { continue }
            queue.append(contentsOf: directExports[x] ?? [])
            queue.append(contentsOf: dependencyReexports[x] ?? [])
        }
        return out
    }

    /// What module `m` re-exports to every importer, MODULE-WIDE: an `@_exported import X` in ANY file of `m` makes X visible in every
    /// file of `m` (swift-http-types' `HTTPTypesFoundation` and SwiftLint's `SwiftLintBuiltInRules` compile only because of this).
    public func exportedClosure(ofModule m: String) -> Set<String> { reexportClosure(directExports[m] ?? []) }

    /// `{module} ∪ imports(file) ∪ exportedClosure(module)`, closed under re-export. With no attributed module the module term is
    /// absent and only the file's own imports (and what they re-export) count — the caller decides what an unattributed file sees.
    public func visibleModules(inFile f: String) -> Set<String> {
        var seed = Set(importsByFile[f] ?? [])
        if let m = moduleOf(f) { seed.insert(m); seed.formUnion(directExports[m] ?? []) }
        return reexportClosure(seed)
    }

    /// The union of `visibleModules` over the module's files: the closure an EXTENSION member of a dependency type is looked up in
    /// (DESIGN §3, Revision 1 edit 3), because without MemberImportVisibility a member is visible target-wide.
    public func targetVisibleModules(ofModule m: String) -> Set<String> {
        var out: Set<String> = [m]
        for f in filesByModule[m] ?? [] { out.formUnion(visibleModules(inFile: f)) }
        return out
    }

    public func memberImportVisibility(ofFile f: String) -> MemberImportVisibilitySetting {
        guard let m = moduleOf(f) else { return .unreadable }
        return memberImportVisibility[m] ?? .unreadable
    }

    /// The modules an extension MEMBER may come from when called in file `f`: the file's own set under MemberImportVisibility, else
    /// the target-wide set. `.unreadable` takes the WIDER answer (target-wide): a lookup that errs wide is a disclosure, not a drop.
    public func memberLookupModules(inFile f: String) -> Set<String> {
        guard let m = moduleOf(f) else { return visibleModules(inFile: f) }
        return memberImportVisibility(ofFile: f) == .enabled ? visibleModules(inFile: f) : targetVisibleModules(ofModule: m)
    }
}
