// GENERATED ONCE from a measurement of the branch point (candor-swift cf4557c) by tools/identity-matrix.py, then the target column
// was added by hand from DESIGN.md §5.2/§5.3. Format: see TypeIdentityHarness.cells. Re-pin with tools/identity-matrix.py.

enum TypeIdentityCells {
    static let fx3 = """
N.n_nested WRITES -+U|-+U|ABSENT l5 -+inv|Fs|-+U+inv ^l2 -+U+inv|-+U|-+inv
N.n_nested_ctor WRITES -+U|-+U|ABSENT l5 -+inv|Fs|-+U+inv ^l2 -+U+inv|-+U|-+U+inv
N.n_nested_own pure -+U|-+U|ABSENT
N.t_twin WRITES -+U|-+U|-+U
N.t_twin_ann WRITES Fs+inc|Fs+inc|Fs+inc
N.r73_ctor WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv
N.r73_ctor_ann WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv
N.n_live WRITES -+inv|Fs+inc|-+inv
"""

    static let fx4 = """
Holder.h_ann_lib WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
Holder.h_ctor_lib WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
Holder.h_ann_vault WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
Holder.h_ctor_vault WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
Holder.h_qann_lib WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
Holder.h_qctor_lib WRITES -+U|-+U|ABSENT l3 -+inv|Fs|-+U+inv
Holder.h_alias_lib WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
Holder.h_own_nested pure ABSENT|ABSENT|ABSENT
Holder.h_mirror_kit pure Fs+inc|Fs+inc|Fs+inc l3 -+inv|-|-+inv
C.l_ann_lib WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
C.l_ctor_lib WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
C.l_ann_vault WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
C.l_ctor_vault WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
C.l_qann_lib WRITES -+inv|-|-+inv l2 -+inv|Fs|-+inv
C.l_qctor_lib WRITES -+inv|-|-+inv l2 -+inv|Fs|-+inv
C.l_alias_lib WRITES -+inv|ABSENT|-+inv l2 -+inv|Fs|-+inv
C.l_fac_lib WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv # L2: `mkLib`'s body `Lib()` is a use-unit spelling (+inv propagates); the RETURN binding is L3's
C.l_fac_vault WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv
C.l_upper_lib WRITES -|-|-+inv ^l2 -+inv|-|-+inv
C.l_inline_lib WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
C.l_inline_vault WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
C.l_closure_lib WRITES -+U|-+U|-+U l3 -+inv|Fs|-+U+inv ^l2 -+U+inv|-+U|-+U+inv # L2: `withLib`'s body `f(Lib())` is a use-unit spelling (+inv propagates); the T4 closure-parameter binding is unchanged
C.l_closure_named WRITES -+U|-+U|-+U l3 -+inv|Fs|-+U+inv ^l2 -+U+inv|-+U|-+U+inv
C.l_generic WRITES -|-|- l3 -+U/-+inv|Fs|-+U/-+inv ^l2 -+inv|-|-+inv # moved from l2 (lane L2 premise check): the dispatch is `GB.run`'s `v.wipeLib` over `Wiper` conformers, and the conformer is `extension Lib: Wiper {}` — a DECLARATION-scope binder (which Lib it extends), not a use-unit spelling; fx5 (no collision) reads -+U chained too
C.l_own_nested pure ABSENT|ABSENT|ABSENT
C.l_mirror_kit pure Fs+inc|Fs+inc|Fs+inc l2 -+inv|-|-+inv
C.g_ann_lib_c WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv # L2: the global's own initializer `Lib()` is a use-unit spelling (Guess.Lib, +inv); the BINDING `g.wipeLib` is L3's and still edges Core's Lib.wipeLib
C.g_ctor_lib_c WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv
C.g_ann_vault_c WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv
C.g_ctor_vault_c WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv
C.g_qann_lib_c WRITES -+inv|-|-+inv l3 -+inv|Fs|-+inv
C.g_qctor_lib_c WRITES -+U+inv|-+U|-+inv l3 -+inv|Fs|-+inv
C.g_alias_lib_c WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs|-+inv
C.g_fac_lib_c WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv
C.g_upper_lib_c WRITES -|-|-+inv ^l2 -+inv|-|-+inv
C.g_own_nested_c pure ABSENT|ABSENT|ABSENT
C.g_mirror_kit_c pure Fs+inc|Fs+inc|Fs+inc l3 -+inv|-|-+inv ^l2 Fs+inv+inc|Fs+inc|Fs+inv+inc
C.live WRITES -+inv|Fs+inc|-+inv
NI.ni_global_ctor WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv ^l2 -+inv|ABSENT|-+inv
NI.ni_global_qann WRITES -+inv|-|-+inv l3 -+inv|Fs|-+inv
NI.ni_field_qann WRITES -+inv|-|-+inv l3 -+inv|Fs|-+inv
Holder.niQann WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
Holder.niCtor WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
"""

