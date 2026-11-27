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
Holder.h_ann_lib WRITES ABSENT|ABSENT|ABSENT l3 -+inv/-+U|Fs|-+U+inv/-+U # L3: the one-variable control is fx5 (these sources with the collisions renamed, `extension Lib: Wiper` kept), which reads -+U standalone: `dispatch:Wiper.wipeLib`; the design's -+inv came from fx5nw, which also drops Wiper
Holder.h_ctor_lib WRITES ABSENT|ABSENT|ABSENT l3 -+inv/-+U|Fs|-+U+inv/-+U # L3: the one-variable control is fx5 (these sources with the collisions renamed, `extension Lib: Wiper` kept), which reads -+U standalone: `dispatch:Wiper.wipeLib`; the design's -+inv came from fx5nw, which also drops Wiper
Holder.h_ann_vault WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
Holder.h_ctor_vault WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv
Holder.h_qann_lib WRITES ABSENT|ABSENT|ABSENT l3 -+inv/-+U|Fs|-+U+inv/-+U # L3: the one-variable control is fx5 (these sources with the collisions renamed, `extension Lib: Wiper` kept), which reads -+U standalone: `dispatch:Wiper.wipeLib`; the design's -+inv came from fx5nw, which also drops Wiper
Holder.h_qctor_lib WRITES -+U|-+U|ABSENT l3 -+inv/-+U|Fs|-+U+inv # L3: fx5 reads -+U standalone (its own-field C12 hedge); unr is the identity:foreign arm
Holder.h_alias_lib WRITES ABSENT|ABSENT|ABSENT l3 -+inv/-+U|Fs|-+U+inv/-+U # L3: the one-variable control is fx5 (these sources with the collisions renamed, `extension Lib: Wiper` kept), which reads -+U standalone: `dispatch:Wiper.wipeLib`; the design's -+inv came from fx5nw, which also drops Wiper
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
Holder.niQann WRITES ABSENT|ABSENT|ABSENT l3 -+inv/-+U|Fs|-+U+inv/-+U # L3: the one-variable control is fx5 (these sources with the collisions renamed, `extension Lib: Wiper` kept), which reads -+U standalone: `dispatch:Wiper.wipeLib`; the design's -+inv came from fx5nw, which also drops Wiper
Holder.niCtor WRITES ABSENT|ABSENT|ABSENT l3 -+inv/-+U|Fs|-+U+inv/-+U # L3: the one-variable control is fx5 (these sources with the collisions renamed, `extension Lib: Wiper` kept), which reads -+U standalone: `dispatch:Wiper.wipeLib`; the design's -+inv came from fx5nw, which also drops Wiper
"""

    static let fx5 = """
Holder.h_ann_lib WRITES -+U|Fs+inc|-+U
Holder.h_ctor_lib WRITES -+U|Fs+inc|-+U
Holder.h_ann_vault WRITES -+inv|Fs+inc|-+inv
Holder.h_ctor_vault WRITES -+inv|Fs+inc|-+inv
Holder.h_qann_lib WRITES -+U|Fs+inc|-+U
Holder.h_qctor_lib WRITES -+U|-+U|ABSENT ^l3 -+U|-+U|-+U+inv
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
C.l_closure_lib WRITES -+U|-+U|-+U ^l3 -+U|Fs+U+inc|-+U
C.l_closure_named WRITES -+U|-+U|-+U ^l3 -+U|Fs+U+inc|-+U
C.l_generic WRITES -+U|-+U|-+U ^l3 -+U|Fs+inc|-+U
C.l_own_nested pure ABSENT|ABSENT|ABSENT
C.l_mirror_kit pure -+inv|-|-+inv
C.g_ann_lib_c WRITES -+U|Fs+inc|-+U
C.g_ctor_lib_c WRITES -+U|Fs+inc|-+U
C.g_ann_vault_c WRITES -+inv|Fs+inc|-+inv
C.g_ctor_vault_c WRITES -+inv|Fs+inc|-+inv
C.g_qann_lib_c WRITES -+U+inv|Fs+inc|-+U+inv
C.g_qctor_lib_c WRITES -+U+inv|-+U|-+inv ^l3 -+U+inv|Fs+inc|-+inv
C.g_alias_lib_c WRITES -+U+inv|Fs+inc|-+U+inv
C.g_fac_lib_c WRITES -+U|Fs+inc|-+U
C.g_upper_lib_c WRITES -|-|-+inv
C.g_own_nested_c pure ABSENT|ABSENT|ABSENT
C.g_mirror_kit_c pure -+inv|-|-+inv
C.live WRITES -+inv|Fs+inc|-+inv
NI.ni_global_ctor WRITES -+U|-+U|-+U ^l3 -+U|Fs+inc|-+U
NI.ni_global_qann WRITES -+inv|-|-+inv ^l3 -+U+inv|Fs+inc|-+U+inv
NI.ni_field_qann WRITES -+inv|-|-+inv ^l3 -+U+inv|Fs+inc|-+U+inv
Holder.niQann WRITES ABSENT|ABSENT|ABSENT ^l3 -+U|Fs+inc|-+U
Holder.niCtor WRITES -+U|-+U|-+U ^l3 -+U|Fs+inc|-+U
"""

    static let fx5nw = """
