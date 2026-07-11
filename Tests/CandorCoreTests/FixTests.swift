import XCTest
@testable import CandorCore

/// Direct unit pins over the PURE boundary-fix cut (CandorCore/Fix.swift) — the remedial inverse of the gate
/// (integrations/FIX-SPEC.md), the byte-for-byte port of candor-query / candor-java / candor-ts. The orderflow
/// ground truth: api.get → domain.bulk → domain.price → infra.fetch, all carrying Net, the leaf performing it
/// directly; `deny Net domain` makes the two domain functions a crossing whose site is the infra leaf and
/// whose hoist target is the api caller. The cross-engine parity itself is pinned by conformance PART 12b.
final class FixTests: XCTestCase {

    private func orderflow() -> (byName: [String: FixFn], cg: [String: [String]]) {
        let byName: [String: FixFn] = [
            "api.get": FixFn(inferred: ["Net"], direct: [], calls: ["domain.bulk"]),
            "domain.bulk": FixFn(inferred: ["Net"], direct: [], calls: ["domain.price"]),
            "domain.price": FixFn(inferred: ["Net"], direct: [], calls: ["infra.fetch"]),
            "infra.fetch": FixFn(inferred: ["Net"], direct: ["Net"], calls: []),
        ]
        let cg: [String: [String]] = [
            "api.get": ["domain.bulk"],
            "domain.bulk": ["domain.price"],
            "domain.price": ["infra.fetch"],
            "infra.fetch": [],
        ]
        return (byName, cg)
    }

    func testFixHoistsNetToApi() {
        let (byName, cg) = orderflow()
        let deny = parsePolicy("deny Net domain").deny
        guard case let .remedy(r) = fix(target: "price", effect: "Net", byName: byName, cg: cg, deny: deny) else {
            return XCTFail("expected a remedy for the domain Net crossing")
        }
        XCTAssertEqual(r.layer, "domain")
        XCTAssertTrue(r.cleanHoist)
        XCTAssertEqual(r.site, ["infra.fetch"])
        XCTAssertEqual(r.hoistTo, ["api.get"])
        XCTAssertEqual(r.deniedSpan, ["domain.bulk", "domain.price"])
        XCTAssertEqual(r.policyAlternative, "allow Net domain")
    }

    func testFixSurfacesHigherHoistTradeoff() {
        // With an allowed-layer caller ABOVE the minimal frontier, the higher option is surfaced: the minimal
        // hoist stays api.get, but main.run (which calls it, also allowed) is a higher place to originate Net.
        var (byName, cg) = orderflow()
        byName["main.run"] = FixFn(inferred: ["Net"], direct: [], calls: ["api.get"])
        cg["main.run"] = ["api.get"]
        let deny = parsePolicy("deny Net domain").deny
        guard case let .remedy(r) = fix(target: "price", effect: "Net", byName: byName, cg: cg, deny: deny) else {
            return XCTFail("expected a remedy")
        }
        XCTAssertEqual(r.hoistTo, ["api.get"], "minimal frontier unchanged")
        XCTAssertEqual(r.hoistHigher, ["main.run"], "main.run is the higher hoist option")
    }

    func testFixNonViolationIsANoOp() {
        let (byName, cg) = orderflow()
        let deny = parsePolicy("deny Net domain").deny
        // api.get performs Net but in an ALLOWED layer — not a crossing.
        guard case let .notACrossing(_, _, reason) = fix(target: "api.get", effect: "Net", byName: byName, cg: cg, deny: deny) else {
            return XCTFail("api.get is not a boundary crossing")
        }
        XCTAssertEqual(reason, "not-forbidden")
    }

    func testFixGateCollapsesInheritorsToOneRemedy() {
        let (byName, cg) = orderflow()
        let deny = parsePolicy("deny Net domain").deny
        let (ok, remedies) = fixGate(byName: byName, cg: cg, deny: deny)
        XCTAssertFalse(ok)
        // the two domain functions both carry Net — ONE root cause, site-anchored → one remedy.
        XCTAssertEqual(remedies.count, 1)
        XCTAssertEqual(remedies[0].site, ["infra.fetch"])
        XCTAssertEqual(remedies[0].hoistTo, ["api.get"])
        XCTAssertEqual(remedies[0].deniedSpan, ["domain.bulk", "domain.price"])
    }

    func testFixGateCleanReportIsOk() {
        let (byName, cg) = orderflow()
        let deny = parsePolicy("deny Net nonesuch").deny // matches no function
        let (ok, remedies) = fixGate(byName: byName, cg: cg, deny: deny)
        XCTAssertTrue(ok)
        XCTAssertTrue(remedies.isEmpty)
    }

    func testFixNoSuchFn() {
        let (byName, cg) = orderflow()
        let deny = parsePolicy("deny Net domain").deny
        guard case .noSuchFn = fix(target: "nope", effect: "Net", byName: byName, cg: cg, deny: deny) else {
            return XCTFail("a name matching nothing must be .noSuchFn")
        }
    }
}