    static let fx5 = """
Holder.h_ann_lib WRITES -+U|Fs+inc|-+U
Holder.h_ctor_lib WRITES -+U|Fs+inc|-+U
Holder.h_ann_vault WRITES -+inv|Fs+inc|-+inv
Holder.h_ctor_vault WRITES -+inv|Fs+inc|-+inv
Holder.h_qann_lib WRITES -+U|Fs+inc|-+U
Holder.h_qctor_lib WRITES -+U|-+U|ABSENT
Holder.h_alias_lib WRITES -+U|Fs+inc|-+U
Holder.h_own_nested pure ABSENT|ABSENT|ABSENT
Holder.h_mirror_kit pure -+inv|-|-+inv
C.l_ann_lib WRITES -+U|Fs+inc|-+U
C.l_ctor_lib WRITES -+U|Fs+inc|-+U
C.l_ann_vault WRITES -+inv|Fs+inc|-+inv
C.l_ctor_vault WRITES -+inv|Fs+inc|-+inv
C.l_qann_lib WRITES -+U+inv|Fs+inc|-+U+inv
C.l_qctor_lib WRITES -+U+inv|Fs+inc|-+U+inv
C.l_alias_lib WRITES -+U+inv|Fs+inc|-+U+inv
C.l_fac_lib WRITES -+U|Fs+inc|-+U
C.l_fac_vault WRITES -+inv|Fs+inc|-+inv
C.l_upper_lib WRITES -|-|-+inv
C.l_inline_lib WRITES -+U|Fs+inc|-+U
C.l_inline_vault WRITES -+inv|Fs+inc|-+inv
C.l_closure_lib WRITES -+U|-+U|-+U
C.l_closure_named WRITES -+U|-+U|-+U
C.l_generic WRITES -+U|-+U|-+U
C.l_own_nested pure ABSENT|ABSENT|ABSENT
C.l_mirror_kit pure -+inv|-|-+inv
C.g_ann_lib_c WRITES -+U|Fs+inc|-+U
C.g_ctor_lib_c WRITES -+U|Fs+inc|-+U
C.g_ann_vault_c WRITES -+inv|Fs+inc|-+inv
C.g_ctor_vault_c WRITES -+inv|Fs+inc|-+inv
C.g_qann_lib_c WRITES -+U+inv|Fs+inc|-+U+inv
C.g_qctor_lib_c WRITES -+U+inv|-+U|-+inv
C.g_alias_lib_c WRITES -+U+inv|Fs+inc|-+U+inv
C.g_fac_lib_c WRITES -+U|Fs+inc|-+U
C.g_upper_lib_c WRITES -|-|-+inv
C.g_own_nested_c pure ABSENT|ABSENT|ABSENT
C.g_mirror_kit_c pure -+inv|-|-+inv
C.live WRITES -+inv|Fs+inc|-+inv
NI.ni_global_ctor WRITES -+U|-+U|-+U
NI.ni_global_qann WRITES -+inv|-|-+inv
NI.ni_field_qann WRITES -+inv|-|-+inv
Holder.niQann WRITES ABSENT|ABSENT|ABSENT
Holder.niCtor WRITES -+U|-+U|-+U
"""

