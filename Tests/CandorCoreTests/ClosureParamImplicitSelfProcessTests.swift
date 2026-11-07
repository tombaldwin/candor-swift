import XCTest
import Foundation

/// SOUNDNESS R1472 defect C — A NAME AN ENCLOSING CLOSURE'S PARAMETER BINDS IS NOT `self.<name>` EITHER. RxCocoa's
/// `Reactive.countDownDuration` passes `setter: { picker, value in picker.countDownDuration = value }`; the bare `value`
/// is the closure parameter, and it edged `Reactive.value` (a different member) through the implicit-`self` arms. R1472
/// withheld only the global read, because the false member edge was then the only thing charging `countDownDuration`
/// (its real callee behind `base.rx.…` on a platform class had no edge). R1485 gives that call its edge, so the false one
/// is withheld too. EXECUTED (distinguishable effects: the helper writes `/tmp/cc-cpd`, `Reactive.value` reads the
/// environment and writes `/tmp/cc-value`):
///
///     cDate -> /tmp/cc-value      cCountDown -> /tmp/cc-cpd      cParamOnly, cParamBase -> none
final class ClosureParamImplicitSelfProcessTests: XCTestCase {
    static let src = """
    import Foundation
    public struct Reactive<Base> { public let base: Base; public init(_ base: Base) { self.base = base } }
    public protocol ReactiveCompatible { associatedtype ReactiveBase; var rx: Reactive<ReactiveBase> { get set } }
    extension ReactiveCompatible { public var rx: Reactive<Self> { get { Reactive(self) } set {} } }
    extension NSObject: ReactiveCompatible {}
    extension Reactive where Base: NSObject {
      func cpd<T>(getter: @escaping (Base) -> T, setter: @escaping (Base, T) -> Void) -> Int {
        FileManager.default.createFile(atPath: "/tmp/cc-cpd", contents: nil); return 0 }
      func purePick<T>(getter: @escaping (Base) -> T, setter: @escaping (Base, T) -> Void) -> Int { 0 }
    }
    extension Reactive where Base: NumberFormatter {
      public var cDate: Int { value }
      public var value: Int {
        FileManager.default.createFile(atPath: "/tmp/cc-value", contents: nil)
        return ProcessInfo.processInfo.environment["CANDOR_CC"] == nil ? 1 : 2 }
      public var cCountDown: Int { base.rx.cpd(getter: { p in p.zeroSymbol ?? "" }, setter: { p, value in p.zeroSymbol = value }) }
      public var cParamOnly: Int { base.rx.purePick(getter: { p in p.zeroSymbol ?? "" }, setter: { p, value in p.zeroSymbol = value }) }
      public var cParamBase: Int { base.rx.purePick(getter: { p in 0 }, setter: { p, value in _ = value.signum() }) }
    }
    """

    private func scan(_ env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let root = try ProcessHarness.makeFilesPackage(["Rx.swift": Self.src, "main.swift": "print(0)\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        return try ProcessHarness.fns(ofJson: r.out)
    }

    func testAClosureParameterNamedLikeAMemberDoesNotEdgeTheMember() throws {
        let by = try scan()
        XCTAssertEqual(ProcessHarness.inferred(by, "Reactive.cCountDown"), ["Fs"], "the helper's file write only (executed) — \(by["Reactive.cCountDown"] ?? [:])")
        XCTAssertNil(ProcessHarness.inferred(by, "Reactive.cParamOnly"), "\(by["Reactive.cParamOnly"] ?? [:])")
        XCTAssertNil(ProcessHarness.inferred(by, "Reactive.cParamBase"), "\(by["Reactive.cParamBase"] ?? [:])")
        // MUST STAY CHARGED: a real implicit-`self` read of `value`.
        XCTAssertEqual(ProcessHarness.inferred(by, "Reactive.cDate"), ["Env", "Fs"], "\(by["Reactive.cDate"] ?? [:])")
    }

    func testKillSwitchRestoresTheFalseEdge() throws {
        let by = try scan(["CANDOR_R1472C_OFF": "1"])
        for fn in ["Reactive.cCountDown", "Reactive.cParamOnly", "Reactive.cParamBase"] {
            XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains("Env") == true, "\(fn) under CANDOR_R1472C_OFF — \(by[fn] ?? [:])")
        }
        // …and WITHOUT R1485 the false edge was the only charge on countDownDuration: why defect C waited for it.
        let noB2 = try scan(["CANDOR_R1485_OFF": "1"])
        XCTAssertNil(ProcessHarness.inferred(noB2, "Reactive.cCountDown"), "\(noB2["Reactive.cCountDown"] ?? [:])")
    }
}
