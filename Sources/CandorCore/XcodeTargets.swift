import Foundation
import SwiftParser
import SwiftSyntax

// PER-TARGET SCAN SCOPING FOR XCODE PROJECTS — the `.xcodeproj` half of `--target`.
//
// WHY, from two measured findings. `--target` resolved only against a `Package.swift`, and the audience
// the privacy-manifest verb is being promoted to — iOS developers — overwhelmingly does not have one.
// On every `.xcodeproj` repo the flag errored, so the scan stayed whole-repo, and a whole-repo scan
// charges each shipped product with every OTHER product's effects. Measured, both reproducible:
//
//   · NetNewsWire's iOS plist was charged NSAppleEventsUsageDescription from Mac-only code
//     (`SendToMarsEditCommand` lives in `Shared/` but is membership-EXCLUDED from the iOS target);
//     the Mac plist verified clean because the key is there. Exit 1 against a shipping app.
//   · Focus's plist was charged Speech reached from firefox's QuickAnswers code — a different
//     product in a different `.xcodeproj` of the same repository.
//
// A first-run user cannot tell that finding from a real one, which is precisely the confident wrong
// answer the verify exists to remove.
//
// WHY A HAND-WRITTEN PARSER AND NOT `plutil`. `project.pbxproj` is an OpenStep property list, and
// `plutil -convert json` parses it — on macOS. CI runs the Linux leg, where plutil does not exist (the
// sibling BuildSettings evaluator's own history includes a plutil differential that ran on Linux and
// compared against the wrong plutil), and a scoping that silently degrades per-platform would give the
// same repo two different verdicts. The evaluator in BuildSettings.swift already owns the lexical half
// of this format — `stripCommentsPreservingStrings` — so the parser below reuses it and adds only the
// structural walk. One lexer for one format; two was a measured defect there (flip #15).
//
// THE SOUNDNESS DIRECTION, same contract as PackageTargets.swift: this feature makes a scan see LESS,
// and under ⟨0.21⟩ absence from `functions` is a positive purity claim. So every way of resolving too
// little REFUSES rather than falls back:
//
//   · an unparseable pbxproj                       -> error naming the file (never "scan everything")
//   · an unknown target name                       -> error listing the targets the project defines
//   · a build-file entry whose reference is gone   -> error naming the id (it could be a Swift source)
//   · a `.swift` reference whose path cannot be resolved through the group tree -> error naming it
//   · a synchronized folder that is absent on disk -> error naming the folder
//
// LOCAL Swift package products ARE resolved into the closure. This was a stated boundary first, and
// the measurement killed it: IceCubesApp's app target is a thin shell over `Packages/*`, so scoping to
// it analyzed `[Notify]` while the app's real Camera/Photos reach sat in the disclosed-uncovered
// channel beside a green tick — a conditionality line of prose does not carry that weight, and a thin
// shell over local packages is the MODERN layout, not an edge case. A `packageProductDependencies`
// entry resolves: its `XCLocalSwiftPackageReference` (or, the commoner drag-in spelling, a product
// NAME with no package ref, matched against every local package the project references) → that
// package's `Package.swift` via the SAME parser the SPM path uses → the product's targets → their
// in-package closure → their source dirs — and `.product(…)` dependencies BETWEEN local packages
// resolve transitively through the same index. A local product that cannot be resolved soundly
// REFUSES; it never quietly narrows the scan.
//
// What stays DELIBERATELY outside the closure, disclosed rather than resolved:
//   · REMOTE package products (`XCRemoteSwiftPackageReference`, or a bare product name no local
//     package declares) — their sources are not in this tree. Calls into them stay DISCLOSED by the
//     κ coverage ledger (the verify goes CONDITIONAL), never silently pure; the count is reported.
//   · cross-project target dependencies (a `PBXContainerItemProxy` whose container is another
//     `.xcodeproj`) — same reasoning, same disclosure channel.

public enum XcodeScopeError: Error, CustomStringConvertible {
    case unparseable(file: String, reason: String)
    case malformed(file: String, what: String)
    case unknownTarget(name: String, available: [XcodeTargetInfo])
    case unresolvableSource(target: String, what: String)
    case missingSyncFolder(target: String, folder: String)
    case unresolvableLocalProduct(product: String, why: String)

    public var description: String {
        switch self {
        case .unparseable(let f, let r):
            return "could not parse \(f): \(r). Refusing to scope by guesswork — scan without --target "
                 + "verifies the whole repo (over-attribution, never silence)."
        case .malformed(let f, let w):
            return "\(f) parsed but is not a pbxproj this reader understands (\(w)). Refusing to scope "
                 + "by guesswork — scan without --target instead."
        case .unknownTarget(let name, let available):
            // The user who mistypes needs the VOCABULARY, and shipped-product targets first: the
            // question this feature answers is about a shipped binary, so applications and extensions
            // lead the list and test bundles trail it, each with its kind so nobody scopes to
            // "MyAppTests" thinking it is the app.
            let list = available.map { "    \($0.name)  (\($0.kindLabel))" }.joined(separator: "\n")
            return "no target named `\(name)`. This project declares:\n\(list)"
        case .unresolvableSource(let t, let w):
            return "target `\(t)`'s source list could not be fully resolved: \(w). Refusing to scan a "
                 + "partial target — a file silently dropped here would read as analyzed-and-pure."
        case .missingSyncFolder(let t, let f):
            return "target `\(t)` synchronizes the folder \(f), which is absent or unreadable. Refusing "
                 + "to scan a partial target — scan without --target instead."
        case .unresolvableLocalProduct(let p, let why):
            // A local product this cannot resolve is exactly the IceCubes shape: the app's real reach
            // lives THERE, and a scan that proceeds without it reads as a successful scoping while
            // answering about a shell. Refuse, name it, and leave the whole-repo scan as the sound path.
            return "the target depends on the local Swift package product `\(p)`, which --target could "
                 + "not resolve to sources (\(why)). Refusing to scan a scope that silently omits it — "
                 + "scan without --target to verify the whole repo."
        }
    }
}

/// One declared target, as the unknown-name listing and the caller's disclosures need it.
public struct XcodeTargetInfo: Equatable, Sendable {
    public let name: String
    /// `com.apple.product-type.application` etc.; nil when the target does not declare one.
    public let productType: String?

    public init(name: String, productType: String?) {
        self.name = name; self.productType = productType
    }
    public var isTest: Bool { (productType ?? "").contains("test") }
    /// The short kind for human output: "application", "app-extension", "unit-test", …
    public var kindLabel: String {
        guard let p = productType else { return "no product type" }
        return p.hasPrefix("com.apple.product-type.") ? String(p.dropFirst("com.apple.product-type.".count))
                                                      : p
    }
    /// Shipped-product ordering: applications, then extensions, then everything else, tests last.
    public var listRank: Int {
        let k = kindLabel
        if k == "application" || k.hasPrefix("application.") { return 0 }
        if k.contains("extension") { return 1 }
        if isTest { return 3 }
        return 2
    }
}

/// The filesystem the resolution reads THROUGH — injected, exactly as `targetSourceDirs` injects
/// `exists`, so every branch is unit-testable against a dictionary instead of a disk.
public struct XcodeScopeFS {
    /// Every `.swift` file under a directory (recursive), or nil when it is absent/unreadable.
    public let swiftFilesUnder: (String) -> [String]?
    /// A file's contents (the resolver only ever asks for `Package.swift`), or nil when absent.
    public let readFile: (String) -> String?
    /// The immediate subdirectories of a directory (absolute paths); empty when absent.
    public let subdirectories: (String) -> [String]
    /// Directory existence — what `targetSourceDirs` needs for the SwiftPM convention probe.
    public let directoryExists: (String) -> Bool
    /// `swift package dump-package --package-path <dir>` as JSON text, or nil when unavailable — the
    /// FALLBACK for a package whose manifest builds its targets programmatically (WordPress constructs
    /// its Xcode-shim targets through a helper function over hoisted arrays, which no structural parse
    /// can read without becoming an interpreter). SwiftPM itself is the one sound authority for that
    /// shape. Injected so CandorCore never spawns a process and tests never need a toolchain.
    public let dumpPackage: (String) -> String?