    static let fx5nw = """
Holder.h_ann_lib WRITES -+inv|Fs+inc|-+inv
Holder.h_ctor_lib WRITES -+inv|Fs+inc|-+inv
Holder.h_ann_vault WRITES -+inv|Fs+inc|-+inv
Holder.h_ctor_vault WRITES -+inv|Fs+inc|-+inv
Holder.h_qann_lib WRITES -+inv|Fs+inc|-+inv
Holder.h_qctor_lib WRITES -+inv|Fs+inc|ABSENT
Holder.h_alias_lib WRITES -+inv|Fs+inc|-+inv
Holder.h_own_nested pure ABSENT|ABSENT|ABSENT
Holder.h_mirror_kit pure -+inv|-|-+inv
C.l_ann_lib WRITES -+inv|Fs+inc|-+inv
C.l_ctor_lib WRITES -+inv|Fs+inc|-+inv
C.l_ann_vault WRITES -+inv|Fs+inc|-+inv
C.l_ctor_vault WRITES -+inv|Fs+inc|-+inv
C.l_qann_lib WRITES -+inv|Fs+inc|-+inv
C.l_qctor_lib WRITES -+inv|Fs+inc|-+inv
C.l_alias_lib WRITES -+inv|Fs+inc|-+inv
C.l_fac_lib WRITES -+inv|Fs+inc|-+inv
C.l_fac_vault WRITES -+inv|Fs+inc|-+inv
C.l_upper_lib WRITES -+inv|-|-+inv
C.l_inline_lib WRITES -+inv|Fs+inc|-+inv
C.l_inline_vault WRITES -+inv|Fs+inc|-+inv
C.l_closure_lib WRITES -+U+inv|-+U|-+U+inv
C.l_closure_named WRITES -+U+inv|-+U|-+U+inv
C.l_own_nested pure ABSENT|ABSENT|ABSENT
C.l_mirror_kit pure -+inv|-|-+inv
C.g_ann_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_ctor_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_ann_vault_c WRITES -+inv|Fs+inc|-+inv
C.g_ctor_vault_c WRITES -+inv|Fs+inc|-+inv
C.g_qann_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_qctor_lib_c WRITES -+U+inv|-+U|-+inv
C.g_alias_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_fac_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_upper_lib_c WRITES -+inv|-|-+inv
C.g_own_nested_c pure ABSENT|ABSENT|ABSENT
C.g_mirror_kit_c pure -+inv|-|-+inv
C.live WRITES -+inv|Fs+inc|-+inv
NI.ni_global_ctor WRITES -+inv|ABSENT|-+inv
NI.ni_global_qann WRITES -+inv|-|-+inv
NI.ni_field_qann WRITES -+inv|-|-+inv
Holder.niQann WRITES ABSENT|ABSENT|ABSENT
Holder.niCtor WRITES ABSENT|ABSENT|ABSENT
"""

    static let fx6 = """
TA.a_data_ann WRITES ABSENT ls Fs
TA.a_data_ctor WRITES ABSENT ls Fs
TB.b_data_ann WRITES ABSENT ls Fs
TB.b_data_ctor WRITES ABSENT ls Fs
TB.b_own_nested pure ABSENT
TC.c_bytes_ann WRITES ABSENT ls Fs # the brief's "fabrication control": same defect class in Pkg6 (Gen's nested Data shadows ToolC too)
"""

    static let fx6c = """
TA.a_data_ann WRITES Fs+inc
TA.a_data_ctor WRITES Fs+inc
TB.b_data_ann WRITES Fs+inc
TB.b_data_ctor WRITES Fs+inc
TB.b_own_nested pure ABSENT
TC.c_bytes_ann WRITES Fs+inc
"""

    static let fx7 = """
H.b3r WRITES Fs+inc
S6.s6_sib WRITES Fs+inc
Sub.inh_nested WRITES Fs+inc
Sub2.inh_shared WRITES Fs+inc
Pure.other_knob pure ABSENT
"""

    static let fx8 = """
A8.a_ext WRITES -+inv|Fs+inc|-+inv
A8.a_live WRITES -+inv|Fs+inc|-+inv
B8.b_ext WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs|-+inv
B8.b_ext_quiet pure -+inv|ABSENT|-+inv
B8.b_own WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs|-+inv
"""

