import SwiftSyntax
import SwiftParser

/// SOUNDNESS R1873 — the STATIC (or `class`) functions a Swift source file declares, by the simple name of the type
/// that declares them: in the type's own body (at any nesting) and in its extensions. `[p].map(HTTPClient.spawn)` invokes
/// `spawn` per element only when it is static; an unapplied INSTANCE method (`HTTPClient.get`) yields a closure and runs
/// nothing. Positive evidence only: a file this cannot read answers nothing, and the caller then forms no call.
public func staticFunctionDeclarations(source: String) -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    func isStatic(_ mods: DeclModifierListSyntax) -> Bool { mods.contains { ["static", "class"].contains($0.name.text) } }
    func walkMembers(_ ty: String, _ items: MemberBlockItemListSyntax) {
        for item in items { walkMember(ty, item.decl) }
    }
    func walkMember(_ ty: String, _ d: DeclSyntax) {
        if let f = d.as(FunctionDeclSyntax.self) {
            if isStatic(f.modifiers) { out[ty, default: []].insert(f.name.text) }
        } else if let x = d.as(IfConfigDeclSyntax.self) {
            for clause in x.clauses { if case .decls(let ds)? = clause.elements { walkMembers(ty, ds) } }
        } else {
            walkDecl(d)   // a nested type declares its own statics under its own simple name
        }
    }
    func walkDecl(_ d: DeclSyntax) {
        if let x = d.as(StructDeclSyntax.self) { walkMembers(x.name.text, x.memberBlock.members) }
        else if let x = d.as(ClassDeclSyntax.self) { walkMembers(x.name.text, x.memberBlock.members) }
        else if let x = d.as(EnumDeclSyntax.self) { walkMembers(x.name.text, x.memberBlock.members) }
        else if let x = d.as(ActorDeclSyntax.self) { walkMembers(x.name.text, x.memberBlock.members) }
        else if let x = d.as(ProtocolDeclSyntax.self) { walkMembers(x.name.text, x.memberBlock.members) }
        else if let e = d.as(ExtensionDeclSyntax.self) {
            let full = e.extendedType.trimmedDescription.split(separator: "<").first.map(String.init) ?? ""
            if let ty = full.split(separator: ".").last.map(String.init), !ty.isEmpty { walkMembers(ty, e.memberBlock.members) }
        } else if let x = d.as(IfConfigDeclSyntax.self) {
            for clause in x.clauses {
                switch clause.elements {
                case .statements(let st)?: for i in st { if let dd = i.item.as(DeclSyntax.self) { walkDecl(dd) } }
                case .decls(let ds)?: for m in ds { walkDecl(m.decl) }
                default: break
                }
            }
        }
    }
    for item in Parser.parse(source: source).statements { if let d = item.item.as(DeclSyntax.self) { walkDecl(d) } }
    return out
}