    public init(swiftFilesUnder: @escaping (String) -> [String]?,
                readFile: @escaping (String) -> String?,
                subdirectories: @escaping (String) -> [String],
                directoryExists: @escaping (String) -> Bool,
                dumpPackage: @escaping (String) -> String? = { _ in nil }) {
        self.swiftFilesUnder = swiftFilesUnder
        self.readFile = readFile
        self.subdirectories = subdirectories
        self.directoryExists = directoryExists
        self.dumpPackage = dumpPackage
    }
}

/// The resolved scope of one Xcode target: which targets ended up in the closure and which `.swift`
/// files they compile, plus the boundary the closure deliberately does not cross.
public struct XcodeTargetScope {
    public let target: XcodeTargetInfo
    /// Every target in the in-project dependency closure, the selected one included, sorted.
    public let closure: [XcodeTargetInfo]
    /// Absolute, standardized `.swift` paths the closure compiles.
    public let files: Set<String>
    /// LOCAL Swift packages resolved INTO the closure (directory basenames, sorted, deduped): the
    /// IceCubes shape — a thin app shell whose real code is `Packages/*` — is scoped correctly only
    /// because these are in.
    public let localPackages: [String]
    /// REMOTE package products the closure depends on — not in this tree, κ-disclosed, never silent.
    public let remoteProductCount: Int
    /// Dependencies living in other `.xcodeproj`s — NOT resolved, κ-disclosed.
    public let crossProjectDependencyCount: Int
    /// Local packages whose manifest had to be read via `swift package dump-package` because it
    /// builds targets programmatically — disclosed, since it means manifest code was executed.
    public let packagesReadViaDump: [String]
    /// The `os(…)` family this target builds for (`iOS`, `macOS`, …), when its build settings say so —
    /// nil when they don't, in which case NO platform pruning happened.
    public let platform: String?
    /// Files dropped because every top-level declaration sits inside `#if os(…)` clauses provably
    /// FALSE for `platform` — they compile to NOTHING in this target's build.
    public let platformExcludedCount: Int
    /// ⟨scope travels⟩ The `.entitlements` file THIS target signs with, from `CODE_SIGN_ENTITLEMENTS`
    /// — absolute, and only when it EXISTS. nil when the settings name none, or name one this cannot
    /// resolve: the consumer then keeps the discovery it had, so nil is never worse than before.
    public let entitlements: String?
}

// MARK: - the OpenStep value parser

/// A parsed OpenStep plist value. pbxproj needs exactly three shapes: `{ k = v; … }`, `( v, … )`,
/// and strings (quoted or bare).
public indirect enum PbxValue {
    case string(String)
    case array([PbxValue])
    case dict([String: PbxValue])

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var array: [PbxValue]? { if case .array(let a) = self { return a }; return nil }
    public var dict: [String: PbxValue]? { if case .dict(let d) = self { return d }; return nil }
}

/// Parse an OpenStep plist document (the pbxproj format) into a `PbxValue`.
///
/// Comments are removed FIRST, by the same quote-aware single pass the build-settings evaluator uses —
/// pbxproj is littered with `/* display name */` annotations, including inside arrays and between a key
/// and its value, and a second, disagreeing comment scanner is how flip #15 happened in the sibling
/// file. Throws (never guesses) on anything structurally unexpected: a truncated file, an unterminated
/// string, a missing `;`. The caller turns that into a refusal that names the file.
public func parseOpenStepPlist(_ raw: String) throws -> PbxValue {
    var p = OpenStepParser(Array(stripCommentsPreservingStrings(raw)))
    let v = try p.parseValue()
    try p.expectEndOfDocument()
    return v
}

private struct OpenStepParser {
    let chars: [Character]
    var i = 0
    init(_ c: [Character]) { chars = c }

    struct Err: Error { let why: String }

    mutating func skipWS() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

    mutating func expectEndOfDocument() throws {
        skipWS()
        guard i == chars.count else { throw Err(why: "trailing content at offset \(i)") }
    }

    mutating func parseValue() throws -> PbxValue {
        skipWS()
        guard i < chars.count else { throw Err(why: "unexpected end of file (expected a value)") }
        switch chars[i] {
        case "{": return try parseDict()
        case "(": return try parseArray()
        default:  return .string(try parseString())
        }
    }

    mutating func parseDict() throws -> PbxValue {
        i += 1  // consume {
        var out: [String: PbxValue] = [:]
        while true {
            skipWS()
            guard i < chars.count else { throw Err(why: "unterminated dictionary") }
            if chars[i] == "}" { i += 1; return .dict(out) }
            let key = try parseString()
            skipWS()
            guard i < chars.count, chars[i] == "=" else {
                throw Err(why: "expected `=` after key `\(key)`")
            }
            i += 1
            let value = try parseValue()
            skipWS()
            guard i < chars.count, chars[i] == ";" else {
                throw Err(why: "expected `;` after the value of `\(key)`")
            }
            i += 1
            // Last-one-wins on a duplicate key, like every plist reader; pbxproj ids are UUID-unique
            // in practice and a duplicate would collide in Xcode itself.
            out[key] = value
        }
    }

    mutating func parseArray() throws -> PbxValue {
        i += 1  // consume (
        var out: [PbxValue] = []
        while true {
            skipWS()
            guard i < chars.count else { throw Err(why: "unterminated array") }
            if chars[i] == ")" { i += 1; return .array(out) }
            out.append(try parseValue())
            skipWS()
            guard i < chars.count else { throw Err(why: "unterminated array") }
            if chars[i] == "," { i += 1; continue }
            guard chars[i] == ")" else { throw Err(why: "expected `,` or `)` in array") }
        }
    }

    mutating func parseString() throws -> String {
        skipWS()
        guard i < chars.count else { throw Err(why: "unexpected end of file (expected a string)") }
        if chars[i] == "\"" {
            i += 1
            var s = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count {
                    // The escapes Xcode writes. An unknown escape keeps its character rather than
                    // failing the whole file over a corner of a shellScript nobody is scoping by.
                    let n = chars[i + 1]
                    switch n {
                    case "n": s.append("\n")
                    case "t": s.append("\t")
                    case "r": s.append("\r")
                    default:  s.append(n)
                    }
                    i += 2; continue
                }
                if c == "\"" { i += 1; return s }
                s.append(c); i += 1
            }
            throw Err(why: "unterminated string literal")
        }
        // A bare token: everything up to a structural delimiter. `/` is legal inside one (paths are
        // written bare when they contain no specials) — the comment forms are already stripped.
        var s = ""
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || ";,=(){}\"".contains(c) { break }
            s.append(c); i += 1
        }
        guard !s.isEmpty else {
            let found = i < chars.count ? "`\(chars[i])`" : "end of file"
            throw Err(why: "expected a value at offset \(i), found \(found)")
        }
        return s
    }
}

// MARK: - the pbxproj object model

/// A parsed `project.pbxproj`: the object table plus the ids the walk starts from.
public struct PbxprojModel {
    public let objects: [String: [String: PbxValue]]
    public let rootObject: String
    /// The path this model was parsed from — refusals name it.
    public let file: String

    func obj(_ id: String) -> [String: PbxValue]? { objects[id] }
    func isa(_ id: String) -> String? { objects[id]?["isa"]?.string }
}

public func parsePbxproj(text: String, file: String) throws -> PbxprojModel {
    let root: PbxValue
    do { root = try parseOpenStepPlist(text) }
    catch let e as OpenStepParser.Err { throw XcodeScopeError.unparseable(file: file, reason: e.why) }
    guard let top = root.dict,
          let objectsV = top["objects"]?.dict,
          let rootId = top["rootObject"]?.string else {
        throw XcodeScopeError.malformed(file: file, what: "no `objects` table or no `rootObject`")
    }
    var objects: [String: [String: PbxValue]] = [:]
    objects.reserveCapacity(objectsV.count)
    for (id, v) in objectsV {
        guard let d = v.dict else { continue }   // a non-dict object is nothing the walk can reach
        objects[id] = d
    }
    return PbxprojModel(objects: objects, rootObject: rootId, file: file)
}