    static let f1 = """
A.a_dep WRITES -+U+inv|-+U l5 -+inv|Fs
A.a_quiet pure -+U|-+U
A.a_store WRITES -+U|-+U
A.a_store_ann WRITES Fs+inc|Fs+inc
A.a_ov WRITES -+U|-+U
A.a_stat pure -+U|-+U
A.a_inst WRITES -+U|-+U
A.a_sub WRITES -+U|-+U
A.a_boxed WRITES -+U|-+U
A.a_any WRITES -+U|-+U
A.a_shadow_loud WRITES Fs+inc|Fs+inc
A.a_param_loud WRITES Fs+inc|Fs+inc
A.a_closure_loud WRITES Fs+inc|Fs+inc
A.a_live WRITES -+inv|Fs+inc
H.h_write WRITES Fs+U+inc|Fs+U+inc
H.h_scribble WRITES Fs+U+inc|Fs+U+inc
H.h_hush pure -+U|-+U
"""

    static let f2 = """
F.f_dep WRITES -+U|-+U l5 -+inv|Fs ^l2 -+U+inv|-+U
F.f_live WRITES -+inv|Fs+inc
"""

    static let r = """
Msg.c_coll WRITES ABSENT|ABSENT l3 -+inv|Fs
Msg.c_coll_self WRITES ABSENT|ABSENT l3 -+inv|Fs
Msg.c_own pure ABSENT|ABSENT
Msg.c_cv WRITES Fs+inc|Fs+inc
Msg.c_mk WRITES -+U|-+U
Msg.c_ta WRITES -+inv|Fs+inc
Msg.c_bare WRITES -+inv|Fs+inc
Msg.c_static WRITES -+inv|Fs+inc
Msg.c_static_self WRITES -+inv|Fs+inc
Msg.c_ext_noimport WRITES ABSENT|-+U l3 -+inv|Fs
Msg.c_ext_coll WRITES ABSENT|ABSENT l3 -+inv|Fs
Msg2.c_tcoll WRITES -+U|-+U l3 -+inv|Fs
Msg2.c_tcoll_self WRITES ABSENT|ABSENT l3 -+inv|Fs
Msg2.c_acoll WRITES ABSENT|ABSENT l3 -+inv|Fs
Msg2.c_ann_bare WRITES -+inv|Fs+inc
Msg2.c_local_mk WRITES -+inv|-
Msg2.c_ann_noimport WRITES ABSENT|ABSENT l3 -+inv|Fs
Msg2.c_tcoll_noimport WRITES ABSENT|-+U l3 -+inv|Fs
Msg3.c_reexport WRITES -+U|-+U
Msg3.c_reexport_ext WRITES -+U|-+U
Msg3.c_aliascoll WRITES -+U|-+U
Msg3.c_genalias WRITES -+inv|Fs+inc
Msg3.c_scoped_import WRITES -+inv|Fs+inc
GBox.c_genparam WRITES -+U|-+U
"""

    static let rp = """
GBox2.c_genparam2 WRITES -+inv|Fs+inc
Msg4.c_platname WRITES -+inv|Fs+inc
Msg4.c_ctrl WRITES -+inv|Fs+inc
"""

