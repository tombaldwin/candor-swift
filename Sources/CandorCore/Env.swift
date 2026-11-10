import Foundation

/// THE ONE PLACE THIS ENGINE READS ITS ENVIRONMENT (SPEC §3.4 ⟨0.42⟩, SOUNDNESS R1634).
///
/// Every read of the process environment in `Sources/` lives in this file, and `EnvLintTests` fails the suite on any
/// other (a SwiftSyntax scan over every source file, shown red on seeded spellings). That is what makes the clause
/// enforceable without a list: SPEC §3.4 says "the registration is the read", because a list of switch names beside
/// the code that reads them is an allowlist, and it fails in the absence direction — a switch added without its entry
/// is exactly the silent one. THERE IS NO TABLE OF NAMES IN THIS FILE.
///
/// FOUR KINDS OF READ, chosen at the call site by what the variable does:
///  · `on` / `value` / `read` — a RESULT-MOVING switch: a kill switch for a closed defect or an opt-in mode, whose
///    value selects which logic runs. When the value, as the caller reads it, selects a branch other than the one an
///    unset variable selects, the name is RECORDED. Recorded names are the report's `switches` (§2) and make a gate
///    refuse (§3.3 cause (e)). Here every switch is presence-keyed, so any value, even empty, is SET.
///  · `trace` / `traceValue` — a DIAGNOSTIC: the value only decides whether something is written to stderr. No report
///    or verdict byte can depend on it, so nothing is recorded (§3.4: "a read that only writes to stderr is out of
///    scope"). A trace read that moves a result is a switch: reclassify it.
///  · `operatorValue` — an INPUT the operator documents (a path to a policy, baseline, dependency report or
///    configuration file, the report locator). Configuration, out of scope (§3.4).
///  · `childEnvironment` / `applyChildEnvironment` — the environment handed to a child process the engine starts.
///
/// AN ENGINE MUST NOT READ EVERY SWITCH AT PROCESS START (§3.4 (a)): a read happens where the logic the variable
/// selects is reached, and a name is consulted only when that read EXECUTES. Swift globals outside `main.swift` and
/// every `static let` are initialised on first use, so a switch held in one is consulted by the process that first
/// touches it and by no other; `gate --report` and the advisory verbs never reach the scan-time ones.
public enum Env {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        func record(_ n: String) { lock.lock(); names.insert(n); lock.unlock() }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(names) }
        func clear() { lock.lock(); names.removeAll(); lock.unlock() }
    }
    private static let store = Store()

    private static func raw(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }

    /// Code-point order, as SPEC §2 (`switches`) requires: Swift `String` `<` compares by Unicode scalar for the
    /// ASCII names a switch has, and the explicit scalar comparison keeps it true for any other.
    public static func byCodePoint(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    /// A RESULT-MOVING read. Returns the raw value and records `name` when `isSet` says the value selects a branch
    /// other than the one an unset variable selects.
    public static func read(_ name: String, isSet: (String) -> Bool) -> String? {
        let v = raw(name)
        if let v, isSet(v) { store.record(name) }
        return v
    }

    /// A presence-keyed switch: SET when the variable is present, whatever its value.
    public static func on(_ name: String) -> Bool { read(name, isSet: { _ in true }) != nil }

    /// A presence-keyed switch whose VALUE the engine also uses (a letter set, a class list).
    public static func value(_ name: String) -> String? { read(name, isSet: { _ in true }) }

    /// A DIAGNOSTIC read: never recorded.
    public static func trace(_ name: String) -> Bool { raw(name) != nil }
    public static func traceValue(_ name: String) -> String? { raw(name) }

    /// A documented INPUT (a path, a locator): never recorded.
    public static func operatorValue(_ name: String) -> String? { raw(name) }

    /// The environment a child process is started with.
    public static func childEnvironment() -> [String: String] { ProcessInfo.processInfo.environment }

    /// Start `proc` with the parent's environment plus `adding`.
    public static func applyChildEnvironment(_ proc: Process, adding: [String: String] = [:]) {
        var e = childEnvironment()
        for (k, v) in adding { e[k] = v }
        proc.environment = e
    }

    /// The result-moving switches set AND consulted by THIS process so far, sorted by code point.
    public static func consultedSwitches() -> [String] { store.all().sorted(by: byCodePoint) }

    /// The refusal's `reason` (§3.3 (e); §3.1: a refusal always says why): names every switch and says to unset them.
    public static func switchRefusalReason(_ names: [String]) -> String {
        "a result-moving switch is set: " + names.joined(separator: ", ")
            + " — the answer depends on an environment variable that selects which logic ran, so the gate cannot say "
            + "whether the code passes (SPEC §3.4). Unset " + (names.count == 1 ? "it" : "them") + " and re-run."
    }

    /// Test seam: forget what was consulted.
    public static func resetConsultedSwitches() { store.clear() }
}