/// Every native target the project declares, in shipped-product-first order (see `listRank`) — the
/// vocabulary the unknown-name refusal prints, and the menu the caller matches a `--target` against.
public func pbxprojTargets(_ model: PbxprojModel) -> [XcodeTargetInfo] {
    guard let project = model.obj(model.rootObject),
          let targetIds = project["targets"]?.array else { return [] }
    var out: [XcodeTargetInfo] = []
    for tid in targetIds.compactMap(\.string) {
        guard let t = model.obj(tid), let isa = t["isa"]?.string,
              isa == "PBXNativeTarget" || isa == "PBXAggregateTarget",
              let name = t["name"]?.string else { continue }
        out.append(XcodeTargetInfo(name: name, productType: t["productType"]?.string))
    }
    return out.sorted { ($0.listRank, $0.name) < ($1.listRank, $1.name) }
}

// MARK: - resolving one target to its Swift file list

/// Resolve `targetName` in a parsed project to the `.swift` files its in-project dependency closure
/// compiles.
///
/// `projectDir` is the directory CONTAINING the `.xcodeproj` (group paths and SOURCE_ROOT are relative
/// to it, adjusted by `projectDirPath` when the project declares one). `fs` is injected so the
/// resolution is unit-testable without a filesystem, exactly as `targetSourceDirs` injects `exists`.
public func xcodeTargetScope(model: PbxprojModel, projectDir: String, targetName: String,
                             fs: XcodeScopeFS) throws -> XcodeTargetScope {
    let swiftFilesUnder = fs.swiftFilesUnder
    let all = pbxprojTargets(model)
    guard let project = model.obj(model.rootObject), let targetIds = project["targets"]?.array else {
        throw XcodeScopeError.malformed(file: model.file, what: "rootObject has no `targets`")
    }
    var idByName: [String: String] = [:]
    for tid in targetIds.compactMap(\.string) {
        if let n = model.obj(tid)?["name"]?.string { idByName[n] = tid }
    }
    // EXACT match only. `NetNewsWire` and `NetNewsWire-iOS` differ by a suffix; anything fuzzy would
    // resolve a typo to a neighbouring product and answer confidently about the wrong binary — the
    // exact failure this feature removes. A miss lists the real names instead.
    guard let rootTid = idByName[targetName] else {
        throw XcodeScopeError.unknownTarget(name: targetName, available: all)
    }

    // The project root, honouring `projectDirPath` (rarely non-empty; "" is the norm).
    var rootDir = projectDir
    if let pd = project["projectDirPath"]?.string, !pd.isEmpty {
        rootDir = (rootDir as NSString).appendingPathComponent(pd)
    }
    // `URL(fileURLWithPath:).path`, NOT `.standardized.path`: on a URL built from a RELATIVE path,
    // `.standardized` collapses `..` and then DROPS the cwd base — measured, `./Proj/../Sources`
    // became `/Sources`, which refused WordPress's (real, existing) synchronized folder with a path on
    // nobody's disk. `.path` both absolutizes against cwd and collapses `..` correctly.
    func std(_ p: String) -> String { URL(fileURLWithPath: p).path }

    // ── the group tree ────────────────────────────────────────────────────────────────────────────
    // Paths are group-relative: each reference resolves against its PARENT group's directory, and a
    // group may itself be `<group>`-relative, SOURCE_ROOT-relative or absolute. Parents are found by
    // walking `children` from the main group — pbxproj stores no back-pointers.
    var parentOf: [String: String] = [:]
    if let mainGroup = project["mainGroup"]?.string {
        var stack = [mainGroup]
        var seen = Set<String>()
        while let gid = stack.popLast() {
            guard seen.insert(gid).inserted else { continue }
            for cid in (model.obj(gid)?["children"]?.array ?? []).compactMap(\.string) {
                parentOf[cid] = gid
                stack.append(cid)
            }
        }
    }
    /// The directory a group/reference's OWN path lands in, or nil when it cannot be resolved to a
    /// repo location (a BUILT_PRODUCTS_DIR/SDKROOT tree — build output, not repo sources).
    var dirMemo: [String: String?] = [:]
    func resolvedPath(_ id: String) -> String? {
        if let m = dirMemo[id] { return m }
        let r = resolveUncached(id)
        dirMemo[id] = r
        return r
    }
    func resolveUncached(_ id: String) -> String? {
        guard let o = model.obj(id) else { return nil }
        let path = o["path"]?.string
        let tree = o["sourceTree"]?.string ?? "<group>"
        switch tree {
        case "<absolute>":
            return path.map(std)
        case "SOURCE_ROOT":
            return std((rootDir as NSString).appendingPathComponent(path ?? ""))
        case "<group>":
            let base: String
            if let pid = parentOf[id], let pdir = resolvedPath(pid) { base = pdir }
            else if parentOf[id] == nil { base = rootDir }   // the main group itself
            else { return nil }                              // parent unresolvable ⇒ so is this
            guard let p = path, !p.isEmpty else { return base }
            return std((base as NSString).appendingPathComponent(p))
        default:
            // BUILT_PRODUCTS_DIR, SDKROOT, DEVELOPER_DIR: derived locations. Nothing there is a repo
            // source the unscoped scan could have seen either, so nil is not a loss channel.
            return nil
        }
    }
    /// True when `id` lives under a DERIVED root (build products, the SDK): a `.swift` there is
    /// generated at build time — WordPress's `Secrets.swift` is `BUILT_PRODUCTS_DIR`-relative — and
    /// does not exist in the repo tree, so SKIPPING it drops nothing the unscoped scan had. The
    /// distinction matters because the same nil from `resolvedPath` otherwise means a BROKEN group
    /// chain, and that one must refuse: the file is somewhere in the repo and about to be dropped.
    func isDerivedLocation(_ id: String) -> Bool {
        guard let o = model.obj(id) else { return false }
        switch o["sourceTree"]?.string ?? "<group>" {
        case "<group>":
            return parentOf[id].map(isDerivedLocation) ?? false
        case "<absolute>", "SOURCE_ROOT":
            return false
        default:
            return true
        }
    }

    // ── the in-project dependency closure ─────────────────────────────────────────────────────────
    // Mirrors `targetClosure` for SPM: an app's shared code commonly lives in a framework TARGET the
    // app depends on, and scoping to the app alone would drop it — the miss-shaped mirror of the
    // over-attribution being fixed. Cross-project proxies and package products stay out (κ-disclosed).
    var closureIds: [String] = []
    var crossProject = 0
    /// (product name, the `package` ref id when the dependency carries one). Drag-in local packages —
    /// the common spelling in every corpus app — carry NO ref; the name is the whole join key.
    var productDeps: [(name: String, refId: String?)] = []
    var stack = [rootTid]
    var seenT = Set<String>()
    while let tid = stack.popLast() {
        guard seenT.insert(tid).inserted, let t = model.obj(tid) else { continue }
        closureIds.append(tid)
        for pid in (t["packageProductDependencies"]?.array ?? []).compactMap(\.string) {
            guard let p = model.obj(pid), let pname = p["productName"]?.string else { continue }
            productDeps.append((pname, p["package"]?.string))
        }
        for did in (t["dependencies"]?.array ?? []).compactMap(\.string) {
            guard let dep = model.obj(did) else { continue }
            if let dt = dep["target"]?.string, model.obj(dt) != nil { stack.append(dt); continue }
            if let proxyId = dep["targetProxy"]?.string, let proxy = model.obj(proxyId) {
                // Same-project proxy: the container IS this project's root object. Anything else
                // points into another .xcodeproj — counted and disclosed, not resolved.
                if proxy["containerPortal"]?.string == model.rootObject,
                   let remote = proxy["remoteGlobalIDString"]?.string, model.obj(remote) != nil {
                    stack.append(remote)
                } else {
                    crossProject += 1
                }
            }
        }
    }

    // ── each closure member's compiled Swift files ────────────────────────────────────────────────
    var files = Set<String>()
    for tid in closureIds {
        guard let t = model.obj(tid), let tname = t["name"]?.string else { continue }

        // (a) the classic explicit list: Sources phase -> PBXBuildFile -> PBXFileReference.
        for phaseId in (t["buildPhases"]?.array ?? []).compactMap(\.string) {
            guard model.isa(phaseId) == "PBXSourcesBuildPhase" else { continue }
            for bfId in (model.obj(phaseId)?["files"]?.array ?? []).compactMap(\.string) {
                // A dangling build file COULD name a Swift source; proving it doesn't is impossible
                // with the reference gone, so this refuses rather than shrugging it off.
                guard let bf = model.obj(bfId), let refId = bf["fileRef"]?.string else {
                    throw XcodeScopeError.unresolvableSource(
                        target: tname, what: "build file \(bfId) has no resolvable fileRef")
                }
                guard let ref = model.obj(refId) else {
                    throw XcodeScopeError.unresolvableSource(
                        target: tname, what: "fileRef \(refId) names no object")
                }
                let isa = ref["isa"]?.string ?? "?"
                switch isa {
                case "PBXFileReference":
                    let leaf = ref["path"]?.string ?? ""
                    guard leaf.hasSuffix(".swift") else { continue }   // .m/.metal/.intentdefinition…
                    guard let p = resolvedPath(refId) else {
                        if isDerivedLocation(refId) { continue }   // build-generated; not in the repo
                        throw XcodeScopeError.unresolvableSource(
                            target: tname,
                            what: "`\(leaf)` (\(refId)) has no resolvable location — its group chain "
                                + "does not reach the main group")
                    }
                    files.insert(p)
                case "PBXVariantGroup", "XCVersionGroup":
                    // Localized files / versioned Core Data models: compiled as a unit. A Swift child
                    // (rare but legal for variant groups) must resolve; the usual .xcdatamodel/.strings
                    // children are not scan inputs.
                    for cid in (ref["children"]?.array ?? []).compactMap(\.string) {
                        guard let c = model.obj(cid), (c["path"]?.string ?? "").hasSuffix(".swift") else { continue }
                        guard let p = resolvedPath(cid) else {
                            throw XcodeScopeError.unresolvableSource(
                                target: tname, what: "variant-group member \(cid) has no resolvable location")
                        }
                        files.insert(p)
                    }
                default:
                    // e.g. PBXReferenceProxy — a product BUILT by another project (a .framework), never
                    // a `.swift` the scan could read. Nothing to lose by skipping: the unscoped scan
                    // cannot see inside it either; the cross-project count above already disclosed it.
                    continue
                }
            }
        }

        // (b) Xcode 16 synchronized folders: membership is THE FILESYSTEM, minus per-target exceptions.
        // Five of the seven corpus apps use this form — NetNewsWire's Mac-only Apple-event code is
        // excluded from the iOS target exactly here, so getting exceptions wrong in either direction
        // is either the false finding kept or real reach dropped.
        for gid in (t["fileSystemSynchronizedGroups"]?.array ?? []).compactMap(\.string) {
            guard let g = model.obj(gid) else {
                throw XcodeScopeError.unresolvableSource(target: tname, what: "synchronized group \(gid) names no object")
            }
            guard let dir = resolvedPath(gid) else {
                throw XcodeScopeError.unresolvableSource(
                    target: tname, what: "synchronized group \(g["path"]?.string ?? gid) has no resolvable location")
            }
            guard let everything = swiftFilesUnder(dir) else {
                throw XcodeScopeError.missingSyncFolder(target: tname, folder: dir)
            }
            // This target's OWN exceptions on the folder it owns: those files are NOT members.
            var excluded = Set<String>()
            for exId in (g["exceptions"]?.array ?? []).compactMap(\.string) {
                guard let ex = model.obj(exId), ex["target"]?.string == tid else { continue }
                for rel in (ex["membershipExceptions"]?.array ?? []).compactMap(\.string) {
                    // Xcode writes localized members with a leading `/Localized/…` marker; strip a
                    // leading slash so the join below stays relative to the folder either way.
                    let r = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
                    excluded.insert(std((dir as NSString).appendingPathComponent(r)))
                }
            }
            for f in everything.map(std) where !excluded.contains(f) { files.insert(f) }
        }
    }

    // (c) the ADDITION half of exception sets: a file inside a folder some OTHER target synchronizes
    // can be a member of THIS target ("Target Membership" ticked across products — NetNewsWire's Mac
    // share extension is built entirely this way). An exception set names the group it hangs off via
    // that group's `exceptions` list, so walk every synchronized group in the project once.
    let closureSet = Set(closureIds)
    for (gid, g) in model.objects where g["isa"]?.string == "PBXFileSystemSynchronizedRootGroup" {
        for exId in (g["exceptions"]?.array ?? []).compactMap(\.string) {
            guard let ex = model.obj(exId), let tgt = ex["target"]?.string, closureSet.contains(tgt) else { continue }
            // The OWNERSHIP test is PER EXCEPTION SET, not per group. The first draft skipped any group
            // owned by anyone in the closure — but NetNewsWire's real shape is a file EXCLUDED from the
            // folder's owner and ADDED to a different closure member (`SafariExtensionHandler.swift`:
            // out of the Mac app, compiled by `Subscribe to Feed`, and the Mac app DEPENDS on that
            // extension) — and the group-level skip dropped it from the closure's union entirely, a
            // silent under-scope inside the very feature built to avoid one. A set whose target owns
            // the group is the EXCLUDE half, already applied in the walk above; any other set on the
            // group is an addition for its target.
            let targetOwnsGroup = (model.obj(tgt)?["fileSystemSynchronizedGroups"]?.array ?? [])
                .compactMap(\.string).contains(gid)
            if targetOwnsGroup { continue }
            guard let dir = resolvedPath(gid) else {
                // The addition names files this target compiles; not knowing where they are is not
                // knowing part of the target's source list.
                throw XcodeScopeError.unresolvableSource(
                    target: targetName, what: "synchronized group \(g["path"]?.string ?? gid) (membership "
                        + "additions for this target) has no resolvable location")
            }
            for rel in (ex["membershipExceptions"]?.array ?? []).compactMap(\.string) where rel.hasSuffix(".swift") {
                let r = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
                files.insert(std((dir as NSString).appendingPathComponent(r)))
            }
        }
    }

    // ── LOCAL Swift package products, resolved into the closure ───────────────────────────────────
    // The measurement that forced this: IceCubesApp scoped to its app target analyzed `[Notify]` while
    // the app's Camera/Photos reach sat in `Packages/*` — a green tick over a shell. Local packages
    // are found from what the PROJECT references (a drag-in `PBXFileReference` wrapper, an
    // `XCLocalSwiftPackageReference`, or a synchronized folder whose subdirectories are packages, the
    // NetNewsWire `Modules/` layout); their manifests go through the SAME SwiftPM parser `--target`
    // already trusts, and `.product(…)` edges BETWEEN local packages resolve transitively through one
    // shared index. Anything local that cannot be resolved soundly REFUSES — the scan must never
    // proceed minus code the user's target actually compiles.

    // 1. Discover every local package directory the project references.
    var localPkgDirs: [String] = []
    var seenPkgDir = Set<String>()
    func notePackageDir(_ dir: String) {
        guard fs.readFile((dir as NSString).appendingPathComponent("Package.swift")) != nil else { return }
        if seenPkgDir.insert(dir).inserted { localPkgDirs.append(dir) }
    }
    for (id, o) in model.objects {
        switch o["isa"]?.string {
        case "XCLocalSwiftPackageReference":
            // Declared local: its manifest MUST exist — a declared-local package that cannot be read
            // is a refusal, not a shrug, and it is checked in step 3 when something depends on it.
            if let rp = o["relativePath"]?.string {
                notePackageDir(std((rootDir as NSString).appendingPathComponent(rp)))
            }
        case "PBXFileReference":
            // The drag-in spelling: a folder/wrapper reference whose directory holds a Package.swift.
            let kind = o["lastKnownFileType"]?.string ?? o["explicitFileType"]?.string ?? ""
            guard kind == "wrapper" || kind.hasPrefix("folder") else { continue }
            if let dir = resolvedPath(id) { notePackageDir(dir) }
        case "PBXFileSystemSynchronizedRootGroup":
            // NetNewsWire's layout: a synchronized `Modules/` folder whose SUBDIRECTORIES are the
            // packages. One level — a package's own manifest sits at its root by definition.
            if let dir = resolvedPath(id) {
                notePackageDir(dir)
                for sub in fs.subdirectories(dir) { notePackageDir(std(sub)) }
            }
        default: break
        }
    }

    // 2. Parse each local manifest ONCE and index its products and targets.
    struct LocalPackage {
        let dir: String
        let targets: [PackageTarget]
        let products: [PackageProduct]
        /// False when the structural read is provably partial AND `dump-package` could not repair it:
        /// resolving THROUGH such a package — or classifying a missed product name as "remote" while
        /// one exists — would silently narrow the scan, so both refuse instead.
        let complete: Bool
    }
    var localPackages: [LocalPackage] = []
    var packagesReadViaDump: [String] = []
    for dir in localPkgDirs.sorted() {
        guard let src = fs.readFile((dir as NSString).appendingPathComponent("Package.swift")) else { continue }
        var targets = parsePackageTargets(manifestSource: src)
        var products = parsePackageProducts(manifestSource: src)
        // Is the STRUCTURAL read provably incomplete? Three checkable signs: the `products:`/`targets:`
        // arguments are not fully-literal arrays (WordPress writes `XcodeSupport.products + […]`, and a
        // wholly computed list can HIDE a local product — which would then misclassify as remote, a
        // silently narrowed scan); a declared product whose member target the parse never saw (the
        // helper-built `XcodeTarget_App`); or a dependency list hoisted into a variable. Any of them
        // means this parse cannot be trusted to answer negatives — so SwiftPM itself is asked, and
        // only if IT cannot answer does the resolution refuse downstream.
        let lists = packageManifestListsAreComplete(manifestSource: src)
        let targetNames = Set(targets.map(\.name))
        let incomplete = !lists.products || !lists.targets
            || products.contains { p in
                p.targetsUnreadable || p.targets.contains { !targetNames.contains($0) }
            }
            || targets.contains { $0.dependenciesUnreadable || $0.productDependenciesUnreadable }
        var complete = !incomplete
        if incomplete, let json = fs.dumpPackage(dir),
           let dumped = parseDumpPackageJSON(json) {
            targets = dumped.targets
            products = dumped.products
            complete = true
            packagesReadViaDump.append((dir as NSString).lastPathComponent)
        }
        localPackages.append(LocalPackage(dir: dir, targets: targets, products: products, complete: complete))
    }
    /// product name -> the packages declaring it (by index). Built from DECLARED products, with the
    /// same-name-target fallback for manifests whose products list this parse cannot read in full.
    var productIndex: [String: [Int]] = [:]
    for (i, pkg) in localPackages.enumerated() {
        for p in pkg.products { productIndex[p.name, default: []].append(i) }
    }
    func lookupLocal(_ product: String) -> [Int] {
        if let hits = productIndex[product], !hits.isEmpty { return hits }
        // Fallback: a target of the same name. Products nearly always mirror a target's name, and a
        // manifest that hoists its products into a variable would otherwise misread as "remote".
        return localPackages.enumerated().compactMap { i, pkg in
            pkg.targets.contains { $0.name == product } ? i : nil
        }
    }

    // 3. Resolve every product dependency: local -> sources (transitively), remote -> disclosed count.
    var remoteProducts = 0
    var resolvedLocalNames: Set<String> = []
    var expandedTargets = Set<String>()   // "dir\u{0}target" — the cross-package recursion's visited set
    /// The refusal when a name misses the index but some local manifest could not be fully read: the
    /// miss proves nothing, and "probably remote" is exactly the guess this resolver must not make.
    func refuseIfAnyIncomplete(_ product: String) throws {
        let partial = localPackages.filter { !$0.complete }
        guard partial.isEmpty else {
            throw XcodeScopeError.unresolvableLocalProduct(
                product: product,
                why: "no fully-read local package declares it, and "
                    + "\(partial.map(\.dir).joined(separator: ", ")) build(s) products/targets in code "
                    + "the structural parser cannot follow (`swift package dump-package` was also "
                    + "unavailable or failed), so it cannot be proved remote")
        }
    }
    func expand(pkgIndex: Int, product: String) throws {
        let pkg = localPackages[pkgIndex]
        guard pkg.complete else {
            throw XcodeScopeError.unresolvableLocalProduct(
                product: product,
                why: "\(pkg.dir)/Package.swift builds its products/targets in code the structural "
                    + "parser cannot follow, and `swift package dump-package` was unavailable or failed")
        }
        // The product's member targets: the declared list, else the same-name target.
        let targetNames: [String]
        if let decl = pkg.products.first(where: { $0.name == product }) {
            if decl.targetsUnreadable, !pkg.targets.contains(where: { $0.name == product }) {
                throw XcodeScopeError.unresolvableLocalProduct(
                    product: product,
                    why: "its `targets:` in \(pkg.dir)/Package.swift is not a literal list")
            }
            targetNames = decl.targets.isEmpty ? [product] : decl.targets
        } else {
            targetNames = [product]   // reached via the same-name-target fallback
        }
        for tn in targetNames {
            let closure: [PackageTarget]
            do { closure = try targetClosure(tn, in: pkg.targets) }
            catch {
                throw XcodeScopeError.unresolvableLocalProduct(
                    product: product, why: "\(error) (in \(pkg.dir)/Package.swift)")
            }
            for t in closure {
                guard expandedTargets.insert(pkg.dir + "\u{0}" + t.name).inserted else { continue }
                let dirs: [String]
                do { dirs = try targetSourceDirs([t], packageRoot: pkg.dir, exists: fs.directoryExists) }
                catch {
                    throw XcodeScopeError.unresolvableLocalProduct(
                        product: product, why: "\(error) (in \(pkg.dir))")
                }
                for d in dirs {
                    guard let swifts = swiftFilesUnder(d) else {
                        throw XcodeScopeError.unresolvableLocalProduct(
                            product: product, why: "sources under \(d) could not be read")
                    }
                    for f in swifts { files.insert(std(f)) }
                }
                if t.productDependenciesUnreadable {
                    throw XcodeScopeError.unresolvableLocalProduct(
                        product: product,
                        why: "target `\(t.name)` in \(pkg.dir)/Package.swift has a `.product(…)` "
                            + "dependency whose name is not a literal")
                }
                // `.product(…)` edges BETWEEN local packages: resolve through the shared index, so
                // IceCubes' StatusKit -> MediaUI chain lands in the scope. A miss here is a remote
                // product (BrowserServicesKit et al) — counted, κ-disclosed, exactly like a remote
                // dependency named at the project level.
                //
                // ⟨the bare-name half⟩ …AND a BARE-STRING dependency naming nothing this package
                // declares is the SAME edge in the other spelling. SwiftPM resolves a bare name
                // against a dependency package's PRODUCTS, and real manifests use it: NetNewsWire's
                // Account writes `.package(path: "../NewsBlur")` beside a plain `"NewsBlur"` in its
                // target, never `.product(name:package:)`. `targetClosure` drops such a name — correct
                // for the SPM `--target` path, where "not declared here" does mean "no sources in this
                // tree", and WRONG here, where the sibling package is three directories away.
                //
                // MEASURED on NetNewsWire, which is why this exists: `Modules/` holds 17 local
                // packages and the scope resolved 14. The three missing — CloudKitSync, FeedFinder,
                // NewsBlur — were exactly the ones no app TARGET names directly, reachable only
                // through Account. NewsBlurAPICaller is the app's sync layer; leaving it out analyzed
                // the app minus its network client. Not a purity claim (the import ledger still
                // disclosed the modules as uncovered), but the scope was smaller than the product.
                //
                // Both misses land in the same arm below, so a bare name that matches no local
                // product is counted remote and κ-disclosed rather than dropped in silence — which is
                // strictly more disclosure than the closure-level drop it replaces.
                let inPackage = Set(pkg.targets.map(\.name))
                for pd in t.productDependencies + t.dependencies.filter({ !inPackage.contains($0) }) {
                    let hits = lookupLocal(pd)
                    if hits.count > 1 {
                        throw XcodeScopeError.unresolvableLocalProduct(
                            product: pd,
                            why: "declared by \(hits.count) local packages "
                                + "(\(hits.map { localPackages[$0].dir }.joined(separator: ", ")))")
                    }
                    if let hit = hits.first {
                        resolvedLocalNames.insert((localPackages[hit].dir as NSString).lastPathComponent)
                        try expand(pkgIndex: hit, product: pd)
                    } else {
                        try refuseIfAnyIncomplete(pd)
                        remoteProducts += 1
                    }
                }
            }
        }
    }
    for dep in productDeps {
        if let refId = dep.refId {
            guard let ref = model.obj(refId) else {
                throw XcodeScopeError.unresolvableLocalProduct(
                    product: dep.name, why: "its package reference \(refId) names no object")
            }
            switch ref["isa"]?.string {
            case "XCRemoteSwiftPackageReference":
                remoteProducts += 1
                continue
            case "XCLocalSwiftPackageReference":
                // Declared local: resolve in THAT package only, and its absence is a refusal.
                guard let rp = ref["relativePath"]?.string else {
                    throw XcodeScopeError.unresolvableLocalProduct(
                        product: dep.name, why: "its XCLocalSwiftPackageReference has no relativePath")
                }
                let dir = std((rootDir as NSString).appendingPathComponent(rp))
                guard let idx = localPackages.firstIndex(where: { $0.dir == dir }) else {
                    throw XcodeScopeError.unresolvableLocalProduct(
                        product: dep.name, why: "no readable Package.swift at \(dir)")
                }
                resolvedLocalNames.insert((dir as NSString).lastPathComponent)
                try expand(pkgIndex: idx, product: dep.name)
                continue
            default:
                throw XcodeScopeError.unresolvableLocalProduct(
                    product: dep.name, why: "its package reference has kind \(ref["isa"]?.string ?? "?")")
            }
        }
        // No package ref — the drag-in spelling. Local when a local package declares it; else remote.
        let hits = lookupLocal(dep.name)
        if hits.count > 1 {
            throw XcodeScopeError.unresolvableLocalProduct(
                product: dep.name,
                why: "declared by \(hits.count) local packages "
                    + "(\(hits.map { localPackages[$0].dir }.joined(separator: ", ")))")
        }
        if let hit = hits.first {
            resolvedLocalNames.insert((localPackages[hit].dir as NSString).lastPathComponent)
            try expand(pkgIndex: hit, product: dep.name)
        } else {
            // A bare name found nowhere local is remote — but ONLY when every local manifest was
            // fully read. A miss against a partial read proves nothing.
            try refuseIfAnyIncomplete(dep.name)
            remoteProducts += 1
        }
    }

    // ── platform pruning ──────────────────────────────────────────────────────────────────────────
    // Forced by the FIRST local-package measurement: resolving NetNewsWire's packages put RSCore's
    // `SendToBlogEditorApp.swift` — a file wholly inside `#if os(macOS)` — into the iOS scope, and the
    // AppleEvents false finding this feature was built to remove came back through it. The file IS a
    // member of the package target; it just compiles to NOTHING on iOS. So: when the target's build
    // settings say which platform it builds for, a file whose every top-level declaration sits inside
    // `#if os(…)` clauses provably FALSE for that platform is dropped. This is still MEMBERSHIP, not
    // semantics — and every undecidable condition (`canImport`, a custom flag, `swift(>=…)`) keeps the
    // file, so the failure mode is the pre-existing over-approximation, never a dropped live file.
    let platform = inferPlatform(of: rootTid, model: model, rootDir: rootDir,
                                 resolvedPath: resolvedPath, fs: fs)
    var platformExcluded = 0
    if let platform {
        files = Set(files.filter { f in
            // Cheap gate first: no `#if os(` in the text, nothing to evaluate. An unreadable file is
            // KEPT — the scan will name its failure itself; pruning must never eat one silently.
            guard let src = fs.readFile(f), src.contains("#if os(") else { return true }
            if swiftFileCompilesToNothing(source: src, on: platform) {
                platformExcluded += 1
                return false
            }
            return true
        })
    }

    let infoByName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    let closureInfos = closureIds.compactMap { model.obj($0)?["name"]?.string }
        .compactMap { infoByName[$0] }
        .sorted { $0.name < $1.name }
    return XcodeTargetScope(target: infoByName[targetName]
                                ?? XcodeTargetInfo(name: targetName, productType: nil),
                            closure: closureInfos,
                            files: files,
                            localPackages: resolvedLocalNames.sorted(),
                            remoteProductCount: remoteProducts,
                            crossProjectDependencyCount: crossProject,
                            packagesReadViaDump: packagesReadViaDump.sorted(),
                            platform: platform,
                            platformExcludedCount: platformExcluded,
                            entitlements: resolveEntitlements(of: rootTid, model: model, rootDir: rootDir,
                                                              resolvedPath: resolvedPath, fs: fs))
}