    static let rl = """
Msg.s_bare WRITES -+inv|Fs+inc
Msg.s_self WRITES -+inv|Fs+inc
Msg.s_let WRITES -+inv|Fs+inc
Msg.s_pure pure -+inv|-
Msg.s_own WRITES Fs+inc|Fs+inc
Msg.s_ownpure pure ABSENT|ABSENT
Msg.s_nest WRITES Fs+inc|Fs+inc
Msg.s_init WRITES -+inv|Fs+inc
Msg.s_gen WRITES -+U|-+U
Msg.s_opt WRITES -+inv|Fs+inc
Msg.s_comp WRITES -+inv|Fs+inc
Msg.s_fac WRITES -+U|-+U
Msg.s_kind WRITES -+U|-+U
Msg.s_shadow_local pure -+inv|-
Msg.s_shadow_param pure -+inv|-
Msg.s_closure WRITES -+inv|Fs+inc
Msg.s_ext WRITES -+inv|Fs+inc
Derived.s_inherit WRITES -+U|-+U
DerivedDep.s_inheritdep WRITES -+U|-+U
GenOwner.s_genowner WRITES -+inv|Fs+inc
Msg.s_dkind WRITES -+U|-+U
Msg.s_mk WRITES -+U|-+U
ODerived.s_oinh WRITES Fs+inc|Fs+inc
ODerived.s_ainh WRITES -+U|-+U
ODerived.s_qinh WRITES Fs+inc|Fs+inc
ODerived.s_qinh_self WRITES Fs+inc|Fs+inc
Msg.s_iuo WRITES -+U|-+U
Msg.s_iuo_self WRITES ABSENT|ABSENT
Msg.s_iuo_pure pure -+U|-+U
Msg.s_b1 WRITES -+U|-+U
Msg.s_b2 WRITES -+U|-+U
Msg.s_b3 WRITES ABSENT|-+U l3 -+inv|Fs
Msg.s_b3_tc WRITES ABSENT|-+U l3 -+inv|Fs
"""

    static let rlog2 = """
Svc.c_log LOGS Log+inv|Fs+Log|-+U
Svc.c_alog LOGS Log+inv|Fs+Log|Log+inv
Svc.c_local LOGS Log+inv|Fs+Log|Log+inv
"""

    static let fx9 = """
U9.s1s12_ann WRITES ABSENT|ABSENT|ABSENT ls Fs|Fs|Fs
U9.s1s12_ctor WRITES ABSENT|ABSENT|ABSENT ls Fs|Fs|Fs
U9.s1s12_inline WRITES ABSENT|ABSENT|ABSENT ls Fs|Fs|Fs
U9.s12_url_ann TOUCHES ABSENT|ABSENT|ABSENT ls Fs|Fs|Fs
U9.s12_url_ctor TOUCHES ABSENT|ABSENT|ABSENT ls Fs|Fs|Fs
U9.s12_result_get pure Fs+inc|Fs+inc|Fs+inc ls ABSENT/-|ABSENT/-|ABSENT/-
UF9.s12_file_ann WRITES ABSENT|ABSENT|ABSENT ls Fs|Fs|Fs
UF9.s12_file_ctor WRITES ABSENT|ABSENT|ABSENT ls Fs|Fs|Fs
UF9.live WRITES -+inv|Fs+inc|-+inv
"""

    static let fx9r = """
Outer9.r_nested pure ABSENT
Outer9.r_nested_ann pure ABSENT
Outer9.r_qualified WRITES ABSENT l2 Fs
Sub9.r_super pure ABSENT
Plain9.p_data WRITES ABSENT ls Fs
"""

    static let fx10 = """
SubOther.inh_other_module WRITES Fs+inc|Fs+inc|Fs+inc
SubOther.inh_other_pure pure ABSENT|ABSENT|ABSENT
SubDep.inh_dependency WRITES -+inv|Fs+inc|-+inv
SubDep.inh_dep_pure pure -+inv|-|-+inv
SubGen.inh_generic WRITES Fs+inc|Fs+inc|Fs+inc
SubGen.inh_generic_pure pure ABSENT|ABSENT|ABSENT
Conf10.alias_conformance WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
Conf10.alias_conformance_pure pure -+inv|ABSENT|-+inv
M10.assoc_witness pure Fs+inc|Fs+inc|Fs+inc l4 ABSENT/-|ABSENT/-|ABSENT/-
Ext10.s13_ext_nested WRITES Fs+inc|Fs+inc|Fs+inc
Ext10.s13_ext_pure pure -|-|-
Ext10.live WRITES -+inv|Fs+inc|-+inv
"""

