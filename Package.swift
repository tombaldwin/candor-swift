// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "candor-swift",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The parsing layer — SwiftSyntax is to this engine what `syn` is to candor-scan:
        // syntactic, no build of the target required.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        // The PURE cores (κ classifier + SwiftSyntax type helpers), factored out of the executable so
        // they can be `@testable import`ed by CandorCoreTests — an executable target cannot. Same lint
        // gate as the executable (-warnings-as-errors on OUR code, not the swift-syntax dependency).
        .target(
            name: "CandorCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                // PackageTargets.swift parses a target's OWN Package.swift to resolve `--target`'s
                // dependency closure. A structured parse, not a regex: `manifestPackageName` in main.swift
                // documents at length why the regex form is fragile (it takes the first `name:` in the
                // file, which is very often a target's, not the package's).
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .executableTarget(
            name: "candor-swift",
            dependencies: [
                "CandorCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                // ⟨0.21⟩ the completeness manifest needs to know a file FAILED TO PARSE. `Parser.parse`
                // is error-TOLERANT and never throws, so without the diagnostics generator a syntax error
                // is indistinguishable from clean source and the file counts as fully analyzed. See the
                // `unanalyzed` loop in Driver.swift for what that cost at gate level.
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
            ],
            // The agent contract is EMBEDDED as a Swift constant (AgentsDoc.swift, generated from
            // AGENTS.md by gen-agents-doc.py) rather than a bundle resource, so `--agents` survives
            // a binary copied out of .build (where Bundle.module would fatalError). smoke.sh gates
            // drift by diffing the served contract against AGENTS.md.
            //
            // Lint gate: THIS target's compiler warnings are errors. Scoped here via swiftSettings (not
            // a global `-Xswiftc -warnings-as-errors`) so a warning emitted by the swift-syntax
            // dependency on a future toolchain can't break our build — only our own code gates. The
            // compiler's diagnostics are the gate; swiftlint isn't a required dependency.
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        // Native unit tests over the extracted pure cores (XCTest ships with the toolchain — offline).
        .testTarget(
            name: "CandorCoreTests",
            dependencies: [
                "CandorCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"), // construct a TypeSyntax from a string
            ]
        ),
    ]
)
