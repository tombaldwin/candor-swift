import Foundation

/// The matrix's fixtures, by the names DESIGN.md §5 uses. The tables are in `TypeIdentityCells`.
enum TypeIdentityFixtures {
    typealias F = TypeIdentityHarness.Fixture
    static let guess = "fx/Guess"
    // A = fx4; its one-variable controls are fx5 (with the Wiper protocol) and fx5nw (without it)
    static let fx3   = F(app: "fx3/App3", truthFile: "fx3/exec-ground-truth.txt", deps: [guess], spelling: "../../fx/Guess", unr: true, live: ["N.n_live"], table: TypeIdentityCells.fx3)
    static let fx4   = F(app: "fx4/App4", truthFile: "fx4/exec-ground-truth.txt", deps: [guess], spelling: "../../fx/Guess", unr: true, live: ["C.live"], table: TypeIdentityCells.fx4)
    static let fx5   = F(app: "fx5/App5", truthFile: "fx5/exec-ground-truth.txt", deps: [guess], spelling: "../../fx/Guess", unr: true, live: ["C.live"], table: TypeIdentityCells.fx5)
    static let fx5nw = F(app: "fx5nw/App5nw", truthFile: "fx5nw/exec-ground-truth.txt", deps: [guess], spelling: "../../fx/Guess", unr: true, live: ["C.live"], table: TypeIdentityCells.fx5nw)
    // B = fx6 + control fx6c (Pkg6c): a nested `Data` anywhere in the package, and the renamed control
    static let fx6   = F(app: "fx6/Pkg6", truthFile: "fx6/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx6)
    static let fx6c  = F(app: "fx6/Pkg6c", truthFile: "fx6/exec-ground-truth-c.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx6c)
    // F7 = Fable fx7: F-B3r, S6, and the inherited-nested rows
    static let fx7   = F(app: "fx7/App7", truthFile: "fx7/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx7)
    // C = fx8: a B3 extension member of a dependency type
    static let fx8   = F(app: "fx8/App8", truthFile: "fx8/exec-ground-truth.txt", deps: ["fx8/Dep8"], spelling: "../Dep8", unr: true, live: ["A8.a_live"], table: TypeIdentityCells.fx8)
    // F1 / F2 = Fable's R1931 fixtures
    static let f1    = F(app: "r1931/fx/App", truthFile: "r1931/fx/exec-ground-truth.txt", deps: ["r1931/fx/Guess"], spelling: "../Guess", unr: false, live: ["A.a_live"], table: TypeIdentityCells.f1)
    static let f2    = F(app: "r1931/fx2/App2", truthFile: "r1931/fx2/exec-ground-truth.txt", deps: ["r1931/fx/Guess"], spelling: "../../fx/Guess", unr: false, live: ["F.f_live"], table: TypeIdentityCells.f2)
    // R / Rp / RL = the R1896 fixtures; Rlog2 = the recreated consumer of a swift-log stand-in through a RELATIVE .package(path:)
    static let r     = F(app: "r1896/fx/App", truthFile: "r1896/fx/exec-ground-truth.txt", deps: ["r1896/fx/Guess", "r1896/fx/Dep2"], spelling: "../Guess", unr: false, live: [], table: TypeIdentityCells.r)
    static let rp    = F(app: "r1896/fxp/App", truthFile: "r1896/fxp/exec-ground-truth.txt", deps: ["r1896/fxp/Guess"], spelling: "../Guess", unr: false, live: [], table: TypeIdentityCells.rp)
    static let rl    = F(app: "r1896/fx3/App", truthFile: "r1896/fx3/exec-ground-truth.txt", deps: ["r1896/fx3/Guess"], spelling: "../Guess", unr: false, live: [], table: TypeIdentityCells.rl)
    static let rlog2 = F(app: "r1896/fxlog2/App", truthFile: "r1896/fxlog2/exec-ground-truth.txt", deps: ["r1896/fxlog2/swift-log"], spelling: "../swift-log", unr: true, live: [], table: TypeIdentityCells.rlog2)
    // new in L0: S1xS12 / S12 (fx9), the LS refusal cells (fx9r), the L4 rows (fx10), the S7e variants (fx11)
    static let fx9   = F(app: "fx9/Pkg9", truthFile: "fx9/exec-ground-truth.txt", deps: ["fx9/Files"], spelling: "../Files", unr: true, live: ["UF9.live"], table: TypeIdentityCells.fx9)
    static let fx9r  = F(app: "fx9r/Pkg9r", truthFile: "fx9r/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx9r)
    static let fx10  = F(app: "fx10/Pkg10", truthFile: "fx10/exec-ground-truth.txt", deps: ["fx10/Guess10"], spelling: "../Guess10", unr: true, live: ["Ext10.live"], table: TypeIdentityCells.fx10)
    static let fx11  = F(app: "fx11/App11", truthFile: "fx11/exec-ground-truth.txt", deps: ["fx11/Dep11"], spelling: "../Dep11", unr: true, live: ["Holder11.a_live"], table: TypeIdentityCells.fx11)

    static let fx12  = F(app: "fx12/Pkg12", truthFile: "fx12/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx12)

    static let fx13  = F(app: "fx13/Pkg13", truthFile: "fx13/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx13)

    static let fx15  = F(app: "fx15/Pkg15", truthFile: "fx15/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx15)

    static let fx16  = F(app: "fx16/App16", truthFile: "fx16/exec-ground-truth.txt", deps: ["fx16/Dep16"], spelling: "../Dep16", unr: true, live: ["U16.live"], table: TypeIdentityCells.fx16)

    static let fx19  = F(app: "fx19/Pkg19", truthFile: "fx19/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx19)
    static let fx20  = F(app: "fx20/Pkg20", truthFile: "fx20/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx20)

    static let fx22  = F(app: "fx22/App22", truthFile: "fx22/exec-ground-truth.txt", deps: ["fx22/Dep22"], spelling: "../Dep22", unr: true, live: ["H22.a_live"], table: TypeIdentityCells.fx22)

    // lane B3 (SOUNDNESS R1981): Fable's fx23 and the B3 attack matrix fx24 (two twin-declaring dependencies + an extending third package)
    static let fx23  = F(app: "fx23/App23", truthFile: "fx23/exec-ground-truth.txt", deps: ["fx23/DepA", "fx23/DepB"], spelling: "../DepA", unr: true, live: ["W23.live"], table: TypeIdentityCells.fx23)
    static let fx24  = F(app: "fx24/App24", truthFile: "fx24/exec-ground-truth.txt", deps: ["fx24/DepA", "fx24/DepB", "fx24/ExtA"], spelling: "../DepA", unr: true, live: ["H24.live"], table: TypeIdentityCells.fx24)

    static let fx25  = F(app: "fx25/App25", truthFile: "fx25/exec-ground-truth.txt", deps: ["fx25/DepA", "fx25/DepB"], spelling: "../DepA", unr: true, live: ["L25.live"], table: TypeIdentityCells.fx25)

    // lane L4 (SOUNDNESS R1938 L4, R1948, R1972, R1984): the supertype walk's attack matrix
    static let fx26  = F(app: "fx26/App26", truthFile: "fx26/exec-ground-truth.txt", deps: ["fx26/Dep26"], spelling: "../Dep26", unr: true, live: ["SubD26.live"], table: TypeIdentityCells.fx26)

    static let fx27  = F(app: "fx27/Pkg27", truthFile: "fx27/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx27)

    static let fx28  = F(app: "fx28/Pkg28", truthFile: "fx28/exec-ground-truth.txt", deps: [], spelling: nil, unr: false, live: [], table: TypeIdentityCells.fx28)

    static let all: [(String, F)] = [("fx3", fx3), ("fx4", fx4), ("fx5", fx5), ("fx5nw", fx5nw), ("fx6", fx6), ("fx6c", fx6c), ("fx7", fx7), ("fx8", fx8),
        ("F1", f1), ("F2", f2), ("R", r), ("Rp", rp), ("RL", rl), ("Rlog2", rlog2), ("fx9", fx9), ("fx9r", fx9r), ("fx10", fx10), ("fx11", fx11), ("fx12", fx12), ("fx13", fx13), ("fx15", fx15), ("fx16", fx16), ("fx19", fx19), ("fx20", fx20), ("fx22", fx22), ("fx23", fx23), ("fx24", fx24), ("fx25", fx25), ("fx26", fx26), ("fx27", fx27), ("fx28", fx28)]
}