// MARK: - reading a `swift package dump-package` document

/// The dump's JSON → the same shapes the structural parse produces. Returns nil when the text is not
/// the expected document — the caller then stays with the structural read and its refusals.
public func parseDumpPackageJSON(_ text: String) -> (targets: [PackageTarget], products: [PackageProduct])? {
    guard let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let top = obj as? [String: Any] else { return nil }
    var products: [PackageProduct] = []
    for p in (top["products"] as? [[String: Any]]) ?? [] {
        guard let name = p["name"] as? String else { continue }
        let targets = (p["targets"] as? [String]) ?? []
        products.append(PackageProduct(name: name, targets: targets, targetsUnreadable: false))
    }
    var targets: [PackageTarget] = []
    var declared = Set<String>()
    let rawTargets = (top["targets"] as? [[String: Any]]) ?? []
    for t in rawTargets {
        if let n = t["name"] as? String { declared.insert(n) }
    }
    for t in rawTargets {
        guard let name = t["name"] as? String else { continue }
        let type = (t["type"] as? String) ?? "regular"
        // `binary` and `system` targets carry no Swift sources to scan; leaving them OUT of the model
        // turns references to them into product-dependency lookups that miss — i.e. the disclosed
        // remote channel — instead of a missing-source-dir refusal over an artifact directory.
        guard ["regular", "executable", "test", "macro", "plugin"].contains(type) else { continue }
        var deps: [String] = []
        var productDeps: [String] = []
        for d in (t["dependencies"] as? [[String: Any]]) ?? [] {
            // Shapes: {"byName": [name, …]}, {"target": [name, …]}, {"product": [name, package, …]}.
            if let arr = d["target"] as? [Any], let n = arr.first as? String { deps.append(n) }
            else if let arr = d["product"] as? [Any], let n = arr.first as? String { productDeps.append(n) }
            else if let arr = d["byName"] as? [Any], let n = arr.first as? String {
                // SwiftPM resolves a bare name to a target first, then to a product — mirrored here.
                if declared.contains(n) { deps.append(n) } else { productDeps.append(n) }
            }
        }
        targets.append(PackageTarget(name: name, dependencies: deps,
                                     path: t["path"] as? String,
                                     isTest: type == "test",
                                     dependenciesUnreadable: false,
                                     productDependencies: productDeps,
                                     productDependenciesUnreadable: false))
    }
    guard !targets.isEmpty else { return nil }
    return (targets, products)
}

