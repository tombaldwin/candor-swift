import Foundation
import CandorCore

// SOUNDNESS R1938 (type-identity lane L1) — the module-identity probe: `ModuleIdentityIndex` (CandorCore) over this scan's files,
// compared with the engine's existing module answer `swiftModuleOf`, written through `identProbe` (stderr, env-gated).
//
// It is the ONLY caller of the index. Nothing the engine reports depends on it, so it cannot move a result; its purpose is to
// measure, over the pool, how often the manifest answer and the path heuristic disagree and how many files have no manifest answer
// at all (the attribution gap), BEFORE a later lane builds the type-identity resolver on `moduleOf`.

struct IdentFileFacts {
    let rel: String
    let module: String?          // the manifest or unique Xcode target
    let via: String              // manifest | xcode | xcode-ambiguous:… | manifest-ambiguous-target | none:no-manifest | none:manifest-unclaimed:<dir>
    let swiftModule: String      // the engine's path heuristic (`swiftModuleOf`, nested-manifest aware)
    let pkgDir: String?          // the owning SwiftPM package directory, when `via == manifest`
}

/// One `IdentFileFacts` per scanned file: the manifest (or unique Xcode) target if one claims it, else WHY none does.
func moduleIdentityFacts(sourcePaths: [String], rootDir: String, owningPackage: (String) -> String?, owningTarget: (String, String) -> String?,
                         xcodeModulesByFile: [String: [String]], swiftModuleOf: (String) -> String) -> [IdentFileFacts] {
    var facts: [IdentFileFacts] = []
    let rootAbs = candorAbsolutePath(rootDir)
    for raw in sourcePaths {
        let abs = candorAbsolutePath(raw)
        let rel = raw.hasPrefix(rootDir)
            ? String(raw.dropFirst(rootDir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : raw
        var module: String? = nil, via = "none:no-manifest", pkgDir: String? = nil
        if let pkg = owningPackage(abs) {
            if let own = owningTarget(abs, pkg) { module = own; via = "manifest"; pkgDir = pkg } else { via = "manifest-ambiguous-target" }
        } else if let xs = xcodeModulesByFile[abs], !xs.isEmpty {
            if xs.count == 1 { module = xs[0]; via = "xcode" } else { via = "xcode-ambiguous:" + xs.sorted().joined(separator: "+") }
        } else {
            // no target claims the file: say whether some ancestor holds a manifest (a `path:` the parse could not resolve, a
            // non-literal target list) or none does
            var dir = (abs as NSString).deletingLastPathComponent
            while dir.count > 1 {
                if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("Package.swift")) {
                    let r = dir.hasPrefix(rootAbs) ? String(dir.dropFirst(rootAbs.count)) : dir
                    let shown = r.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    via = "none:manifest-unclaimed:" + (shown.isEmpty ? "." : shown)
                    break
                }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }
        facts.append(IdentFileFacts(rel: rel, module: module, via: via, swiftModule: swiftModuleOf(rel), pkgDir: pkgDir))
    }
    return facts
}

func emitModuleIdentityProbe(_ files: [IdentFileFacts], imports: [String: [String]], exported: [String: Set<String>],
                             reexports: [String: Set<String>], manifestSource: (String) -> String?) {
    guard identProbeOn else { return }
    var moduleOf: [String: String] = [:]
    for f in files { if let m = f.module { moduleOf[f.rel] = m } }
    // MemberImportVisibility per target: a SwiftPM manifest is parsed; an Xcode target's build settings are not read here (unreadable)
    var miv: [String: MemberImportVisibilitySetting] = [:]
    var pkgs: [String: [String: MemberImportVisibilitySetting]] = [:]
    for f in files {
        guard let m = f.module else { continue }
        if let p = f.pkgDir {
            if pkgs[p] == nil { pkgs[p] = manifestSource(p).map(parsePackageMemberImportVisibility(manifestSource:)) ?? [:] }
            miv[m] = pkgs[p]?[m] ?? .unreadable
        } else if miv[m] == nil { miv[m] = .unreadable }
    }
    let idx = ModuleIdentityIndex(moduleOfFile: moduleOf, importsByFile: imports, exportedByFile: exported,
                                  dependencyReexports: reexports, memberImportVisibility: miv)
    var attributed = 0, disagree = 0, unattributed = 0
    var reasons: [String: Int] = [:]
    for f in files.sorted(by: { $0.rel < $1.rel }) {
        let verdict: String
        if f.module == nil { verdict = "unattributed"; unattributed += 1; reasons[f.via, default: 0] += 1 }
        else if f.module == f.swiftModule { verdict = "agree"; attributed += 1 }
        else { verdict = "disagree"; attributed += 1; disagree += 1 }
        let vis = idx.visibleModules(inFile: f.rel).sorted().joined(separator: ",")
        identProbe("IDM\t\(f.rel)\t\(f.module ?? "-")\t\(f.via)\t\(f.swiftModule.isEmpty ? "-" : f.swiftModule)\t\(verdict)\t\(idx.memberImportVisibility(ofFile: f.rel).rawValue)\t\(vis)")
    }
    for m in idx.ownModules.sorted() {
        identProbe("IDX\t\(m)\t\(idx.files(ofModule: m).count)\t\(idx.exportedClosure(ofModule: m).sorted().joined(separator: ","))\t\(idx.targetVisibleModules(ofModule: m).sorted().joined(separator: ","))\t\(miv[m]?.rawValue ?? "unreadable")")
    }
    identProbe("IDMS\tfiles=\(files.count)\tattributed=\(attributed)\tagree=\(attributed - disagree)\tdisagree=\(disagree)\tunattributed=\(unattributed)\t"
               + reasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"))
}