Holder.h_ann_lib WRITES -+inv|Fs+inc|-+inv
Holder.h_ctor_lib WRITES -+inv|Fs+inc|-+inv
Holder.h_ann_vault WRITES -+inv|Fs+inc|-+inv
Holder.h_ctor_vault WRITES -+inv|Fs+inc|-+inv
Holder.h_qann_lib WRITES -+inv|Fs+inc|-+inv
Holder.h_qctor_lib WRITES -+inv|Fs+inc|ABSENT ^l3 -+inv|Fs+inc|-+U+inv
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
C.l_closure_lib WRITES -+U+inv|-+U|-+U+inv ^l3 -+U+inv|Fs+U+inc|-+U+inv
C.l_closure_named WRITES -+U+inv|-+U|-+U+inv ^l3 -+U+inv|Fs+U+inc|-+U+inv
C.l_own_nested pure ABSENT|ABSENT|ABSENT
C.l_mirror_kit pure -+inv|-|-+inv
C.g_ann_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_ctor_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_ann_vault_c WRITES -+inv|Fs+inc|-+inv
C.g_ctor_vault_c WRITES -+inv|Fs+inc|-+inv
C.g_qann_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_qctor_lib_c WRITES -+U+inv|-+U|-+inv ^l3 -+inv|Fs+inc|-+inv
C.g_alias_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_fac_lib_c WRITES -+inv|Fs+inc|-+inv
C.g_upper_lib_c WRITES -+inv|-|-+inv
C.g_own_nested_c pure ABSENT|ABSENT|ABSENT
C.g_mirror_kit_c pure -+inv|-|-+inv
C.live WRITES -+inv|Fs+inc|-+inv
NI.ni_global_ctor WRITES -+inv|ABSENT|-+inv ^l3 -+inv|Fs+inc|-+inv
NI.ni_global_qann WRITES -+inv|-|-+inv ^l3 -+inv|Fs+inc|-+inv
NI.ni_field_qann WRITES -+inv|-|-+inv ^l3 -+inv|Fs+inc|-+inv
Holder.niQann WRITES ABSENT|ABSENT|ABSENT ^l3 -+inv|Fs+inc|-+inv
Holder.niCtor WRITES ABSENT|ABSENT|ABSENT ^l3 -+inv|Fs+inc|-+inv
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
B8.b_ext_quiet pure -+inv|ABSENT|-+inv ^l3 -+inv|-|-+inv
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
GBox.c_genparam WRITES -+U|-+U ^l3 -+inv|Fs+inc
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
Msg.s_b1 WRITES -+U|-+U ^l3 -+inv|Fs+inc
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
B11.b_ext_quiet pure -+inv|ABSENT|-+inv ^l3 -+inv|-|-+inv
B11.b_own_field WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs|-+inv
Holder11.b_ext_self WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs|-+U+inv/-+inv # L3: no collision here (Pipe11 is only Dep11's), so unr reads what the importing-file control `a_field` reads, -+inv
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
Sp12.sp_data WRITES ABSENT l4 Fs # LS refused a superclass the scan does not declare (NSObject); L4 walks it (R1948): NSObject nests no Data
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

    // fx19 (Fable's merge review of lane L2, B1): a nested type spelled only as a MEMBER (`Resp19.Status19.isValid`) and constructed
    // through an implicit member with that CONTEXTUAL type (`.init(code:)`, `.make(p)`): neither is a bare spelling of the unit's, so no
    // L2 context may attach (swift-http-types `HTTPParsedFields.response` is the pool shape). Pinned at main: lane ca8cfae read ABSENT.
    static let fx19 = """
Parsed19.resp_init WRITES Fs+inc
Parsed19.resp_make WRITES Fs+inc
Parsed19.resp_plain WRITES Fs+inc
Parsed19.resp_quiet pure ABSENT
"""

    // fx20 (Fable's merge review of lane L2, B2): a typealias of a PLATFORM type the scan EXTENDS (`MyResult<S> = Result<S, Error>`,
    // the Alamofire `AFResult` shape) keeps the scan's extension init on Swift.Result. Pinned at main: lane ca8cfae read ABSENT.
    static let fx20 = """
U20.alias_generic WRITES Fs+inc
U20.alias_plain WRITES Fs+inc
U20.direct WRITES Fs+inc
U20.alias_quiet pure ABSENT
"""


    // lane L4 attack cells (fx26): a bare name reached as a member type or member alias of a SUPERTYPE (or of the enclosing type)
    // where the module also declares that simple name top-level, so the package-wide key answered wrong in both directions; a
    // dependency superclass nesting a name an imported own module declares top-level (hedged when its sources are not readable);
    // inherited initializers (R1972); a protocol-extension member reached through a nested type's path (R1984's pool cost).
    static let fx26 = """
Sub26.a_grand WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
Sub26.a_grand_inline WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
Sub26.a_grand_mirror pure Fs+inc|Fs+inc|Fs+inc l4 ABSENT|ABSENT|ABSENT
Sub26.a_nearer pure Fs+inc|Fs+inc|Fs+inc l4 ABSENT|ABSENT|ABSENT # Mid26.Near26 (nearer) shadows Base26's and the top level
Sub26.a_ext WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
Sub26.a_ext_mirror pure Fs+inc|Fs+inc|Fs+inc l4 ABSENT|ABSENT|ABSENT
Outer26.In26.a_in WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs # In26 inherits Base26.Cfg26 before Outer26's own pure Cfg26
SubF26.f_field WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs # a field (declaration scope, L3's binder)
SubF26.f_field_mirror pure Fs+inc|Fs+inc|Fs+inc l4 ABSENT|ABSENT|ABSENT
SubA26.b_super_alias WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
ConfA26.b_proto_alias pure Fs+inc|Fs+inc|Fs+inc l4 ABSENT|ABSENT|ABSENT
OwnA26.b_own_alias WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
OwnA26.b_own_alias_mirror pure Fs+inc|Fs+inc|Fs+inc l4 ABSENT|ABSENT|ABSENT
SubD26.d_dep_nested WRITES ABSENT|ABSENT|ABSENT l4 -+inv|Fs|-+U # readable: the dependency's type; unreadable: hedged, main's binding kept
SubD26.d_dep_nested_mirror pure Fs+inc|Fs+inc|Fs+inc l4 -+inv|-|Fs+U # unreadable: main's (fabricated) binding kept, hedged
SubD26.live WRITES -+inv|Fs+inc|-+inv
OuterI26.i_twin WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs # R1972: inherited LoudInit26.init
OuterI26.i_lone WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
Tbl26.e_field WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs # R1984: the field is Tbl26.Body26; Mk26.mark26 through its path
Tbl26.e_local WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
Plain26.e_top pure ABSENT|ABSENT|ABSENT
Tbl26.e_field_prop WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
Tbl26.e_local_prop WRITES ABSENT|ABSENT|ABSENT l4 Fs|Fs|Fs
Plain26.e_top_prop pure ABSENT|ABSENT|ABSENT
UseP26.p_shared WRITES Fs+inc|Fs+inc|Fs+inc # must not move: a SIMPLE key two files' declarations share (ProdA26/ProdB26.Pair26) keeps main's union; a439c1e bound the last writer (ABSENT)
Back26.g_switch_self WRITES -+U|-+U|-+U l4 Fs|Fs|Fs # a case payload bound against `self` where another enum shares the case name (main: hedged; v0.43.0 ABSENT)
Back26.g_if_case_self WRITES -+U|-+U|-+U l4 Fs|Fs|Fs
UseH26.h_top_owner WRITES Fs+inc|Fs+inc|Fs+inc # must not move: an OWNER simple name shared with a nested type that nests the field's type; 996abe9 read ABSENT
HoldS26.s_dep_prop WRITES ABSENT|Fs+inc|ABSENT l4 -+inv|Fs|ABSENT # a property read on a dependency-typed field names the module standalone (unreadable: unchanged)
TagJ26.j_eq pure -+U+inv|-+U|-+U+inv l4 -+inv|ABSENT|-+inv # Fable B2: no `dispatch:ExpressibleByStringLiteral.==` on a path-typed receiver (the protocol declares no `==`)
"""

    // Fable's merge review of lane L4 (fx27, executed): inherited initializers chosen by LABEL (B1: `NoInit27(name:)` runs the PURE
    // `init(name:)`, never the same-arity loud `init(path:)`), a convenience-only subclass (pinned at main: a pre-existing silence row),
    // overrides and `super.` calls, protocol-extension default vs class member, a generic superclass's nested type.
    static let fx27 = """
I27.noinit_path WRITES ABSENT l4 Fs
I27.noinit_name pure ABSENT
I27.conv_path WRITES ABSENT # pre-existing: a convenience-only subclass still inherits the designated inits (row)
I27.conv_x pure ABSENT
I27.desig pure ABSENT
OSub27.via_super WRITES Fs+inc
O27.sub_go pure ABSENT
O27.sub_quiet WRITES Fs+inc
O27.base_go WRITES Fs+inc
O27.upcast_go pure Fs+inc # pre-existing CHA over-approximation
Q27.class_wins pure ABSENT
Q27.default_runs WRITES Fs+inc
Q27.existential pure Fs+inc # pre-existing CHA over-approximation
GSub27.gen_nested WRITES ABSENT l4 Fs
Plain27.top pure ABSENT
"""

    // lane L3 attack cells (fx22): a.swift (imports Base22 only) declares every binder; b.swift imports nothing; s.swift is a sibling
    // importing Ext22X; c.swift imports Ext22X too (not evaluated as a.swift). Mirrors (`*_mirror`) beside every B1-direction cell.
    static let fx22 = """
H22.a_live WRITES -+inv|Fs+inc|-+inv
O22.o_nested pure ABSENT|ABSENT|ABSENT
B22.b_field WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs+inc|-+U+inv
B22.b_field_mirror pure Fs+inv+inc|Fs+inc|Fs+inv+inc l3 -+inv|-|-+U+inv
B22.b_param WRITES ABSENT|ABSENT|ABSENT l3 -+inv|Fs+inc|-+U+inv
B22.b_local WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs+inc|-+U+inv
B22.b_global WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs+inc|-+U+inv
B22.b_global_mirror pure Fs+inv+inc|Fs+inc|Fs+inv+inc l3 -+inv|-|-+U+inv
B22.b_ret WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs+inc|-+U+inv
B22.b_closure WRITES -+U+inv|-+U|-+U+inv l3 -+U+inv|Fs+U+inc|-+U+inv
B22.b_ext_sibling WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs+inc|-+inv
B22.b_ext_sibling_quiet pure -+inv|ABSENT|-+inv l3 -+inv|-|-+inv
B22.b_nested pure ABSENT|ABSENT|ABSENT
C22.c_field WRITES -+inv|ABSENT|-+inv l3 -+inv|Fs+inc|-+U+inv
C22.c_field_mirror pure Fs+inv+inc|Fs+inc|Fs+inv+inc l3 -+inv|-|-+U+inv
C22.c_ext WRITES -+inv|Fs+inc|-+inv
W22.w_witness WRITES Fs+inc|Fs+inc|Fs+inc # a dependency type conforming to a scan protocol by a scan extension whose member is the witness (pool: vapor FormDataEncoder); round 1 dropped it to -+U
"""

    // lane B3 (SOUNDNESS R1981): Fable's fx23. decl.swift imports DepA only and declares every binder; useB.swift imports DepB
    // (same-named twins, opposite loudness), useC.swift an own module Core23 with a pure `Lib23`. The value's type is DepA's in
    // every use file. `b3` targets: lib cells charge chained, kit mirrors lose DepB's write (the pure-only DepA entry keeps `-+U`).
    static let fx23 = """
UB23.field_lib WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+U+inv
UB23.field_kit pure -+inv|Fs+inc|-+inv b3 -+inv|-+U/-|-+inv # Fable's fabrication: DepB's loud tap23 on DepA's pure Kit23
UB23.bare_lib pure -+inv|-+U|-+inv
UB23.bare_kit WRITES -+inv|Fs+inc|-+inv
UB23.ret_lib WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+U+inv
UC23.field_lib WRITES -+inv|ABSENT|-+inv b3 -+inv|Fs+inc|-+U+inv # Fable's silence: the own pure twin
UC23.bare_lib pure ABSENT|ABSENT|ABSENT
UT23.t4_overload_lib WRITES -+U+inv|-+U|-+U+inv
UT23.t4_overload_kit pure -+U+inv|-+U|-+U+inv
UT23.t4_generic WRITES -+U+inv|-+U|-+U+inv
UT23.t4_shadow pure -+U+inv|-+U|-+U+inv
W23.w_default WRITES Fs+U+inc|Fs+U+inc|Fs+U+inc
W23.w_refined WRITES Fs+U+inc|Fs+U+inc|Fs+U+inc
W23.w_cond WRITES Fs+U+inc|Fs+U+inc|Fs+U+inc
W23.live WRITES -+inv|Fs+inc|-+inv
"""

    // lane B3 (SOUNDNESS R1981) attack matrix: every binder (field, global, factory return, a local bound from a field, a parameter's
    // field, a T4 closure parameter) declared in decl.swift (imports DepA) and called from use files whose imports are NOT a subset
    // of decl.swift's: useB (DepB twins), useC (own Core24 twins), useX (DepB + DepAX, the module of a third package ExtA extending DepA's types),
    // useAB (DepA + DepB), useXC (the declaration in ANOTHER own module, Core24/hc.swift). useN (no imports) is L3's subset case,
    // here only for the extension members DepAX supplies through a sibling's import. Each loud `*_lib` has its pure `*_kit` mirror.
    static let fx24 = """
UB24.field_lib WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv
UB24.field_kit pure -+inv|Fs+inc|-+inv b3 -+inv|-+U/-|-+inv
UB24.global_lib WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv
UB24.global_kit pure -+inv|Fs+inc|-+inv b3 -+inv|-+U/-|-+inv
UB24.ret_lib WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv
UB24.ret_kit pure -+inv|Fs+inc|-+inv b3 -+inv|-+U/-|-+inv
UB24.local_lib WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv
UB24.local_kit pure -+inv|Fs+inc|-+inv b3 -+inv|-+U/-|-+inv
UB24.param_lib WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv
UB24.param_kit pure -+inv|Fs+inc|-+inv b3 -+inv|-+U/-|-+inv
UB24.closure_lib WRITES -+U+inv|-+U|-+U+inv b3 -+U+inv|Fs+U+inc|-+U+inv
UB24.closure_kit pure -+U+inv|Fs+U+inc|-+U+inv b3 -+U+inv|-+U/-|-+U+inv
UB24.ext_lib WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv
UB24.bare_lib pure -+inv|-+U|-+inv
UB24.bare_kit WRITES -+inv|Fs+inc|-+inv
UC24.field_lib WRITES -+inv|ABSENT|-+inv b3 -+inv|Fs+inc|-+inv
UC24.field_kit pure -+inv|ABSENT|-+inv b3 -+inv|-+U/-|-+inv
UC24.global_lib WRITES -+inv|ABSENT|-+inv b3 -+inv|Fs+inc|-+inv
UC24.global_kit pure -+inv|ABSENT|-+inv b3 -+inv|-+U/-|-+inv
UC24.ret_lib WRITES -+inv|ABSENT|-+inv b3 -+inv|Fs+inc|-+inv
UC24.ret_kit pure -+inv|ABSENT|-+inv b3 -+inv|-+U/-|-+inv
UC24.param_lib WRITES ABSENT|ABSENT|ABSENT b3 -+inv|Fs+inc|-+inv
UC24.param_kit pure ABSENT|ABSENT|ABSENT b3 -+inv|-+U/-|-+inv
UC24.closure_lib WRITES -+U+inv|-+U|-+U+inv b3 -+U+inv|Fs+U+inc|-+U+inv
UC24.closure_kit pure -+U+inv|-+U|-+U+inv
UC24.bare_lib pure ABSENT|ABSENT|ABSENT
UC24.bare_kit WRITES Fs+inc|Fs+inc|Fs+inc
UX24.ext_pipe WRITES -+inv|Fs+inc|-+inv
UX24.ext_quiet pure -+inv|ABSENT|-+inv b3 -+inv|-|-+inv
UX24.ext_lib WRITES -+inv|Fs+inc|-+inv
UX24.field_lib WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv
UX24.field_kit pure -+inv|Fs+inc|-+inv b3 -+inv|-+U/-|-+inv
UN24.ext_pipe WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv # DepAX is imported by a SIBLING file only (edit 3: target-wide)
UN24.ext_quiet pure -+inv|-|-+inv
UN24.field_lib WRITES -+inv|Fs+inc|-+inv
UN24.field_kit pure -+inv|-+U|-+inv
UAB24.field_lib WRITES -+U+inv|Fs+inc|-+U+inv ^b3 -+inv|Fs+inc|-+inv # the ambiguity hedge goes with DepB; slot (c): DepA's chain charges
UAB24.field_kit pure -+U+inv|Fs+inc|-+U+inv b3 -+inv|-+U/-|-+inv
UAB24.ret_lib WRITES -+U+inv|Fs+inc|-+U+inv ^b3 -+inv|Fs+inc|-+inv
H24.live WRITES -+inv|Fs+inc|-+inv
UXC24.tool WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv
UXC24.gear pure -+inv|Fs+inc|-+inv b3 -+inv|-+U/-|-+inv
UXC24.ext_pipe WRITES -+inv|Fs+inc|-+inv
UXC24.ext_quiet pure -+inv|ABSENT|-+inv b3 -+inv|-|-+inv
"""

    // lane B3 follow-up (SOUNDNESS R1981, Fable's fx25): DepB is a TWIN (its own pure `Lib25`) AND extends DepA's `Lib25` with the
    // called member (`extension DepA.Lib25 { extWipe25 }`, loud). decl.swift imports DepA; useB.swift imports DepB only. Main (the
    // use-file routing) reached `Fs` by accident; B3's twin exclusion read `Unknown` (true reason); a twin whose sources extend the
    // identity's type THROUGH the identity's module keeps the member: `Fs` chained again, DepB named beside DepA standalone.
    // `ext_twin` is a control (main and the target agree, the B3 commit 11351409 read `-+U` chained); `ext_twin_quiet` is its pure twin.
    static let fx25 = """
UB25.ext_twin WRITES -+inv|Fs+inc|-+inv
UB25.ext_twin_quiet pure -+inv|-|-+inv
UB25.field WRITES -+inv|-+U|-+inv b3 -+inv|Fs+inc|-+inv # the twin's own wipe25 is NOT an extension of DepA's type: DepB stays out
L25.live WRITES -+inv|Fs+inc|-+inv
"""
}
