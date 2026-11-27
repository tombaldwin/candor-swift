import XCTest
import Foundation

/// SOUNDNESS R1938 (lane L0) — the type-identity attack matrix as process tests. Each test stages a fixture package tree, scans it
/// with the BUILT binary standalone / chained / with an unreadable dependency, and asserts every executed cell against the table
/// in `TypeIdentityCells` (see `TypeIdentityHarness` for the format, the `main`/`target` columns and the lane flags).
///
/// This lane changes no engine behaviour: every assertion below is a measurement of the branch point. The cells whose `target`
/// differs from `main` are the later lanes' acceptance tests — `TypeIdentityTargetCalibrationTests` proves they can fail.
final class TypeIdentityMatrixTests: XCTestCase {
    typealias H = TypeIdentityHarness
    typealias E = TypeIdentityHarness.EdgePin
    typealias X = TypeIdentityFixtures

    private func matrix(_ f: H.Fixture, _ label: String, edges: [E] = [], file: StaticString = #filePath, line: UInt = #line) throws {
        let st = try H.stage(Self.self); defer { st.cleanup() }
        let arms = try H.run(f, in: st, label: label, file: file, line: line)
        H.checkEdges(edges, arms.un, label: label + " (un)", file: file, line: line)
        if !f.deps.isEmpty { H.checkEdges(edges, arms.ch, label: label + " (ch)", file: file, line: line) }
    }

    /// A = fx4. The §5.4 pure controls are pinned by their sidecar edge, because their member name is shared with the loud type. The
    /// three mirror cells (the scan's `Kit` is LOUD, Guess's is pure and is what Swift calls) must move OFF the scan's `Kit`.
    func testFx4_A() throws {
        try matrix(X.fx4, "fx4", edges: [
            E("C.l_own_nested", has: ["Outer.Vault.init", "Outer.Vault.wipeVault"]),
            E("Holder.h_own_nested", has: ["Outer.Vault.wipeVault"]),
            // `g_own_nested_c`'s member was renamed to a name NO other type has: the call is DROPPED on main (only the global is an edge)
            E("C.g_own_nested_c", has: ["g_own_nested"], hasNot: ["Outer.Vault.quietOuterVault"], lane: .l3, targetHas: ["Outer.Vault.quietOuterVault"]),
            E("C.l_mirror_kit", has: ["Kit.tapKit"], lane: .l2, targetHasNot: ["Kit.tapKit"]),
            E("C.g_mirror_kit_c", has: ["Kit.tapKit"], lane: .l3, targetHasNot: ["Kit.tapKit"]),
            E("Holder.h_mirror_kit", has: ["Kit.tapKit"], lane: .l3, targetHasNot: ["Kit.tapKit"]),
        ])
    }
    /// fx5 = fx4 with the scan's nested `Vault` renamed `Vlt`; fx5nw = fx5 without the `Wiper` conformance (the clean prediction).
    func testFx5_control() throws { try matrix(X.fx5, "fx5", edges: [E("C.l_own_nested", has: ["Outer.Vlt.init", "Outer.Vlt.wipeVault"])]) }
    func testFx5nw_control() throws {
        try matrix(X.fx5nw, "fx5nw", edges: [E("C.l_own_nested", has: ["Outer.Vlt.init", "Outer.Vlt.wipeVault"]),
                                             E("C.g_own_nested_c", has: ["g_own_nested"], hasNot: ["Outer.Vlt.quietOuterVault"])])
    }
    func testFx3_F3() throws { try matrix(X.fx3, "fx3") }

    /// B: a nested `Data` ANYWHERE in the package makes every bare `Data(...)` read as the scan's. The sidecar shows the UNION
    /// `Node.Data.*` + `Outer.Data.*`; the control `fx6c` renames the nested types and reads `Fs`.
    func testFx6_B_nestedDataShadow() throws {
        let both = ["Node.Data.write", "Outer.Data.write"]
        try matrix(X.fx6, "fx6", edges: [
            E("TB.b_own_nested", has: ["Outer.Data.write"]),
            E("TA.a_data_ann", has: both, lane: .ls, targetHasNot: both), E("TA.a_data_ctor", has: both, lane: .ls, targetHasNot: both),
            E("TB.b_data_ann", has: both, lane: .ls, targetHasNot: both), E("TB.b_data_ctor", has: both, lane: .ls, targetHasNot: both),
        ])
    }
    func testFx6c_B_control() throws { try matrix(X.fx6c, "fx6c", edges: [E("TB.b_own_nested", has: ["Outer.Datum.write"])]) }

