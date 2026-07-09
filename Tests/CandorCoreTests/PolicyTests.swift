import XCTest
@testable import CandorCore

/// Direct unit pins over the PURE §6.2 policy parser + literal-surface matchers (CandorCore/Policy.swift).
/// These encode cross-engine gate-verdict semantics that previously were only reachable through the
/// process-level exit-code matrix (GateProcessTests / smoke.sh): the CRLF/bare-\r/NBSP subtleties, the
/// IPv6 host split, the `..` path rejection and the schema-wildcard table cover each get a named pin here
/// so a regression fails AT the function, not three layers up in a smoke diff.
final class PolicyTests: XCTestCase {

    // ── parsePolicy: line splitting ───────────────────────────────────────────────────────────────

    func testCRLFLinesParseAsSeparateRules() {
        let p = parsePolicy("deny Net\r\ndeny Fs io\r\n")
        XCTAssertEqual(p.deny.map(\.effects), [["Net"], ["Fs"]])
        XCTAssertEqual(p.deny.map(\.scope), ["", "io"])
    }

    func testBareCRLinesParseAsSeparateRules() {
        // classic-Mac line endings: \r alone must BREAK lines — treating it as an in-line separator
        // glued every rule after the first into the first rule's tokens (sweep [16]/[17]).
        let p = parsePolicy("deny Net\rdeny Exec\rpure domain")
        XCTAssertEqual(p.deny.count, 3)
        XCTAssertEqual(p.deny[1].effects, ["Exec"])
        XCTAssertEqual(p.deny[2].effects, [])          // `pure` = deny-everything
        XCTAssertEqual(p.deny[2].scope, "domain")
    }

    func testVerticalTabAndFormFeedAreInlineTokenSeparators() {
        // \v / \f are ASCII whitespace but NOT line breaks (Java's readLine doesn't break on them
        // either) — they separate tokens WITHIN one rule.
        let p = parsePolicy("deny\u{0B}Net\u{0C}io")
        XCTAssertEqual(p.deny.count, 1)
        XCTAssertEqual(p.deny[0].effects, ["Net"])
        XCTAssertEqual(p.deny[0].scope, "io")
    }

    func testNBSPStaysInItsToken() {
        // The §6.2 token separator is ASCII whitespace ONLY: a NBSP-joined "deny\u{A0}Net" is ONE
        // malformed token → the rule is dropped (unknown kind), never silently split into a live rule.
        let p = parsePolicy("deny\u{A0}Net")
        XCTAssertTrue(p.deny.isEmpty && p.allow.isEmpty && p.forbid.isEmpty)
    }

    // ── parsePolicy: rule grammar ─────────────────────────────────────────────────────────────────

    func testInlineCommentIsStripped() {
        let p = parsePolicy("deny Db domain   # no persistence in the domain layer")
        XCTAssertEqual(p.deny.count, 1)
        XCTAssertEqual(p.deny[0].scope, "domain")
        XCTAssertEqual(p.deny[0].raw, "deny Db domain")
    }

    func testDenyWithNoKnownEffectIsDroppedNotPure() {
        // `deny Nett` names no known effect → the rule is DROPPED with a warning; it must not become
        // a `pure` (deny-everything) rule.
        let p = parsePolicy("deny Nett")
        XCTAssertTrue(p.deny.isEmpty)
    }

    func testDenyMultipleEffectsThenScope() {
        let p = parsePolicy("deny Net Fs io.disk")
        XCTAssertEqual(p.deny[0].effects, ["Fs", "Net"])   // stored sorted
        XCTAssertEqual(p.deny[0].scope, "io.disk")
    }

    func testDenyUnknownIsAKnownGateToken() {
        let p = parsePolicy("deny Unknown")
        XCTAssertEqual(p.deny[0].effects, ["Unknown"])
    }

    func testDenyDuplicateEffectTokensDedupToASet() {
        // `deny Net Net` ≡ `deny Net` — the reference parser's EffectSet semantics; the battery's
        // duplicate-token case would otherwise split the PART 4 grammar differential.
        let p = parsePolicy("deny Net Net")
        XCTAssertEqual(p.deny[0].effects, ["Net"])
    }

    func testAllowDuplicateValuesDedup() {
        // `allow Net dup dup` keeps one value — the reference parser's TreeSet semantics.
        let p = parsePolicy("allow Net dup.example.com dup.example.com")
        XCTAssertEqual(p.allow[0].values, ["dup.example.com"])
    }

    func testAllowRequiresValues() {
        XCTAssertTrue(parsePolicy("allow Net").allow.isEmpty)
        XCTAssertTrue(parsePolicy("allow Net in scope").allow.isEmpty)   // `in <scope>` but no values
    }

    func testAllowSupportsOnlySurfacedEffects() {
        XCTAssertTrue(parsePolicy("allow Clock now").allow.isEmpty)
        let p = parsePolicy("allow Net api.stripe.com")
        XCTAssertEqual(p.allow[0].effect, "Net")
        XCTAssertEqual(p.allow[0].values, ["api.stripe.com"])
        XCTAssertEqual(p.allow[0].scope, "")
    }

    func testAllowInScopeForm() {
        let p = parsePolicy("allow Exec in tools git rsync")
        XCTAssertEqual(p.allow[0].scope, "tools")
        XCTAssertEqual(p.allow[0].values, ["git", "rsync"])   // sorted
    }