// MARK: - one target's build settings, from the project AND its xcconfig chain

/// Every value a target's build settings give the named keys, in the order the build system would see
/// them: the target's own `XCBuildConfiguration` dictionaries first, then the `baseConfigurationReference`
/// xcconfig CHAIN (bounded, cycle-safe, `#include` followed to the end).
///
/// ONE traversal, two consumers, because they were the same walk with different aggregation: the platform
/// prune unions its tokens across configurations, and the entitlements lookup needs LAST-WINS per key
/// (Xcode's own rule, and the reason flip #17 existed). Splitting the aggregation out of the traversal is
/// what let the second consumer exist without a second copy of the xcconfig-chain reader — including the
/// Xcode 16 spelling for an xcconfig inside a SYNCHRONIZED folder (an anchor group plus a relative path,
/// no file reference at all), which NetNewsWire's entire build hangs off.
private func targetSettingValues(_ keys: Set<String>, of targetId: String, model: PbxprojModel,
                                 resolvedPath: (String) -> String?,
                                 fs: XcodeScopeFS) -> [(key: String, value: String)] {
    var out: [(key: String, value: String)] = []
    func takeXcconfig(path: String, depth: Int, visited: inout Set<String>) {
        guard depth < 6, visited.insert(path).inserted, let text = fs.readFile(path) else { return }
        // INCLUDES FIRST: an including file's own assignment must win over the file it includes, and
        // `out` is read last-wins by the entitlements consumer. (The platform consumer unions, so the
        // order is immaterial to it.)
        let base = (path as NSString).deletingLastPathComponent
        for rawLine in stripCommentsPreservingStrings(text).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#include") else { continue }
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""),
                  open < close else { continue }
            let rel = String(line[line.index(after: open)..<close])
            guard !rel.isEmpty, !rel.hasPrefix("/") else { continue }
            takeXcconfig(path: URL(fileURLWithPath: (base as NSString).appendingPathComponent(rel)).path,
                         depth: depth + 1, visited: &visited)
        }
        for st in buildSettingStatements(text) {
            guard let eq = st.firstIndex(of: "=") else { continue }
            var name = String(st[st.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            // `KEY[sdk=iphoneos*]` — a CONDITIONAL assignment. The base name is what it assigns.
            if let br = name.firstIndex(of: "[") { name = String(name[name.startIndex..<br]) }
            guard keys.contains(name) else { continue }
            out.append((name, String(st[st.index(after: eq)...]).trimmingCharacters(in: .whitespaces)))
        }
    }
    var visited = Set<String>()
    for cid in configurationIds(of: targetId, model: model) {
        guard let conf = model.obj(cid) else { continue }
        if let baseRef = conf["baseConfigurationReference"]?.string, let path = resolvedPath(baseRef) {
            takeXcconfig(path: path, depth: 0, visited: &visited)
        }
        if let anchor = conf["baseConfigurationReferenceAnchor"]?.string,
           let rel = conf["baseConfigurationReferenceRelativePath"]?.string,
           let anchorDir = resolvedPath(anchor) {
            takeXcconfig(path: URL(fileURLWithPath: (anchorDir as NSString).appendingPathComponent(rel)).path,
                         depth: 0, visited: &visited)
        }
        // The project's own dictionary wins over the xcconfig it is based on — Xcode's precedence.
        if let bs = conf["buildSettings"]?.dict {
            for k in keys { if let v = bs[k]?.string { out.append((k, v)) } }
        }
    }
    return out
}