    static let fx11 = """
Holder11.a_field WRITES -+inv|Fs+inc|-+inv
Holder11.a_live WRITES -+inv|Fs+inc|-+inv
B11.b_ext_field WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs|-+inv
B11.b_ext_factory WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs|-+inv
B11.b_ext_local WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs|-+inv
B11.b_ext_quiet pure -+inv|ABSENT|-+inv
B11.b_own_field WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs|-+inv
Holder11.b_ext_self WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
HolderMi.mi_ext WRITES -+inv|Fs+inc|-+inv
HolderMi.mi_ext_quiet pure -+inv|-|-+inv
HolderMi.mi_own WRITES -+inv|Fs+inc|-+inv
BMi.mi_b_ext WRITES -+inv|Fs+inc|-+inv
BMi.mi_b_ext_quiet pure -+inv|-|-+inv
"""

    // fx12 (lane LS): binder shapes (as!, optional annotation, `N.init`), rebinds that must not inherit the platform reading, the
    // refusals (visible nested, visible module top level, body-local, foreign superclass) and the platform-name F-B3r analogue
    // (a FIELD typed Core12.Data in a file importing Core12, used from a file that does not import it).
    static let fx12 = """
Outer12.inner_nested pure ABSENT # LS refusal: visible nested Outer12.Data (main binds Core12's Data.write: pre-existing, L2/L4)
O12.as_cast WRITES ABSENT ls Fs
O12.opt_ann WRITES ABSENT ls Fs
O12.static_init WRITES ABSENT ls Fs
O12.rebind_for pure ABSENT
O12.rebind_closure pure ABSENT
O12.rebind_block WRITES ABSENT ls Fs
String.fe_data WRITES ABSENT ls Fs # a platform enclosing type whose nested types the generated table lists
L12.body_local pure ABSENT # LS refusal: a body-local Data
Sp12.sp_data WRITES ABSENT # LS refusal: a superclass the scan does not declare (NSObject); pre-existing silence, L4
Plain12.pe_data WRITES ABSENT ls Fs # an extension of a scan protocol with no member named Data
Conf12.ce_data WRITES ABSENT ls Fs # a conformer of that protocol and of `Swift.Error` (a qualified platform supertype)
Wit12.w_data pure ABSENT # LS refusal: the conformer's member alias Data = Quiet12
Wit12b.wb_data pure ABSENT # LS refusal: an associated type Data (default Quiet12) through a refinement
H12.own_top WRITES Fs+inc
H12.own_top_pure pure ABSENT
H12.b3r_plat WRITES Fs+inc # field: must not move
H12.b3r_plat_pure pure ABSENT # field: must not move (a platform reading would fabricate Fs)
H12.b3r_copy WRITES Fs+inc
H12.b_found WRITES ABSENT ls Fs
"""

    // fx13 (Fable's merge review of lane LS, B1): a nested `Data` declared in a MODULE-QUALIFIED extension of the enclosing type
    // (`extension Own13.Outer13 { struct Data }`, another file) is what bare `Data` names inside `Outer13`. Both directions pinned: the
    // pure member is the fabrication control, the loud one the silence control; `Outer13b` is the unqualified twin, `Sub13` the
    // module-qualified SUPERCLASS spelling. `Q13.q_url` is the pre-existing module-wide nested-alias fallback (not LS's), pinned at main.
    static let fx13 = """
Outer13.a_pure pure ABSENT
Outer13.a_loud WRITES Fs+inc
Outer13.a_inline WRITES Fs+inc
Outer13b.b_pure pure ABSENT
Outer13b.b_loud WRITES Fs+inc
C13.c_alias pure ABSENT
Q13.q_url TOUCHES ABSENT # pre-existing: `S13.URL = QuietURL13` binds every bare URL (aliasInScope's module-wide fallback); not LS
Sub13.s_pure pure ABSENT
Sub13.s_loud WRITES Fs+inc
Plain13.p_data WRITES ABSENT ls Fs
"""

    // fx15 (Fable's recheck of lane LS round 2, B2): the own module `Own15` shares its name with a TOP-LEVEL type of a sibling target
    // the file does not import (`Core15: struct Own15`). `extension Own15.Outer15 { struct Data }` is still module-qualified (Swift's
    // shadowing is per file), so inside `Outer15` bare `Data` is that type: the pure member is the fabrication control, the loud one
    // the silence control, `Plain15` the payoff that must stay `Fs`.
    static let fx15 = """
Outer15.a_pure pure ABSENT
Outer15.a_loud WRITES Fs+inc
Plain15.p_data WRITES ABSENT ls Fs
"""