    func testForbidRequiresArrow() {
        XCTAssertTrue(parsePolicy("forbid a b").forbid.isEmpty)
        XCTAssertTrue(parsePolicy("forbid a ->").forbid.isEmpty)
        let p = parsePolicy("forbid web -> repo")
        XCTAssertEqual(p.forbid[0].from, "web")
        XCTAssertEqual(p.forbid[0].to, "repo")
    }

    func testUnknownRuleKindIsDropped() {
        let p = parsePolicy("denyy Net\nalloww Fs /tmp")
        XCTAssertTrue(p.deny.isEmpty && p.allow.isEmpty && p.forbid.isEmpty)
    }

    // ── scopeMatches ──────────────────────────────────────────────────────────────────────────────

    func testScopeMatchSegmentRunAndLastPrefix() {
        XCTAssertTrue(scopeMatches("Store.save", "Store"))
        XCTAssertTrue(scopeMatches("Store.save", "Store.sa"))     // last segment is a PREFIX
        XCTAssertTrue(scopeMatches("Outer.Inner.go", "Inner.go"))
        XCTAssertFalse(scopeMatches("Store.save", "save.Store"))  // order matters (a run, not a set)
        XCTAssertFalse(scopeMatches("Store.save", "Store.save.extra"))  // scope longer than name
    }

    func testScopeMatchEmptyScopeMatchesEverything() {
        XCTAssertTrue(scopeMatches("anything.at.all", ""))
    }

    func testScopeMatchColonScopedPolicy() {
        // a shared `::`-scoped policy (Rust path syntax) matches Swift dotted names too
        XCTAssertTrue(scopeMatches("Store.save", "Store::save"))
        XCTAssertTrue(scopeMatches("a.b.c", "b::c"))
    }

    // ── hostPort / hostPart ───────────────────────────────────────────────────────────────────────

    func testHostPortStripsSchemeAndPathKeepsPort() {
        XCTAssertEqual(hostPort("https://api.example.com:8080/v1/x"), "api.example.com:8080")
        XCTAssertEqual(hostPort("tcp://rates.internal:7070"), "rates.internal:7070")
        XCTAssertEqual(hostPort("api.example.com/x"), "api.example.com")
    }

    func testHostPartStripsPort() {
        XCTAssertEqual(hostPart("api.stripe.com:443"), "api.stripe.com")
        XCTAssertEqual(hostPart("https://api.stripe.com:443/v1"), "api.stripe.com")
        XCTAssertEqual(hostPart("api.stripe.com"), "api.stripe.com")
    }

    func testHostPartIPv6() {
        XCTAssertEqual(hostPart("[2001:db8::1]:8080"), "2001:db8::1")   // bracketed host, port stripped
        XCTAssertEqual(hostPart("[2001:db8::1]"), "2001:db8::1")
        // a BARE IPv6 literal has no port suffix — a naive first-colon split would collapse it to "2001"
        XCTAssertEqual(hostPart("2001:db8::1"), "2001:db8::1")
    }

    // ── pathCovered / dbTableCovered / cmdBase / literalAllowed ───────────────────────────────────

    func testPathCoveredPrefixSemantics() {
        XCTAssertTrue(pathCovered("/var/data", "/var/data"))          // exact
        XCTAssertTrue(pathCovered("/var/data", "/var/data/x.txt"))    // directory cover
        XCTAssertTrue(pathCovered("/var/data/", "/var/data/x.txt"))   // trailing slash tolerated
        XCTAssertFalse(pathCovered("/var/data", "/var/database"))     // NOT a string prefix — a segment cover
        XCTAssertFalse(pathCovered("/var/data", "/var/data/../etc/passwd"))  // `..` rejected outright
    }

    func testDbTableCoveredCaseAndSchemaWildcard() {
        XCTAssertTrue(dbTableCovered("Users", "users"))
        XCTAssertTrue(dbTableCovered("billing.*", "billing.invoices"))
        XCTAssertFalse(dbTableCovered("billing.*", "billing"))         // wildcard needs a qualified table
        XCTAssertFalse(dbTableCovered("users", "users_archive"))
    }

    func testCmdBase() {
        XCTAssertEqual(cmdBase("/usr/bin/git"), "git")
        XCTAssertEqual(cmdBase("git"), "git")
    }

    func testLiteralAllowedDispatch() {
        XCTAssertTrue(literalAllowed("Net", "api.stripe.com:443", ["api.stripe.com"]))
        XCTAssertTrue(literalAllowed("Exec", "/usr/bin/git", ["git"]))
        XCTAssertTrue(literalAllowed("Fs", "/tmp/scratch/x", ["/tmp/scratch"]))
        XCTAssertTrue(literalAllowed("Db", "billing.invoices", ["billing.*"]))
        XCTAssertFalse(literalAllowed("Clock", "now", ["now"]))   // non-allowlistable effect: never allowed
    }

    // ── decodeEscapes ─────────────────────────────────────────────────────────────────────────────

    func testDecodeEscapesKnownForms() {
        XCTAssertEqual(decodeEscapes(#"a\nb\tc\rd\0e"#), "a\nb\tc\rd\0e")
        XCTAssertEqual(decodeEscapes(#"q\"w\'x\\y"#), "q\"w'x\\y")
    }

    func testDecodeEscapesUnknownEscapeKeptRaw() {
        // \u{…} etc.: keep the raw two characters, never guess a decoding
        XCTAssertEqual(decodeEscapes(#"a\u{41}b"#), #"a\u{41}b"#)
    }
}