/// Expand `$(NAME)` / `${NAME}` using `defs`. **An undefined variable expands to the EMPTY STRING** —
/// that is Xcode's rule, not a fallback, and it is the rule that makes this exact rather than a guess:
/// NetNewsWire writes `CODE_SIGN_ENTITLEMENTS = iOS/Resources/NetNewsWire$(DEVELOPER_ENTITLEMENTS)
/// .entitlements`, and `DEVELOPER_ENTITLEMENTS` is defined only in a personal file OUTSIDE the checkout
/// (`#include?` of `../../SharedXcodeSettings/…`). In a clone it is undefined, so the path is
/// `NetNewsWire.entitlements` — which is precisely the file that checkout builds against.
func expandBuildVariables(_ raw: String, defs: [String: String]) -> String {
    var out = ""
    var i = raw.startIndex
    while i < raw.endIndex {
        guard raw[i] == "$", raw.index(after: i) < raw.endIndex else { out.append(raw[i]); i = raw.index(after: i); continue }
        let open = raw[raw.index(after: i)]
        guard open == "(" || open == "{" else { out.append(raw[i]); i = raw.index(after: i); continue }
        let close: Character = open == "(" ? ")" : "}"
        guard let end = raw[raw.index(i, offsetBy: 2)...].firstIndex(of: close) else {
            out.append(raw[i]); i = raw.index(after: i); continue
        }
        let name = String(raw[raw.index(i, offsetBy: 2)..<end])
        out += defs[name] ?? ""      // undefined ⇒ empty, per Xcode
        i = raw.index(after: end)
    }
    return out
}