    /// F7 = Fable fx7. `H.b3r` (a field typed in a file that imports Core, called from a file with no imports) and `S6.s6_sib` must
    /// not move in L2 or LS; the inherited-nested rows are L4's.
    func testFx7_F7() throws {
        try matrix(X.fx7, "fx7", edges: [
            E("H.b3r", has: ["Lib.wipeLib"]), E("S6.s6_sib", has: ["Lib.init", "Lib.wipeLib"]),
            E("Sub.inh_nested", has: ["Base.Cfg.init", "Base.Cfg.wipeCfg"]),
            E("Sub2.inh_shared", has: ["Base2.Knob.turnKnob", "Other.Knob.turnKnob"], lane: .l4, targetHas: ["Base2.Knob.turnKnob"], targetHasNot: ["Other.Knob.turnKnob"]),
            E("Pure.other_knob", has: ["Other.Knob.turnKnob"]),
        ])
    }
    /// C = fx8: the B3 extension member. `A8.a_ext` is the importing-file control; `B8.b_ext_quiet` is pinned by its unique member name.
    func testFx8_C_b3ExtensionMember() throws { try matrix(X.fx8, "fx8") }
    func testF1_F2_R1931() throws {
        try matrix(X.f1, "F1")
        try matrix(X.f2, "F2")
    }
    func testR_Rp_RL_R1896() throws {
        try matrix(X.r, "R")
        try matrix(X.rp, "Rp")
        try matrix(X.rl, "RL")
    }
    /// Rlog2: `Logging.Logger(label:)` through a RELATIVE `.package(path:)` — SOUNDNESS R1896 round 2's lost fixture.
    func testRlog2() throws { try matrix(X.rlog2, "Rlog2") }