    // fx16 (lane L2): use-unit spellings of names a NON-imported sibling target (Core16) declares, with NO conformance on the
    // dependency type (so no protocol hedge stands in for the binding in `un`/`unr`): B1 direction (scan pure, dependency loud) beside
    // every mirror (scan loud, dependency pure), the scan's extension of the dependency type (must keep its edge), qualified and alias
    // spellings; R1950's innermost nested type in both directions and two levels deep; R1947's qualified platform name inside a type
    // nesting the same name, both directions.
    static let fx16 = """
U16.s1_ann WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
U16.s1_inline WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
U16.s1_as WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
U16.s1_ext WRITES Fs+inc|Fs+inc|Fs+inc ^l2 Fs+inv+inc|Fs+inc|Fs+U+inv+inc # the scan's extension of Dep16.Lib16 keeps its edge
U16.s1_ext_quiet pure ABSENT|ABSENT|ABSENT ^l2 -+inv|ABSENT|-+U+inv # pure twin of s1_ext (unique name): constructs Dep16.Lib16 (+inv)
U16.s2_nested WRITES ABSENT|ABSENT|ABSENT l2 -+inv|Fs|-+U+inv
U16.s3_qual WRITES -+inv|-|-+inv l2 -+inv|Fs|-+U+inv
U16.s3_qual_ann WRITES -+inv|-|-+inv l2 -+inv|Fs|-+U+inv
U16.s5_alias WRITES -+inv|ABSENT|-+inv l2 -+inv|Fs|-+U+inv
U16.m_kit pure Fs+inc|Fs+inc|Fs+inc l2 -+inv|-|-+U+inv
U16.m_kit_inline pure Fs+inc|Fs+inc|Fs+inc l2 -+inv|-|-+U+inv
U16.live WRITES -+inv|Fs+inc|-+inv
Outer16.s4_own pure ABSENT|ABSENT|ABSENT
Outer16a.r_inner_loud WRITES ABSENT|ABSENT|ABSENT l2 Fs|Fs|Fs
Outer16a.r_inner_inline WRITES ABSENT|ABSENT|ABSENT l2 Fs|Fs|Fs
Outer16b.r_inner_pure pure Fs+inc|Fs+inc|Fs+inc l2 ABSENT|ABSENT|ABSENT
Outer16b.r_top_loud pure Fs+inc|Fs+inc|Fs+inc l2 ABSENT|ABSENT|ABSENT
Plain16.r_plain_top WRITES Fs+inc|Fs+inc|Fs+inc
Outer16c.Mid16.r_mid_pure pure Fs+inc|Fs+inc|Fs+inc l2 ABSENT|ABSENT|ABSENT
Outer16c.r_outer_loud WRITES Fs+inc|Fs+inc|Fs+inc
Outer16d.q_found_pure pure Fs+inv+inc|Fs+inc|Fs+inv+inc l2 -+inv|-|-+inv
Outer16d.q_nested_loud WRITES Fs+inv+inc|Fs+inc|Fs+inv+inc
Outer16d.q_found_write WRITES -+inv|-|-+inv l2 Fs|Fs|Fs
Outer16e.q_dep WRITES -+inv|-|-+inv l2 -+inv|Fs|-+U+inv
Outer16e.q_nested_pure pure ABSENT|ABSENT|ABSENT
U16.implicit_member WRITES Fs+inc|Fs+inc|Fs+inc ^l2 Fs+inv+inc|Fs+inc|Fs+U+inv+inc # control: an implicit member typed `Outer16g.Gear16` beside a bare (Dep16) `Gear16`
Ext16Use.q_own_loud WRITES Fs+inc|Fs+inc|Fs+inc # control: `Feat16.Pipe16()` — an OWN module qualifier is never "as if undeclared"
Outer16f.r_unseen_nested pure ABSENT|ABSENT|ABSENT # R1950 control: Ext16 nests a LOUD `Outer16f.Tank16` from a module Feat16 does not import
"""

}