/// The `.entitlements` file THIS target signs with, resolved from `CODE_SIGN_ENTITLEMENTS` — absolute,
/// and only when the file actually EXISTS.
///
/// WHY THIS IS WORTH RESOLVING. `--target` scopes the scan, but the `privacy-manifest --verify` that
/// follows reads a REPORT and a plist, so it re-discovered entitlements by walking the plist's directory
/// — and a repo with several shipped binaries has several `.entitlements`, so it refused to guess and
/// left the entitlement-sourced keys unchecked (measured on NetNewsWire: 8 files, 1 key unchecked).
/// Narrowing that SEARCH would still be a search. The build settings do not search: they name the file,
/// per target, which is the answer the question was always asking for.
///
/// Returns nil rather than a guess when the setting is absent, or when the expanded path names no file
/// (a variable this cannot resolve, a generated entitlements) — the caller then keeps the disclosure it
/// had, which is never worse than before.
private func resolveEntitlements(of targetId: String, model: PbxprojModel, rootDir: String,
                                 resolvedPath: (String) -> String?, fs: XcodeScopeFS) -> String? {
    let pairs = targetSettingValues(["CODE_SIGN_ENTITLEMENTS"], of: targetId, model: model,
                                    resolvedPath: resolvedPath, fs: fs)
    guard let raw = pairs.last?.value, !raw.isEmpty else { return nil }
    // The variables the same chain defines. Collected from the SAME traversal so a value defined beside
    // the entitlements line resolves; anything else is undefined and expands to empty, per Xcode.
    var names = Set<String>()
    var i = raw.startIndex
    while let dollar = raw[i...].firstIndex(of: "$") {
        let after = raw.index(after: dollar)
        guard after < raw.endIndex, raw[after] == "(" || raw[after] == "{" else {
            i = after; if i >= raw.endIndex { break }; continue
        }
        let close: Character = raw[after] == "(" ? ")" : "}"
        guard let end = raw[raw.index(after: after)...].firstIndex(of: close) else { break }
        names.insert(String(raw[raw.index(after: after)..<end]))
        i = raw.index(after: end)
        if i >= raw.endIndex { break }
    }
    var defs: [String: String] = [:]
    if !names.isEmpty {
        for (k, v) in targetSettingValues(names, of: targetId, model: model,
                                          resolvedPath: resolvedPath, fs: fs) {
            defs[k] = v
        }
    }
    let expanded = expandBuildVariables(raw, defs: defs).trimmingCharacters(in: .whitespaces)
    guard !expanded.isEmpty else { return nil }
    let abs = expanded.hasPrefix("/") ? expanded
        : URL(fileURLWithPath: (rootDir as NSString).appendingPathComponent(expanded)).path
    return fs.readFile(abs) != nil ? abs : nil
}

// MARK: - the target's platform, from its build settings