    /// fx9: S1xS12 (a TOP-LEVEL `Data` in a sibling target the use file does not import), S12 for `URL`, `File` and `Result.get()`.
    /// `s12_result_get` is a REMOVAL cell: Swift's `Result.get()` is pure (executed), the scan's nested one writes.
    func testFx9_S12() throws {
        try matrix(X.fx9, "fx9", edges: [
            E("U9.s1s12_ann", has: ["Data.write"], lane: .ls, targetHasNot: ["Data.write"]),
            E("U9.s1s12_ctor", has: ["Data.write"], lane: .ls, targetHasNot: ["Data.write"]),
            E("U9.s1s12_inline", has: ["Data.write"], lane: .ls, targetHasNot: ["Data.write"]),
            E("U9.s12_url_ann", has: ["URL.checkResourceIsReachable"], lane: .ls, targetHasNot: ["URL.checkResourceIsReachable"]),
            E("U9.s12_result_get", has: ["Node9.Result.get"], lane: .ls, targetHasNot: ["Node9.Result.get"]),
            E("UF9.s12_file_ann", has: ["Node9.File.write"], lane: .ls, targetHasNot: ["Node9.File.write"]),
        ])
    }
    /// fx9r: the LS REFUSAL cells — where Swift's own scope DOES see a nested `Data`, the scan type is the right binding.
    func testFx9r_LSRefusal() throws {
        try matrix(X.fx9r, "fx9r", edges: [
            E("Outer9.r_nested", has: ["Outer9.Data.write"]), E("Outer9.r_nested_ann", has: ["Outer9.Data.write"]),
            E("Sub9.r_super", has: ["Base9.Data.write"]),
        ])
    }
    /// fx10: the L4 rows. Every pure twin has a UNIQUE member name and is also pinned by its edge.
    func testFx10_L4Rows() throws {
        try matrix(X.fx10, "fx10", edges: [
            E("SubOther.inh_other_module", has: ["OBase10.Cfg10.wipeCfg10"]), E("SubOther.inh_other_pure", has: ["OBase10.Calm10.calm10"]),
            E("SubGen.inh_generic", has: ["GBase10.GCfg10.wipeG10"]), E("SubGen.inh_generic_pure", has: ["GBase10.GCalm10.calmG10"]),
            E("Conf10.alias_conformance", has: ["OtherHolder10.Handle10.wipeHandle10"], hasNot: ["LoudHandle10.wipeHandle10"], lane: .l4, targetHas: ["LoudHandle10.wipeHandle10"]),
            E("Conf10.alias_conformance_pure", has: ["CalmHandle10.calmHandle10"]),
            E("M10.assoc_witness", has: ["Item10.hushItem10"], hasNot: ["QuietItem10.hushItem10"], lane: .l4, targetHas: ["QuietItem10.hushItem10"], targetHasNot: ["Item10.hushItem10"]),
            E("Ext10.s13_ext_nested", has: ["Data.Chunk10.wipeChunk10"]), E("Ext10.s13_ext_pure", has: ["Data.CalmChunk10.calmChunk10"]),
        ])
    }
    /// fx11: the S7e variants of fx8 — an extension member reached through a field, a factory return and a local declared in the
    /// importing file, an extension of that file's type, and a target that enables MemberImportVisibility.
    func testFx11_S7eVariants() throws { try matrix(X.fx11, "fx11") }
    /// fx12 (lane LS): the inner binding of a rebind keeps its scan type and loses the platform ctor edge; a field keeps its
    /// declaration's type in a file that cannot see it; the refusals keep main's edges.
    /// fx13 (Fable merge review B1): the refusal must see an own path spelled with its module (`extension Own13.Outer13`,
    /// `class Sub13: Own13.Base13`). The scan type's edges stay; only `Plain13` (no nested Data) moves.
    func testFx13_ModuleQualifiedOwnPaths() throws {
        try matrix(X.fx13, "fx13", edges: [
            E("Outer13.a_pure", has: ["Own13.Outer13.Data.write"]), E("Outer13.a_loud", has: ["Own13.Outer13.Data.wipe13"]),
            E("Outer13.a_inline", has: ["Own13.Outer13.Data.wipe13"]),
            E("Outer13b.b_pure", has: ["Outer13b.Data.write"]), E("Outer13b.b_loud", has: ["Outer13b.Data.wipe13"]),
            E("Sub13.s_pure", has: ["Base13.Data.write"]), E("Sub13.s_loud", has: ["Base13.Data.wipe13"]),
            E("Plain13.p_data", has: ["Base13.Data.write"], lane: .ls, targetHasNot: ["Base13.Data.write", "Own13.Outer13.Data.write", "Outer13b.Data.write"]),
        ])
    }
    /// fx15 (Fable recheck B2): a module-qualified extension head whose module name some OTHER target uses for a top-level type is
    /// still stripped; the scan type's edges stay on `Outer15`, and only `Plain15` moves.
    func testFx15_ModuleNamedLikeASiblingType() throws {
        try matrix(X.fx15, "fx15", edges: [
            E("Outer15.a_pure", has: ["Own15.Outer15.Data.write"]), E("Outer15.a_loud", has: ["Own15.Outer15.Data.wipe15"]),
            E("Plain15.p_data", has: ["Own15.Outer15.Data.write"], lane: .ls, targetHasNot: ["Own15.Outer15.Data.write", "Own15.Data.write"]),
        ])
    }
    /// (R1950's constructor filter keeps a BARE-owner init beside the innermost one — `Store16.init` of the top-level type — since an
    /// `extension N { init }` head is recorded bare and cannot be told apart: an over-edge, never a loss.)
    /// fx16 (lane L2): every moved cell's edge is pinned — the dependency-typed cells lose the scan twin's edges, the extension member
    /// keeps its own, and each R1950 cell binds exactly the innermost nested type.
    func testFx16_L2UseUnitGuard() throws {
        try matrix(X.fx16, "fx16", edges: [
            E("U16.s1_ann", has: ["Lib16.init", "Lib16.wipe16"], lane: .l2, targetHasNot: ["Lib16.init", "Lib16.wipe16"]),
            E("U16.s1_inline", has: ["Lib16.wipe16"], lane: .l2, targetHasNot: ["Lib16.init", "Lib16.wipe16"]),
            E("U16.s1_as", has: ["Lib16.wipe16"], lane: .l2, targetHasNot: ["Lib16.wipe16"]),
            E("U16.s1_ext", has: ["Lib16.extWipe16"], lane: .l2, targetHas: ["Lib16.extWipe16"], targetHasNot: ["Lib16.init"]),
            E("U16.s1_ext_quiet", has: ["Lib16.extQuiet16"], lane: .l2, targetHas: ["Lib16.extQuiet16"]),
            E("U16.s2_nested", has: ["Outer16.Box16.seal16"], lane: .l2, targetHasNot: ["Outer16.Box16.init", "Outer16.Box16.seal16"]),
            E("U16.s3_qual", has: ["Lib16.wipe16"], lane: .l2, targetHasNot: ["Lib16.wipe16"]),
            E("U16.s5_alias", has: ["Lib16.wipe16"], lane: .l2, targetHasNot: ["Lib16.wipe16"]),
            E("U16.m_kit", has: ["Kit16.tap16"], lane: .l2, targetHasNot: ["Kit16.init", "Kit16.tap16"]),
            E("U16.m_kit_inline", has: ["Kit16.tap16"], lane: .l2, targetHasNot: ["Kit16.init", "Kit16.tap16"]),
            E("Outer16.s4_own", has: ["Outer16.Box16.init", "Outer16.Box16.seal16"]),
            E("Outer16a.r_inner_loud", has: ["Store16.put16"], lane: .l2, targetHas: ["Outer16a.Store16.init", "Outer16a.Store16.put16"], targetHasNot: ["Store16.put16"]),
            E("Outer16b.r_inner_pure", has: ["Pipe16.flow16"], lane: .l2, targetHas: ["Outer16b.Pipe16.flow16"], targetHasNot: ["Pipe16.flow16"]),
            E("Plain16.r_plain_top", has: ["Pipe16.init", "Pipe16.flow16"]),
            E("Outer16c.Mid16.r_mid_pure", has: ["Outer16c.Mid16.Knob16.turn16", "Outer16c.Knob16.turn16"], lane: .l2,
              targetHas: ["Outer16c.Mid16.Knob16.init", "Outer16c.Mid16.Knob16.turn16"], targetHasNot: ["Outer16c.Knob16.init", "Outer16c.Knob16.turn16"]),
            E("Outer16c.r_outer_loud", has: ["Outer16c.Knob16.turn16"], lane: .l2, targetHas: ["Outer16c.Knob16.turn16"], targetHasNot: ["Outer16c.Mid16.Knob16.turn16"]),
            E("Outer16d.q_found_pure", has: ["Outer16d.Data.append"], lane: .l2, targetHasNot: ["Outer16d.Data.append", "Outer16d.Data.init"]),
            E("Outer16d.q_nested_loud", has: ["Outer16d.Data.append"]),
            E("Outer16e.q_dep", has: ["Lib16.wipe16"], lane: .l2, targetHasNot: ["Lib16.wipe16", "Outer16e.Lib16.wipe16"]),
            E("Outer16e.q_nested_pure", has: ["Lib16.wipe16"], lane: .l2, targetHas: ["Outer16e.Lib16.init", "Outer16e.Lib16.wipe16"], targetHasNot: ["Lib16.wipe16"]),
            // the innermost rewrite must not reach a nested type declared by an extension in a module this file cannot see
            E("Outer16f.r_unseen_nested", has: ["Tank16.init", "Tank16.fill16"], hasNot: ["Outer16f.Tank16.fill16"]),
            E("U16.implicit_member", has: ["Outer16g.Gear16.make16"], lane: .l2, targetHas: ["Outer16g.Gear16.make16"], targetHasNot: ["Outer16g.Gear16.init"]),
            E("Ext16Use.q_own_loud", has: ["Pipe16.flow16"]),
        ])
    }
    func testFx12_LSAttack() throws {
        try matrix(X.fx12, "fx12", edges: [
            E("O12.rebind_for", has: ["Outer12.Data.write", "Node12.Data.init()"], lane: .ls, targetHas: ["Outer12.Data.write"], targetHasNot: ["Node12.Data.init()"]),
            E("O12.rebind_closure", has: ["Outer12.Data.write", "Node12.Data.init()"], lane: .ls, targetHas: ["Outer12.Data.write"], targetHasNot: ["Node12.Data.init()"]),
            E("O12.rebind_block", has: ["Outer12.Data.write", "Data.write"], lane: .ls, targetHas: ["Outer12.Data.write"], targetHasNot: ["Data.write"]),
            // `targetHasNot Quiet12.*`: with `Data` out of `localTypes`, the module-wide nested-alias fallback bound it to Wit12's
            // `typealias Data = Quiet12` until canonicalTypeRef was told the platform name answers itself (measured, fx12)
            E("O12.as_cast", has: ["Data.write"], lane: .ls, targetHasNot: ["Data.write", "Node12.Data.init(S)", "Quiet12.write", "Quiet12.init"]),
            E("Plain12.pe_data", has: ["Data.write"], lane: .ls, targetHasNot: ["Data.write", "Quiet12.write"]),
            E("Wit12.w_data", has: ["Data.write"]), E("Wit12b.wb_data", has: ["Data.write"]),
            E("H12.b_found", has: ["Data.write"], lane: .ls, targetHasNot: ["Data.write", "Node12.Data.init(S)"]),
            E("H12.own_top", has: ["Data.wipe12"]), E("H12.own_top_pure", has: ["Data.write"]),
            E("H12.b3r_plat", has: ["Data.wipe12"]), E("H12.b3r_plat_pure", has: ["Data.write"]), E("H12.b3r_copy", has: ["Data.wipe12"]),
            // R1950 (lane L2): inside `Outer12`, bare `Data` is the innermost nested `Outer12.Data`, not Core12's top-level key `Data`
            E("Outer12.inner_nested", has: ["Data.write"], lane: .l2, targetHas: ["Outer12.Data.init", "Outer12.Data.write"], targetHasNot: ["Data.write", "Node12.Data.init()"]),
            E("L12.body_local", has: ["Data.write"]), E("Sp12.sp_data", has: ["Data.write"]),
        ])
    }
}