/// The `os(…)` family a target builds for, or nil when its settings don't say. Sources, in order:
/// `SDKROOT` / `SUPPORTED_PLATFORMS` in the target's own `XCBuildConfiguration` blocks, then in the
/// `baseConfigurationReference` xcconfig CHAIN — NetNewsWire keeps `SDKROOT = macosx` two `#include`
/// levels below the target's xcconfig, which is why the chain is followed (bounded, cycle-safe).
/// Conflicting families (a genuinely multi-platform target) resolve to nil: no pruning, never a guess.
private func inferPlatform(of targetId: String, model: PbxprojModel, rootDir: String,
                           resolvedPath: (String) -> String?, fs: XcodeScopeFS) -> String? {
    var tokens: [String] = []
    func takeSettings(_ dict: [String: PbxValue]) {
        for key in ["SDKROOT", "SUPPORTED_PLATFORMS"] {
            if let v = dict[key]?.string { tokens += v.split(separator: " ").map(String.init) }
        }
    }
    func takeXcconfig(path: String, depth: Int, visited: inout Set<String>) {
        guard depth < 6, visited.insert(path).inserted, let text = fs.readFile(path) else { return }
        for st in buildSettingStatements(text) {
            guard let eq = st.firstIndex(of: "=") else { continue }
            let name = String(st[st.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            guard name == "SDKROOT" || name == "SUPPORTED_PLATFORMS" else { continue }
            let value = String(st[st.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            tokens += value.split(separator: " ").map(String.init)
        }
        // `#include "…"`, relative to the including file — same one-pass comment stripping as the
        // settings themselves, so a commented-out include is not followed.
        let base = (path as NSString).deletingLastPathComponent
        for rawLine in stripCommentsPreservingStrings(text).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#include") else { continue }
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""),
                  open < close else { continue }
            let rel = String(line[line.index(after: open)..<close])
            guard !rel.isEmpty, !rel.hasPrefix("/") else { continue }
            takeXcconfig(path: URL(fileURLWithPath: (base as NSString).appendingPathComponent(rel)).path,
                         depth: depth + 1, visited: &visited)
        }
    }
    var visited = Set<String>()
    for cid in configurationIds(of: targetId, model: model) {
        guard let conf = model.obj(cid) else { continue }
        if let bs = conf["buildSettings"]?.dict { takeSettings(bs) }
        if let baseRef = conf["baseConfigurationReference"]?.string,
           let path = resolvedPath(baseRef) {
            takeXcconfig(path: path, depth: 0, visited: &visited)
        }
        // The Xcode 16 spelling for an xcconfig living in a SYNCHRONIZED folder: an anchor group plus
        // a path relative to it, no file reference at all. NetNewsWire's whole platform story hangs
        // off this — every one of its xcconfigs sits in a synced `xcconfig/` folder.
        if let anchor = conf["baseConfigurationReferenceAnchor"]?.string,
           let rel = conf["baseConfigurationReferenceRelativePath"]?.string,
           let anchorDir = resolvedPath(anchor) {
            takeXcconfig(path: URL(fileURLWithPath: (anchorDir as NSString).appendingPathComponent(rel)).path,
                         depth: 0, visited: &visited)
        }
    }
    var families = Set<String>()
    for raw in tokens {
        let t = raw.lowercased()
        // Order matters: "maccatalyst" builds `os(iOS)`, and a substring test for "mac" would
        // misfile it. `auto`/`$(…)` say nothing.
        if t.contains("maccatalyst") || t.contains("iphone") || t == "ios" { families.insert("iOS") }
        else if t.contains("macosx") || t == "macos" { families.insert("macOS") }
        else if t.contains("appletv") || t == "tvos" { families.insert("tvOS") }
        else if t.contains("watch") { families.insert("watchOS") }
        else if t.contains("xros") || t.contains("vision") { families.insert("visionOS") }
    }
    return families.count == 1 ? families.first : nil
}

private func configurationIds(of targetId: String, model: PbxprojModel) -> [String] {
    guard let t = model.obj(targetId), let listId = t["buildConfigurationList"]?.string,
          let list = model.obj(listId) else { return [] }
    return (list["buildConfigurations"]?.array ?? []).compactMap(\.string)
}

// MARK: - does a file compile to anything on a platform?

/// True when EVERY top-level declaration of `source` sits inside `#if` clauses provably inactive on
/// `platform` — the file contributes nothing to that platform's build. Three-valued on purpose: only
/// `os(…)`, `!`, `&&`, `||`, parentheses and boolean literals are decided; `canImport`, custom flags,
/// `swift(>=…)` and anything else evaluate to UNKNOWN, and an UNKNOWN clause KEEPS the file. Import
/// declarations don't count as contribution (a pruned file is exactly `import Foundation` plus a
/// fully-gated body — RSCore's `SendToBlogEditorApp.swift` verbatim).
public func swiftFileCompilesToNothing(source: String, on platform: String) -> Bool {
    let tree = Parser.parse(source: source)
    for item in tree.statements {
        if item.item.as(ImportDeclSyntax.self) != nil { continue }
        guard let ifc = item.item.as(IfConfigDeclSyntax.self) else { return false }  // live code
        var seenTrue = false
        for clause in ifc.clauses {
            // A clause after a provably-TRUE one can never be active; otherwise it is possibly
            // active unless its own condition is provably FALSE (`#else` has no condition).
            var possiblyActive = !seenTrue
            if possiblyActive, let cond = clause.condition {
                let v = evalPlatformCondition(cond, platform: platform)
                if v == false { possiblyActive = false }
                if v == true { seenTrue = true }
            }
            guard possiblyActive, let elements = clause.elements else { continue }
            if case .statements(let stmts) = elements {
                // Import-only content is still no contribution; anything else is.
                if stmts.contains(where: { $0.item.as(ImportDeclSyntax.self) == nil && $0.item.as(IfConfigDeclSyntax.self) == nil })
                    { return false }
                // A NESTED `#if` inside a possibly-active clause: kept conservatively — recursing
                // buys little and every miscount here is in the dangerous direction.
                if stmts.contains(where: { $0.item.as(IfConfigDeclSyntax.self) != nil }) { return false }
            } else {
                return false   // members/attributes/expressions — content this does not model: keep
            }
        }
    }
    return true
}

/// `true`/`false` when decidable on `platform`, nil otherwise (which the caller treats as "keep").
private func evalPlatformCondition(_ expr: ExprSyntax, platform: String) -> Bool? {
    if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
       let inner = tuple.elements.first {
        return evalPlatformCondition(inner.expression, platform: platform)
    }
    if let lit = expr.as(BooleanLiteralExprSyntax.self) { return lit.literal.text == "true" }
    if let neg = expr.as(PrefixOperatorExprSyntax.self), neg.operator.text == "!" {
        return evalPlatformCondition(neg.expression, platform: platform).map { !$0 }
    }
    if let call = expr.as(FunctionCallExprSyntax.self),
       let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
        guard callee.baseName.text == "os",
              let arg = call.arguments.first?.expression.as(DeclReferenceExprSyntax.self) else {
            return nil   // canImport / targetEnvironment / arch / swift / compiler / a custom flag
        }
        return arg.baseName.text == platform
    }
    // `a || b || c`: the parser leaves the sequence UNFOLDED. Only a chain of ONE operator is
    // decided; mixed `&&`/`||` without parentheses is rare enough that UNKNOWN (keep) is the
    // right price for not re-implementing precedence.
    if let seq = expr.as(SequenceExprSyntax.self) {
        let parts = Array(seq.elements)
        if parts.count == 1 { return evalPlatformCondition(parts[0], platform: platform) }
        guard parts.count >= 3, parts.count % 2 == 1 else { return nil }
        var op: String? = nil
        var values: [Bool?] = []
        for (i, p) in parts.enumerated() {
            if i % 2 == 1 {
                guard let b = p.as(BinaryOperatorExprSyntax.self) else { return nil }
                if op == nil { op = b.operator.text }
                guard b.operator.text == op else { return nil }
            } else {
                values.append(evalPlatformCondition(p, platform: platform))
            }
        }
        switch op {
        case "||":
            if values.contains(true) { return true }
            return values.allSatisfy { $0 == false } ? false : nil
        case "&&":
            if values.contains(false) { return false }
            return values.allSatisfy { $0 == true } ? true : nil
        default: return nil
        }
    }
    // A bare identifier is a custom compilation flag — unknown by definition.
    return nil
}

// MARK: - project discovery

/// Every `.xcodeproj` under `root` that actually contains a `project.pbxproj`, sorted. Skips VCS/build
/// trees and anything inside a derived bundle — the same exclusions the plist discovery uses, for the
/// same reason: a `.xcodeproj` inside somebody's `Pods/` or a checkout's `.build/` is not a product of
/// this repo, and resolving a target there answers about the wrong code.
public func findXcodeProjects(under root: String) -> [String] {
    let fm = FileManager.default
    let skip: Set<String> = [".build", ".git", "DerivedData", "Pods", "node_modules", "Carthage", ".swiftpm"]
    var found: [String] = []
    if let en = fm.enumerator(atPath: root) {
        for case let rel as String in en {
            let parts = rel.split(separator: "/").map(String.init)
            if parts.dropLast().contains(where: { skip.contains($0) || $0.hasSuffix(".xcodeproj") }) {
                en.skipDescendants(); continue
            }
            guard let leaf = parts.last, leaf.hasSuffix(".xcodeproj") else {
                if let leaf = parts.last, skip.contains(leaf) { en.skipDescendants() }
                continue
            }
            let abs = (root as NSString).appendingPathComponent(rel)
            if fm.fileExists(atPath: (abs as NSString).appendingPathComponent("project.pbxproj")) {
                found.append(abs)
            }
            en.skipDescendants()
        }
    }
    return found.sorted()
}
